//! Workspace state layer.
//!
//! Yardlet owns canonical state under `.agents/` in the target repo. This module
//! is the only place that reads and writes those files. Everything is durable
//! and readable without any previous chat context.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Local, Utc};

use serde::{Deserialize, Serialize};

use crate::planning::{PlanningCapabilityAudit, PlanningScoutCacheEntry};
use crate::schemas::{
    ActionReceipt, ActivatedIntent, ActivatedQueue, ActivatedTask, ActivationReceipt,
    ActivationRequirement, Answer, AnswerActionOutcome, AnswerActionRequest, Artifact,
    ArtifactProposal, AttemptState, BillingPolicy, ChannelActionKind, ChannelActionStatus,
    ChannelEvent, ChannelEventType, ContinuationMode, Conversation, ConversationTurn,
    DraftRevision, EventActor, EventActorKind, FollowUpTask, IntentContract, PlanningActionReceipt,
    PlanningEvent, PlanningProposal, PlanningSession, PreservedFollowUps, Question, QuestionState,
    RedirectActionOutcome, RedirectActionRequest, ResolvedWorkerSelection, ResourceActionReceipt,
    ResourceActionRecoveryReceipt, ResourceIndex, ResourceObservation, ResourceStatus,
    ResourceTaskIndex, RuntimeCapabilityCommit, RuntimeCapabilityReceipt, RuntimeResource,
    RuntimeResourceProposal, RuntimeTaskCommit, RuntimeTaskReceipt, SelectionPolicy, Task,
    TaskChannel, TaskChannelIndex, TaskState, TransitionActor, TransitionCause, TransitionLog,
    TransitionRecord, TurnRole, WorkQueue, WorkerAttempt, WorkersFile, YardConfig,
};
use crate::yaml;

pub const STATE_DIR: &str = ".agents";
/// Canonical config filename. `yard.yaml` is the pre-rename name, still read
/// (and written in place) for back-compat so existing workspaces keep working.
pub const CONFIG_FILE: &str = "yardlet.yaml";
pub const LEGACY_CONFIG_FILE: &str = "yard.yaml";
pub const CHANNEL_INDEX_EVENT_LIMIT: usize = 128;
pub const RESOURCE_INDEX_ENTRY_LIMIT: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TaskChannelIdentity {
    schema_version: u32,
    channel_id: String,
    session_id: String,
    intent_id: String,
    task_id: String,
}

/// A located Yardlet workspace: the directory that owns `.agents/`.
#[derive(Debug, Clone)]
pub struct Workspace {
    pub root: PathBuf,
}

/// Kernel-owned workspace lock for every conversational-planning mutation.
/// The descriptor lifetime is the transaction lifetime, and process exit
/// releases the lock without a stale PID cleanup protocol.
pub struct PlanningLock {
    #[cfg(unix)]
    file: fs::File,
    queue_snapshot: RefCell<Option<String>>,
}

struct RuntimeTaskPlacement {
    ordinal: usize,
    runs_before: Vec<String>,
}

#[cfg(unix)]
impl Drop for PlanningLock {
    fn drop(&mut self) {
        // SAFETY: `self.file` owns this descriptor until Drop finishes.
        let _ = unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&self.file), libc::LOCK_UN) };
    }
}

fn mutation_lock_timeout() -> Duration {
    #[cfg(debug_assertions)]
    if let Ok(value) = std::env::var("YARDLET_TEST_LOCK_TIMEOUT_MS") {
        if let Ok(milliseconds) = value.parse::<u64>() {
            return Duration::from_millis(milliseconds.max(1));
        }
    }
    Duration::from_secs(5)
}

fn wait_at_test_mutation_barrier() -> Result<()> {
    #[cfg(debug_assertions)]
    if let Ok(directory) = std::env::var("YARDLET_TEST_MUTATION_BARRIER") {
        let directory = PathBuf::from(directory);
        fs::create_dir_all(&directory)
            .with_context(|| format!("creating mutation barrier {}", directory.display()))?;
        let entered = directory.join("entered");
        write_str_atomic(&entered, &format!("{}\n", std::process::id()))?;
        let release = directory.join("release");
        let started = Instant::now();
        while !release.is_file() {
            if started.elapsed() >= Duration::from_secs(10) {
                bail!("test mutation barrier timed out at {}", directory.display());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntegrationProvenance {
    #[default]
    Unknown,
    SerialCoreStaged,
    ParallelWorkerDirect,
}

/// Core-owned receipt proving that a run used the serial staging boundary.
/// It lives outside the worker-writable canonical run directory so recovery
/// never has to trust a worker-authored `run.yaml` when selecting the native
/// Git transaction protocol.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SerialIntegrationReceipt {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub worktree: String,
    pub branch: String,
    pub baseline_oid: String,
}

/// Core-owned receipt for one successful merge. Cleanup recovery trusts this
/// record rather than the worker-writable run directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntegratedCleanupReceipt {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub intent_id: String,
    pub worker: String,
    pub worktree: String,
    pub branch: String,
    pub baseline_oid: String,
    pub integration_base_oid: String,
    pub integration_worker_oid: String,
    pub integration_oid: String,
    pub provenance: IntegrationProvenance,
    pub owned_oids: Vec<String>,
}

/// Core-owned proof that a run produced no Git changes and therefore needs no
/// push. It is persisted before deleting the isolated worktree so recovery can
/// reconstruct the `not_needed` finish outcome across either cleanup window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NoChangeReceipt {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub intent_id: String,
    pub worker: String,
    pub worktree: String,
    pub branch: String,
    pub baseline_oid: String,
    pub worker_oid: String,
    pub provenance: IntegrationProvenance,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PlanningWorkerConfig {
    #[serde(default = "default_auto")]
    pub planning_model: String,
    #[serde(default = "default_auto")]
    pub planning_effort: String,
}

impl Default for PlanningWorkerConfig {
    fn default() -> Self {
        Self {
            planning_model: default_auto(),
            planning_effort: default_auto(),
        }
    }
}

fn default_auto() -> String {
    "auto".to_string()
}

fn stable_digest_bytes(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn task_channel_id(intent_id: &str, task_id: &str) -> String {
    let input = format!("{intent_id}\0{task_id}");
    format!("chn_{}", stable_digest_bytes(input.as_bytes()))
}

pub(crate) fn validate_action_id(action_id: &str) -> Result<()> {
    let mut chars = action_id.chars();
    let safe = action_id.len() <= 128
        && chars.next().is_some_and(|ch| ch.is_ascii_alphanumeric())
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
        && Path::new(action_id).components().count() == 1
        && Path::new(action_id)
            .components()
            .all(|component| matches!(component, std::path::Component::Normal(_)));
    if !safe {
        bail!(
            "invalid action id '{action_id}': expected one portable identifier using letters, digits, '.', '_' or '-'"
        );
    }
    Ok(())
}

fn contained_action_path(actions_dir: &Path, filename: &str) -> Result<PathBuf> {
    let path = actions_dir.join(filename);
    if path.parent() != Some(actions_dir) {
        bail!("action receipt path escapes its canonical actions directory");
    }
    Ok(path)
}

fn channel_action_digest<T: Serialize>(value: &T) -> Result<String> {
    let bytes = serde_json::to_vec(value)?;
    Ok(format!("fnv1a64:{}", stable_digest_bytes(&bytes)))
}

impl Workspace {
    /// Walk up from `start` looking for an existing config file (the canonical
    /// `.agents/yardlet.yaml` or the legacy `.agents/yard.yaml`).
    pub fn discover(start: &Path) -> Option<Workspace> {
        let mut dir = Some(start);
        while let Some(d) = dir {
            let agents = d.join(STATE_DIR);
            if agents.join(CONFIG_FILE).is_file() || agents.join(LEGACY_CONFIG_FILE).is_file() {
                return Some(Workspace {
                    root: d.to_path_buf(),
                });
            }
            dir = d.parent();
        }
        None
    }

    /// The workspace rooted at `root`, whether or not it is initialized yet.
    pub fn at(root: &Path) -> Workspace {
        Workspace {
            root: root.to_path_buf(),
        }
    }

    pub fn agents_dir(&self) -> PathBuf {
        self.root.join(STATE_DIR)
    }

    pub fn task_channels_dir(&self) -> PathBuf {
        self.agents_dir().join("task-channels")
    }

    pub fn task_channel_dir(&self, intent_id: &str, task_id: &str) -> PathBuf {
        self.task_channels_dir()
            .join(task_channel_id(intent_id, task_id))
    }

    pub fn task_channel_index_path(&self, intent_id: &str, task_id: &str) -> PathBuf {
        self.task_channel_dir(intent_id, task_id).join("index.yaml")
    }

    pub fn resources_dir(&self) -> PathBuf {
        self.agents_dir().join("resources")
    }

    pub fn resource_index_path(&self) -> PathBuf {
        self.resources_dir().join("index.yaml")
    }

    fn artifacts_dir(&self) -> PathBuf {
        self.resources_dir().join("artifacts")
    }

    fn runtime_resources_dir(&self) -> PathBuf {
        self.resources_dir().join("runtime")
    }

    fn resource_observations_dir(&self, resource_id: &str) -> PathBuf {
        self.resources_dir().join("observations").join(resource_id)
    }

    fn resource_actions_dir(&self) -> PathBuf {
        self.resources_dir().join("actions")
    }

    pub fn is_initialized(&self) -> bool {
        self.agents_dir().join(CONFIG_FILE).is_file()
            || self.agents_dir().join(LEGACY_CONFIG_FILE).is_file()
    }

    /// The config file path. Prefers the canonical `yardlet.yaml`; falls back to
    /// the legacy `yard.yaml` when that is the file a workspace already has, so
    /// pre-rename workspaces are read and written in place rather than orphaned.
    /// A fresh workspace gets the canonical name.
    pub fn config_path(&self) -> PathBuf {
        let canonical = self.agents_dir().join(CONFIG_FILE);
        let legacy = self.agents_dir().join(LEGACY_CONFIG_FILE);
        if !canonical.is_file() && legacy.is_file() {
            legacy
        } else {
            canonical
        }
    }
    pub fn queue_path(&self) -> PathBuf {
        self.agents_dir().join("work-queue.yaml")
    }
    pub fn intent_path(&self) -> PathBuf {
        self.agents_dir().join("intent-contract.yaml")
    }
    pub fn workers_path(&self) -> PathBuf {
        self.agents_dir().join("workers.yaml")
    }
    pub fn conversations_dir(&self) -> PathBuf {
        self.agents_dir().join("conversations")
    }
    pub fn conversation_path(&self, task_id: &str) -> PathBuf {
        self.conversations_dir().join(format!("{task_id}.yaml"))
    }
    pub fn transitions_dir(&self) -> PathBuf {
        self.agents_dir().join("transitions")
    }
    pub fn transition_path(&self, task_id: &str) -> PathBuf {
        self.transitions_dir().join(format!("{task_id}.yaml"))
    }
    pub fn billing_path(&self) -> PathBuf {
        self.agents_dir().join("billing-policy.yaml")
    }
    pub fn runs_dir(&self) -> PathBuf {
        self.agents_dir().join("runs")
    }

    pub fn planning_sessions_dir(&self) -> PathBuf {
        self.agents_dir().join("planning-sessions")
    }

    pub fn planning_session_dir(&self, session_id: &str) -> PathBuf {
        self.planning_sessions_dir().join(session_id)
    }

    pub fn planning_session_path(&self, session_id: &str) -> PathBuf {
        self.planning_session_dir(session_id).join("session.yaml")
    }

    pub fn latest_planning_session_path(&self) -> PathBuf {
        self.planning_sessions_dir().join("latest")
    }

    pub fn planning_proposal_path(&self, session_id: &str, proposal_id: &str) -> PathBuf {
        self.planning_session_dir(session_id)
            .join("proposals")
            .join(format!("{proposal_id}.yaml"))
    }

    pub fn draft_revision_path(&self, session_id: &str, revision_id: &str) -> PathBuf {
        self.planning_session_dir(session_id)
            .join("drafts")
            .join(format!("{revision_id}.yaml"))
    }

    pub fn planning_event_path(&self, session_id: &str, seq: u64) -> PathBuf {
        self.planning_session_dir(session_id)
            .join("events")
            .join(format!("{seq:020}.yaml"))
    }

    pub fn planning_action_path(&self, session_id: &str, action_id: &str) -> PathBuf {
        self.planning_session_dir(session_id)
            .join("actions")
            .join(format!("{action_id}.yaml"))
    }

    pub fn planning_capability_audits_dir(&self, session_id: &str) -> PathBuf {
        self.planning_session_dir(session_id)
            .join("capability-audits")
    }

    pub fn planning_scout_cache_dir(&self, session_id: &str) -> PathBuf {
        self.planning_session_dir(session_id).join("scout-cache")
    }

    fn checked_planning_action_path(&self, session_id: &str, action_id: &str) -> Result<PathBuf> {
        validate_action_id(action_id)?;
        let actions_dir = self.planning_session_dir(session_id).join("actions");
        let path = self.planning_action_path(session_id, action_id);
        if path.parent() != Some(actions_dir.as_path()) {
            bail!("action receipt path escapes its canonical actions directory");
        }
        Ok(path)
    }

    pub fn activation_path(&self, confirmation_id: &str) -> PathBuf {
        self.agents_dir()
            .join("activations")
            .join(format!("{confirmation_id}.yaml"))
    }

    pub fn runtime_task_receipts_dir(&self) -> PathBuf {
        self.agents_dir().join("runtime-task-receipts")
    }

    pub fn runtime_task_receipt_path(&self, confirmation_id: &str, task_id: &str) -> PathBuf {
        self.runtime_task_receipts_dir()
            .join(format!("{task_id}--{confirmation_id}.yaml"))
    }

    pub fn runtime_task_commit_path(&self, confirmation_id: &str, task_id: &str) -> PathBuf {
        self.runtime_task_receipts_dir()
            .join(format!("{task_id}--{confirmation_id}.committed.yaml"))
    }

    pub fn runtime_capability_receipts_dir(&self) -> PathBuf {
        self.agents_dir().join("runtime-capability-receipts")
    }

    pub fn runtime_capability_receipt_path(&self, confirmation_id: &str, task_id: &str) -> PathBuf {
        self.runtime_capability_receipts_dir()
            .join(format!("{task_id}--{confirmation_id}.yaml"))
    }

    pub fn runtime_capability_commit_path(&self, confirmation_id: &str, task_id: &str) -> PathBuf {
        self.runtime_capability_receipts_dir()
            .join(format!("{task_id}--{confirmation_id}.committed.yaml"))
    }

    pub fn activation_requirement_path(&self) -> PathBuf {
        self.agents_dir().join("activation-required.yaml")
    }

    pub fn acquire_planning_lock(&self) -> Result<PlanningLock> {
        let path = self.agents_dir().join("planning.lock");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;

            let file = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .custom_flags(libc::O_CLOEXEC)
                .open(&path)
                .with_context(|| format!("opening planning lock {}", path.display()))?;
            let timeout = mutation_lock_timeout();
            let started = Instant::now();
            loop {
                // SAFETY: `file` stays alive in PlanningLock and flock only
                // reads its valid descriptor. LOCK_NB prevents an unbounded
                // wait; a crash releases the kernel-owned lock.
                if unsafe {
                    libc::flock(
                        std::os::fd::AsRawFd::as_raw_fd(&file),
                        libc::LOCK_EX | libc::LOCK_NB,
                    )
                } == 0
                {
                    break;
                }
                let error = std::io::Error::last_os_error();
                let retryable = error.raw_os_error().is_some_and(|code| {
                    code == libc::EINTR || code == libc::EAGAIN || code == libc::EWOULDBLOCK
                });
                if !retryable {
                    return Err(error)
                        .with_context(|| format!("locking planning workspace {}", path.display()));
                }
                if started.elapsed() >= timeout {
                    bail!(
                        "workspace_mutation_lock_timeout after {}ms at {}",
                        timeout.as_millis(),
                        path.display()
                    );
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let queue_snapshot = if self.queue_path().is_file() {
                Some(
                    fs::read_to_string(self.queue_path())
                        .with_context(|| format!("reading {}", self.queue_path().display()))?,
                )
            } else {
                None
            };
            let guard = PlanningLock {
                file,
                queue_snapshot: RefCell::new(queue_snapshot),
            };
            wait_at_test_mutation_barrier()?;
            Ok(guard)
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            let queue_snapshot = if self.queue_path().is_file() {
                Some(fs::read_to_string(self.queue_path())?)
            } else {
                None
            };
            Ok(PlanningLock {
                queue_snapshot: RefCell::new(queue_snapshot),
            })
        }
    }

    pub fn save_planning_session(&self, session: &PlanningSession) -> Result<()> {
        let path = self.planning_session_path(&session.session_id);
        fs::create_dir_all(
            self.planning_session_dir(&session.session_id)
                .join("events"),
        )
        .with_context(|| format!("creating initial event journal for {}", session.session_id))?;
        write_str_atomic(&path, &yaml::to_string(session)?)?;
        write_str_atomic(
            &self.latest_planning_session_path(),
            &format!("{}\n", session.session_id),
        )
    }

    pub fn save_planning_session_cas(
        &self,
        expected: &PlanningSession,
        session: &PlanningSession,
    ) -> Result<()> {
        let path = self.planning_session_path(&session.session_id);
        if expected.session_id != session.session_id {
            bail!("planning session CAS identity mismatch");
        }
        write_str_atomic_cas(
            &path,
            Some(&yaml::to_string(expected)?),
            &yaml::to_string(session)?,
        )
    }

    pub fn load_planning_session(&self, session_id: &str) -> Result<PlanningSession> {
        let session: PlanningSession = load_yaml(&self.planning_session_path(session_id))?;
        if session.session_id != session_id {
            bail!(
                "planning_session_corrupt: path session {session_id} contains identity {}",
                session.session_id
            );
        }
        Ok(session)
    }

    pub fn load_latest_planning_session(&self) -> Result<Option<PlanningSession>> {
        let pointer = self.latest_planning_session_path();
        if pointer.is_file() {
            let session_id = fs::read_to_string(&pointer)
                .with_context(|| format!("reading {}", pointer.display()))?;
            let session_id = session_id.trim();
            if !session_id.is_empty() {
                return self.load_planning_session(session_id).map(Some);
            }
            bail!("planning_session_corrupt: latest pointer is empty");
        }
        let sessions = self.planning_sessions_dir();
        if sessions.is_dir()
            && fs::read_dir(&sessions)
                .with_context(|| format!("reading {}", sessions.display()))?
                .filter_map(std::result::Result::ok)
                .any(|entry| entry.path().is_dir())
        {
            bail!("planning_session_corrupt: persisted sessions have no latest pointer");
        }
        Ok(None)
    }

    pub fn save_planning_proposal(&self, proposal: &PlanningProposal) -> Result<()> {
        save_immutable_yaml(
            &self.planning_proposal_path(&proposal.session_id, &proposal.proposal_id),
            proposal,
        )
    }

    pub fn load_planning_proposal(
        &self,
        session_id: &str,
        proposal_id: &str,
    ) -> Result<PlanningProposal> {
        load_yaml(&self.planning_proposal_path(session_id, proposal_id))
    }

    pub fn load_planning_proposals(&self, session_id: &str) -> Result<Vec<PlanningProposal>> {
        load_yaml_dir(&self.planning_session_dir(session_id).join("proposals"))
    }

    pub fn save_planning_capability_audit(&self, audit: &PlanningCapabilityAudit) -> Result<()> {
        if audit.session_id.trim().is_empty() || audit.attempt_id.trim().is_empty() {
            bail!("planning capability audit requires session and attempt identity");
        }
        let key = stable_record_key(&audit.attempt_id);
        save_immutable_yaml(
            &self
                .planning_capability_audits_dir(&audit.session_id)
                .join(format!("{key}.yaml")),
            audit,
        )
    }

    pub fn load_planning_capability_audits(
        &self,
        session_id: &str,
    ) -> Result<Vec<PlanningCapabilityAudit>> {
        let audits: Vec<PlanningCapabilityAudit> =
            load_yaml_dir(&self.planning_capability_audits_dir(session_id))?;
        if audits.iter().any(|audit| audit.session_id != session_id) {
            bail!("planning capability audit session identity mismatch");
        }
        Ok(audits)
    }

    pub fn load_planning_capability_audit_for_attempt(
        &self,
        session_id: &str,
        attempt_id: &str,
    ) -> Result<Option<PlanningCapabilityAudit>> {
        let matches = self
            .load_planning_capability_audits(session_id)?
            .into_iter()
            .filter(|audit| audit.attempt_id == attempt_id)
            .collect::<Vec<_>>();
        if matches.len() > 1 {
            bail!("planning capability audit attempt identity is ambiguous");
        }
        Ok(matches.into_iter().next())
    }

    pub fn save_planning_scout_cache(&self, entry: &PlanningScoutCacheEntry) -> Result<()> {
        if entry.session_id.trim().is_empty()
            || entry.intent_id.trim().is_empty()
            || entry.topic_key.trim().is_empty()
        {
            bail!("planning scout cache requires session, intent, and topic identity");
        }
        save_immutable_yaml(
            &self
                .planning_scout_cache_dir(&entry.session_id)
                .join(format!("{}.yaml", stable_record_key(&entry.topic_key))),
            entry,
        )
    }

    pub fn load_fresh_planning_scout_cache(
        &self,
        session_id: &str,
        intent_id: &str,
        topic_key: &str,
        now: &str,
        ttl_days: u32,
    ) -> Result<Option<PlanningScoutCacheEntry>> {
        let path = self
            .planning_scout_cache_dir(session_id)
            .join(format!("{}.yaml", stable_record_key(topic_key)));
        if !path.is_file() {
            return Ok(None);
        }
        let entry: PlanningScoutCacheEntry = load_yaml(&path)?;
        if entry.session_id != session_id
            || entry.intent_id != intent_id
            || entry.topic_key != topic_key
        {
            return Ok(None);
        }
        let recorded = entry.recorded_at.parse::<DateTime<Utc>>()?;
        let now = now.parse::<DateTime<Utc>>()?;
        let ttl = chrono::Duration::days(i64::from(ttl_days));
        Ok((now >= recorded && now - recorded <= ttl).then_some(entry))
    }

    pub fn load_research_policy(&self) -> Result<crate::schemas::ResearchPolicy> {
        let path = self.agents_dir().join("research-policy.yaml");
        if path.is_file() {
            let text =
                fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
            return crate::templates::parse_research_policy(&text)
                .with_context(|| format!("parsing {}", path.display()));
        }
        Ok(crate::templates::research_policy())
    }

    pub fn save_draft_revision(&self, revision: &DraftRevision) -> Result<()> {
        save_immutable_yaml(
            &self.draft_revision_path(&revision.session_id, &revision.draft_revision_id),
            revision,
        )
    }

    pub fn load_draft_revision(
        &self,
        session_id: &str,
        revision_id: &str,
    ) -> Result<DraftRevision> {
        load_yaml(&self.draft_revision_path(session_id, revision_id))
    }

    pub fn save_planning_event(&self, event: &PlanningEvent) -> Result<()> {
        save_immutable_yaml(
            &self.planning_event_path(&event.session_id, event.seq),
            event,
        )
    }

    pub fn load_planning_events(&self, session_id: &str) -> Result<Vec<PlanningEvent>> {
        let dir = self.planning_session_dir(session_id).join("events");
        if !dir.is_dir() {
            bail!("planning_session_corrupt: event journal directory is missing");
        }
        let mut events = Vec::new();
        for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
            let path = entry?.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                bail!("planning_event_journal: non-UTF8 event filename");
            };
            if name.starts_with('.') {
                continue;
            }
            let Some(stem) = name.strip_suffix(".yaml") else {
                bail!("planning_event_journal: unexpected event file {name}");
            };
            let seq = stem.parse::<u64>().map_err(|_| {
                anyhow::anyhow!("planning_event_journal: invalid event filename {name}")
            })?;
            if name != format!("{seq:020}.yaml") {
                bail!("planning_event_journal: non-canonical event filename {name}");
            }
            let event: PlanningEvent = load_yaml(&path)?;
            if event.seq != seq || event.session_id != session_id || event.event_id.is_empty() {
                bail!("planning_event_journal: filename/seq/session/event id identity mismatch");
            }
            events.push(event);
        }
        events.sort_by_key(|event| event.seq);
        let mut event_ids = BTreeSet::new();
        let mut exact_payloads = BTreeSet::new();
        let mut action_types = BTreeMap::new();
        for (index, event) in events.iter().enumerate() {
            let expected_seq = index as u64 + 1;
            if event.seq != expected_seq {
                bail!(
                    "planning_event_journal: expected contiguous seq {expected_seq}, found {}",
                    event.seq
                );
            }
            if !event_ids.insert(event.event_id.clone()) {
                bail!(
                    "planning_event_journal: duplicate event id {}",
                    event.event_id
                );
            }
            let payload = serde_json::to_string(event)?;
            if !exact_payloads.insert(payload) {
                bail!("planning_event_journal: duplicate exact event payload");
            }
            if !event.action_id.is_empty() {
                let key = (event.action_id.clone(), format!("{:?}", event.event_type));
                if action_types.insert(key, event.event_id.clone()).is_some() {
                    bail!("planning_event_journal: action/type cardinality violation");
                }
            }
        }
        let session = self.load_planning_session(session_id)?;
        let journal_next = events.last().map_or(1, |event| event.seq + 1);
        if session.next_seq == 0 || session.next_seq > journal_next {
            bail!(
                "planning_event_journal: next_seq {} is ahead of journal next {journal_next}",
                session.next_seq
            );
        }
        if events.is_empty() {
            let has_artifacts = ["actions", "drafts", "proposals"].iter().try_fold(
                false,
                |found, child| -> Result<bool> {
                    if found {
                        return Ok(true);
                    }
                    let child = self.planning_session_dir(session_id).join(child);
                    if !child.is_dir() {
                        return Ok(false);
                    }
                    Ok(fs::read_dir(&child)
                        .with_context(|| format!("reading {}", child.display()))?
                        .filter_map(std::result::Result::ok)
                        .any(|entry| entry.path().extension().is_some_and(|ext| ext == "yaml")))
                },
            )?;
            if session.next_seq != 1
                || session.lifecycle != crate::schemas::PlanningLifecycle::Open
                || session.current_head.is_some()
                || session.confirmation_id.is_some()
                || has_artifacts
            {
                bail!("planning_session_corrupt: empty journal is not a fresh initial state");
            }
        }
        Ok(events)
    }

    pub fn load_planning_actions(&self, session_id: &str) -> Result<Vec<PlanningActionReceipt>> {
        let dir = self.planning_session_dir(session_id).join("actions");
        if !dir.is_dir() {
            return Ok(Vec::new());
        }
        let mut actions = Vec::new();
        for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
            let path = entry?.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                bail!("planning action filename is not UTF-8");
            };
            if name.starts_with('.') {
                continue;
            }
            let Some(action_id) = name.strip_suffix(".yaml") else {
                bail!("unexpected planning action file {name}");
            };
            let receipt: PlanningActionReceipt = load_yaml(&path)?;
            if receipt.session_id != session_id || receipt.action_id != action_id {
                bail!("planning action path identity mismatch");
            }
            actions.push(receipt);
        }
        actions.sort_by(|left, right| left.action_id.cmp(&right.action_id));
        Ok(actions)
    }

    pub fn create_planning_action(&self, receipt: &PlanningActionReceipt) -> Result<()> {
        let path = self.checked_planning_action_path(&receipt.session_id, &receipt.action_id)?;
        save_immutable_yaml(&path, receipt)
    }

    pub fn save_planning_action_cas(
        &self,
        expected: &PlanningActionReceipt,
        receipt: &PlanningActionReceipt,
    ) -> Result<()> {
        if expected.session_id != receipt.session_id || expected.action_id != receipt.action_id {
            bail!("planning action CAS identity mismatch");
        }
        let path = self.checked_planning_action_path(&receipt.session_id, &receipt.action_id)?;
        write_str_atomic_cas(
            &path,
            Some(&yaml::to_string(expected)?),
            &yaml::to_string(receipt)?,
        )
    }

    pub fn load_planning_action(
        &self,
        session_id: &str,
        action_id: &str,
    ) -> Result<Option<PlanningActionReceipt>> {
        let path = self.checked_planning_action_path(session_id, action_id)?;
        if !path.is_file() {
            return Ok(None);
        }
        load_yaml(&path).map(Some)
    }

    pub fn save_activated_intent_snapshot(&self, intent: &ActivatedIntent) -> Result<()> {
        write_str_atomic(&self.intent_path(), &yaml::to_string(intent)?)
    }

    pub fn save_activated_queue_snapshot_locked(
        &self,
        lock: &PlanningLock,
        queue: &ActivatedQueue,
    ) -> Result<()> {
        let expected = lock.queue_snapshot.borrow().clone();
        let text = yaml::to_string(queue)?;
        write_str_atomic_cas(&self.queue_path(), expected.as_deref(), &text)?;
        *lock.queue_snapshot.borrow_mut() = Some(text);
        Ok(())
    }

    pub fn load_active_snapshot_texts(&self) -> Result<(Option<String>, Option<String>)> {
        fn read_optional(path: &Path) -> Result<Option<String>> {
            if !path.is_file() {
                return Ok(None);
            }
            fs::read_to_string(path)
                .with_context(|| format!("reading {}", path.display()))
                .map(Some)
        }
        Ok((
            read_optional(&self.intent_path())?,
            read_optional(&self.queue_path())?,
        ))
    }

    pub fn load_activated_intent(&self) -> Result<Option<ActivatedIntent>> {
        let path = self.intent_path();
        if !path.is_file() {
            return Ok(None);
        }
        load_yaml(&path).map(Some)
    }

    pub fn load_activated_queue(&self) -> Result<Option<ActivatedQueue>> {
        let path = self.queue_path();
        if !path.is_file() {
            return Ok(None);
        }
        load_yaml(&path).map(Some)
    }

    /// Detect durable V010 planning evidence that belongs to the active ids.
    /// This discriminator is independent of the mutable active snapshots, so
    /// deleting every provenance field from those snapshots cannot make a
    /// confirmed plan look like a legacy v1 intent/queue pair.
    pub fn has_matching_modern_planning_evidence(
        &self,
        intent_id: &str,
        queue_id: &str,
    ) -> Result<bool> {
        if intent_id.is_empty() && queue_id.is_empty() {
            return Ok(false);
        }

        let activations = self.agents_dir().join("activations");
        if activations.is_dir() {
            for entry in fs::read_dir(&activations)
                .with_context(|| format!("reading {}", activations.display()))?
            {
                let path = entry?.path();
                if path.extension().and_then(|extension| extension.to_str()) != Some("yaml") {
                    continue;
                }
                let activation: ActivationReceipt = load_yaml(&path)?;
                if (intent_id.is_empty() || activation.intent_id == intent_id)
                    && (queue_id.is_empty() || activation.queue_id == queue_id)
                {
                    return Ok(true);
                }
            }
        }

        let sessions = self.planning_sessions_dir();
        if !sessions.is_dir() {
            return Ok(false);
        }
        for entry in
            fs::read_dir(&sessions).with_context(|| format!("reading {}", sessions.display()))?
        {
            let session_dir = entry?.path();
            if !session_dir.is_dir() {
                continue;
            }
            let session_path = session_dir.join("session.yaml");
            if session_path.is_file() {
                let session: PlanningSession = load_yaml(&session_path)?;
                if (intent_id.is_empty() || session.intent_id == intent_id)
                    && (queue_id.is_empty() || session.queue_id == queue_id)
                {
                    return Ok(true);
                }
            }
            let drafts = session_dir.join("drafts");
            if !drafts.is_dir() {
                continue;
            }
            for draft in
                fs::read_dir(&drafts).with_context(|| format!("reading {}", drafts.display()))?
            {
                let path = draft?.path();
                if path.extension().and_then(|extension| extension.to_str()) != Some("yaml") {
                    continue;
                }
                let revision: DraftRevision = load_yaml(&path)?;
                if (intent_id.is_empty() || revision.content.intent.id == intent_id)
                    && (queue_id.is_empty() || revision.content.queue.queue_id == queue_id)
                {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }

    pub fn save_activation(&self, activation: &ActivationReceipt) -> Result<()> {
        save_immutable_yaml(
            &self.activation_path(&activation.confirmation_id),
            activation,
        )
    }

    pub fn load_activation(&self, confirmation_id: &str) -> Result<Option<ActivationReceipt>> {
        let path = self.activation_path(confirmation_id);
        if !path.is_file() {
            return Ok(None);
        }
        load_yaml(&path).map(Some)
    }

    pub fn load_runtime_task_receipt(
        &self,
        confirmation_id: &str,
        task_id: &str,
    ) -> Result<Option<RuntimeTaskReceipt>> {
        if !Self::runtime_receipt_id_is_safe(confirmation_id)
            || !Self::runtime_receipt_id_is_safe(task_id)
        {
            bail!("active_runtime_origin_mismatch: unsafe receipt path identity");
        }
        let path = self.runtime_task_receipt_path(confirmation_id, task_id);
        if !path.is_file() {
            return Ok(None);
        }
        let receipt: RuntimeTaskReceipt = load_yaml(&path)?;
        if receipt.confirmation_id != confirmation_id || receipt.task_id != task_id {
            bail!("active_runtime_origin_mismatch: receipt path identity mismatch");
        }
        Ok(Some(receipt))
    }

    fn runtime_receipt_id_is_safe(value: &str) -> bool {
        !value.is_empty()
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    }

    fn runtime_record_digest<T: serde::Serialize>(value: &T) -> Result<String> {
        let bytes = serde_json::to_vec(value)?;
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in bytes {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Ok(format!("fnv1a64:{hash:016x}"))
    }

    fn runtime_queue_digest(queue: &ActivatedQueue) -> Result<String> {
        Self::runtime_record_digest(queue)
    }

    fn load_runtime_task_commit(
        &self,
        confirmation_id: &str,
        task_id: &str,
    ) -> Result<Option<RuntimeTaskCommit>> {
        if !Self::runtime_receipt_id_is_safe(confirmation_id)
            || !Self::runtime_receipt_id_is_safe(task_id)
        {
            bail!("active_runtime_origin_mismatch: unsafe commit path identity");
        }
        let path = self.runtime_task_commit_path(confirmation_id, task_id);
        if !path.is_file() {
            return Ok(None);
        }
        let commit: RuntimeTaskCommit = load_yaml(&path)?;
        if commit.confirmation_id != confirmation_id || commit.task_id != task_id {
            bail!("active_runtime_origin_mismatch: commit path identity mismatch");
        }
        Ok(Some(commit))
    }

    fn validate_runtime_task_receipt_record(
        &self,
        queue: &ActivatedQueue,
        receipt: &RuntimeTaskReceipt,
    ) -> Result<()> {
        let receipt_digest = receipt.task.runtime_contract_digest()?;
        let expected_action_id = format!("runtime-task:{}:{}", receipt.origin, receipt.task_id);
        let mut targets = BTreeSet::new();
        if receipt.schema_version != 1
            || receipt.confirmation_id != queue.confirmation_id
            || receipt.intent_id != queue.intent_id
            || receipt.queue_id != queue.queue_id
            || !Self::runtime_receipt_id_is_safe(&receipt.task_id)
            || !matches!(receipt.origin.as_str(), "user-added" | "worker-proposed")
            || receipt.origin_action_id != expected_action_id
            || receipt.task_contract_digest != receipt_digest
            || receipt.task.id != receipt.task_id
            || receipt.task.provenance != receipt.origin
            || receipt.queue_digest_after.is_empty()
            || receipt.recorded_at.is_empty()
            || receipt.runs_before.iter().any(|target| {
                !Self::runtime_receipt_id_is_safe(target)
                    || target == &receipt.task_id
                    || !targets.insert(target)
            })
        {
            bail!(
                "active_runtime_origin_mismatch: task {} does not match its immutable origin receipt",
                receipt.task_id
            );
        }
        Ok(())
    }

    fn validate_runtime_task_receipt_identity(
        &self,
        queue: &ActivatedQueue,
        task: &ActivatedTask,
        receipt: &RuntimeTaskReceipt,
    ) -> Result<()> {
        self.validate_runtime_task_receipt_record(queue, receipt)?;
        if receipt.task_id != task.task.id || receipt.origin != task.task.provenance {
            bail!(
                "active_runtime_origin_mismatch: task {} does not match its immutable origin receipt",
                task.task.id
            );
        }
        Ok(())
    }

    fn validate_runtime_task_receipt(
        &self,
        queue: &ActivatedQueue,
        task: &ActivatedTask,
        receipt: &RuntimeTaskReceipt,
        dependency_additions: &[String],
        capability_clear: bool,
        selection: Option<&ResolvedWorkerSelection>,
    ) -> Result<()> {
        self.validate_runtime_task_receipt_identity(queue, task, receipt)?;
        let mut expected_dependencies = receipt.task.depends_on.clone();
        expected_dependencies.extend(dependency_additions.iter().cloned());
        let mut normalized = if let Some(selection) = selection {
            selection
                .normalized_runtime_overlay(&receipt.task, &task.task)
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "active_runtime_origin_mismatch: task {} has an invalid dispatch selection overlay",
                        task.task.id
                    )
                })?
        } else {
            task.task.clone()
        };
        normalized.depends_on = receipt.task.depends_on.clone();
        if capability_clear {
            if receipt.task.required_capabilities.is_empty()
                || !task.task.required_capabilities.is_empty()
            {
                bail!(
                    "active_runtime_capability_mismatch: task {} does not match its capability receipt",
                    task.task.id
                );
            }
            normalized.required_capabilities = receipt.task.required_capabilities.clone();
        }
        if task.task.depends_on != expected_dependencies
            || normalized.runtime_contract_digest()? != receipt.task_contract_digest
        {
            bail!(
                "active_runtime_origin_mismatch: task {} does not match its immutable origin receipt",
                task.task.id
            );
        }
        Ok(())
    }

    fn ensure_runtime_task_receipt(
        &self,
        queue: &ActivatedQueue,
        active_before: &ActivatedQueue,
        task: &ActivatedTask,
        baseline_task: &Task,
        placement: RuntimeTaskPlacement,
        queue_digest_after: &str,
    ) -> Result<()> {
        let RuntimeTaskPlacement {
            ordinal,
            runs_before,
        } = placement;
        if let Some(receipt) =
            self.load_runtime_task_receipt(&queue.confirmation_id, &task.task.id)?
        {
            self.validate_runtime_task_receipt_record(queue, &receipt)?;
            let exact = receipt.ordinal == ordinal
                && receipt.runs_before == runs_before
                && receipt.queue_digest_after == queue_digest_after
                && receipt.origin == task.task.provenance
                && receipt.task.runtime_contract_digest()?
                    == baseline_task.runtime_contract_digest()?;
            if exact {
                self.validate_runtime_task_receipt_identity(queue, task, &receipt)?;
                return Ok(());
            }
            let effect_absent = active_before.confirmation_id == queue.confirmation_id
                && !active_before
                    .tasks
                    .iter()
                    .any(|active| active.task.id == task.task.id);
            if self
                .load_runtime_task_commit(&queue.confirmation_id, &task.task.id)?
                .is_some()
                || !effect_absent
            {
                bail!(
                    "active_runtime_origin_mismatch: task {} conflicts with its prepared origin receipt",
                    task.task.id
                );
            }
            fs::remove_file(self.runtime_task_receipt_path(&queue.confirmation_id, &task.task.id))
                .with_context(|| {
                    format!(
                        "superseding uncommitted runtime task receipt for {}",
                        task.task.id
                    )
                })?;
        }
        let digest = baseline_task.runtime_contract_digest()?;
        let receipt = RuntimeTaskReceipt {
            schema_version: 1,
            confirmation_id: queue.confirmation_id.clone(),
            intent_id: queue.intent_id.clone(),
            queue_id: queue.queue_id.clone(),
            task_id: task.task.id.clone(),
            origin: task.task.provenance.clone(),
            origin_action_id: format!("runtime-task:{}:{}", task.task.provenance, task.task.id),
            ordinal,
            runs_before,
            task_contract_digest: digest,
            task: baseline_task.clone(),
            queue_digest_after: queue_digest_after.to_string(),
            recorded_at: Local::now().to_rfc3339(),
        };
        self.validate_runtime_task_receipt_identity(queue, task, &receipt)?;
        save_immutable_yaml(
            &self.runtime_task_receipt_path(&queue.confirmation_id, &task.task.id),
            &receipt,
        )
    }

    fn commit_runtime_task_receipt(&self, confirmation_id: &str, task_id: &str) -> Result<()> {
        let receipt = self
            .load_runtime_task_receipt(confirmation_id, task_id)?
            .ok_or_else(|| {
                anyhow::anyhow!("active_runtime_origin_mismatch: missing prepared receipt")
            })?;
        save_immutable_yaml(
            &self.runtime_task_commit_path(confirmation_id, task_id),
            &RuntimeTaskCommit {
                schema_version: 1,
                confirmation_id: confirmation_id.to_string(),
                task_id: task_id.to_string(),
                ordinal: receipt.ordinal,
                receipt_digest: Self::runtime_record_digest(&receipt)?,
                committed_at: receipt.recorded_at.clone(),
            },
        )
    }

    fn repair_runtime_task_commits(&self, queue: &ActivatedQueue) -> Result<()> {
        let queue_digest = Self::runtime_queue_digest(queue)?;
        for task in queue
            .tasks
            .iter()
            .filter(|task| task.materialized_by_confirmation_id.is_empty())
        {
            if self
                .load_runtime_task_commit(&queue.confirmation_id, &task.task.id)?
                .is_some()
            {
                continue;
            }
            let receipt = self
                .load_runtime_task_receipt(&queue.confirmation_id, &task.task.id)?
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "active_runtime_origin_mismatch: task {} has no immutable origin receipt",
                        task.task.id
                    )
                })?;
            self.validate_runtime_task_receipt_identity(queue, task, &receipt)?;
            if receipt.queue_digest_after != queue_digest {
                bail!(
                    "active_runtime_origin_mismatch: task {} has an uncommitted origin receipt",
                    task.task.id
                );
            }
            self.commit_runtime_task_receipt(&queue.confirmation_id, &task.task.id)?;
        }
        Ok(())
    }

    fn committed_runtime_tasks(
        &self,
        queue: &ActivatedQueue,
    ) -> Result<Vec<(RuntimeTaskCommit, RuntimeTaskReceipt)>> {
        let Ok(entries) = fs::read_dir(self.runtime_task_receipts_dir()) else {
            return Ok(Vec::new());
        };
        let mut records = Vec::new();
        let current_suffix = format!("--{}.committed.yaml", queue.confirmation_id);
        for entry in entries {
            let path = entry?.path();
            if !path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(&current_suffix))
            {
                continue;
            }
            let commit: RuntimeTaskCommit = load_yaml(&path)?;
            if commit.confirmation_id != queue.confirmation_id {
                continue;
            }
            if path != self.runtime_task_commit_path(&commit.confirmation_id, &commit.task_id) {
                bail!("active_runtime_origin_mismatch: commit path identity mismatch");
            }
            let receipt = self
                .load_runtime_task_receipt(&commit.confirmation_id, &commit.task_id)?
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "active_runtime_origin_mismatch: committed task {} has no receipt",
                        commit.task_id
                    )
                })?;
            if commit.schema_version != 1
                || commit.ordinal != receipt.ordinal
                || commit.receipt_digest != Self::runtime_record_digest(&receipt)?
                || commit.committed_at.is_empty()
            {
                bail!(
                    "active_runtime_origin_mismatch: committed task {} has an invalid commit marker",
                    commit.task_id
                );
            }
            records.push((commit, receipt));
        }
        records.sort_by_key(|(commit, _)| commit.ordinal);
        Ok(records)
    }

    fn load_runtime_capability_receipt(
        &self,
        confirmation_id: &str,
        task_id: &str,
    ) -> Result<Option<RuntimeCapabilityReceipt>> {
        if !Self::runtime_receipt_id_is_safe(confirmation_id)
            || !Self::runtime_receipt_id_is_safe(task_id)
        {
            bail!("active_runtime_capability_mismatch: unsafe receipt path identity");
        }
        let path = self.runtime_capability_receipt_path(confirmation_id, task_id);
        if !path.is_file() {
            return Ok(None);
        }
        let receipt: RuntimeCapabilityReceipt = load_yaml(&path)?;
        if receipt.confirmation_id != confirmation_id || receipt.task_id != task_id {
            bail!("active_runtime_capability_mismatch: receipt path identity mismatch");
        }
        Ok(Some(receipt))
    }

    fn load_runtime_capability_commit(
        &self,
        confirmation_id: &str,
        task_id: &str,
    ) -> Result<Option<RuntimeCapabilityCommit>> {
        if !Self::runtime_receipt_id_is_safe(confirmation_id)
            || !Self::runtime_receipt_id_is_safe(task_id)
        {
            bail!("active_runtime_capability_mismatch: unsafe commit path identity");
        }
        let path = self.runtime_capability_commit_path(confirmation_id, task_id);
        if !path.is_file() {
            return Ok(None);
        }
        let commit: RuntimeCapabilityCommit = load_yaml(&path)?;
        if commit.confirmation_id != confirmation_id || commit.task_id != task_id {
            bail!("active_runtime_capability_mismatch: commit path identity mismatch");
        }
        Ok(Some(commit))
    }

    fn validate_runtime_capability_receipt_record(
        &self,
        queue: &ActivatedQueue,
        receipt: &RuntimeCapabilityReceipt,
    ) -> Result<()> {
        let expected_action_id = format!("runtime-capability:stale-decision:{}", receipt.task_id);
        const QUESTION_PREFIX: &str = "This task needs your decision before Yardlet can run it: ";
        const QUESTION_SUFFIX: &str = ". Reply with the decision or instructions to proceed.";
        let question_subject = receipt
            .decision_question
            .strip_prefix(QUESTION_PREFIX)
            .and_then(|question| question.strip_suffix(QUESTION_SUFFIX))
            .map(str::trim)
            .filter(|question| !question.is_empty());
        if receipt.schema_version != 1
            || receipt.confirmation_id != queue.confirmation_id
            || receipt.intent_id != queue.intent_id
            || receipt.queue_id != queue.queue_id
            || !Self::runtime_receipt_id_is_safe(&receipt.task_id)
            || receipt.action != "stale-capability-decision"
            || receipt.action_id != expected_action_id
            || receipt.target_state != TaskState::NeedsUser
            || question_subject.is_none()
            || receipt.original_required_capabilities.is_empty()
            || !receipt.replacement_required_capabilities.is_empty()
            || receipt.queue_digest_after.is_empty()
            || !matches!(
                crate::routing::classify_stale_gate(&receipt.original_required_capabilities),
                crate::routing::GateShape::Decision
            )
            || receipt.recorded_at.is_empty()
        {
            bail!(
                "active_runtime_capability_mismatch: task {} has an invalid capability receipt",
                receipt.task_id
            );
        }
        Ok(())
    }

    fn validate_runtime_capability_receipt(
        &self,
        queue: &ActivatedQueue,
        planned: &Task,
        receipt: &RuntimeCapabilityReceipt,
    ) -> Result<()> {
        self.validate_runtime_capability_receipt_record(queue, receipt)?;
        let expected_question = format!(
            "This task needs your decision before Yardlet can run it: {}. Reply with the decision or instructions to proceed.",
            planned.title
        );
        if receipt.task_id != planned.id
            || receipt.decision_question != expected_question
            || receipt.original_required_capabilities != planned.required_capabilities
        {
            bail!(
                "active_runtime_capability_mismatch: task {} has an invalid capability receipt",
                planned.id
            );
        }
        Ok(())
    }

    fn ensure_runtime_capability_receipt(
        &self,
        queue: &ActivatedQueue,
        active_before: &ActivatedQueue,
        planned: &Task,
        current: &Task,
        queue_digest_after: &str,
    ) -> Result<()> {
        if current.state != TaskState::NeedsUser
            || !current.required_capabilities.is_empty()
            || planned.required_capabilities.is_empty()
        {
            bail!(
                "active_runtime_capability_mismatch: task {} is not a stale decision migration",
                current.id
            );
        }
        let receipt = RuntimeCapabilityReceipt {
            schema_version: 1,
            confirmation_id: queue.confirmation_id.clone(),
            intent_id: queue.intent_id.clone(),
            queue_id: queue.queue_id.clone(),
            task_id: current.id.clone(),
            action: "stale-capability-decision".to_string(),
            action_id: format!("runtime-capability:stale-decision:{}", current.id),
            target_state: TaskState::NeedsUser,
            decision_question: format!(
                "This task needs your decision before Yardlet can run it: {}. Reply with the decision or instructions to proceed.",
                planned.title
            ),
            original_required_capabilities: planned.required_capabilities.clone(),
            replacement_required_capabilities: Vec::new(),
            queue_digest_after: queue_digest_after.to_string(),
            recorded_at: Local::now().to_rfc3339(),
        };
        if let Some(existing) =
            self.load_runtime_capability_receipt(&queue.confirmation_id, &current.id)?
        {
            self.validate_runtime_capability_receipt_record(queue, &existing)?;
            // `recorded_at` is intentionally immutable. Compare the contract
            // fields after preserving an existing valid timestamp.
            let mut expected = receipt.clone();
            expected.recorded_at = existing.recorded_at.clone();
            if Self::runtime_record_digest(&existing)? == Self::runtime_record_digest(&expected)? {
                self.validate_runtime_capability_receipt(queue, planned, &existing)?;
                return Ok(());
            }
            let effect_absent = active_before.confirmation_id == queue.confirmation_id
                && active_before
                    .tasks
                    .iter()
                    .find(|active| active.task.id == current.id)
                    .map(|active| {
                        active.task.required_capabilities == planned.required_capabilities
                    })
                    .unwrap_or(true);
            if self
                .load_runtime_capability_commit(&queue.confirmation_id, &current.id)?
                .is_some()
                || !effect_absent
            {
                bail!(
                    "active_runtime_capability_mismatch: task {} conflicts with its capability receipt",
                    current.id
                );
            }
            fs::remove_file(
                self.runtime_capability_receipt_path(&queue.confirmation_id, &current.id),
            )
            .with_context(|| {
                format!(
                    "superseding uncommitted runtime capability receipt for {}",
                    current.id
                )
            })?;
        }
        self.validate_runtime_capability_receipt(queue, planned, &receipt)?;
        save_immutable_yaml(
            &self.runtime_capability_receipt_path(&queue.confirmation_id, &current.id),
            &receipt,
        )
    }

    fn commit_runtime_capability_receipt(
        &self,
        confirmation_id: &str,
        task_id: &str,
    ) -> Result<()> {
        let receipt = self
            .load_runtime_capability_receipt(confirmation_id, task_id)?
            .ok_or_else(|| {
                anyhow::anyhow!("active_runtime_capability_mismatch: missing prepared receipt")
            })?;
        save_immutable_yaml(
            &self.runtime_capability_commit_path(confirmation_id, task_id),
            &RuntimeCapabilityCommit {
                schema_version: 1,
                confirmation_id: confirmation_id.to_string(),
                task_id: task_id.to_string(),
                receipt_digest: Self::runtime_record_digest(&receipt)?,
                committed_at: receipt.recorded_at.clone(),
            },
        )
    }

    pub fn runtime_capability_decision_question(&self, task_id: &str) -> Result<Option<String>> {
        let Some(queue) = self.load_activated_queue()? else {
            return Ok(None);
        };
        if queue.confirmation_id.is_empty() {
            return Ok(None);
        }
        self.validate_activated_queue_runtime(&queue)?;
        let baselines = self.runtime_contract_baselines(&queue)?;
        let Some(baseline) = baselines.get(task_id) else {
            return Ok(None);
        };
        let Some(receipt) =
            self.load_runtime_capability_receipt(&queue.confirmation_id, task_id)?
        else {
            return Ok(None);
        };
        self.validate_runtime_capability_receipt(&queue, baseline, &receipt)?;
        let Some(commit) = self.load_runtime_capability_commit(&queue.confirmation_id, task_id)?
        else {
            return Ok(None);
        };
        if commit.schema_version != 1
            || commit.receipt_digest != Self::runtime_record_digest(&receipt)?
            || commit.committed_at.is_empty()
        {
            bail!(
                "active_runtime_capability_mismatch: task {} has an invalid commit marker",
                task_id
            );
        }
        Ok(Some(receipt.decision_question))
    }

    fn runtime_contract_baselines(&self, queue: &ActivatedQueue) -> Result<BTreeMap<String, Task>> {
        let mut baselines = queue
            .materialized_queue
            .as_ref()
            .ok_or_else(|| {
                anyhow::anyhow!("active_runtime_envelope_mismatch: materialized queue is missing")
            })?
            .tasks
            .iter()
            .cloned()
            .map(|task| (task.id.clone(), task))
            .collect::<BTreeMap<_, _>>();
        for task in queue
            .tasks
            .iter()
            .filter(|task| task.materialized_by_confirmation_id.is_empty())
        {
            let receipt = self
                .load_runtime_task_receipt(&queue.confirmation_id, &task.task.id)?
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "active_runtime_origin_mismatch: task {} has no immutable origin receipt",
                        task.task.id
                    )
                })?;
            self.validate_runtime_task_receipt_identity(queue, task, &receipt)?;
            baselines.insert(task.task.id.clone(), receipt.task);
        }
        Ok(baselines)
    }

    fn receipted_runtime_selections(
        &self,
        queue: &ActivatedQueue,
        baselines: &BTreeMap<String, Task>,
    ) -> BTreeMap<String, ResolvedWorkerSelection> {
        queue
            .tasks
            .iter()
            .filter_map(|task| {
                let baseline = baselines.get(&task.task.id)?;
                let selection = ResolvedWorkerSelection::from_task(&task.task)?;
                selection.normalized_runtime_overlay(baseline, &task.task)?;
                crate::run::has_receipted_runtime_selection(
                    self,
                    &queue.intent_id,
                    &task.task.id,
                    &selection,
                )
                .then(|| (task.task.id.clone(), selection))
            })
            .collect()
    }

    fn repair_runtime_capability_commits(&self, queue: &ActivatedQueue) -> Result<()> {
        let queue_digest = Self::runtime_queue_digest(queue)?;
        let baselines = self.runtime_contract_baselines(queue)?;
        for task in &queue.tasks {
            let Some(baseline) = baselines.get(&task.task.id) else {
                continue;
            };
            if task.task.required_capabilities == baseline.required_capabilities {
                continue;
            }
            if self
                .load_runtime_capability_commit(&queue.confirmation_id, &task.task.id)?
                .is_some()
            {
                continue;
            }
            let receipt = self
                .load_runtime_capability_receipt(&queue.confirmation_id, &task.task.id)?
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "active_runtime_capability_mismatch: task {} has no capability receipt",
                        task.task.id
                    )
                })?;
            self.validate_runtime_capability_receipt(queue, baseline, &receipt)?;
            if receipt.queue_digest_after != queue_digest {
                bail!(
                    "active_runtime_capability_mismatch: task {} has an uncommitted capability receipt",
                    task.task.id
                );
            }
            self.commit_runtime_capability_receipt(&queue.confirmation_id, &task.task.id)?;
        }
        Ok(())
    }

    pub fn validate_activated_queue_runtime(&self, queue: &ActivatedQueue) -> Result<()> {
        self.repair_runtime_task_commits(queue)?;
        self.repair_runtime_capability_commits(queue)?;
        self.validate_activated_queue_runtime_with_prepared(
            queue,
            &BTreeSet::new(),
            &BTreeSet::new(),
        )
    }

    fn validate_activated_queue_runtime_with_prepared(
        &self,
        queue: &ActivatedQueue,
        prepared_task_ids: &BTreeSet<String>,
        prepared_capability_ids: &BTreeSet<String>,
    ) -> Result<()> {
        let materialized = queue.materialized_queue.as_ref().ok_or_else(|| {
            anyhow::anyhow!("active_runtime_envelope_mismatch: materialized queue is missing")
        })?;
        let materialized_digest = Self::runtime_record_digest(materialized)?;
        if queue.materialized_queue_digest.is_empty()
            || queue.materialized_queue_digest != materialized_digest
        {
            bail!("active_runtime_envelope_mismatch: immutable materialized queue digest mismatch");
        }
        let mut committed = self.committed_runtime_tasks(queue)?;
        for task_id in prepared_task_ids {
            if committed
                .iter()
                .any(|(commit, _)| &commit.task_id == task_id)
            {
                continue;
            }
            let receipt = self
                .load_runtime_task_receipt(&queue.confirmation_id, task_id)?
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "active_runtime_origin_mismatch: prepared task {} has no receipt",
                        task_id
                    )
                })?;
            committed.push((
                RuntimeTaskCommit {
                    schema_version: 1,
                    confirmation_id: queue.confirmation_id.clone(),
                    task_id: task_id.clone(),
                    ordinal: receipt.ordinal,
                    receipt_digest: Self::runtime_record_digest(&receipt)?,
                    committed_at: receipt.recorded_at.clone(),
                },
                receipt,
            ));
        }
        committed.sort_by_key(|(commit, _)| commit.ordinal);
        let runtime_tasks = queue
            .tasks
            .iter()
            .filter(|task| task.materialized_by_confirmation_id.is_empty())
            .collect::<Vec<_>>();
        if committed.len() != runtime_tasks.len() {
            bail!("active_runtime_origin_mismatch: committed runtime task inventory mismatch");
        }
        for (ordinal, ((commit, receipt), task)) in committed.iter().zip(&runtime_tasks).enumerate()
        {
            if commit.ordinal != ordinal
                || receipt.ordinal != ordinal
                || commit.task_id != task.task.id
            {
                bail!("active_runtime_origin_mismatch: committed runtime task order mismatch");
            }
        }

        let known_ids = queue
            .tasks
            .iter()
            .map(|task| task.task.id.as_str())
            .collect::<BTreeSet<_>>();
        let positions = queue
            .tasks
            .iter()
            .enumerate()
            .map(|(index, task)| (task.task.id.as_str(), index))
            .collect::<BTreeMap<_, _>>();
        let confirmed_ids = materialized
            .tasks
            .iter()
            .map(|task| task.id.as_str())
            .collect::<BTreeSet<_>>();
        let mut runs_before = BTreeMap::<String, Vec<String>>::new();
        for ((_, receipt), task) in committed.iter().zip(&runtime_tasks) {
            self.validate_runtime_task_receipt_identity(queue, task, receipt)?;
            for target in &receipt.runs_before {
                if !known_ids.contains(target.as_str())
                    || positions.get(target.as_str()) >= positions.get(task.task.id.as_str())
                {
                    bail!(
                        "active_runtime_origin_mismatch: task {} has an invalid runtime dependency target {}",
                        task.task.id,
                        target
                    );
                }
                runs_before
                    .entry(target.clone())
                    .or_default()
                    .push(task.task.id.clone());
            }
        }
        let mut capability_clears = BTreeSet::new();
        let baselines = self.runtime_contract_baselines(queue)?;
        let authorized_selections = self.receipted_runtime_selections(queue, &baselines);
        for task in &queue.tasks {
            let Some(planned) = baselines.get(&task.task.id) else {
                continue;
            };
            if task.task.required_capabilities != planned.required_capabilities {
                if !task.task.required_capabilities.is_empty() {
                    bail!(
                        "active_runtime_capability_mismatch: task {} changed required capabilities",
                        task.task.id
                    );
                }
                let receipt = self
                    .load_runtime_capability_receipt(&queue.confirmation_id, &task.task.id)?
                    .ok_or_else(|| {
                        anyhow::anyhow!(
                            "active_runtime_capability_mismatch: task {} has no capability receipt",
                            task.task.id
                        )
                    })?;
                self.validate_runtime_capability_receipt(queue, planned, &receipt)?;
                if !prepared_capability_ids.contains(&task.task.id) {
                    let commit = self
                        .load_runtime_capability_commit(&queue.confirmation_id, &task.task.id)?
                        .ok_or_else(|| {
                            anyhow::anyhow!(
                                "active_runtime_capability_mismatch: task {} has no commit marker",
                                task.task.id
                            )
                        })?;
                    if commit.schema_version != 1
                        || commit.confirmation_id != queue.confirmation_id
                        || commit.task_id != task.task.id
                        || commit.receipt_digest != Self::runtime_record_digest(&receipt)?
                        || commit.committed_at.is_empty()
                    {
                        bail!(
                            "active_runtime_capability_mismatch: task {} has an invalid commit marker",
                            task.task.id
                        );
                    }
                }
                capability_clears.insert(task.task.id.clone());
            }
        }
        for ((_, receipt), task) in committed.iter().zip(&runtime_tasks) {
            self.validate_runtime_task_receipt(
                queue,
                task,
                receipt,
                runs_before
                    .get(&task.task.id)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]),
                capability_clears.contains(&task.task.id),
                authorized_selections.get(&task.task.id),
            )?;
        }
        let confirmed_runs_before = runs_before
            .into_iter()
            .filter(|(target, _)| confirmed_ids.contains(target.as_str()))
            .collect::<BTreeMap<_, _>>();
        if !queue.runtime_envelope_matches_materialized_with_overlays(
            &confirmed_runs_before,
            &capability_clears,
            &authorized_selections,
        ) {
            bail!(
                "active_runtime_envelope_mismatch: current tasks differ from immutable confirmed contracts"
            );
        }
        Ok(())
    }

    pub fn require_confirmed_activation(&self) -> Result<()> {
        save_immutable_yaml(
            &self.activation_requirement_path(),
            &ActivationRequirement {
                schema_version: 1,
                required: true,
            },
        )
    }

    pub fn confirmed_activation_required(&self) -> Result<bool> {
        let path = self.activation_requirement_path();
        if !path.is_file() {
            return Ok(false);
        }
        let marker: ActivationRequirement = load_yaml(&path)?;
        if marker.schema_version != 1 || !marker.required {
            bail!("invalid activation requirement marker");
        }
        Ok(true)
    }

    /// Canonical writer for the secret-free Git finish attempt attached to a
    /// run. The authoritative copy lives outside the worker-writable run
    /// directory; `run_dir/git-finish.json` is a user-facing projection only.
    /// Git URLs, user-provided check text/output, and environment values are not
    /// fields in the record schema. A failure from either write is a hard gate.
    pub fn save_git_finish_record(
        &self,
        run_dir: &Path,
        record: &crate::git_finish::GitFinishRecord,
    ) -> Result<()> {
        self.validate_receipt_run_id(&record.run_id)?;
        if run_dir != self.runs_dir().join(&record.run_id) {
            bail!("Git finish run directory does not match its core identity");
        }
        let text = serde_json::to_string_pretty(record)?;
        write_str_atomic(
            &self
                .checkpoints_dir()
                .join("git-finish")
                .join(format!("{}.json", record.run_id)),
            &text,
        )?;
        write_str_atomic(&run_dir.join("git-finish.json"), &text)
    }

    pub fn load_git_finish_record(
        &self,
        run_dir: &Path,
    ) -> Result<crate::git_finish::GitFinishRecord> {
        let run_id = run_dir
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow::anyhow!("Git finish run directory has no valid run id"))?;
        self.validate_receipt_run_id(run_id)?;
        if run_dir != self.runs_dir().join(run_id) {
            bail!("Git finish run directory is outside the canonical runs directory");
        }
        let raw = fs::read_to_string(
            self.checkpoints_dir()
                .join("git-finish")
                .join(format!("{run_id}.json")),
        )?;
        let record: crate::git_finish::GitFinishRecord = serde_json::from_str(&raw)?;
        if record.run_id != run_id {
            bail!("Git finish core record does not match its run id");
        }
        Ok(record)
    }
    /// Atomically claim a run directory without reusing an existing attempt's
    /// artifacts. Timestamp-based ids can collide during fast queue drains, so
    /// later claims receive a stable numeric suffix.
    pub fn claim_run_dir(&self, base_id: &str) -> Result<(String, PathBuf)> {
        let runs_dir = self.runs_dir();
        fs::create_dir_all(&runs_dir)
            .with_context(|| format!("creating {}", runs_dir.display()))?;

        for attempt in 1_u64.. {
            let run_id = if attempt == 1 {
                base_id.to_string()
            } else {
                format!("{base_id}-{attempt}")
            };
            let run_dir = runs_dir.join(&run_id);
            match fs::create_dir(&run_dir) {
                Ok(()) => return Ok((run_id, run_dir)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => {
                    return Err(e).with_context(|| format!("creating {}", run_dir.display()));
                }
            }
        }

        unreachable!("the run directory suffix space is unbounded")
    }
    pub fn checkpoints_dir(&self) -> PathBuf {
        self.agents_dir().join("checkpoints")
    }
    pub fn handoffs_dir(&self) -> PathBuf {
        self.agents_dir().join("handoffs")
    }
    fn serial_integration_receipts_dir(&self) -> PathBuf {
        self.checkpoints_dir().join("serial-integration")
    }
    fn integrated_cleanup_receipts_dir(&self) -> PathBuf {
        self.checkpoints_dir().join("integrated-cleanup")
    }
    fn no_change_receipts_dir(&self) -> PathBuf {
        self.checkpoints_dir().join("no-change")
    }
    fn no_change_receipt_path(&self, run_id: &str) -> Result<PathBuf> {
        self.validate_receipt_run_id(run_id)?;
        Ok(self.no_change_receipts_dir().join(format!("{run_id}.yaml")))
    }
    fn validate_receipt_run_id(&self, run_id: &str) -> Result<()> {
        use std::path::Component;

        if run_id.is_empty()
            || Path::new(run_id).components().count() != 1
            || !Path::new(run_id)
                .components()
                .all(|component| matches!(component, Component::Normal(_)))
        {
            bail!("invalid integration receipt run id '{run_id}'");
        }
        Ok(())
    }
    fn serial_integration_receipt_path(&self, run_id: &str) -> Result<PathBuf> {
        self.validate_receipt_run_id(run_id)?;
        Ok(self
            .serial_integration_receipts_dir()
            .join(format!("{run_id}.yaml")))
    }
    fn integrated_cleanup_receipt_path(&self, run_id: &str) -> Result<PathBuf> {
        self.validate_receipt_run_id(run_id)?;
        Ok(self
            .integrated_cleanup_receipts_dir()
            .join(format!("{run_id}.yaml")))
    }
    pub fn save_serial_integration_receipt(
        &self,
        receipt: &SerialIntegrationReceipt,
    ) -> Result<()> {
        let path = self.serial_integration_receipt_path(&receipt.run_id)?;
        let text = yaml::to_string(receipt)?;
        write_str_atomic(&path, &text)
    }
    pub fn load_serial_integration_receipt(
        &self,
        run_id: &str,
    ) -> Result<SerialIntegrationReceipt> {
        load_yaml(&self.serial_integration_receipt_path(run_id)?)
    }
    pub fn save_integrated_cleanup_receipt(
        &self,
        receipt: &IntegratedCleanupReceipt,
    ) -> Result<()> {
        let path = self.integrated_cleanup_receipt_path(&receipt.run_id)?;
        let text = yaml::to_string(receipt)?;
        write_str_atomic(&path, &text)
    }
    pub fn load_integrated_cleanup_receipt(
        &self,
        run_id: &str,
    ) -> Result<IntegratedCleanupReceipt> {
        load_yaml(&self.integrated_cleanup_receipt_path(run_id)?)
    }
    pub fn load_integrated_cleanup_receipts(&self) -> Result<Vec<IntegratedCleanupReceipt>> {
        let directory = self.integrated_cleanup_receipts_dir();
        let Ok(entries) = fs::read_dir(&directory) else {
            return Ok(Vec::new());
        };
        let mut paths = entries
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "yaml")
            })
            .collect::<Vec<_>>();
        paths.sort();
        paths.into_iter().map(|path| load_yaml(&path)).collect()
    }
    pub fn save_no_change_receipt(&self, receipt: &NoChangeReceipt) -> Result<()> {
        let path = self.no_change_receipt_path(&receipt.run_id)?;
        write_str_atomic(&path, &yaml::to_string(receipt)?)
    }
    pub fn load_no_change_receipt(&self, run_id: &str) -> Result<NoChangeReceipt> {
        load_yaml(&self.no_change_receipt_path(run_id)?)
    }
    pub fn load_no_change_receipts(&self) -> Result<Vec<NoChangeReceipt>> {
        let directory = self.no_change_receipts_dir();
        let Ok(entries) = fs::read_dir(&directory) else {
            return Ok(Vec::new());
        };
        let mut paths = entries
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "yaml")
            })
            .collect::<Vec<_>>();
        paths.sort();
        paths.into_iter().map(|path| load_yaml(&path)).collect()
    }
    pub fn memory_dir(&self) -> PathBuf {
        self.agents_dir().join("memory")
    }

    // ---- typed loaders -------------------------------------------------

    pub fn load_config(&self) -> Result<YardConfig> {
        load_yaml(&self.config_path())
    }

    pub fn load_planning_worker_config(&self) -> Result<PlanningWorkerConfig> {
        load_yaml(&self.config_path())
    }

    pub fn load_queue(&self) -> Result<WorkQueue> {
        let path = self.queue_path();
        if !path.exists() {
            // The queue is runtime state, not config: a fresh checkout (or one
            // that gitignores the queue) can have none. A missing file is an
            // empty queue, not an error. A present-but-malformed file still fails.
            return Ok(WorkQueue::empty());
        }
        load_yaml(&path)
    }

    pub fn save_queue(&self, queue: &WorkQueue) -> Result<()> {
        let lock = self.acquire_planning_lock()?;
        self.save_queue_locked(&lock, queue)
    }

    fn queue_text_preserving_activation(
        &self,
        queue: &WorkQueue,
        existing: Option<&str>,
    ) -> Result<(String, Vec<String>, Vec<String>)> {
        if let Some(mut activated) = existing.map(yaml::from_str::<ActivatedQueue>).transpose()? {
            if activated.activation_required
                || !activated.confirmation_id.is_empty()
                || !activated.planning_session_id.is_empty()
            {
                self.validate_activated_queue_runtime(&activated)?;
                if activated.queue_id != queue.queue_id || activated.intent_id != queue.intent_id {
                    bail!("activated queue identity changed during runtime mutation");
                }
                let existing_materialization = activated
                    .tasks
                    .iter()
                    .map(|task| {
                        (
                            task.task.id.clone(),
                            task.materialized_by_confirmation_id.clone(),
                        )
                    })
                    .collect::<BTreeMap<_, _>>();
                let existing_ids = activated
                    .tasks
                    .iter()
                    .map(|task| task.task.id.clone())
                    .collect::<BTreeSet<_>>();
                let mut candidate = activated.clone();
                candidate.schema_version = queue.schema_version;
                candidate.selection_policy = queue.selection_policy.clone();
                candidate.tasks = queue
                    .tasks
                    .iter()
                    .cloned()
                    .map(|task| ActivatedTask {
                        materialized_by_confirmation_id: existing_materialization
                            .get(&task.id)
                            .cloned()
                            .unwrap_or_default(),
                        task,
                    })
                    .collect();

                let new_runtime_ids = candidate
                    .tasks
                    .iter()
                    .filter(|task| {
                        task.materialized_by_confirmation_id.is_empty()
                            && !existing_ids.contains(&task.task.id)
                    })
                    .map(|task| task.task.id.clone())
                    .collect::<BTreeSet<_>>();
                let mut runs_before_by_source = BTreeMap::<String, Vec<String>>::new();
                for (source_index, source) in candidate.tasks.iter().enumerate() {
                    if !new_runtime_ids.contains(&source.task.id) {
                        continue;
                    }
                    let targets = candidate.tasks[..source_index]
                        .iter()
                        .filter(|target| target.task.depends_on.contains(&source.task.id))
                        .map(|target| target.task.id.clone())
                        .collect::<Vec<_>>();
                    runs_before_by_source.insert(source.task.id.clone(), targets);
                }

                let mut baselines = candidate
                    .materialized_queue
                    .as_ref()
                    .ok_or_else(|| {
                        anyhow::anyhow!(
                            "active_runtime_envelope_mismatch: materialized queue is missing"
                        )
                    })?
                    .tasks
                    .iter()
                    .cloned()
                    .map(|task| (task.id.clone(), task))
                    .collect::<BTreeMap<_, _>>();
                for task in activated
                    .tasks
                    .iter()
                    .filter(|task| task.materialized_by_confirmation_id.is_empty())
                {
                    let receipt = self
                        .load_runtime_task_receipt(&activated.confirmation_id, &task.task.id)?
                        .ok_or_else(|| {
                            anyhow::anyhow!(
                                "active_runtime_origin_mismatch: task {} has no immutable origin receipt",
                                task.task.id
                            )
                        })?;
                    baselines.insert(task.task.id.clone(), receipt.task);
                }
                for task in candidate.tasks.iter().filter(|task| {
                    task.materialized_by_confirmation_id.is_empty()
                        && new_runtime_ids.contains(&task.task.id)
                }) {
                    let mut baseline = task.task.clone();
                    for (source, targets) in &runs_before_by_source {
                        if targets.contains(&task.task.id) {
                            baseline
                                .depends_on
                                .retain(|dependency| dependency != source);
                        }
                    }
                    baselines.insert(task.task.id.clone(), baseline);
                }

                let queue_digest_after = Self::runtime_queue_digest(&candidate)?;
                let existing_runtime_count = activated
                    .tasks
                    .iter()
                    .filter(|task| task.materialized_by_confirmation_id.is_empty())
                    .count();
                let mut prepared_task_ids = BTreeSet::new();
                for (next_ordinal, task) in
                    (existing_runtime_count..).zip(candidate.tasks.iter().filter(|task| {
                        task.materialized_by_confirmation_id.is_empty()
                            && new_runtime_ids.contains(&task.task.id)
                    }))
                {
                    let baseline = baselines.get(&task.task.id).ok_or_else(|| {
                        anyhow::anyhow!(
                            "active_runtime_origin_mismatch: task {} has no baseline",
                            task.task.id
                        )
                    })?;
                    self.ensure_runtime_task_receipt(
                        &candidate,
                        &activated,
                        task,
                        baseline,
                        RuntimeTaskPlacement {
                            ordinal: next_ordinal,
                            runs_before: runs_before_by_source
                                .get(&task.task.id)
                                .cloned()
                                .unwrap_or_default(),
                        },
                        &queue_digest_after,
                    )?;
                    prepared_task_ids.insert(task.task.id.clone());
                }

                let previous_tasks = activated
                    .tasks
                    .iter()
                    .map(|task| (task.task.id.as_str(), &task.task))
                    .collect::<BTreeMap<_, _>>();
                let mut prepared_capability_ids = BTreeSet::new();
                for task in &candidate.tasks {
                    let Some(baseline) = baselines.get(&task.task.id) else {
                        continue;
                    };
                    let previous_capabilities = previous_tasks
                        .get(task.task.id.as_str())
                        .map(|task| task.required_capabilities.as_slice())
                        .unwrap_or(baseline.required_capabilities.as_slice());
                    if previous_capabilities == baseline.required_capabilities.as_slice()
                        && task.task.required_capabilities != baseline.required_capabilities
                    {
                        self.ensure_runtime_capability_receipt(
                            &candidate,
                            &activated,
                            baseline,
                            &task.task,
                            &queue_digest_after,
                        )?;
                        prepared_capability_ids.insert(task.task.id.clone());
                    }
                }

                self.validate_activated_queue_runtime_with_prepared(
                    &candidate,
                    &prepared_task_ids,
                    &prepared_capability_ids,
                )?;
                activated = candidate;
                return Ok((
                    yaml::to_string(&activated)?,
                    prepared_task_ids.into_iter().collect(),
                    prepared_capability_ids.into_iter().collect(),
                ));
            }
        }
        Ok((yaml::to_string(queue)?, Vec::new(), Vec::new()))
    }

    /// Queue writer for callers that already own the permanent workspace
    /// mutation lock. Requiring the guard at the call site prevents helpers
    /// inside a transaction from trying to acquire the non-reentrant lock again.
    pub fn save_queue_locked(&self, _lock: &PlanningLock, queue: &WorkQueue) -> Result<()> {
        let expected = _lock.queue_snapshot.borrow().clone();
        let (text, prepared_task_ids, prepared_capability_ids) =
            self.queue_text_preserving_activation(queue, expected.as_deref())?;
        write_str_atomic_cas(&self.queue_path(), expected.as_deref(), &text)?;
        *_lock.queue_snapshot.borrow_mut() = Some(text);
        if !prepared_task_ids.is_empty() || !prepared_capability_ids.is_empty() {
            let activated = self.load_activated_queue()?.ok_or_else(|| {
                anyhow::anyhow!("active_runtime_origin_mismatch: committed queue is missing")
            })?;
            for task_id in prepared_task_ids {
                self.commit_runtime_task_receipt(&activated.confirmation_id, &task_id)?;
            }
            for task_id in prepared_capability_ids {
                self.commit_runtime_capability_receipt(&activated.confirmation_id, &task_id)?;
            }
        }
        Ok(())
    }

    /// Append a user-authored task to the latest queue without re-planning or
    /// rewriting existing tasks. This is the `yardlet add` path used while an
    /// auto-drain may already be running; always load the current queue first so
    /// a stale caller cannot clobber runtime state.
    pub fn append_user_task(&self, input: UserTaskInput) -> Result<Task> {
        let _lock = self.acquire_planning_lock()?;
        let mut queue = self.load_queue()?;
        let next_num = queue
            .tasks
            .iter()
            .filter_map(|t| {
                t.id.strip_prefix("YARD-")
                    .and_then(|n| n.parse::<usize>().ok())
            })
            .max()
            .unwrap_or(queue.tasks.len())
            + 1;
        let base_priority = queue.tasks.iter().map(|t| t.priority).max().unwrap_or(0);
        let task = Task {
            id: format!("YARD-{next_num:03}"),
            title: input.title,
            state: TaskState::Queued,
            priority: base_priority + 10,
            risk: input.risk,
            kind: input.kind,
            preferred_worker: input.preferred_worker,
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: input.depends_on,
            skills: Vec::new(),
            required_capabilities: Vec::new(),
            allowed_scope: input.allowed_scope,
            acceptance: Vec::new(),
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: Some("added directly by user with yardlet add".to_string()),
            provenance: "user-added".to_string(),
            routing_provenance: None,
        };
        queue.tasks.push(task.clone());
        self.save_queue_locked(&_lock, &queue)?;
        Ok(task)
    }

    pub fn load_workers(&self) -> Result<WorkersFile> {
        let workers: WorkersFile = load_yaml(&self.workers_path())?;
        workers.validate().map_err(anyhow::Error::msg)?;
        Ok(workers)
    }

    /// A task's conversation transcript (empty when the task never paused for
    /// the user). A malformed file reads as empty rather than failing the run.
    pub fn load_conversation(&self, task_id: &str) -> Conversation {
        let p = self.conversation_path(task_id);
        if !p.is_file() {
            return Conversation {
                task_id: task_id.to_string(),
                turns: Vec::new(),
            };
        }
        load_yaml(&p).unwrap_or_else(|_| Conversation {
            task_id: task_id.to_string(),
            turns: Vec::new(),
        })
    }

    fn ensure_task_channel_identity(
        &self,
        intent_id: &str,
        task_id: &str,
        session_id: &str,
    ) -> Result<TaskChannelIdentity> {
        if intent_id.is_empty() || task_id.is_empty() || session_id.is_empty() {
            bail!("task channel identity requires session, intent, and task ids");
        }
        let identity = TaskChannelIdentity {
            schema_version: 1,
            channel_id: task_channel_id(intent_id, task_id),
            session_id: session_id.to_string(),
            intent_id: intent_id.to_string(),
            task_id: task_id.to_string(),
        };
        save_immutable_yaml(
            &self
                .task_channel_dir(intent_id, task_id)
                .join("channel.yaml"),
            &identity,
        )?;
        Ok(identity)
    }

    fn find_worker_attempt(
        &self,
        attempt_id: &str,
    ) -> Result<Option<(TaskChannelIdentity, WorkerAttempt)>> {
        let mut channel_dirs = if self.task_channels_dir().is_dir() {
            fs::read_dir(self.task_channels_dir())?
                .filter_map(|entry| entry.ok().map(|entry| entry.path()))
                .filter(|path| path.is_dir())
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        channel_dirs.sort();
        let mut found = None;
        for directory in channel_dirs {
            let path = directory
                .join("attempts")
                .join(format!("{attempt_id}.yaml"));
            if !path.is_file() {
                continue;
            }
            let identity: TaskChannelIdentity = load_yaml(&directory.join("channel.yaml"))?;
            let attempt: WorkerAttempt = load_yaml(&path)?;
            if found.is_some() {
                bail!("attempt_id_conflict: {attempt_id} appears in multiple task channels");
            }
            found = Some((identity, attempt));
        }
        Ok(found)
    }

    pub fn record_worker_attempt(&self, attempt: &WorkerAttempt) -> Result<()> {
        attempt.validate().map_err(anyhow::Error::msg)?;
        if let Some((identity, existing)) = self.find_worker_attempt(&attempt.attempt_id)? {
            if existing == *attempt
                && identity.intent_id == attempt.intent_id
                && identity.task_id == attempt.task_id
            {
                return Ok(());
            }
            bail!("attempt_id_conflict: {}", attempt.attempt_id);
        }
        self.ensure_task_channel_identity(
            &attempt.intent_id,
            &attempt.task_id,
            &attempt.session_id,
        )?;
        save_immutable_yaml(
            &self
                .task_channel_dir(&attempt.intent_id, &attempt.task_id)
                .join("attempts")
                .join(format!("{}.yaml", attempt.attempt_id)),
            attempt,
        )
    }

    fn validate_publication_attempt(
        &self,
        intent_id: &str,
        task_id: &str,
        attempt_id: &str,
        worker_id: &str,
    ) -> Result<WorkerAttempt> {
        let Some((identity, attempt)) = self.find_worker_attempt(attempt_id)? else {
            bail!("publication_attempt_missing: {attempt_id}");
        };
        if identity.intent_id != intent_id
            || identity.task_id != task_id
            || attempt.intent_id != intent_id
            || attempt.task_id != task_id
            || attempt.worker_id != worker_id
        {
            bail!("publication_attempt_linkage_conflict: {attempt_id}");
        }
        Ok(attempt)
    }

    fn resolve_publication_causation(
        &self,
        intent_id: &str,
        task_id: &str,
        attempt_id: &str,
        proposed_causation_id: &str,
    ) -> Result<String> {
        let channel = self.load_task_channel(intent_id, task_id)?;
        let cause = if proposed_causation_id == attempt_id {
            channel
                .events
                .iter()
                .rev()
                .find(|event| {
                    event.attempt_id.as_deref() == Some(attempt_id)
                        && event.event_type == ChannelEventType::WorkerCompleted
                })
                .or_else(|| {
                    channel
                        .events
                        .iter()
                        .rev()
                        .find(|event| event.attempt_id.as_deref() == Some(attempt_id))
                })
        } else {
            channel
                .events
                .iter()
                .find(|event| event.event_id == proposed_causation_id)
        }
        .ok_or_else(|| anyhow::anyhow!("publication_causation_missing: {proposed_causation_id}"))?;
        if cause.attempt_id.as_deref() != Some(attempt_id) {
            bail!("publication_causation_linkage_conflict: {proposed_causation_id}");
        }
        Ok(cause.event_id.clone())
    }

    fn find_artifact_by_proposal(&self, proposal_id: &str) -> Result<Option<Artifact>> {
        let mut found = None;
        for artifact in load_yaml_dir::<Artifact>(&self.artifacts_dir())? {
            if artifact.proposal_id != proposal_id {
                continue;
            }
            if found.is_some() {
                bail!("artifact_proposal_conflict: {proposal_id}");
            }
            found = Some(artifact);
        }
        Ok(found)
    }

    fn find_resource_by_proposal(&self, proposal_id: &str) -> Result<Option<RuntimeResource>> {
        let mut found = None;
        for resource in load_yaml_dir::<RuntimeResource>(&self.runtime_resources_dir())? {
            if resource.proposal_id != proposal_id {
                continue;
            }
            if found.is_some() {
                bail!("resource_proposal_conflict: {proposal_id}");
            }
            found = Some(resource);
        }
        Ok(found)
    }

    pub fn publish_artifact(
        &self,
        session_id: &str,
        intent_id: &str,
        proposal: &ArtifactProposal,
        source_path: &str,
    ) -> Result<Artifact> {
        proposal
            .validate_provenance(&proposal.task_id, &proposal.attempt_id)
            .map_err(anyhow::Error::msg)?;
        self.validate_publication_attempt(
            intent_id,
            &proposal.task_id,
            &proposal.attempt_id,
            &proposal.producer.worker_id,
        )?;
        let causation_id = self.resolve_publication_causation(
            intent_id,
            &proposal.task_id,
            &proposal.attempt_id,
            &proposal.causation_id,
        )?;
        let _lock = self.acquire_planning_lock()?;
        if let Some(existing) = self.find_artifact_by_proposal(&proposal.proposal_id)? {
            let same = existing.session_id == session_id
                && existing.intent_id == intent_id
                && existing.task_id == proposal.task_id
                && existing.attempt_id == proposal.attempt_id
                && existing.producer == proposal.producer
                && existing.causation_id == causation_id
                && existing.path == proposal.path
                && existing.digest == proposal.digest
                && existing.media_type == proposal.media_type
                && existing.role == proposal.role
                && existing.channel_role == proposal.channel_role;
            if same {
                // `source_path` is the physical location used to verify the
                // publication, not proposal identity. A Git-finish recovery
                // can replay an already-published worktree artifact from the
                // integrated workspace root. `worker_authored` is likewise a
                // classification of the run directory at publication time,
                // not identity: records published before the field existed
                // carry no authorship, and a recovery replay may reclassify a
                // handoff the evaluator has since filled in. Preserve the
                // first canonical record while still failing closed on
                // provenance, logical path, digest, media type, or role
                // mutations.
                return Ok(existing);
            }
            bail!("artifact_proposal_conflict: {}", proposal.proposal_id);
        }
        let artifact_id = format!(
            "art_{}",
            stable_digest_bytes(
                format!("{}\0{}", proposal.attempt_id, proposal.proposal_id).as_bytes()
            )
        );
        let event_role = if proposal.channel_role.is_empty() {
            serde_json::to_value(proposal.role)?
        } else {
            serde_json::Value::String(proposal.channel_role.clone())
        };
        let mut payload = serde_json::json!({
            "artifact_id": artifact_id,
            "proposal_id": proposal.proposal_id,
            "path": proposal.path,
            "source_path": source_path,
            "content_digest": proposal.digest,
            "media_type": proposal.media_type,
            "role": event_role,
            "producer_attempt_id": proposal.attempt_id,
            "producer_worker_id": proposal.producer.worker_id
        });
        if let Some(worker_authored) = proposal.worker_authored {
            payload["worker_authored"] = serde_json::Value::Bool(worker_authored);
        }
        let event = self.record_task_event_locked(
            intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_publish_{artifact_id}"),
                session_id: session_id.to_string(),
                seq: 0,
                event_type: ChannelEventType::ArtifactCreated,
                recorded_at: String::new(),
                actor: EventActor {
                    kind: EventActorKind::Worker,
                    id: proposal.producer.worker_id.clone(),
                },
                action_id: None,
                causation_id: Some(causation_id.clone()),
                correlation_id: format!("cor_{}", task_channel_id(intent_id, &proposal.task_id)),
                task_id: proposal.task_id.clone(),
                attempt_id: Some(proposal.attempt_id.clone()),
                payload,
                raw_ref: None,
            },
        )?;
        let artifact = Artifact {
            schema_version: 1,
            artifact_id: artifact_id.clone(),
            proposal_id: proposal.proposal_id.clone(),
            session_id: session_id.to_string(),
            intent_id: intent_id.to_string(),
            task_id: proposal.task_id.clone(),
            attempt_id: proposal.attempt_id.clone(),
            producer: proposal.producer.clone(),
            causation_id,
            path: proposal.path.clone(),
            source_path: source_path.to_string(),
            digest: proposal.digest.clone(),
            media_type: proposal.media_type.clone(),
            role: proposal.role,
            channel_role: proposal.channel_role.clone(),
            worker_authored: proposal.worker_authored,
            created_event_id: event.event_id,
            published_seq: event.seq,
            recorded_at: event.recorded_at,
        };
        save_immutable_yaml(
            &self.artifacts_dir().join(format!("{artifact_id}.yaml")),
            &artifact,
        )?;
        Ok(artifact)
    }

    pub fn publish_runtime_resource(
        &self,
        session_id: &str,
        intent_id: &str,
        proposal: &RuntimeResourceProposal,
    ) -> Result<RuntimeResource> {
        proposal
            .validate_provenance(&proposal.task_id, &proposal.attempt_id)
            .map_err(anyhow::Error::msg)?;
        let capabilities = proposal
            .target
            .normalize_capabilities(&proposal.capabilities)
            .map_err(anyhow::Error::msg)?;
        self.validate_publication_attempt(
            intent_id,
            &proposal.task_id,
            &proposal.attempt_id,
            &proposal.producer.worker_id,
        )?;
        let causation_id = self.resolve_publication_causation(
            intent_id,
            &proposal.task_id,
            &proposal.attempt_id,
            &proposal.causation_id,
        )?;
        let _lock = self.acquire_planning_lock()?;
        if let Some(existing) = self.find_resource_by_proposal(&proposal.proposal_id)? {
            let same = existing.session_id == session_id
                && existing.intent_id == intent_id
                && existing.task_id == proposal.task_id
                && existing.attempt_id == proposal.attempt_id
                && existing.producer == proposal.producer
                && existing.causation_id == causation_id
                && existing.ownership == proposal.ownership
                && existing.capabilities == capabilities
                && existing.target == proposal.target;
            if same {
                return Ok(existing);
            }
            bail!("resource_proposal_conflict: {}", proposal.proposal_id);
        }
        let resource_id = format!(
            "res_{}",
            stable_digest_bytes(
                format!("{}\0{}", proposal.attempt_id, proposal.proposal_id).as_bytes()
            )
        );
        let event = self.record_task_event_locked(
            intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_publish_{resource_id}"),
                session_id: session_id.to_string(),
                seq: 0,
                event_type: ChannelEventType::ResourceDeclared,
                recorded_at: String::new(),
                actor: EventActor {
                    kind: EventActorKind::Worker,
                    id: proposal.producer.worker_id.clone(),
                },
                action_id: None,
                causation_id: Some(causation_id.clone()),
                correlation_id: format!("cor_{}", task_channel_id(intent_id, &proposal.task_id)),
                task_id: proposal.task_id.clone(),
                attempt_id: Some(proposal.attempt_id.clone()),
                payload: serde_json::json!({
                    "resource_id": resource_id,
                    "proposal_id": proposal.proposal_id,
                    "ownership": proposal.ownership,
                    "capabilities": capabilities,
                    "target": proposal.target
                }),
                raw_ref: None,
            },
        )?;
        let resource = RuntimeResource {
            schema_version: 1,
            resource_id: resource_id.clone(),
            proposal_id: proposal.proposal_id.clone(),
            session_id: session_id.to_string(),
            intent_id: intent_id.to_string(),
            task_id: proposal.task_id.clone(),
            attempt_id: proposal.attempt_id.clone(),
            producer: proposal.producer.clone(),
            causation_id,
            ownership: proposal.ownership,
            capabilities,
            target: proposal.target.clone(),
            created_event_id: event.event_id,
            published_seq: event.seq,
            recorded_at: event.recorded_at,
        };
        save_immutable_yaml(
            &self
                .runtime_resources_dir()
                .join(format!("{resource_id}.yaml")),
            &resource,
        )?;
        let _ = self.record_resource_observation_locked(
            &resource,
            ResourceStatus::Unknown,
            false,
            None,
            "",
            "declared; current liveness has not been probed",
            &resource.created_event_id,
            None,
            &format!("obs_{resource_id}_declared"),
        )?;
        Ok(resource)
    }

    #[allow(clippy::too_many_arguments)]
    fn record_resource_observation_locked(
        &self,
        resource: &RuntimeResource,
        status: ResourceStatus,
        current: bool,
        pid: Option<u32>,
        start_identity: &str,
        detail: &str,
        causation_id: &str,
        action_id: Option<&str>,
        observation_id: &str,
    ) -> Result<ResourceObservation> {
        let path = self
            .resource_observations_dir(&resource.resource_id)
            .join(format!("{observation_id}.yaml"));
        if path.is_file() {
            return load_yaml(&path);
        }
        let event = self.record_task_event_locked(
            &resource.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{observation_id}"),
                session_id: resource.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::ResourceObserved,
                recorded_at: String::new(),
                actor: EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                action_id: action_id.map(str::to_string),
                causation_id: Some(causation_id.to_string()),
                correlation_id: format!(
                    "cor_{}",
                    task_channel_id(&resource.intent_id, &resource.task_id)
                ),
                task_id: resource.task_id.clone(),
                attempt_id: Some(resource.attempt_id.clone()),
                payload: serde_json::json!({
                    "resource_id": resource.resource_id,
                    "observation_id": observation_id,
                    "status": status,
                    "current": current,
                    "pid": pid,
                    "start_identity": start_identity,
                    "detail": detail
                }),
                raw_ref: None,
            },
        )?;
        let observation = ResourceObservation {
            schema_version: 1,
            observation_id: observation_id.to_string(),
            resource_id: resource.resource_id.clone(),
            task_id: resource.task_id.clone(),
            attempt_id: resource.attempt_id.clone(),
            status,
            observed_at: event.recorded_at,
            current,
            pid,
            start_identity: start_identity.to_string(),
            detail: detail.to_string(),
            causation_id: causation_id.to_string(),
            event_id: event.event_id,
            seq: event.seq,
        };
        save_immutable_yaml(&path, &observation)?;
        Ok(observation)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record_resource_observation(
        &self,
        resource: &RuntimeResource,
        status: ResourceStatus,
        current: bool,
        pid: Option<u32>,
        start_identity: &str,
        detail: &str,
        causation_id: &str,
        action_id: &str,
    ) -> Result<ResourceObservation> {
        validate_action_id(action_id)?;
        let _lock = self.acquire_planning_lock()?;
        self.record_resource_observation_locked(
            resource,
            status,
            current,
            pid,
            start_identity,
            detail,
            causation_id,
            Some(action_id),
            &format!(
                "obs_{}_{}",
                stable_digest_bytes(action_id.as_bytes()),
                stable_digest_bytes(resource.resource_id.as_bytes())
            ),
        )
    }

    pub fn load_artifacts(&self) -> Result<Vec<Artifact>> {
        let mut artifacts = load_yaml_dir::<Artifact>(&self.artifacts_dir())?;
        artifacts.sort_by(|left, right| {
            left.published_seq
                .cmp(&right.published_seq)
                .then_with(|| left.artifact_id.cmp(&right.artifact_id))
        });
        Ok(artifacts)
    }

    pub fn load_runtime_resources(&self) -> Result<Vec<RuntimeResource>> {
        let mut resources = load_yaml_dir::<RuntimeResource>(&self.runtime_resources_dir())?;
        resources.sort_by(|left, right| {
            left.published_seq
                .cmp(&right.published_seq)
                .then_with(|| left.resource_id.cmp(&right.resource_id))
        });
        Ok(resources)
    }

    pub fn load_resource_observations(
        &self,
        resource_id: &str,
    ) -> Result<Vec<ResourceObservation>> {
        let mut observations =
            load_yaml_dir::<ResourceObservation>(&self.resource_observations_dir(resource_id))?;
        observations.sort_by(|left, right| {
            left.seq
                .cmp(&right.seq)
                .then_with(|| left.observation_id.cmp(&right.observation_id))
        });
        Ok(observations)
    }

    pub fn load_or_rebuild_resource_index(&self) -> Result<ResourceIndex> {
        let artifacts = self.load_artifacts()?;
        let resources = self.load_runtime_resources()?;
        let mut canonical = Vec::new();
        for artifact in &artifacts {
            canonical.extend(serde_json::to_vec(artifact)?);
        }
        for resource in &resources {
            canonical.extend(serde_json::to_vec(resource)?);
            for observation in self.load_resource_observations(&resource.resource_id)? {
                canonical.extend(serde_json::to_vec(&observation)?);
            }
        }
        let artifact_start = artifacts.len().saturating_sub(RESOURCE_INDEX_ENTRY_LIMIT);
        let resource_start = resources.len().saturating_sub(RESOURCE_INDEX_ENTRY_LIMIT);
        let artifact_ids = artifacts[artifact_start..]
            .iter()
            .map(|artifact| artifact.artifact_id.clone())
            .collect::<Vec<_>>();
        let resource_ids = resources[resource_start..]
            .iter()
            .map(|resource| resource.resource_id.clone())
            .collect::<Vec<_>>();
        let mut attempts = artifacts[artifact_start..]
            .iter()
            .map(|artifact| artifact.attempt_id.clone())
            .chain(
                resources[resource_start..]
                    .iter()
                    .map(|resource| resource.attempt_id.clone()),
            )
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        if attempts.len() > RESOURCE_INDEX_ENTRY_LIMIT {
            attempts = attempts.split_off(attempts.len() - RESOURCE_INDEX_ENTRY_LIMIT);
        }
        let mut task_entries = BTreeMap::<(String, String), ResourceTaskIndex>::new();
        for artifact in &artifacts {
            let entry = task_entries
                .entry((artifact.intent_id.clone(), artifact.task_id.clone()))
                .or_insert_with(|| ResourceTaskIndex {
                    intent_id: artifact.intent_id.clone(),
                    task_id: artifact.task_id.clone(),
                    artifacts: Vec::new(),
                    resources: Vec::new(),
                    attempts: Vec::new(),
                    truncated: false,
                });
            entry.artifacts.push(artifact.artifact_id.clone());
            if !entry.attempts.contains(&artifact.attempt_id) {
                entry.attempts.push(artifact.attempt_id.clone());
            }
        }
        for resource in &resources {
            let entry = task_entries
                .entry((resource.intent_id.clone(), resource.task_id.clone()))
                .or_insert_with(|| ResourceTaskIndex {
                    intent_id: resource.intent_id.clone(),
                    task_id: resource.task_id.clone(),
                    artifacts: Vec::new(),
                    resources: Vec::new(),
                    attempts: Vec::new(),
                    truncated: false,
                });
            entry.resources.push(resource.resource_id.clone());
            if !entry.attempts.contains(&resource.attempt_id) {
                entry.attempts.push(resource.attempt_id.clone());
            }
        }
        for entry in task_entries.values_mut() {
            for values in [
                &mut entry.artifacts,
                &mut entry.resources,
                &mut entry.attempts,
            ] {
                if values.len() > RESOURCE_INDEX_ENTRY_LIMIT {
                    *values = values.split_off(values.len() - RESOURCE_INDEX_ENTRY_LIMIT);
                    entry.truncated = true;
                }
            }
        }
        let tasks_truncated = task_entries.len() > RESOURCE_INDEX_ENTRY_LIMIT;
        let mut tasks = task_entries.into_values().collect::<Vec<_>>();
        if tasks_truncated {
            tasks = tasks.split_off(tasks.len() - RESOURCE_INDEX_ENTRY_LIMIT);
        }
        let index = ResourceIndex {
            schema_version: 1,
            canonical_digest: format!("fnv1a64:{}", stable_digest_bytes(&canonical)),
            artifacts: artifact_ids,
            resources: resource_ids,
            attempts,
            tasks,
            tasks_truncated,
        };
        let current = if self.resource_index_path().is_file() {
            load_yaml::<ResourceIndex>(&self.resource_index_path()).ok()
        } else {
            None
        };
        if current.as_ref() != Some(&index) {
            write_str_atomic(&self.resource_index_path(), &yaml::to_string(&index)?)?;
        }
        Ok(index)
    }

    pub fn load_resource_action(&self, action_id: &str) -> Result<Option<ResourceActionReceipt>> {
        validate_action_id(action_id)?;
        let path =
            contained_action_path(&self.resource_actions_dir(), &format!("{action_id}.yaml"))?;
        if !path.is_file() {
            return Ok(None);
        }
        load_yaml(&path).map(Some)
    }

    pub fn save_resource_action(&self, receipt: &ResourceActionReceipt) -> Result<()> {
        validate_action_id(&receipt.action_id)?;
        let path = contained_action_path(
            &self.resource_actions_dir(),
            &format!("{}.yaml", receipt.action_id),
        )?;
        if path.is_file() {
            let existing: ResourceActionReceipt = load_yaml(&path)?;
            if existing == *receipt {
                return Ok(());
            }
            bail!("resource_action_conflict: {}", receipt.action_id);
        }
        save_immutable_yaml(&path, receipt)
    }

    pub fn load_resource_action_recovery(
        &self,
        action_id: &str,
    ) -> Result<Option<ResourceActionRecoveryReceipt>> {
        validate_action_id(action_id)?;
        let path = contained_action_path(
            &self.resource_actions_dir(),
            &format!("{action_id}.recovery.yaml"),
        )?;
        if !path.is_file() {
            return Ok(None);
        }
        load_yaml(&path).map(Some)
    }

    pub fn save_resource_action_recovery(
        &self,
        recovery: &ResourceActionRecoveryReceipt,
    ) -> Result<()> {
        validate_action_id(&recovery.action_id)?;
        let path = contained_action_path(
            &self.resource_actions_dir(),
            &format!("{}.recovery.yaml", recovery.action_id),
        )?;
        if path.is_file() {
            let existing: ResourceActionRecoveryReceipt = load_yaml(&path)?;
            if existing == *recovery {
                return Ok(());
            }
            let same_action = existing.action_id == recovery.action_id
                && existing.request_digest == recovery.request_digest
                && existing.operation == recovery.operation
                && existing.intent_id == recovery.intent_id
                && existing.task_id == recovery.task_id
                && existing.target_id == recovery.target_id
                && existing.expected_status == recovery.expected_status
                && existing.requested_event_id == recovery.requested_event_id;
            let fills_spawn_identity = existing.phase == recovery.phase
                && existing.phase == crate::schemas::ResourceActionRecoveryPhase::Spawned
                && existing.effect_pid == recovery.effect_pid
                && existing.effect_start_identity.is_empty()
                && !recovery.effect_start_identity.is_empty();
            if !same_action
                || (existing.phase.rank() >= recovery.phase.rank() && !fills_spawn_identity)
            {
                bail!("resource_action_recovery_conflict: {}", recovery.action_id);
            }
        }
        write_str_atomic(&path, &yaml::to_string(recovery)?)
    }

    pub fn load_artifact(&self, artifact_id: &str) -> Result<Option<Artifact>> {
        Ok(self
            .load_artifacts()?
            .into_iter()
            .find(|artifact| artifact.artifact_id == artifact_id))
    }

    pub fn load_runtime_resource(&self, resource_id: &str) -> Result<Option<RuntimeResource>> {
        Ok(self
            .load_runtime_resources()?
            .into_iter()
            .find(|resource| resource.resource_id == resource_id))
    }

    /// Replay the canonical event stream for one work session across every
    /// task channel. Channel directories are a storage partition only; `seq`
    /// belongs to the session and therefore may have gaps in an individual
    /// task projection but must be contiguous in this merged stream.
    fn replay_task_session_events(
        &self,
        session_id: &str,
    ) -> Result<(Vec<ChannelEvent>, Vec<String>)> {
        let mut events = Vec::new();
        let mut channel_dirs = if self.task_channels_dir().is_dir() {
            fs::read_dir(self.task_channels_dir())?
                .filter_map(|entry| entry.ok().map(|entry| entry.path()))
                .filter(|path| path.is_dir())
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        channel_dirs.sort();
        for directory in channel_dirs {
            let identity_path = directory.join("channel.yaml");
            if !identity_path.is_file() {
                continue;
            }
            let identity: TaskChannelIdentity = load_yaml(&identity_path)?;
            if identity.session_id == session_id {
                events.extend(load_yaml_dir::<ChannelEvent>(&directory.join("events"))?);
            }
        }
        events.sort_by(|left, right| {
            left.seq
                .cmp(&right.seq)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });

        let mut replayed = Vec::new();
        let mut errors = Vec::new();
        let mut event_ids: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        let mut expected_seq = 1_u64;
        for event in events {
            let bytes = serde_json::to_vec(&event)?;
            if let Some(existing) = event_ids.get(&event.event_id) {
                if *existing == bytes {
                    continue;
                }
                errors.push(format!("event_id_conflict:{}", event.event_id));
                break;
            }
            if event.seq != expected_seq {
                errors.push(format!("session_sequence_gap:{expected_seq}-{}", event.seq));
                break;
            }
            if event.session_id != session_id {
                errors.push(format!("event_session_conflict:{}", event.event_id));
                break;
            }
            if let Err(error) = event.validate() {
                errors.push(format!("invalid_event:{}:{error}", event.event_id));
                break;
            }
            event_ids.insert(event.event_id.clone(), bytes);
            expected_seq += 1;
            replayed.push(event);
        }
        Ok((replayed, errors))
    }

    fn record_task_event_locked(
        &self,
        intent_id: &str,
        mut event: ChannelEvent,
    ) -> Result<ChannelEvent> {
        let identity =
            self.ensure_task_channel_identity(intent_id, &event.task_id, &event.session_id)?;
        let (session_events, replay_errors) = self.replay_task_session_events(&event.session_id)?;
        if !replay_errors.is_empty() {
            bail!("task_channel_corrupt: {}", replay_errors.join(", "));
        }
        if !event.event_id.is_empty() {
            if let Some(existing) = session_events
                .iter()
                .find(|existing| existing.event_id == event.event_id)
            {
                event.seq = existing.seq;
                event.recorded_at = existing.recorded_at.clone();
                if event == *existing {
                    return Ok(existing.clone());
                }
                bail!("event_id_conflict: {}", event.event_id);
            }
        }
        event.seq = session_events.last().map_or(1, |existing| existing.seq + 1);
        if event.event_id.is_empty() {
            event.event_id = format!("evt_{}_{:020}", &identity.channel_id[4..], event.seq);
        }
        if event.recorded_at.is_empty() {
            event.recorded_at = Local::now().to_rfc3339();
        }
        event.validate().map_err(anyhow::Error::msg)?;
        let path = self
            .task_channel_dir(intent_id, &event.task_id)
            .join("events")
            .join(format!("{:020}.yaml", event.seq));
        save_immutable_yaml(&path, &event)?;
        Ok(event)
    }

    pub fn record_task_event(&self, intent_id: &str, event: ChannelEvent) -> Result<ChannelEvent> {
        let _lock = self.acquire_planning_lock()?;
        self.record_task_event_locked(intent_id, event)
    }

    pub fn record_task_event_with_lock(
        &self,
        _lock: &PlanningLock,
        intent_id: &str,
        event: ChannelEvent,
    ) -> Result<ChannelEvent> {
        self.record_task_event_locked(intent_id, event)
    }

    pub fn record_question(&self, question: &Question) -> Result<()> {
        question.validate().map_err(anyhow::Error::msg)?;
        let Some((identity, attempt)) = self.find_worker_attempt(&question.attempt_id)? else {
            bail!("question_attempt_missing: {}", question.attempt_id);
        };
        if attempt.session_id != question.session_id
            || attempt.task_id != question.task_id
            || identity.task_id != question.task_id
        {
            bail!(
                "question_attempt_linkage_conflict: {}",
                question.question_id
            );
        }
        let channel = self.load_task_channel(&identity.intent_id, &identity.task_id)?;
        let asked = channel
            .events
            .iter()
            .find(|event| event.event_id == question.asked_event_id)
            .ok_or_else(|| anyhow::anyhow!("question_asked_event_missing"))?;
        if asked.seq != question.asked_seq
            || asked.event_type != ChannelEventType::QuestionAsked
            || asked.attempt_id.as_deref() != Some(question.attempt_id.as_str())
        {
            bail!("question_asked_event_linkage_conflict");
        }
        save_immutable_yaml(
            &self
                .task_channel_dir(&identity.intent_id, &identity.task_id)
                .join("questions")
                .join(format!("{}.yaml", question.question_id)),
            question,
        )
    }

    pub fn load_task_channel(&self, intent_id: &str, task_id: &str) -> Result<TaskChannel> {
        let directory = self.task_channel_dir(intent_id, task_id);
        if !directory.is_dir() {
            return Ok(TaskChannel {
                schema_version: 1,
                channel_id: task_channel_id(intent_id, task_id),
                session_id: format!("legacy:{intent_id}"),
                intent_id: intent_id.to_string(),
                task_id: task_id.to_string(),
                highest_seq: 0,
                attempts: Vec::new(),
                questions: Vec::new(),
                answers: Vec::new(),
                events: Vec::new(),
                replay_errors: Vec::new(),
            });
        }
        let identity: TaskChannelIdentity = load_yaml(&directory.join("channel.yaml"))?;
        if identity.schema_version != 1
            || identity.channel_id != task_channel_id(intent_id, task_id)
            || identity.intent_id != intent_id
            || identity.task_id != task_id
        {
            bail!("task_channel_identity_conflict");
        }

        let (session_events, mut replay_errors) =
            self.replay_task_session_events(&identity.session_id)?;
        let events = session_events
            .into_iter()
            .filter(|event| event.task_id == identity.task_id)
            .collect::<Vec<_>>();

        let mut attempts: Vec<WorkerAttempt> = load_yaml_dir(&directory.join("attempts"))?;
        let mut questions: Vec<Question> = load_yaml_dir(&directory.join("questions"))?;
        let mut answers: Vec<Answer> = load_yaml_dir(&directory.join("answers"))?;
        for attempt in &attempts {
            if attempt.intent_id != intent_id || attempt.task_id != task_id {
                replay_errors.push(format!("attempt_identity_conflict:{}", attempt.attempt_id));
            }
        }
        for answer in &answers {
            if !questions
                .iter()
                .any(|question| question.question_id == answer.question_id)
            {
                replay_errors.push(format!("answer_question_missing:{}", answer.answer_id));
            }
        }
        for question in &mut questions {
            if let Some(answer) = answers
                .iter()
                .find(|answer| answer.question_id == question.question_id)
            {
                question.state = QuestionState::Answered;
                question.answer_id = Some(answer.answer_id.clone());
            }
        }
        for event in events
            .iter()
            .filter(|event| event.event_type == ChannelEventType::QuestionClosed)
        {
            let Some(question_id) = event
                .payload
                .get("question_id")
                .and_then(|value| value.as_str())
            else {
                replay_errors.push(format!("question_closed_id_missing:{}", event.event_id));
                continue;
            };
            let Some(question) = questions
                .iter_mut()
                .find(|question| question.question_id == question_id)
            else {
                replay_errors.push(format!("question_closed_missing:{question_id}"));
                continue;
            };
            if question.answer_id.is_none() {
                question.state = QuestionState::Closed;
            }
        }
        for event in &events {
            let Some(attempt_id) = event.attempt_id.as_deref() else {
                continue;
            };
            let Some(attempt) = attempts
                .iter_mut()
                .find(|attempt| attempt.attempt_id == attempt_id)
            else {
                replay_errors.push(format!("event_attempt_missing:{}", event.event_id));
                continue;
            };
            match event.event_type {
                ChannelEventType::WorkerStarted => attempt.state = AttemptState::Running,
                ChannelEventType::WorkerCompleted => {
                    if let Some(worker_session_ref) = event
                        .payload
                        .get("worker_session_ref")
                        .and_then(|value| value.as_str())
                        .filter(|value| !value.is_empty())
                    {
                        attempt.worker_session_ref = Some(worker_session_ref.to_string());
                    }
                    attempt.state = match event.payload.get("result").and_then(|v| v.as_str()) {
                        Some("needs_user") => AttemptState::NeedsUser,
                        Some("succeeded") => AttemptState::Succeeded,
                        Some("timed_out") => AttemptState::TimedOut,
                        Some("cancelled") => AttemptState::Cancelled,
                        Some("abandoned") => AttemptState::Abandoned,
                        _ => AttemptState::Failed,
                    }
                }
                _ => {}
            }
        }
        let attempt_order = events
            .iter()
            .filter_map(|event| {
                (event.event_type == ChannelEventType::AttemptPrepared)
                    .then(|| event.attempt_id.clone())
                    .flatten()
            })
            .enumerate()
            .map(|(index, id)| (id, index))
            .collect::<BTreeMap<_, _>>();
        attempts.sort_by_key(|attempt| {
            attempt_order
                .get(&attempt.attempt_id)
                .copied()
                .unwrap_or(usize::MAX)
        });
        questions.sort_by_key(|question| question.asked_seq);
        let answer_order = events
            .iter()
            .filter_map(|event| {
                (event.event_type == ChannelEventType::UserAnswered)
                    .then(|| {
                        event
                            .payload
                            .get("answer_id")
                            .and_then(|value| value.as_str())
                            .map(str::to_string)
                    })
                    .flatten()
                    .map(|answer_id| (answer_id, event.seq))
            })
            .collect::<BTreeMap<_, _>>();
        answers.sort_by_key(|answer| {
            answer_order
                .get(&answer.answer_id)
                .copied()
                .unwrap_or(u64::MAX)
        });
        let highest_seq = events.last().map_or(0, |event| event.seq);
        Ok(TaskChannel {
            schema_version: 1,
            channel_id: identity.channel_id,
            session_id: identity.session_id,
            intent_id: identity.intent_id,
            task_id: identity.task_id,
            highest_seq,
            attempts,
            questions,
            answers,
            events,
            replay_errors,
        })
    }

    fn build_task_channel_index(channel: &TaskChannel) -> TaskChannelIndex {
        let start = channel
            .events
            .len()
            .saturating_sub(CHANNEL_INDEX_EVENT_LIMIT);
        let tail_events = channel.events[start..].to_vec();
        TaskChannelIndex {
            schema_version: 1,
            channel_id: channel.channel_id.clone(),
            highest_applied_seq: channel.highest_seq,
            retained_from_seq: tail_events.first().map_or(0, |event| event.seq),
            event_count: channel.events.len(),
            tail_events,
        }
    }

    pub fn load_or_rebuild_task_channel(
        &self,
        intent_id: &str,
        task_id: &str,
    ) -> Result<TaskChannel> {
        let channel = self.load_task_channel(intent_id, task_id)?;
        if !channel.replay_errors.is_empty() {
            bail!("task_channel_corrupt: {}", channel.replay_errors.join(", "));
        }
        let index = Self::build_task_channel_index(&channel);
        write_str_atomic(
            &self.task_channel_index_path(intent_id, task_id),
            &yaml::to_string(&index)?,
        )?;
        Ok(channel)
    }

    fn channel_action_path(
        &self,
        intent_id: &str,
        task_id: &str,
        action_id: &str,
        terminal: bool,
    ) -> Result<PathBuf> {
        validate_action_id(action_id)?;
        let actions_dir = self.task_channel_dir(intent_id, task_id).join("actions");
        contained_action_path(
            &actions_dir,
            &format!(
                "{action_id}.{}.yaml",
                if terminal { "terminal" } else { "prepared" }
            ),
        )
    }

    fn load_answer_action_outcome(
        &self,
        request: &AnswerActionRequest,
        receipt: ActionReceipt,
    ) -> Result<AnswerActionOutcome> {
        let channel = self.load_task_channel(&request.intent_id, &request.task_id)?;
        let answer = channel
            .answers
            .into_iter()
            .find(|answer| answer.answer_id == request.answer_id)
            .ok_or_else(|| anyhow::anyhow!("answer_action_corrupt: answer missing"))?;
        let attempt = channel
            .attempts
            .into_iter()
            .find(|attempt| attempt.attempt_id == request.continuation_attempt_id)
            .ok_or_else(|| anyhow::anyhow!("answer_action_corrupt: attempt missing"))?;
        Ok(AnswerActionOutcome {
            receipt,
            answer,
            attempt,
        })
    }

    pub fn answer_question(&self, request: &AnswerActionRequest) -> Result<AnswerActionOutcome> {
        if request.action_id.is_empty()
            || request.answer_id.is_empty()
            || request.continuation_attempt_id.is_empty()
            || request.session_id.is_empty()
            || request.intent_id.is_empty()
            || request.task_id.is_empty()
            || request.question_id.is_empty()
            || request.text.trim().is_empty()
            || request.worker_id.is_empty()
        {
            bail!("invalid answer action request");
        }
        validate_action_id(&request.action_id)?;
        let digest = channel_action_digest(request)?;
        let _lock = self.acquire_planning_lock()?;
        let terminal_path = self.channel_action_path(
            &request.intent_id,
            &request.task_id,
            &request.action_id,
            true,
        )?;
        if terminal_path.is_file() {
            let receipt: ActionReceipt = load_yaml(&terminal_path)?;
            if receipt.request_digest != digest {
                bail!("idempotency_conflict: {}", request.action_id);
            }
            return self.load_answer_action_outcome(request, receipt);
        }

        let prepared_path = self.channel_action_path(
            &request.intent_id,
            &request.task_id,
            &request.action_id,
            false,
        )?;
        let recovering = if prepared_path.is_file() {
            let existing: ActionReceipt = load_yaml(&prepared_path)?;
            if existing.request_digest != digest {
                bail!("idempotency_conflict: {}", request.action_id);
            }
            true
        } else {
            false
        };
        let channel = self.load_task_channel(&request.intent_id, &request.task_id)?;
        let question = channel
            .questions
            .iter()
            .find(|question| question.question_id == request.question_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("question_missing: {}", request.question_id))?;
        if question.session_id != request.session_id || question.task_id != request.task_id {
            bail!("question_linkage_conflict: {}", request.question_id);
        }
        if !recovering
            && (question.state != QuestionState::Open
                || channel
                    .answers
                    .iter()
                    .any(|answer| answer.question_id == request.question_id))
        {
            bail!("question_closed: {}", request.question_id);
        }
        if recovering
            && channel.answers.iter().any(|answer| {
                answer.question_id == request.question_id
                    && (answer.answer_id != request.answer_id
                        || answer.action_id != request.action_id
                        || answer.text != request.text)
            })
        {
            bail!("idempotency_conflict: {}", request.action_id);
        }

        if !recovering {
            save_immutable_yaml(
                &prepared_path,
                &ActionReceipt {
                    schema_version: 1,
                    action_id: request.action_id.clone(),
                    session_id: request.session_id.clone(),
                    task_id: request.task_id.clone(),
                    action: ChannelActionKind::Answer,
                    request_digest: digest.clone(),
                    status: ChannelActionStatus::Prepared,
                    result_event_ids: Vec::new(),
                    result_attempt_id: Some(request.continuation_attempt_id.clone()),
                    error: String::new(),
                },
            )?;
        }

        let event_id_suffix = stable_digest_bytes(request.action_id.as_bytes());
        let requested = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{event_id_suffix}_requested"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::ActionRequested,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::User,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: Some(question.asked_event_id.clone()),
                correlation_id: channel
                    .events
                    .first()
                    .map(|event| event.correlation_id.clone())
                    .unwrap_or_else(|| format!("cor_{}", channel.channel_id)),
                task_id: request.task_id.clone(),
                attempt_id: None,
                payload: serde_json::json!({"action": "answer", "question_id": request.question_id}),
                raw_ref: None,
            },
        )?;
        let answered_event = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{event_id_suffix}_answered"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::UserAnswered,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::User,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: Some(question.asked_event_id.clone()),
                correlation_id: requested.correlation_id.clone(),
                task_id: request.task_id.clone(),
                attempt_id: None,
                payload: serde_json::json!({
                    "answer_id": request.answer_id,
                    "question_id": request.question_id,
                    "text": request.text
                }),
                raw_ref: None,
            },
        )?;
        let answer = Answer {
            schema_version: 1,
            answer_id: request.answer_id.clone(),
            question_id: request.question_id.clone(),
            action_id: request.action_id.clone(),
            answered_event_id: answered_event.event_id.clone(),
            text: request.text.clone(),
        };
        answer.validate().map_err(anyhow::Error::msg)?;
        save_immutable_yaml(
            &self
                .task_channel_dir(&request.intent_id, &request.task_id)
                .join("answers")
                .join(format!("{}.yaml", request.answer_id)),
            &answer,
        )?;

        let native = request.supports_native_resume
            && request
                .worker_session_ref
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty());
        let attempt = WorkerAttempt {
            schema_version: 1,
            attempt_id: request.continuation_attempt_id.clone(),
            session_id: request.session_id.clone(),
            intent_id: request.intent_id.clone(),
            task_id: request.task_id.clone(),
            worker_id: request.worker_id.clone(),
            worker_session_ref: native.then(|| request.worker_session_ref.clone()).flatten(),
            state: AttemptState::Prepared,
            continuation: if native {
                ContinuationMode::NativeResume
            } else {
                ContinuationMode::ExplicitPacket
            },
            caused_by_event_id: Some(answered_event.event_id.clone()),
            caused_by_action_id: Some(request.action_id.clone()),
            raw_stdout_ref: format!(
                "task-channels/{}/attempts/{}/stdout.log",
                channel.channel_id, request.continuation_attempt_id
            ),
            raw_stderr_ref: format!(
                "task-channels/{}/attempts/{}/stderr.log",
                channel.channel_id, request.continuation_attempt_id
            ),
        };
        self.record_worker_attempt(&attempt)?;
        let attempt_event = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{event_id_suffix}_attempt"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::AttemptPrepared,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: Some(answered_event.event_id.clone()),
                correlation_id: requested.correlation_id.clone(),
                task_id: request.task_id.clone(),
                attempt_id: Some(attempt.attempt_id.clone()),
                payload: serde_json::json!({
                    "worker_id": attempt.worker_id,
                    "worker_session_ref": attempt.worker_session_ref,
                    "continuation": attempt.continuation
                }),
                raw_ref: None,
            },
        )?;
        let completed_event = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{event_id_suffix}_completed"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::ActionCompleted,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: Some(attempt_event.event_id.clone()),
                correlation_id: requested.correlation_id,
                task_id: request.task_id.clone(),
                attempt_id: None,
                payload: serde_json::json!({
                    "answer_id": answer.answer_id,
                    "attempt_id": attempt.attempt_id
                }),
                raw_ref: None,
            },
        )?;
        let receipt = ActionReceipt {
            schema_version: 1,
            action_id: request.action_id.clone(),
            session_id: request.session_id.clone(),
            task_id: request.task_id.clone(),
            action: ChannelActionKind::Answer,
            request_digest: digest,
            status: ChannelActionStatus::Completed,
            result_event_ids: vec![
                requested.event_id,
                answered_event.event_id,
                attempt_event.event_id,
                completed_event.event_id,
            ],
            result_attempt_id: Some(attempt.attempt_id.clone()),
            error: String::new(),
        };
        save_immutable_yaml(&terminal_path, &receipt)?;
        self.load_or_rebuild_task_channel(&request.intent_id, &request.task_id)?;
        Ok(AnswerActionOutcome {
            receipt,
            answer,
            attempt,
        })
    }

    pub fn redirect_task(&self, request: &RedirectActionRequest) -> Result<RedirectActionOutcome> {
        if request.action_id.is_empty()
            || request.continuation_attempt_id.is_empty()
            || request.session_id.is_empty()
            || request.intent_id.is_empty()
            || request.task_id.is_empty()
            || request.stopped_attempt_id.is_empty()
            || request.reason.trim().is_empty()
            || request.guidance.trim().is_empty()
            || request.worker_id.is_empty()
        {
            bail!("invalid redirect action request");
        }
        validate_action_id(&request.action_id)?;
        if !request.observed_terminal_state.is_terminal() {
            bail!("redirect_requires_observed_terminal");
        }
        let digest = channel_action_digest(request)?;
        let _lock = self.acquire_planning_lock()?;
        let terminal_path = self.channel_action_path(
            &request.intent_id,
            &request.task_id,
            &request.action_id,
            true,
        )?;
        if terminal_path.is_file() {
            let receipt: ActionReceipt = load_yaml(&terminal_path)?;
            if receipt.request_digest != digest {
                bail!("idempotency_conflict: {}", request.action_id);
            }
            let channel = self.load_task_channel(&request.intent_id, &request.task_id)?;
            let attempt = channel
                .attempts
                .into_iter()
                .find(|attempt| attempt.attempt_id == request.continuation_attempt_id)
                .ok_or_else(|| anyhow::anyhow!("redirect_action_corrupt: attempt missing"))?;
            return Ok(RedirectActionOutcome { receipt, attempt });
        }

        let channel = self.load_task_channel(&request.intent_id, &request.task_id)?;
        let stopped = channel
            .attempts
            .iter()
            .find(|attempt| attempt.attempt_id == request.stopped_attempt_id)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "redirect_stopped_attempt_missing: {}",
                    request.stopped_attempt_id
                )
            })?;
        if stopped.state != request.observed_terminal_state || !stopped.state.is_terminal() {
            bail!("redirect_requires_observed_terminal");
        }
        let prepared_path = self.channel_action_path(
            &request.intent_id,
            &request.task_id,
            &request.action_id,
            false,
        )?;
        if prepared_path.is_file() {
            let existing: ActionReceipt = load_yaml(&prepared_path)?;
            if existing.request_digest != digest {
                bail!("idempotency_conflict: {}", request.action_id);
            }
        } else {
            save_immutable_yaml(
                &prepared_path,
                &ActionReceipt {
                    schema_version: 1,
                    action_id: request.action_id.clone(),
                    session_id: request.session_id.clone(),
                    task_id: request.task_id.clone(),
                    action: ChannelActionKind::Redirect,
                    request_digest: digest.clone(),
                    status: ChannelActionStatus::Prepared,
                    result_event_ids: Vec::new(),
                    result_attempt_id: Some(request.continuation_attempt_id.clone()),
                    error: String::new(),
                },
            )?;
        }

        let suffix = stable_digest_bytes(request.action_id.as_bytes());
        let requested = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{suffix}_redirect_requested"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::ActionRequested,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::User,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: channel.events.last().map(|event| event.event_id.clone()),
                correlation_id: channel
                    .events
                    .first()
                    .map(|event| event.correlation_id.clone())
                    .unwrap_or_else(|| format!("cor_{}", channel.channel_id)),
                task_id: request.task_id.clone(),
                attempt_id: None,
                payload: serde_json::json!({
                    "action": "redirect",
                    "reason": request.reason,
                    "guidance": request.guidance,
                    "stopped_attempt_id": request.stopped_attempt_id,
                    "observed_terminal_state": request.observed_terminal_state,
                    "live_message_delivered": false
                }),
                raw_ref: None,
            },
        )?;
        let mut result_event_ids = vec![requested.event_id.clone()];
        let mut redirect_cause = requested.event_id.clone();
        for question in channel.questions.iter().filter(|question| {
            question.attempt_id == request.stopped_attempt_id
                && question.state == QuestionState::Open
                && !channel
                    .answers
                    .iter()
                    .any(|answer| answer.question_id == question.question_id)
        }) {
            let closed = self.record_task_event_locked(
                &request.intent_id,
                ChannelEvent {
                    schema_version: 1,
                    event_id: format!("evt_{suffix}_closed_{}", question.question_id),
                    session_id: request.session_id.clone(),
                    seq: 0,
                    event_type: ChannelEventType::QuestionClosed,
                    recorded_at: Local::now().to_rfc3339(),
                    actor: EventActor {
                        kind: EventActorKind::System,
                        id: String::new(),
                    },
                    action_id: Some(request.action_id.clone()),
                    causation_id: Some(redirect_cause.clone()),
                    correlation_id: requested.correlation_id.clone(),
                    task_id: request.task_id.clone(),
                    attempt_id: Some(request.stopped_attempt_id.clone()),
                    payload: serde_json::json!({
                        "question_id": question.question_id,
                        "reason": "superseded_by_redirect",
                        "continuation_attempt_id": request.continuation_attempt_id
                    }),
                    raw_ref: None,
                },
            )?;
            redirect_cause = closed.event_id.clone();
            result_event_ids.push(closed.event_id);
        }
        let cause = if let Some(checkpoint_ref) = request.checkpoint_ref.as_deref() {
            let checkpoint = self.record_task_event_locked(
                &request.intent_id,
                ChannelEvent {
                    schema_version: 1,
                    event_id: format!("evt_{suffix}_checkpoint"),
                    session_id: request.session_id.clone(),
                    seq: 0,
                    event_type: ChannelEventType::WorkerCheckpoint,
                    recorded_at: Local::now().to_rfc3339(),
                    actor: EventActor {
                        kind: EventActorKind::System,
                        id: String::new(),
                    },
                    action_id: Some(request.action_id.clone()),
                    causation_id: Some(redirect_cause.clone()),
                    correlation_id: requested.correlation_id.clone(),
                    task_id: request.task_id.clone(),
                    attempt_id: Some(request.stopped_attempt_id.clone()),
                    payload: serde_json::json!({"checkpoint_ref": checkpoint_ref}),
                    raw_ref: None,
                },
            )?;
            result_event_ids.push(checkpoint.event_id.clone());
            checkpoint.event_id
        } else {
            redirect_cause
        };

        let attempt = WorkerAttempt {
            schema_version: 1,
            attempt_id: request.continuation_attempt_id.clone(),
            session_id: request.session_id.clone(),
            intent_id: request.intent_id.clone(),
            task_id: request.task_id.clone(),
            worker_id: request.worker_id.clone(),
            worker_session_ref: None,
            state: AttemptState::Prepared,
            continuation: ContinuationMode::Redirect,
            caused_by_event_id: Some(cause.clone()),
            caused_by_action_id: Some(request.action_id.clone()),
            raw_stdout_ref: format!(
                "task-channels/{}/attempts/{}/stdout.log",
                channel.channel_id, request.continuation_attempt_id
            ),
            raw_stderr_ref: format!(
                "task-channels/{}/attempts/{}/stderr.log",
                channel.channel_id, request.continuation_attempt_id
            ),
        };
        self.record_worker_attempt(&attempt)?;
        let attempt_event = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{suffix}_redirect_attempt"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::AttemptPrepared,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: Some(cause),
                correlation_id: requested.correlation_id.clone(),
                task_id: request.task_id.clone(),
                attempt_id: Some(attempt.attempt_id.clone()),
                payload: serde_json::json!({
                    "worker_id": attempt.worker_id,
                    "continuation": "redirect",
                    "guidance": request.guidance
                }),
                raw_ref: None,
            },
        )?;
        result_event_ids.push(attempt_event.event_id.clone());
        let completed = self.record_task_event_locked(
            &request.intent_id,
            ChannelEvent {
                schema_version: 1,
                event_id: format!("evt_{suffix}_redirect_completed"),
                session_id: request.session_id.clone(),
                seq: 0,
                event_type: ChannelEventType::ActionCompleted,
                recorded_at: Local::now().to_rfc3339(),
                actor: EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                action_id: Some(request.action_id.clone()),
                causation_id: Some(attempt_event.event_id),
                correlation_id: requested.correlation_id,
                task_id: request.task_id.clone(),
                attempt_id: None,
                payload: serde_json::json!({"attempt_id": attempt.attempt_id}),
                raw_ref: None,
            },
        )?;
        result_event_ids.push(completed.event_id);
        let receipt = ActionReceipt {
            schema_version: 1,
            action_id: request.action_id.clone(),
            session_id: request.session_id.clone(),
            task_id: request.task_id.clone(),
            action: ChannelActionKind::Redirect,
            request_digest: digest,
            status: ChannelActionStatus::Completed,
            result_event_ids,
            result_attempt_id: Some(attempt.attempt_id.clone()),
            error: String::new(),
        };
        let mut queue = self.load_queue()?;
        if let Some(task) = queue
            .tasks
            .iter_mut()
            .find(|task| task.id == request.task_id)
        {
            if task.state == TaskState::Queued {
                task.state = TaskState::NeedsUser;
                self.save_queue_locked(&_lock, &queue)?;
            }
        }
        save_immutable_yaml(&terminal_path, &receipt)?;
        self.load_or_rebuild_task_channel(&request.intent_id, &request.task_id)?;
        Ok(RedirectActionOutcome { receipt, attempt })
    }

    pub fn load_transition_log(&self, task_id: &str) -> TransitionLog {
        let p = self.transition_path(task_id);
        if !p.is_file() {
            return TransitionLog {
                task_id: task_id.to_string(),
                records: Vec::new(),
            };
        }
        load_yaml(&p).unwrap_or_else(|_| TransitionLog {
            task_id: task_id.to_string(),
            records: Vec::new(),
        })
    }

    #[cfg(test)]
    pub fn latest_transition(&self, task_id: &str) -> Option<TransitionRecord> {
        self.load_transition_log(task_id).records.pop()
    }

    /// Latest transition for this task that belongs to one intent. Task ids may
    /// be reused by later plans, so live queue projections must not use the
    /// unscoped `latest_transition` lookup. An empty intent id deliberately
    /// matches legacy records, preserving pre-intent workspaces without
    /// rewriting their transition history.
    pub fn latest_transition_for_intent(
        &self,
        task_id: &str,
        intent_id: &str,
    ) -> Option<TransitionRecord> {
        self.load_transition_log(task_id)
            .records
            .into_iter()
            .rev()
            .find(|record| record.intent_id == intent_id)
    }

    /// Read every task's transition log under `.agents/transitions/`. Read-only:
    /// the trust report (`src/trust.rs`) consumes these; nothing here writes.
    /// Malformed or empty logs are skipped, and the result is ordered by task id
    /// so callers fold them deterministically. A missing directory (a fresh or
    /// queue-gitignored workspace) is simply no logs, not an error.
    pub fn load_all_transition_logs(&self) -> Vec<TransitionLog> {
        let Ok(entries) = fs::read_dir(self.transitions_dir()) else {
            return Vec::new();
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "yaml"))
            .collect();
        paths.sort();
        paths
            .iter()
            .filter_map(|p| load_yaml::<TransitionLog>(p).ok())
            .filter(|log| !log.records.is_empty())
            .collect()
    }

    pub fn load_billing(&self) -> Result<BillingPolicy> {
        load_yaml(&self.billing_path())
    }

    /// The intent contract is optional until a planning gate has run.
    pub fn load_intent(&self) -> Result<Option<IntentContract>> {
        let p = self.intent_path();
        if !p.is_file() {
            return Ok(None);
        }
        Ok(Some(load_yaml(&p)?))
    }

    /// Wipe the live intent + queue so the workspace starts fresh. Call AFTER
    /// [`crate::report::archive_intent`] has captured the record: this only
    /// removes the live files, so `load_intent` then reads None and `load_queue`
    /// reads an empty queue. Missing files are not an error (already clear).
    pub fn clear_intent_and_queue(&self) -> Result<()> {
        let lock = self.acquire_planning_lock()?;
        self.clear_intent_and_queue_locked(&lock)
    }

    fn clear_intent_and_queue_locked(&self, lock: &PlanningLock) -> Result<()> {
        let expected = lock.queue_snapshot.borrow().clone();
        let actual = if self.queue_path().is_file() {
            Some(fs::read_to_string(self.queue_path())?)
        } else {
            None
        };
        if actual != expected {
            bail!("queue_transaction_conflict: raw queue bytes changed before clear");
        }
        if let Some(activated) = expected
            .as_deref()
            .map(yaml::from_str::<ActivatedQueue>)
            .transpose()?
            .filter(|queue| {
                queue.activation_required
                    || !queue.confirmation_id.is_empty()
                    || !queue.planning_session_id.is_empty()
            })
        {
            self.validate_activated_queue_runtime(&activated)?;
        }
        if self.intent_path().is_file() {
            fs::remove_file(self.intent_path())
                .with_context(|| format!("removing {}", self.intent_path().display()))?;
        }
        if self.queue_path().is_file() {
            fs::remove_file(self.queue_path())
                .with_context(|| format!("removing {}", self.queue_path().display()))?;
        }
        *lock.queue_snapshot.borrow_mut() = None;
        Ok(())
    }

    /// Load the follow-ups preserved when an intent was archived
    /// (`.agents/intents/<intent_id>/follow-up-tasks.yaml`). None when the intent
    /// left no proposed follow-ups (or the file is absent/unreadable).
    pub fn load_preserved_follow_ups(&self, intent_id: &str) -> Option<PreservedFollowUps> {
        let p = self
            .agents_dir()
            .join("intents")
            .join(intent_id)
            .join("follow-up-tasks.yaml");
        if !p.is_file() {
            return None;
        }
        load_yaml(&p).ok()
    }

    /// Seed a fresh live intent + queue from a single (typically preserved)
    /// follow-up: write a new `intent-contract.yaml` derived from the follow-up
    /// and an empty queue for `seed_fn` to populate. Returns the new intent id.
    /// The caller (the engine promote path) fills the queue's seed task so the
    /// planner's ingest logic (id/approval/decision handling) stays the single
    /// owner of task shaping.
    pub fn seed_intent_from_follow_up(
        &self,
        fu: &FollowUpTask,
        intent_id: &str,
        seed_fn: impl FnOnce(&mut WorkQueue),
    ) -> Result<String> {
        let lock = self.acquire_planning_lock()?;
        let summary = {
            let title = fu.title.trim();
            let reason = fu.reason.trim();
            if reason.is_empty() {
                title.to_string()
            } else {
                format!("{title} \u{2014} {reason}")
            }
        };
        let intent = IntentContract {
            schema_version: 1,
            id: intent_id.to_string(),
            source: "promoted-follow-up".to_string(),
            raw_request: fu.title.trim().to_string(),
            summary,
            allowed_scope: fu.allowed_scope.clone(),
            out_of_scope: Vec::new(),
            acceptance: fu
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            images: Vec::new(),
            ambiguity: String::new(),
            open_questions: Vec::new(),
            clarifications: Vec::new(),
            interview_turns: 0,
            status: String::new(),
        };
        save_yaml(&self.intent_path(), &intent)?;
        let mut queue = WorkQueue {
            schema_version: 1,
            queue_id: format!("queue-{intent_id}"),
            intent_id: intent_id.to_string(),
            selection_policy: SelectionPolicy::default(),
            tasks: Vec::new(),
        };
        seed_fn(&mut queue);
        self.save_queue_locked(&lock, &queue)?;
        Ok(intent_id.to_string())
    }

    pub fn tidy(&self) -> Result<TidyReport> {
        let lock = self.acquire_planning_lock()?;
        let workers = self.load_workers().ok();
        let vocab = workers
            .as_ref()
            .map(crate::routing::declared_capabilities)
            .unwrap_or_default();
        let mut queue = self.load_queue()?;
        let snapshot = queue.clone();
        let mut report = TidyReport::default();
        let mut pending_conversations = Vec::new();
        let mut pending_transitions = Vec::new();

        for task in &mut queue.tasks {
            let from = task.state;
            if task.state == TaskState::Blocked && !task.required_capabilities.is_empty() {
                let missing =
                    crate::routing::unsatisfiable_capabilities(&task.required_capabilities, &vocab);
                if missing.is_empty() {
                    continue;
                }
                match crate::routing::classify_stale_gate(&missing) {
                    crate::routing::GateShape::Decision => {
                        task.state = TaskState::NeedsUser;
                        task.required_capabilities.clear();
                        let detail = format!(
                            "migrated stale capability gate to a human decision question: {}",
                            missing.join(", ")
                        );
                        append_rationale(task, &detail);
                        let question = format!(
                            "This task needs your decision before Yardlet can run it: {}. Reply with the decision or instructions to proceed.",
                            task.title
                        );
                        pending_conversations.push((
                            task.id.clone(),
                            ConversationTurn {
                                role: TurnRole::Worker,
                                text: question,
                                run_id: String::new(),
                                ts: Local::now().to_rfc3339(),
                            },
                        ));
                        pending_transitions.push(transition(
                            &task.id,
                            from,
                            task.state,
                            TransitionCause::StaleMigration,
                            &detail,
                            TransitionActor::System,
                        ));
                        report.migrated_decisions.push(task.id.clone());
                    }
                    crate::routing::GateShape::ToolGap => {
                        task.state = TaskState::Deferred;
                        task.set_deferred_by(Some(crate::schemas::DeferredBy::new(&task.id)));
                        let detail = format!(
                            "set aside stale capability gate because no enabled worker declares [{}]",
                            missing.join(", ")
                        );
                        append_rationale(task, &detail);
                        pending_transitions.push(transition(
                            &task.id,
                            from,
                            task.state,
                            TransitionCause::TidyDefer,
                            &detail,
                            TransitionActor::System,
                        ));
                        report.deferred.push(task.id.clone());
                    }
                }
                continue;
            }

            if task.state == TaskState::Queued {
                let approved =
                    task.approval_required() && crate::approvals::is_granted(self, &task.id);
                let class = snapshot.runnable_class(task, approved, &vocab);
                if matches!(
                    class,
                    crate::schemas::RunnableClass::WaitingDependency
                        | crate::schemas::RunnableClass::WaitingApproval
                        | crate::schemas::RunnableClass::WaitingCapability
                ) {
                    task.state = TaskState::Deferred;
                    task.set_deferred_by(Some(crate::schemas::DeferredBy::new(&task.id)));
                    let detail = format!("tidy set aside non-runnable task: {}", class.label());
                    append_rationale(task, &detail);
                    pending_transitions.push(transition(
                        &task.id,
                        from,
                        task.state,
                        TransitionCause::TidyDefer,
                        &detail,
                        TransitionActor::System,
                    ));
                    report.deferred.push(task.id.clone());
                }
            }
        }

        self.save_queue_locked(&lock, &queue)?;
        for (task_id, turn) in pending_conversations {
            append_conversation_turn(self, &task_id, turn)?;
        }
        for transition in pending_transitions {
            append_transition(self, transition)?;
        }

        let has_runnable = queue.tasks.iter().any(|t| {
            queue.is_runnable_now(
                t,
                t.approval_required() && crate::approvals::is_granted(self, &t.id),
                &vocab,
            )
        });
        // Wrap only when the intent is genuinely complete: drained AND no open
        // NeedsUser question (finding 21) AND nothing still runnable. Running is
        // covered by `drained()` (it is not terminal).
        if ready_for_completion(&queue) && !has_runnable {
            if let Some(intent_id) = crate::report::archive_intent(self)? {
                clear_intent_and_queue_with_wrap(self, &lock, &queue, &intent_id)?;
                report.archived_intent = Some(intent_id);
            }
        }

        Ok(report)
    }

    /// Deterministic writer for canonical project memory. Workers may draft
    /// memory content into a run directory, but only this state-layer method
    /// writes `.agents/memory/*.md` and the generated `index.yaml`.
    pub fn write_memory_documents(
        &self,
        drafts: &[MemoryDocumentDraft],
        mode: MemoryWriteMode,
    ) -> Result<MemoryWriteReport> {
        let dir = self.memory_dir();
        fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;

        let readme = dir.join("README.md");
        if !readme.is_file() {
            write_str(&readme, crate::templates::MEMORY_README)?;
        }

        let mut report = MemoryWriteReport::default();
        let mut occupied = existing_memory_slugs(&dir);
        for draft in drafts {
            let title = draft.title.trim();
            let body = draft.body.trim();
            if title.is_empty() || body.is_empty() {
                report.skipped.push(MemorySkip {
                    slug: draft.slug.clone(),
                    reason: "empty title or body".to_string(),
                });
                continue;
            }

            let mut slug = memory_slug(if draft.slug.trim().is_empty() {
                title
            } else {
                draft.slug.trim()
            });
            if slug.is_empty() {
                slug = "memory".to_string();
            }
            let existing = dir.join(format!("{slug}.md"));
            if mode == MemoryWriteMode::Init {
                let base = slug.clone();
                let mut n = 2;
                while occupied.contains(&slug) {
                    slug = format!("{base}-{n}");
                    n += 1;
                }
            } else if !existing.is_file() {
                report.skipped.push(MemorySkip {
                    slug,
                    reason: "refresh target does not exist".to_string(),
                });
                continue;
            }

            let path = dir.join(format!("{slug}.md"));
            let markdown = render_memory_markdown(&slug, draft)?;
            write_str(&path, &markdown)?;
            occupied.insert(slug.clone());
            report.written.push(format!(".agents/memory/{slug}.md"));
        }

        self.write_memory_index()?;
        report.index_path = Some(".agents/memory/index.yaml".to_string());
        Ok(report)
    }

    pub fn write_memory_index(&self) -> Result<()> {
        let dir = self.memory_dir();
        fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        let mut docs: Vec<_> = fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                let path = e.path();
                let name = path.file_name()?.to_str()?.to_string();
                if !name.ends_with(".md") || name.eq_ignore_ascii_case("README.md") {
                    return None;
                }
                Some(MemoryIndexDocument {
                    path: format!(".agents/memory/{name}"),
                })
            })
            .collect();
        docs.sort_by(|a, b| a.path.cmp(&b.path));
        let index = MemoryIndex {
            schema_version: 1,
            generated_by: "yardlet".to_string(),
            generated_at: Local::now().to_rfc3339(),
            documents: docs,
        };
        save_yaml(&dir.join("index.yaml"), &index)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TidyReport {
    pub archived_intent: Option<String>,
    pub migrated_decisions: Vec<String>,
    pub deferred: Vec<String>,
}

fn append_rationale(task: &mut Task, detail: &str) {
    task.worker_rationale = Some(match task.worker_rationale.take() {
        Some(r) if !r.trim().is_empty() => format!("{r}\n{detail}"),
        _ => detail.to_string(),
    });
}

pub struct UserTaskInput {
    pub title: String,
    pub risk: String,
    pub kind: String,
    pub preferred_worker: String,
    pub depends_on: Vec<String>,
    pub allowed_scope: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MemoryDocumentDraft {
    pub slug: String,
    pub title: String,
    pub summary: String,
    pub look_at: Vec<String>,
    pub body: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryWriteMode {
    Init,
    Refresh,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MemoryWriteReport {
    pub written: Vec<String>,
    pub skipped: Vec<MemorySkip>,
    pub index_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemorySkip {
    pub slug: String,
    pub reason: String,
}

#[derive(Serialize)]
struct MemoryFrontmatter<'a> {
    name: &'a str,
    description: &'a str,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    look_at: Vec<String>,
    source: &'static str,
    updated_at: String,
}

#[derive(Serialize)]
struct MemoryIndex {
    schema_version: u8,
    generated_by: String,
    generated_at: String,
    documents: Vec<MemoryIndexDocument>,
}

#[derive(Serialize)]
struct MemoryIndexDocument {
    path: String,
}

fn render_memory_markdown(slug: &str, draft: &MemoryDocumentDraft) -> Result<String> {
    let title = draft.title.trim();
    let summary = if draft.summary.trim().is_empty() {
        title
    } else {
        draft.summary.trim()
    };
    let frontmatter = MemoryFrontmatter {
        name: title,
        description: summary,
        look_at: draft
            .look_at
            .iter()
            .map(|p| p.trim().trim_start_matches("./").to_string())
            .filter(|p| !p.is_empty())
            .collect(),
        source: "yardlet-memory-draft",
        updated_at: Local::now().to_rfc3339(),
    };
    Ok(format!(
        "---\n{}---\n\n# {}\n\n{}\n",
        yaml::to_string(&frontmatter)?,
        title,
        strip_memory_body_wrappers(&draft.body, title, slug)
    ))
}

fn strip_memory_body_wrappers(body: &str, title: &str, slug: &str) -> String {
    let mut lines: Vec<&str> = body.trim().lines().collect();
    while lines.first().is_some_and(|l| l.trim().is_empty()) {
        lines.remove(0);
    }
    if lines.first().is_some_and(|l| l.trim() == "---") {
        lines.remove(0);
        while let Some(line) = lines.first() {
            let done = line.trim() == "---";
            lines.remove(0);
            if done {
                break;
            }
        }
    }
    if let Some(first) = lines.first() {
        let heading = first.trim().strip_prefix("# ").map(str::trim);
        if heading.is_some_and(|h| h == title || memory_slug(h) == slug) {
            lines.remove(0);
        }
    }
    lines.join("\n").trim().to_string()
}

fn existing_memory_slugs(dir: &Path) -> std::collections::HashSet<String> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.extension().is_some_and(|x| x == "md") {
                p.file_stem().and_then(|s| s.to_str()).map(str::to_string)
            } else {
                None
            }
        })
        .filter(|s| !s.eq_ignore_ascii_case("README"))
        .collect()
}

fn memory_slug(input: &str) -> String {
    let s: String = input
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    s.split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .take(64)
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

pub fn load_yaml<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    yaml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
}

fn load_yaml_dir<T: serde::de::DeserializeOwned>(dir: &Path) -> Result<Vec<T>> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut paths = fs::read_dir(dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "yaml")
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths.iter().map(|path| load_yaml(path)).collect()
}

fn stable_record_key(value: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("fnv1a64-{hash:016x}")
}

fn save_immutable_yaml<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    let text = yaml::to_string(value)?;
    if write_str_atomic_create(path, &text)? {
        return Ok(());
    }
    let existing = fs::read_to_string(path)
        .with_context(|| format!("reading immutable record {}", path.display()))?;
    if existing == text {
        Ok(())
    } else {
        bail!("immutable record conflict at {}", path.display())
    }
}

pub fn save_yaml<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let text = yaml::to_string(value)?;
    fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

pub fn save_yaml_atomic<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    write_str_atomic(path, &yaml::to_string(value)?)
}

pub(crate) fn save_private_yaml_atomic<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    write_private_str_atomic(path, &yaml::to_string(value)?)
}

pub fn save_config_preserving_format(path: &Path, config: &YardConfig) -> Result<bool> {
    let current: YardConfig = load_yaml(path)?;
    let mut edits = Vec::new();
    if current.language != config.language {
        edits.push(LineEdit::string("language", &config.language));
    }
    if current.default_access != config.default_access {
        edits.push(LineEdit::string("default_access", &config.default_access));
    }
    if current.max_parallel != config.max_parallel {
        edits.push(LineEdit::usize("max_parallel", config.max_parallel));
    }
    if current.auto_ime != config.auto_ime {
        edits.push(LineEdit::bool("auto_ime", config.auto_ime));
    }
    if edits.is_empty() {
        return Ok(false);
    }

    let original =
        fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let updated = apply_top_level_edits(&original, &edits)?;
    if updated == original {
        return Ok(false);
    }
    fs::write(path, updated).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

pub fn save_workers_preserving_format(path: &Path, workers: &WorkersFile) -> Result<bool> {
    let current: WorkersFile = load_yaml(path)?;
    let mut text =
        fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let original = text.clone();

    for desired in &workers.workers {
        let Some(existing) = current.workers.iter().find(|w| w.id == desired.id) else {
            continue;
        };
        if existing.enabled != desired.enabled {
            text = apply_worker_edit(
                &text,
                &desired.id,
                &LineEdit::bool("enabled", desired.enabled),
            )?;
        }
        if existing.model != desired.model {
            text = apply_worker_edit(
                &text,
                &desired.id,
                &LineEdit::string("model", &desired.model),
            )?;
        }
        if existing.effort != desired.effort {
            text = apply_worker_edit(
                &text,
                &desired.id,
                &LineEdit::string("effort", &desired.effort),
            )?;
        }
    }

    if text == original {
        return Ok(false);
    }
    fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

#[derive(Debug)]
struct LineEdit<'a> {
    key: &'static str,
    value: ScalarValue<'a>,
}

impl<'a> LineEdit<'a> {
    fn string(key: &'static str, value: &'a str) -> Self {
        Self {
            key,
            value: ScalarValue::String(value),
        }
    }

    fn bool(key: &'static str, value: bool) -> Self {
        Self {
            key,
            value: ScalarValue::Bool(value),
        }
    }

    fn usize(key: &'static str, value: usize) -> Self {
        Self {
            key,
            value: ScalarValue::Usize(value),
        }
    }
}

#[derive(Debug)]
enum ScalarValue<'a> {
    String(&'a str),
    Bool(bool),
    Usize(usize),
}

fn apply_top_level_edits(input: &str, edits: &[LineEdit<'_>]) -> Result<String> {
    let mut lines = split_preserving_newlines(input);
    for edit in edits {
        let mut found = false;
        for line in &mut lines {
            let (body, eol) = split_line_ending(line);
            let Some((indent, key, _)) = yaml_key_line(body) else {
                continue;
            };
            if indent == 0 && key == edit.key {
                *line = format!("{}{}", replace_line_value(body, &edit.value), eol);
                found = true;
                break;
            }
        }
        if !found {
            lines.push(format!(
                "{}: {}\n",
                edit.key,
                render_scalar("", &edit.value)
            ));
        }
    }
    Ok(lines.concat())
}

fn apply_worker_edit(input: &str, worker_id: &str, edit: &LineEdit<'_>) -> Result<String> {
    let mut lines = split_preserving_newlines(input);
    let Some((start, end, child_indent)) = find_worker_block(&lines, worker_id) else {
        anyhow::bail!("worker '{worker_id}' not found in workers.yaml");
    };

    for line in lines.iter_mut().take(end).skip(start + 1) {
        let (body, eol) = split_line_ending(line);
        let Some((indent, key, _)) = yaml_key_line(body) else {
            continue;
        };
        if indent == child_indent && key == edit.key {
            *line = format!("{}{}", replace_line_value(body, &edit.value), eol);
            return Ok(lines.concat());
        }
    }

    let eol = lines
        .get(start)
        .map(|line| split_line_ending(line).1)
        .filter(|e| !e.is_empty())
        .unwrap_or("\n");
    lines.insert(
        start + 1,
        format!(
            "{}{}: {}{}",
            " ".repeat(child_indent),
            edit.key,
            render_scalar("", &edit.value),
            eol
        ),
    );
    Ok(lines.concat())
}

fn find_worker_block(lines: &[String], worker_id: &str) -> Option<(usize, usize, usize)> {
    for (idx, line) in lines.iter().enumerate() {
        let (body, _) = split_line_ending(line);
        let Some((item_indent, id)) = worker_id_line(body) else {
            continue;
        };
        if id != worker_id {
            continue;
        }
        let mut end = lines.len();
        for (j, next) in lines.iter().enumerate().skip(idx + 1) {
            let (next_body, _) = split_line_ending(next);
            let trimmed = next_body.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let indent = leading_spaces(next_body);
            if indent <= item_indent {
                end = j;
                break;
            }
        }
        return Some((idx, end, item_indent + 2));
    }
    None
}

fn worker_id_line(line: &str) -> Option<(usize, &str)> {
    let item_indent = leading_spaces(line);
    let trimmed = line.trim_start();
    let rest = trimmed.strip_prefix("- ")?;
    let (_, key, value) = yaml_key_line(rest)?;
    if key != "id" {
        return None;
    }
    Some((
        item_indent,
        value_without_comment(value)
            .trim_matches('"')
            .trim_matches('\''),
    ))
}

fn yaml_key_line(line: &str) -> Option<(usize, &str, &str)> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let colon = trimmed.find(':')?;
    let key = trimmed[..colon].trim();
    if key.is_empty()
        || !key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    Some((line.len() - trimmed.len(), key, &trimmed[colon + 1..]))
}

fn replace_line_value(line: &str, value: &ScalarValue<'_>) -> String {
    let Some(colon) = line.find(':') else {
        return line.to_string();
    };
    let (prefix, rest) = line.split_at(colon + 1);
    let rest = rest.strip_prefix(' ').unwrap_or(rest);
    let (old_value, comment) = split_inline_comment(rest);
    let rendered = render_scalar(old_value.trim(), value);
    if comment.is_empty() {
        format!("{prefix} {rendered}")
    } else {
        format!("{prefix} {rendered}{comment}")
    }
}

fn render_scalar(existing: &str, value: &ScalarValue<'_>) -> String {
    match value {
        ScalarValue::Bool(v) => v.to_string(),
        ScalarValue::Usize(v) => v.to_string(),
        ScalarValue::String(v) => render_string_scalar(existing, v),
    }
}

fn render_string_scalar(existing: &str, value: &str) -> String {
    if existing.starts_with('\'') {
        return format!("'{}'", value.replace('\'', "''"));
    }
    if existing.starts_with('"') {
        return serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string());
    }
    if value.is_empty() {
        return "\"\"".to_string();
    }
    if is_plain_scalar(value) {
        value.to_string()
    } else {
        serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
    }
}

fn is_plain_scalar(value: &str) -> bool {
    if value.trim() != value || matches!(value, "true" | "false" | "null" | "~") {
        return false;
    }
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '@'))
}

fn split_inline_comment(rest: &str) -> (&str, &str) {
    let mut quote: Option<char> = None;
    for (idx, ch) in rest.char_indices() {
        match (quote, ch) {
            (Some('\''), '\'') => quote = None,
            (Some('"'), '"') => quote = None,
            (None, '\'' | '"') => quote = Some(ch),
            (None, '#') if idx == 0 || rest[..idx].ends_with(char::is_whitespace) => {
                let mut comment_start = idx;
                while comment_start > 0
                    && rest[..comment_start]
                        .chars()
                        .next_back()
                        .is_some_and(char::is_whitespace)
                {
                    comment_start -= rest[..comment_start]
                        .chars()
                        .next_back()
                        .map(char::len_utf8)
                        .unwrap_or(1);
                }
                return (&rest[..comment_start], &rest[comment_start..]);
            }
            _ => {}
        }
    }
    (rest, "")
}

fn value_without_comment(value: &str) -> &str {
    split_inline_comment(value).0.trim()
}

fn split_preserving_newlines(input: &str) -> Vec<String> {
    if input.is_empty() {
        return Vec::new();
    }
    input.split_inclusive('\n').map(str::to_string).collect()
}

fn split_line_ending(line: &str) -> (&str, &str) {
    if let Some(body) = line.strip_suffix("\r\n") {
        (body, "\r\n")
    } else if let Some(body) = line.strip_suffix('\n') {
        (body, "\n")
    } else {
        (line, "")
    }
}

fn leading_spaces(line: &str) -> usize {
    line.bytes().take_while(|b| *b == b' ').count()
}

/// Append a turn to a task's conversation transcript. Yardlet stays the sole
/// writer of `.agents/`: the worker authors its message via `question_for_user`
/// and the user replies through `yardlet answer`; the core records both here.
/// Worker turns dedupe by `run_id`, and an identical consecutive turn is
/// skipped, so a retried run never double-records.
pub fn append_conversation_turn(
    ws: &Workspace,
    task_id: &str,
    turn: ConversationTurn,
) -> Result<()> {
    let mut conv = ws.load_conversation(task_id);
    if conv.task_id.is_empty() {
        conv.task_id = task_id.to_string();
    }
    if turn.role == TurnRole::Worker
        && !turn.run_id.is_empty()
        && conv
            .turns
            .iter()
            .any(|t| t.role == TurnRole::Worker && t.run_id == turn.run_id)
    {
        return Ok(());
    }
    if conv
        .turns
        .last()
        .is_some_and(|t| t.role == turn.role && t.text.trim() == turn.text.trim())
    {
        return Ok(());
    }
    conv.turns.push(turn);
    save_yaml(&ws.conversation_path(task_id), &conv)
}

pub fn transition(
    task_id: &str,
    from: TaskState,
    to: TaskState,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> TransitionRecord {
    TransitionRecord {
        task_id: task_id.to_string(),
        intent_id: String::new(),
        from,
        to,
        cause,
        detail: detail.to_string(),
        actor,
        ts: Local::now().to_rfc3339(),
    }
}

pub fn append_transition(ws: &Workspace, rec: TransitionRecord) -> Result<()> {
    let rec = with_transition_intent(ws, rec);
    let mut log = ws.load_transition_log(&rec.task_id);
    if log.task_id.is_empty() {
        log.task_id = rec.task_id.clone();
    }
    if log.records.last().is_some_and(|last| {
        last.intent_id == rec.intent_id
            && last.from == rec.from
            && last.to == rec.to
            && last.cause == rec.cause
            && last.detail.trim() == rec.detail.trim()
    }) {
        return Ok(());
    }
    log.records.push(rec);
    save_yaml(&ws.transition_path(&log.task_id), &log)
}

fn with_transition_intent(ws: &Workspace, mut rec: TransitionRecord) -> TransitionRecord {
    if !rec.intent_id.is_empty() {
        return rec;
    }
    if let Ok(queue) = ws.load_queue() {
        if !queue.intent_id.is_empty() && queue.tasks.iter().any(|t| t.id == rec.task_id) {
            rec.intent_id = queue.intent_id;
        }
    }
    rec
}

/// Is the intent ready to surface a completion report? The queue must be
/// [`WorkQueue::drained`] AND carry no OPEN question. This is the completion
/// judgment, distinct from `drained()` (holds-inclusive): a `Deferred` task is a
/// settled human decision, so the intent may wrap with it recorded; a
/// `NeedsUser` task is an OPEN question the user still owes an answer to, so the
/// report must NOT fire `done/complete` while one is pending (finding 21 —
/// NeedsUser is gated apart from Deferred in the completion judgment). A
/// `Running` task is excluded implicitly: it is not terminal, so `drained()` is
/// already false.
pub fn ready_for_completion(queue: &WorkQueue) -> bool {
    !queue.tasks.is_empty()
        && queue.drained()
        && !queue
            .tasks
            .iter()
            .any(|t| matches!(t.state, TaskState::NeedsUser | TaskState::Partial))
}

/// Outcome of finalizing a merge-conflict `Partial` to `Done`.
pub struct ResolveOutcome {
    /// The worktree that was removed, if one was still on disk.
    pub removed_worktree: Option<PathBuf>,
    /// Whether a `partial-reason` marker was cleared.
    pub cleared_partial_reason: bool,
    /// Queued dependents whose dependencies are now all met.
    pub unblocked: Vec<String>,
}

/// Finalize a task left `Partial` by a merge conflict, once a human has manually
/// integrated its worktree (finding 23). Marks it `Done` through the sole state
/// writer — recording the transition to the audit log so Trust v2 sees the
/// Done-transition — clears the `partial-reason` marker, and removes the merged
/// worktree. No worker is re-invoked: the work is already integrated, so this is
/// pure bookkeeping. Errors if the task is missing or not `Partial`.
pub fn resolve_partial(ws: &Workspace, task_id: &str, detail: &str) -> Result<ResolveOutcome> {
    let lock = ws.acquire_planning_lock()?;
    let mut queue = ws.load_queue()?;
    let Some(idx) = queue.tasks.iter().position(|t| t.id == task_id) else {
        anyhow::bail!("task '{task_id}' not found in the queue");
    };
    let from = queue.tasks[idx].state;
    match from {
        TaskState::Partial => {}
        TaskState::Done => {
            anyhow::bail!("{task_id} is already Done — nothing to resolve")
        }
        other => anyhow::bail!(
            "{task_id} is {other:?}, not Partial — `resolve` only finalizes a Partial task whose \
             worktree you merged by hand"
        ),
    }
    queue.tasks[idx].state = TaskState::Done;
    // Yardlet stays the sole queue writer: persist, then record the transition.
    ws.save_queue_locked(&lock, &queue)?;
    append_transition(
        ws,
        transition(
            task_id,
            from,
            TaskState::Done,
            // Reuse the recovery cause: resolve reconciles stranded state after a
            // manual integration, the same family as orphan recovery. Actor=User
            // and the detail keep it audit-clear.
            TransitionCause::Recover,
            detail,
            TransitionActor::User,
        ),
    )?;

    // Clean up the run's Partial artifacts. The worktree's branch is already in
    // HEAD (the human merged it), so removing it strands nothing.
    let mut removed_worktree = None;
    let mut cleared_partial_reason = false;
    if let Some((_, run_dir)) = crate::run::latest_run_for(ws, task_id) {
        let marker = run_dir.join("partial-reason");
        if marker.exists() {
            let _ = fs::remove_file(&marker);
            cleared_partial_reason = true;
        }
        if let Some(wt) = crate::run::run_worktree(&run_dir).filter(|w| w.exists()) {
            let branch = format!("yard/{}", task_id.to_lowercase());
            crate::parallel::remove_worktree(&ws.root, &wt, &branch);
            removed_worktree = Some(wt);
        }
    }

    // Dependents that were only waiting on this task can now run.
    let unblocked = queue
        .tasks
        .iter()
        .filter(|t| {
            t.state == TaskState::Queued
                && t.depends_on.iter().any(|d| d == task_id)
                && queue.deps_met(t)
        })
        .map(|t| t.id.clone())
        .collect();

    Ok(ResolveOutcome {
        removed_worktree,
        cleared_partial_reason,
        unblocked,
    })
}

fn clear_intent_and_queue_with_wrap(
    ws: &Workspace,
    lock: &PlanningLock,
    queue: &WorkQueue,
    intent_id: &str,
) -> Result<()> {
    for task in &queue.tasks {
        append_transition(
            ws,
            transition(
                &task.id,
                task.state,
                task.state,
                TransitionCause::Wrap,
                &format!("archived drained intent {intent_id} and cleared the live queue"),
                TransitionActor::System,
            ),
        )?;
    }
    ws.clear_intent_and_queue_locked(lock)
}

pub fn write_str(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, contents).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Create an immutable private evidence file. On Unix the requested mode is
/// applied at inode creation, so there is no window where raw worker output is
/// readable by group or other users.
pub(crate) fn create_private_file(path: &Path) -> Result<fs::File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .with_context(|| format!("creating private evidence {}", path.display()))
}

/// Open a private append-only evidence file. `mode` affects creation only;
/// callers retain append semantics for a combined log shared by stream readers.
pub(crate) fn append_private_file(path: &Path) -> Result<fs::File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut options = fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .with_context(|| format!("opening private evidence {}", path.display()))
}

/// Write a durable state snapshot through a same-directory temporary file so a
/// crash cannot leave readers with a truncated JSON/YAML record.
pub fn write_str_atomic(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("state");
    let tmp = path.with_file_name(format!(".{file_name}.tmp-{}", std::process::id()));
    let mut file = fs::File::create(&tmp).with_context(|| format!("creating {}", tmp.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("writing {}", tmp.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", tmp.display()))?;
    fs::rename(&tmp, path)
        .with_context(|| format!("renaming {} to {}", tmp.display(), path.display()))?;
    Ok(())
}

fn write_private_str_atomic(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("private-state");
    let tmp = path.with_file_name(format!(".{file_name}.tmp-{}", std::process::id()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&tmp)
        .with_context(|| format!("creating private snapshot {}", tmp.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("writing {}", tmp.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", tmp.display()))?;
    fs::rename(&tmp, path)
        .with_context(|| format!("renaming {} to {}", tmp.display(), path.display()))?;
    Ok(())
}

/// Atomically create an immutable file without a check-then-replace race.
/// A fully synced temporary inode is linked into the final name with
/// no-clobber semantics. `Ok(false)` means another writer won the name.
fn write_str_atomic_create(path: &Path, contents: &str) -> Result<bool> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("immutable path has no parent: {}", path.display()))?;
    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("state");
    let mut created = None;
    for suffix in 0..1_000_u32 {
        let tmp = parent.join(format!(
            ".{file_name}.create-{}-{suffix}",
            std::process::id()
        ));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
        {
            Ok(file) => {
                created = Some((tmp, file));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error).with_context(|| format!("creating {}", tmp.display())),
        }
    }
    let (tmp, mut file) = created.ok_or_else(|| {
        anyhow::anyhow!("exhausted immutable temporary names for {}", path.display())
    })?;
    let written = (|| -> Result<()> {
        file.write_all(contents.as_bytes())
            .with_context(|| format!("writing {}", tmp.display()))?;
        file.sync_all()
            .with_context(|| format!("syncing {}", tmp.display()))?;
        Ok(())
    })();
    if let Err(error) = written {
        let _ = fs::remove_file(&tmp);
        return Err(error);
    }
    let linked = match fs::hard_link(&tmp, path) {
        Ok(()) => true,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => false,
        Err(error) => {
            let _ = fs::remove_file(&tmp);
            return Err(error).with_context(|| {
                format!("atomically creating immutable record {}", path.display())
            });
        }
    };
    fs::remove_file(&tmp).with_context(|| format!("removing {}", tmp.display()))?;
    Ok(linked)
}

fn write_str_atomic_cas(path: &Path, expected: Option<&str>, contents: &str) -> Result<()> {
    let current = if path.is_file() {
        Some(fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?)
    } else {
        None
    };
    if current.as_deref() != expected {
        bail!("compare_and_swap_conflict at {}", path.display());
    }
    write_str_atomic(path, contents)
}

pub fn append_str(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening {}", path.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Place one complete skill directory under `.agents/skills/` without ever
/// overwriting an existing entry. Callers provide the worker- or bundle-authored
/// files; this deterministic core function is the only canonical writer used by
/// both authored skills and managed built-ins.
pub fn place_skill_files_no_clobber(
    ws: &Workspace,
    name: &str,
    files: &[(String, String)],
) -> Result<bool> {
    use std::path::Component;

    let valid_name = !name.is_empty()
        && Path::new(name).components().count() == 1
        && Path::new(name)
            .components()
            .all(|c| matches!(c, Component::Normal(_)));
    if !valid_name || files.is_empty() {
        bail!("invalid or empty skill placement for '{name}'");
    }
    for (relative, _) in files {
        let path = Path::new(relative);
        if path.as_os_str().is_empty()
            || path.is_absolute()
            || !path.components().all(|c| matches!(c, Component::Normal(_)))
        {
            bail!("invalid skill file path '{relative}'");
        }
    }

    let skills = ws.agents_dir().join("skills");
    fs::create_dir_all(&skills)?;
    let dst = skills.join(name);
    if fs::symlink_metadata(&dst).is_ok() {
        return Ok(false);
    }

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let staging = skills.join(format!(
        ".yardlet-install-{name}-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&staging)?;
    let staged = (|| -> Result<()> {
        for (relative, contents) in files {
            write_str(&staging.join(relative), contents)?;
        }
        Ok(())
    })();
    if let Err(error) = staged {
        let _ = fs::remove_dir_all(&staging);
        return Err(error);
    }

    match fs::rename(&staging, &dst) {
        Ok(()) => Ok(true),
        Err(_error) if fs::symlink_metadata(&dst).is_ok() => {
            let _ = fs::remove_dir_all(&staging);
            Ok(false)
        }
        Err(error) => {
            let _ = fs::remove_dir_all(&staging);
            Err(error).with_context(|| format!("placing skill {}", dst.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONFIG_WITH_COMMENTS: &str = r#"schema_version: 1
product: yardlet
workspace_id: test-workspace
created_at: "2026-07-03T00:00:00Z"
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: ""
# language stays user-owned
language: auto
default_access: sandboxed # keep access comment
max_parallel: 1
auto_ime: true
ambiguity_gate: true
harness_discovery: true
skill_library: ""
auto_equip: true
auto_skill: true
auto_rule: false
auto_prune: true
hooks: true
auto_commit: false
"#;

    const WORKERS_WITH_COMMENTS: &str = r#"schema_version: 1
workers:
  - id: codex
    # user note for codex
    enabled: true # keep enabled comment
    model: "" # keep model comment
    effort: ""
    invocation:
      command: codex
  - id: claude-code
    # untouched worker comment
    enabled: true
    model: sonnet
    effort: medium
    invocation:
      command: claude
routing:
  default_worker: codex
  fallback_order: [codex, claude-code]
"#;

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("yard-{name}-{}", std::process::id()))
    }

    #[test]
    fn run_directory_claims_never_reuse_an_existing_id() {
        let dir = temp_root("unique-run-dir");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);

        let (first_id, first_dir) = ws.claim_run_dir("run-20990101-000000").unwrap();
        fs::write(first_dir.join("result.json"), "first").unwrap();
        let (second_id, second_dir) = ws.claim_run_dir("run-20990101-000000").unwrap();

        assert_eq!(first_id, "run-20990101-000000");
        assert_eq!(second_id, "run-20990101-000000-2");
        assert_ne!(first_dir, second_dir);
        assert_eq!(
            fs::read_to_string(first_dir.join("result.json")).unwrap(),
            "first"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn memory_writer_creates_docs_and_index_as_core() {
        let dir = temp_root("memory-writer");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        let report = ws
            .write_memory_documents(
                &[MemoryDocumentDraft {
                    slug: "runtime-routing".to_string(),
                    title: "Runtime routing".to_string(),
                    summary: "Routing is deterministic at runtime.".to_string(),
                    look_at: vec!["src/routing.rs".to_string()],
                    body: "---\nignored: true\n---\n# Runtime routing\n\nUse routing.rs as the source of truth."
                        .to_string(),
                }],
                MemoryWriteMode::Init,
            )
            .unwrap();
        assert_eq!(report.written, vec![".agents/memory/runtime-routing.md"]);
        assert_eq!(
            report.index_path,
            Some(".agents/memory/index.yaml".to_string())
        );

        let doc = fs::read_to_string(ws.memory_dir().join("runtime-routing.md")).unwrap();
        assert!(doc.contains("source: yardlet-memory-draft"));
        assert!(doc.contains("look_at:"));
        assert!(doc.contains("- src/routing.rs"));
        assert!(doc.contains("# Runtime routing"));
        assert!(!doc.contains("ignored: true"));

        let index = fs::read_to_string(ws.memory_dir().join("index.yaml")).unwrap();
        assert!(index.contains("schema_version: 1"));
        assert!(index.contains(".agents/memory/runtime-routing.md"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn memory_refresh_updates_existing_doc_only() {
        let dir = temp_root("memory-refresh");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        ws.write_memory_documents(
            &[MemoryDocumentDraft {
                slug: "existing".to_string(),
                title: "Existing".to_string(),
                summary: "Old".to_string(),
                look_at: vec![],
                body: "Old body".to_string(),
            }],
            MemoryWriteMode::Init,
        )
        .unwrap();

        let report = ws
            .write_memory_documents(
                &[
                    MemoryDocumentDraft {
                        slug: "existing".to_string(),
                        title: "Existing".to_string(),
                        summary: "New".to_string(),
                        look_at: vec![],
                        body: "New body".to_string(),
                    },
                    MemoryDocumentDraft {
                        slug: "new-doc".to_string(),
                        title: "New doc".to_string(),
                        summary: String::new(),
                        look_at: vec![],
                        body: "Must be skipped".to_string(),
                    },
                ],
                MemoryWriteMode::Refresh,
            )
            .unwrap();
        assert_eq!(report.written, vec![".agents/memory/existing.md"]);
        assert_eq!(report.skipped.len(), 1);
        assert!(!ws.memory_dir().join("new-doc.md").exists());
        let doc = fs::read_to_string(ws.memory_dir().join("existing.md")).unwrap();
        assert!(doc.contains("New body"));
        assert!(!doc.contains("Old body"));

        let _ = fs::remove_dir_all(&dir);
    }

    fn worker(text: &str, run_id: &str) -> ConversationTurn {
        ConversationTurn {
            role: TurnRole::Worker,
            text: text.into(),
            run_id: run_id.into(),
            ts: String::new(),
        }
    }
    fn user(text: &str) -> ConversationTurn {
        ConversationTurn {
            role: TurnRole::User,
            text: text.into(),
            run_id: String::new(),
            ts: String::new(),
        }
    }

    #[test]
    fn conversation_appends_dedupes_and_roundtrips() {
        let dir = std::env::temp_dir().join(format!("yard-conv-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        // First worker question seeds the transcript.
        append_conversation_turn(&ws, "YARD-1", worker("Forward+ or GL?", "run-1")).unwrap();
        // The same run's worker turn is deduped by run_id.
        append_conversation_turn(&ws, "YARD-1", worker("dup of run-1", "run-1")).unwrap();
        // A user reply lands.
        append_conversation_turn(&ws, "YARD-1", user("what is Forward+?")).unwrap();
        // An identical consecutive user turn is skipped.
        append_conversation_turn(&ws, "YARD-1", user("what is Forward+?")).unwrap();
        // A worker turn from a different run lands.
        append_conversation_turn(
            &ws,
            "YARD-1",
            worker("Forward+ is the advanced path", "run-2"),
        )
        .unwrap();

        let conv = ws.load_conversation("YARD-1");
        assert_eq!(conv.task_id, "YARD-1");
        assert_eq!(conv.turns.len(), 3, "the two duplicate turns are dropped");
        assert_eq!(conv.turns[0].role, TurnRole::Worker);
        assert_eq!(conv.turns[0].text, "Forward+ or GL?");
        assert_eq!(conv.turns[1].role, TurnRole::User);
        assert_eq!(conv.turns[2].run_id, "run-2");

        // A task that never paused reads as an empty transcript.
        assert!(ws.load_conversation("YARD-2").turns.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    fn channel_event(kind: ChannelEventType, attempt_id: Option<&str>) -> ChannelEvent {
        ChannelEvent {
            schema_version: 1,
            event_id: String::new(),
            session_id: "ses_channel".into(),
            seq: 0,
            event_type: kind,
            recorded_at: "2026-07-14T00:00:00Z".into(),
            actor: EventActor {
                kind: EventActorKind::Worker,
                id: "codex".into(),
            },
            action_id: None,
            causation_id: None,
            correlation_id: "cor_channel".into(),
            task_id: "YARD-001".into(),
            attempt_id: attempt_id.map(str::to_string),
            payload: serde_json::json!({"text": "progress"}),
            raw_ref: None,
        }
    }

    fn prepared_attempt(id: &str) -> WorkerAttempt {
        WorkerAttempt {
            schema_version: 1,
            attempt_id: id.into(),
            session_id: "ses_channel".into(),
            intent_id: "intent_channel".into(),
            task_id: "YARD-001".into(),
            worker_id: "codex".into(),
            worker_session_ref: Some("thread-1".into()),
            state: AttemptState::Prepared,
            continuation: ContinuationMode::Fresh,
            caused_by_event_id: None,
            caused_by_action_id: None,
            raw_stdout_ref: format!("attempts/{id}/stdout.log"),
            raw_stderr_ref: format!("attempts/{id}/stderr.log"),
        }
    }

    #[test]
    fn artifact_proposal_replay_accepts_a_new_source_location_but_rejects_mutation() {
        let dir = temp_root("artifact-proposal-source-replay");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        let attempt_id = "att_artifact_replay";
        let mut attempt = prepared_attempt(attempt_id);
        attempt.raw_stdout_ref = format!("attempts/{attempt_id}/stdout.log");
        attempt.raw_stderr_ref = format!("attempts/{attempt_id}/stderr.log");
        ws.record_worker_attempt(&attempt).unwrap();

        let mut completed = channel_event(ChannelEventType::WorkerCompleted, Some(attempt_id));
        completed.payload = serde_json::json!({"worker_id": "codex", "outcome": "succeeded"});
        ws.record_task_event("intent_channel", completed).unwrap();

        let proposal = ArtifactProposal {
            proposal_id: "proposal_guard_rs".into(),
            task_id: "YARD-001".into(),
            attempt_id: attempt_id.into(),
            producer: crate::schemas::ResourceProducer {
                worker_id: "codex".into(),
            },
            causation_id: attempt_id.into(),
            path: "src/guard.rs".into(),
            digest: "fnv1a64:0123456789abcdef".into(),
            media_type: "text/plain".into(),
            role: crate::schemas::ArtifactRole::File,
            channel_role: "worker_declared".into(),
            worker_authored: None,
        };

        let first = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &proposal,
                "/workspace/.agents/worktrees/run-yard-010/src/guard.rs",
            )
            .unwrap();
        let replay = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &proposal,
                "/workspace/src/guard.rs",
            )
            .expect("recovery must replay the same proposal from the workspace root");

        assert_eq!(replay, first);
        assert_eq!(ws.load_artifacts().unwrap(), vec![first]);

        let mut mutated = proposal.clone();
        mutated.digest = "fnv1a64:fedcba9876543210".into();
        let error = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &mutated,
                "/workspace/src/guard.rs",
            )
            .unwrap_err();
        assert!(
            error.to_string().contains("artifact_proposal_conflict"),
            "{error:#}"
        );
        let mut mutated = proposal;
        mutated.path = "src/guard-mutated.rs".into();
        let error = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &mutated,
                "/workspace/src/guard-mutated.rs",
            )
            .unwrap_err();
        assert!(
            error.to_string().contains("artifact_proposal_conflict"),
            "{error:#}"
        );
        assert_eq!(ws.load_artifacts().unwrap().len(), 1);

        let _ = fs::remove_dir_all(&dir);
    }

    fn authorship_proposal(
        attempt_id: &str,
        suffix: &str,
        worker_authored: Option<bool>,
    ) -> ArtifactProposal {
        ArtifactProposal {
            proposal_id: format!("proposal_authorship_{suffix}"),
            task_id: "YARD-001".into(),
            attempt_id: attempt_id.into(),
            producer: crate::schemas::ResourceProducer {
                worker_id: "codex".into(),
            },
            causation_id: attempt_id.into(),
            path: format!("runs/run-authorship/{suffix}.md"),
            digest: "fnv1a64:0123456789abcdef".into(),
            media_type: "text/markdown".into(),
            role: crate::schemas::ArtifactRole::Handoff,
            channel_role: "handoff".into(),
            worker_authored,
        }
    }

    #[test]
    fn artifact_publication_persists_worker_authorship_in_payload_and_record() {
        let dir = temp_root("artifact-authorship-payload");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        let attempt_id = "att_authorship";
        ws.record_worker_attempt(&prepared_attempt(attempt_id))
            .unwrap();
        let mut completed = channel_event(ChannelEventType::WorkerCompleted, Some(attempt_id));
        completed.payload = serde_json::json!({"worker_id": "codex", "outcome": "succeeded"});
        ws.record_task_event("intent_channel", completed).unwrap();

        let authored = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &authorship_proposal(attempt_id, "worker", Some(true)),
                "/runs/run-authorship/worker.md",
            )
            .unwrap();
        let fallback = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &authorship_proposal(attempt_id, "fallback", Some(false)),
                "/runs/run-authorship/fallback.md",
            )
            .unwrap();
        assert_eq!(authored.worker_authored, Some(true));
        assert_eq!(fallback.worker_authored, Some(false));

        let channel = ws.load_task_channel("intent_channel", "YARD-001").unwrap();
        let payload_for = |artifact_id: &str| {
            channel
                .events
                .iter()
                .find(|event| {
                    event.event_type == ChannelEventType::ArtifactCreated
                        && event.payload["artifact_id"] == artifact_id
                })
                .unwrap_or_else(|| panic!("artifact.created missing for {artifact_id}"))
                .payload["worker_authored"]
                .clone()
        };
        assert_eq!(
            payload_for(&authored.artifact_id),
            serde_json::Value::Bool(true),
            "worker-authored artifact must record worker_authored=true in its payload"
        );
        assert_eq!(
            payload_for(&fallback.artifact_id),
            serde_json::Value::Bool(false),
            "core-authored artifact must record worker_authored=false in its payload"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn artifact_replay_over_pre_authorship_record_passes_without_conflict() {
        let dir = temp_root("artifact-authorship-replay");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        let attempt_id = "att_pre_authorship";
        ws.record_worker_attempt(&prepared_attempt(attempt_id))
            .unwrap();
        let mut completed = channel_event(ChannelEventType::WorkerCompleted, Some(attempt_id));
        completed.payload = serde_json::json!({"worker_id": "codex", "outcome": "succeeded"});
        ws.record_task_event("intent_channel", completed).unwrap();

        // A proposal without authorship serializes exactly like a record
        // published by a pre-authorship binary: no `worker_authored` key.
        let pre_field = authorship_proposal(attempt_id, "handoff", None);
        let first = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &pre_field,
                "/worktree/runs/run-authorship/handoff.md",
            )
            .unwrap();
        assert_eq!(first.worker_authored, None);
        let record = fs::read_to_string(
            ws.artifacts_dir()
                .join(format!("{}.yaml", first.artifact_id)),
        )
        .unwrap();
        assert!(
            !record.contains("worker_authored"),
            "pre-authorship record shape must omit the key entirely: {record}"
        );

        let mut replayed = pre_field.clone();
        replayed.worker_authored = Some(true);
        let replay = ws
            .publish_artifact(
                "ses_channel",
                "intent_channel",
                &replayed,
                "/workspace/runs/run-authorship/handoff.md",
            )
            .expect("recovery replay over a pre-authorship record must not conflict");
        assert_eq!(replay, first, "the first canonical record is preserved");
        assert_eq!(ws.load_artifacts().unwrap().len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn channel_replay_recovers_a_deleted_or_malformed_bounded_index() {
        let dir = temp_root("channel-index-replay");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        ws.record_worker_attempt(&prepared_attempt("att_1"))
            .unwrap();
        let raw_path = ws
            .task_channel_dir("intent_channel", "YARD-001")
            .join("attempts/att_1/stdout.log");
        fs::create_dir_all(raw_path.parent().unwrap()).unwrap();
        fs::write(&raw_path, b"durable raw evidence").unwrap();

        let mut prepared = channel_event(ChannelEventType::AttemptPrepared, Some("att_1"));
        prepared.payload = serde_json::json!({"worker_id": "codex"});
        ws.record_task_event("intent_channel", prepared).unwrap();
        for index in 0..140 {
            let mut event = channel_event(ChannelEventType::WorkerMessage, Some("att_1"));
            event.payload = serde_json::json!({"text": format!("message-{index}")});
            ws.record_task_event("intent_channel", event).unwrap();
        }

        let original = ws
            .load_or_rebuild_task_channel("intent_channel", "YARD-001")
            .unwrap();
        let index_path = ws.task_channel_index_path("intent_channel", "YARD-001");
        let bounded: TaskChannelIndex = load_yaml(&index_path).unwrap();
        assert_eq!(original.events.len(), 141);
        assert!(bounded.tail_events.len() <= CHANNEL_INDEX_EVENT_LIMIT);
        assert_eq!(bounded.highest_applied_seq, 141);

        fs::remove_file(&index_path).unwrap();
        drop(ws);
        let restarted = Workspace::at(&dir);
        let rebuilt = restarted
            .load_or_rebuild_task_channel("intent_channel", "YARD-001")
            .unwrap();
        assert_eq!(rebuilt, original);
        assert!(index_path.is_file());
        assert_eq!(fs::read(&raw_path).unwrap(), b"durable raw evidence");

        fs::write(&index_path, "not: [valid yaml").unwrap();
        let repaired = restarted
            .load_or_rebuild_task_channel("intent_channel", "YARD-001")
            .unwrap();
        assert_eq!(repaired, original);
        let repaired_index: TaskChannelIndex = load_yaml(&index_path).unwrap();
        assert_eq!(repaired_index.highest_applied_seq, 141);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn channel_events_share_one_strict_sequence_across_tasks_in_a_session() {
        let dir = temp_root("channel-session-sequence");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);

        let mut first = channel_event(ChannelEventType::WorkerMessage, Some("att_1"));
        first.task_id = "YARD-001".into();
        let mut second = channel_event(ChannelEventType::WorkerMessage, Some("att_2"));
        second.task_id = "YARD-002".into();
        let first = ws.record_task_event("intent_channel", first).unwrap();
        let second = ws.record_task_event("intent_channel", second).unwrap();

        assert_eq!(first.seq, 1);
        assert_eq!(second.seq, 2);
        assert_eq!(
            ws.load_task_channel("intent_channel", "YARD-001")
                .unwrap()
                .events[0]
                .seq,
            1
        );
        assert_eq!(
            ws.load_task_channel("intent_channel", "YARD-002")
                .unwrap()
                .events[0]
                .seq,
            2
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn answer_action_is_exact_idempotent_and_creates_a_new_continuation_attempt() {
        let dir = temp_root("channel-answer-action");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        ws.record_worker_attempt(&prepared_attempt("att_1"))
            .unwrap();

        let asked = ws
            .record_task_event(
                "intent_channel",
                channel_event(ChannelEventType::QuestionAsked, Some("att_1")),
            )
            .unwrap();
        ws.record_question(&Question {
            schema_version: 1,
            question_id: "qst_1".into(),
            session_id: "ses_channel".into(),
            task_id: "YARD-001".into(),
            attempt_id: "att_1".into(),
            asked_event_id: asked.event_id.clone(),
            asked_seq: asked.seq,
            context_start_seq: 1,
            text: "Which path?".into(),
            state: QuestionState::Open,
            answer_id: None,
        })
        .unwrap();

        let request = AnswerActionRequest {
            action_id: "act_answer_1".into(),
            answer_id: "ans_1".into(),
            continuation_attempt_id: "att_2".into(),
            session_id: "ses_channel".into(),
            intent_id: "intent_channel".into(),
            task_id: "YARD-001".into(),
            question_id: "qst_1".into(),
            text: "Path A".into(),
            worker_id: "codex".into(),
            worker_session_ref: Some("thread-1".into()),
            supports_native_resume: false,
        };
        let first = ws.answer_question(&request).unwrap();
        let duplicate = ws.answer_question(&request).unwrap();
        assert_eq!(duplicate, first);
        assert_eq!(first.attempt.attempt_id, "att_2");
        assert_eq!(first.attempt.continuation, ContinuationMode::ExplicitPacket);
        assert_eq!(first.answer.question_id, "qst_1");

        let channel = ws.load_task_channel("intent_channel", "YARD-001").unwrap();
        assert_eq!(channel.answers.len(), 1);
        assert_eq!(channel.attempts.len(), 2);

        let mut conflicting = request.clone();
        conflicting.text = "Path B".into();
        assert!(ws
            .answer_question(&conflicting)
            .unwrap_err()
            .to_string()
            .contains("idempotency_conflict"));

        let mut stale = request;
        stale.action_id = "act_answer_2".into();
        stale.answer_id = "ans_2".into();
        stale.continuation_attempt_id = "att_3".into();
        assert!(ws
            .answer_question(&stale)
            .unwrap_err()
            .to_string()
            .contains("question_closed"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn answer_action_rejects_unsafe_action_id_before_writing_a_receipt() {
        for label in ["absolute", "parent"] {
            let dir = temp_root(&format!("channel-unsafe-action-{label}"));
            let _ = fs::remove_dir_all(&dir);
            let ws = Workspace::at(&dir);
            let action_id = if label == "absolute" {
                dir.join("escaped-action-receipt").display().to_string()
            } else {
                "../escaped-action-receipt".to_string()
            };
            ws.record_worker_attempt(&prepared_attempt("att_1"))
                .unwrap();
            let asked = ws
                .record_task_event(
                    "intent_channel",
                    channel_event(ChannelEventType::QuestionAsked, Some("att_1")),
                )
                .unwrap();
            ws.record_question(&Question {
                schema_version: 1,
                question_id: "qst_unsafe".into(),
                session_id: "ses_channel".into(),
                task_id: "YARD-001".into(),
                attempt_id: "att_1".into(),
                asked_event_id: asked.event_id,
                asked_seq: asked.seq,
                context_start_seq: 1,
                text: "Continue?".into(),
                state: QuestionState::Open,
                answer_id: None,
            })
            .unwrap();
            let request = AnswerActionRequest {
                action_id,
                answer_id: "ans_unsafe".into(),
                continuation_attempt_id: "att_unsafe".into(),
                session_id: "ses_channel".into(),
                intent_id: "intent_channel".into(),
                task_id: "YARD-001".into(),
                question_id: "qst_unsafe".into(),
                text: "Continue".into(),
                worker_id: "generic-text".into(),
                worker_session_ref: None,
                supports_native_resume: false,
            };

            let error = ws.answer_question(&request).unwrap_err();
            assert!(
                error.to_string().contains("invalid action id"),
                "unexpected error for {label}: {error}"
            );
            assert!(
                ws.task_channel_dir("intent_channel", "YARD-001")
                    .join("actions")
                    .read_dir()
                    .is_err(),
                "unsafe {label} action id created an action receipt"
            );
            let _ = fs::remove_dir_all(&dir);
        }
    }

    #[test]
    fn answer_action_recovers_after_restart_from_a_prepared_receipt() {
        let dir = temp_root("channel-answer-restart");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        ws.record_worker_attempt(&prepared_attempt("att_1"))
            .unwrap();
        let asked = ws
            .record_task_event(
                "intent_channel",
                channel_event(ChannelEventType::QuestionAsked, Some("att_1")),
            )
            .unwrap();
        ws.record_question(&Question {
            schema_version: 1,
            question_id: "qst_restart".into(),
            session_id: "ses_channel".into(),
            task_id: "YARD-001".into(),
            attempt_id: "att_1".into(),
            asked_event_id: asked.event_id,
            asked_seq: asked.seq,
            context_start_seq: 1,
            text: "Continue?".into(),
            state: QuestionState::Open,
            answer_id: None,
        })
        .unwrap();
        let request = AnswerActionRequest {
            action_id: "act_restart".into(),
            answer_id: "ans_restart".into(),
            continuation_attempt_id: "att_restart".into(),
            session_id: "ses_channel".into(),
            intent_id: "intent_channel".into(),
            task_id: "YARD-001".into(),
            question_id: "qst_restart".into(),
            text: "Continue".into(),
            worker_id: "generic-text".into(),
            worker_session_ref: None,
            supports_native_resume: false,
        };
        let digest = channel_action_digest(&request).unwrap();
        save_immutable_yaml(
            &ws.channel_action_path("intent_channel", "YARD-001", &request.action_id, false)
                .unwrap(),
            &ActionReceipt {
                schema_version: 1,
                action_id: request.action_id.clone(),
                session_id: request.session_id.clone(),
                task_id: request.task_id.clone(),
                action: ChannelActionKind::Answer,
                request_digest: digest,
                status: ChannelActionStatus::Prepared,
                result_event_ids: Vec::new(),
                result_attempt_id: Some(request.continuation_attempt_id.clone()),
                error: String::new(),
            },
        )
        .unwrap();
        drop(ws);

        let restarted = Workspace::at(&dir);
        let outcome = restarted.answer_question(&request).unwrap();
        assert_eq!(outcome.receipt.status, ChannelActionStatus::Completed);
        assert_eq!(
            outcome.attempt.continuation,
            ContinuationMode::ExplicitPacket
        );
        assert_eq!(restarted.answer_question(&request).unwrap(), outcome);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn redirect_requires_observed_terminal_state_before_new_guidance_attempt() {
        let dir = temp_root("channel-redirect-action");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        ws.record_worker_attempt(&prepared_attempt("att_1"))
            .unwrap();
        ws.record_task_event(
            "intent_channel",
            channel_event(ChannelEventType::AttemptPrepared, Some("att_1")),
        )
        .unwrap();

        let request = RedirectActionRequest {
            action_id: "act_redirect_1".into(),
            continuation_attempt_id: "att_2".into(),
            session_id: "ses_channel".into(),
            intent_id: "intent_channel".into(),
            task_id: "YARD-001".into(),
            stopped_attempt_id: "att_1".into(),
            observed_terminal_state: AttemptState::Cancelled,
            reason: "user changed the target".into(),
            guidance: "build path B".into(),
            worker_id: "codex".into(),
            checkpoint_ref: None,
        };
        assert!(ws
            .redirect_task(&request)
            .unwrap_err()
            .to_string()
            .contains("redirect_requires_observed_terminal"));

        let mut completed = channel_event(ChannelEventType::WorkerCompleted, Some("att_1"));
        completed.payload = serde_json::json!({"result": "cancelled", "reason": "user stop"});
        ws.record_task_event("intent_channel", completed).unwrap();

        let first = ws.redirect_task(&request).unwrap();
        let duplicate = ws.redirect_task(&request).unwrap();
        assert_eq!(first, duplicate);
        assert_eq!(first.attempt.attempt_id, "att_2");
        assert_eq!(first.attempt.continuation, ContinuationMode::Redirect);
        assert!(first.attempt.worker_session_ref.is_none());
        let channel = ws.load_task_channel("intent_channel", "YARD-001").unwrap();
        assert_eq!(channel.attempts.len(), 2);
        assert!(channel.events.iter().any(|event| {
            event.event_type == ChannelEventType::ActionRequested
                && event.payload["reason"] == "user changed the target"
        }));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn transition_log_appends_and_dedupes_last_reason() {
        let dir = temp_root("transition-log");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        let rec = transition(
            "YARD-1",
            TaskState::Queued,
            TaskState::Deferred,
            TransitionCause::Defer,
            "set aside for later",
            TransitionActor::User,
        );
        append_transition(&ws, rec.clone()).unwrap();
        append_transition(&ws, rec).unwrap();

        let log = ws.load_transition_log("YARD-1");
        assert_eq!(log.records.len(), 1);
        assert_eq!(
            ws.latest_transition("YARD-1").unwrap().detail,
            "set aside for later"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn transition_log_stamps_intent_from_live_queue() {
        let dir = temp_root("transition-intent");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);

        let task: Task = crate::yaml::from_str("id: YARD-1\ntitle: test task\n").unwrap();
        let mut queue = WorkQueue::empty();
        queue.intent_id = "intent-live".to_string();
        queue.tasks = vec![task];
        ws.save_queue(&queue).unwrap();

        append_transition(
            &ws,
            transition(
                "YARD-1",
                TaskState::Queued,
                TaskState::Running,
                TransitionCause::RunOutcome,
                "worker run started",
                TransitionActor::System,
            ),
        )
        .unwrap();

        let log = ws.load_transition_log("YARD-1");
        assert_eq!(log.records[0].intent_id, "intent-live");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_transition_records_without_intent_still_read() {
        let dir = temp_root("legacy-transition-intent");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        fs::create_dir_all(ws.transitions_dir()).unwrap();
        fs::write(
            ws.transition_path("YARD-1"),
            r#"task_id: YARD-1
records:
  - task_id: YARD-1
    from: queued
    to: done
    cause: run_outcome
    detail: old record
    actor:
      kind: system
    ts: "2026-07-08T00:00:00+09:00"
"#,
        )
        .unwrap();

        let log = ws.load_transition_log("YARD-1");
        assert_eq!(log.records.len(), 1);
        assert_eq!(log.records[0].intent_id, "");
        assert_eq!(log.records[0].to, TaskState::Done);
        assert_eq!(
            ws.latest_transition_for_intent("YARD-1", "")
                .unwrap()
                .detail,
            "old record"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn latest_transition_for_intent_filters_reused_task_history_without_rewriting_it() {
        let dir = temp_root("transition-intent-scope");
        let _ = fs::remove_dir_all(&dir);
        let ws = Workspace::at(&dir);
        fs::create_dir_all(ws.transitions_dir()).unwrap();
        let historical = r#"task_id: SHARED
records:
  - task_id: SHARED
    intent_id: intent-old
    from: queued
    to: failed
    cause: run_outcome
    detail: stale intent reason
    actor:
      kind: system
    ts: "2026-07-08T00:00:00+09:00"
  - task_id: SHARED
    intent_id: intent-current
    from: queued
    to: needs_user
    cause: run_outcome
    detail: current intent reason
    actor:
      kind: system
    ts: "2026-07-09T00:00:00+09:00"
  - task_id: SHARED
    intent_id: intent-old
    from: failed
    to: done
    cause: recover
    detail: later stale audit entry
    actor:
      kind: user
    ts: "2026-07-10T00:00:00+09:00"
"#;
        fs::write(ws.transition_path("SHARED"), historical).unwrap();

        assert_eq!(
            ws.latest_transition_for_intent("SHARED", "intent-current")
                .unwrap()
                .detail,
            "current intent reason"
        );
        assert_eq!(
            ws.latest_transition_for_intent("SHARED", "intent-old")
                .unwrap()
                .detail,
            "later stale audit entry"
        );
        assert!(ws
            .latest_transition_for_intent("SHARED", "intent-missing")
            .is_none());
        assert_eq!(
            fs::read_to_string(ws.transition_path("SHARED")).unwrap(),
            historical,
            "intent-scoped reads must not rewrite history"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn load_all_transition_logs_reads_every_task_deterministically() {
        let dir = temp_root("all-transitions");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        // A missing transitions dir is simply no logs, not an error.
        assert!(ws.load_all_transition_logs().is_empty());

        append_transition(
            &ws,
            transition(
                "YARD-2",
                TaskState::Running,
                TaskState::Done,
                TransitionCause::RunOutcome,
                "worker evaluated task as Done",
                TransitionActor::Worker("run-2".into()),
            ),
        )
        .unwrap();
        append_transition(
            &ws,
            transition(
                "YARD-1",
                TaskState::Queued,
                TaskState::Deferred,
                TransitionCause::Defer,
                "set aside",
                TransitionActor::User,
            ),
        )
        .unwrap();

        let logs = ws.load_all_transition_logs();
        assert_eq!(logs.len(), 2);
        // Ordered by task id (path sort), not by write order.
        assert_eq!(logs[0].task_id, "YARD-1");
        assert_eq!(logs[1].task_id, "YARD-2");
        assert_eq!(logs[1].records[0].cause, TransitionCause::RunOutcome);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tidy_migrates_stale_decision_and_defers_tool_gap_without_deleting_done() {
        let dir = temp_root("tidy-state");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let mut decision: Task =
            crate::yaml::from_str("id: DECIDE\ntitle: pick option\nrequired_capabilities: [user_creative_direction_approval]\n").unwrap();
        decision.state = TaskState::Blocked;
        let mut tool: Task =
            crate::yaml::from_str("id: TOOL\ntitle: import licensed asset\nrequired_capabilities: [licensed_3d_asset_intake]\n").unwrap();
        tool.state = TaskState::Blocked;
        let mut done: Task = crate::yaml::from_str("id: DONE\ntitle: done\n").unwrap();
        done.state = TaskState::Done;
        let mut queue = WorkQueue::empty();
        queue.tasks = vec![decision, tool, done];
        ws.save_queue(&queue).unwrap();

        let report = ws.tidy().unwrap();

        assert_eq!(report.migrated_decisions, vec!["DECIDE".to_string()]);
        assert_eq!(report.deferred, vec!["TOOL".to_string()]);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].state, TaskState::NeedsUser);
        assert!(q.tasks[0].required_capabilities.is_empty());
        assert_eq!(q.tasks[1].state, TaskState::Deferred);
        assert_eq!(q.tasks[2].state, TaskState::Done);
        assert_eq!(
            ws.latest_transition("DECIDE").unwrap().cause,
            TransitionCause::StaleMigration
        );
        assert_eq!(
            ws.latest_transition("TOOL").unwrap().cause,
            TransitionCause::TidyDefer
        );
        assert!(!ws.load_conversation("DECIDE").turns.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_queue_loads_as_empty() {
        let dir = std::env::temp_dir().join(format!("yard-noqueue-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        // This workspace has no work-queue.yaml at all.
        assert!(!ws.queue_path().exists());

        // Loading must not error; an absent queue reads as empty (runtime state,
        // not config, so a fresh or queue-gitignoring checkout has none).
        let q = ws
            .load_queue()
            .expect("a missing queue must load as empty, not error");
        assert!(q.tasks.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_user_task_preserves_existing_runtime_queue() {
        let dir = std::env::temp_dir().join(format!("yard-add-task-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);
        let mut queue = WorkQueue::empty();
        queue.tasks.push(Task {
            id: "YARD-001".to_string(),
            title: "running".to_string(),
            state: TaskState::Running,
            priority: 10,
            risk: "medium".to_string(),
            kind: "implementation".to_string(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: Vec::new(),
            skills: Vec::new(),
            required_capabilities: Vec::new(),
            allowed_scope: Vec::new(),
            acceptance: Vec::new(),
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        });
        ws.save_queue(&queue).unwrap();

        let added = ws
            .append_user_task(UserTaskInput {
                title: "새 독립 작업".to_string(),
                risk: "low".to_string(),
                kind: "implementation".to_string(),
                preferred_worker: String::new(),
                depends_on: Vec::new(),
                allowed_scope: vec!["src/run.rs".to_string()],
            })
            .unwrap();

        let q = ws.load_queue().unwrap();
        assert_eq!(added.id, "YARD-002");
        assert_eq!(q.tasks.len(), 2);
        assert_eq!(q.tasks[0].state, TaskState::Running);
        assert_eq!(q.tasks[1].id, "YARD-002");
        assert_eq!(q.tasks[1].state, TaskState::Queued);
        assert!(q.tasks[1].depends_on.is_empty());
        assert_eq!(q.tasks[1].provenance, "user-added");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn serde_yaml_save_reproduces_comment_loss_for_user_config_files() {
        let dir = temp_root("serde-comment-loss");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let cfg: YardConfig = load_yaml(&ws.config_path()).unwrap();
        save_yaml(&ws.config_path(), &cfg).unwrap();
        let rewritten_config = fs::read_to_string(ws.config_path()).unwrap();
        assert!(!rewritten_config.contains("language stays user-owned"));
        assert!(!rewritten_config.contains("keep access comment"));

        let workers: WorkersFile = load_yaml(&ws.workers_path()).unwrap();
        save_yaml(&ws.workers_path(), &workers).unwrap();
        let rewritten_workers = fs::read_to_string(ws.workers_path()).unwrap();
        assert!(!rewritten_workers.contains("user note for codex"));
        assert!(!rewritten_workers.contains("untouched worker comment"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn config_preserving_save_noops_and_keeps_legacy_path() {
        let dir = temp_root("legacy-config-preserve");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        let legacy = ws.agents_dir().join(LEGACY_CONFIG_FILE);
        fs::write(&legacy, CONFIG_WITH_COMMENTS).unwrap();

        assert_eq!(ws.config_path(), legacy);
        let before = fs::read(&legacy).unwrap();
        let cfg = ws.load_config().unwrap();
        assert!(!cfg.git_finish.auto_push);
        assert!(cfg.git_finish.remote.is_empty());
        assert!(cfg.git_finish.target_ref.is_empty());
        assert!(!save_config_preserving_format(&ws.config_path(), &cfg).unwrap());
        assert_eq!(fs::read(&legacy).unwrap(), before);
        assert!(!ws.agents_dir().join(CONFIG_FILE).exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn config_preserving_save_changes_only_target_scalar_lines() {
        let dir = temp_root("config-target-edit");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();

        let mut cfg = ws.load_config().unwrap();
        cfg.default_access = "full".to_string();
        cfg.language = "ko".to_string();
        assert!(save_config_preserving_format(&ws.config_path(), &cfg).unwrap());
        let updated = fs::read_to_string(ws.config_path()).unwrap();
        assert!(updated.contains("# language stays user-owned"));
        assert!(updated.contains("language: ko"));
        assert!(updated.contains("default_access: full # keep access comment"));
        assert!(updated.contains("workspace_id: test-workspace"));
        assert!(updated.contains("auto_commit: false"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn planning_worker_config_defaults_to_auto_when_keys_are_missing() {
        let dir = temp_root("planning-config-default");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();

        let cfg = ws.load_planning_worker_config().unwrap();
        assert_eq!(cfg.planning_model, "auto");
        assert_eq!(cfg.planning_effort, "auto");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn planning_worker_config_reads_explicit_model_and_effort() {
        let dir = temp_root("planning-config-explicit");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        let config =
            format!("{CONFIG_WITH_COMMENTS}planning_model: gpt-5.5\nplanning_effort: high\n");
        fs::write(ws.config_path(), config).unwrap();

        let cfg = ws.load_planning_worker_config().unwrap();
        assert_eq!(cfg.planning_model, "gpt-5.5");
        assert_eq!(cfg.planning_effort, "high");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn workers_preserving_save_changes_only_target_worker_keys() {
        let dir = temp_root("workers-target-edit");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let before = fs::read_to_string(ws.workers_path()).unwrap();
        let mut workers = ws.load_workers().unwrap();
        let codex = workers
            .workers
            .iter_mut()
            .find(|w| w.id == "codex")
            .unwrap();
        codex.enabled = false;
        codex.model = "gpt-5".to_string();
        codex.effort = "high".to_string();
        assert!(save_workers_preserving_format(&ws.workers_path(), &workers).unwrap());
        let updated = fs::read_to_string(ws.workers_path()).unwrap();
        assert_ne!(updated, before);
        assert!(updated.contains("# user note for codex"));
        assert!(updated.contains("enabled: false # keep enabled comment"));
        assert!(updated.contains("model: \"gpt-5\" # keep model comment"));
        assert!(updated.contains("effort: \"high\""));
        assert!(updated.contains("# untouched worker comment"));
        assert!(updated.contains("model: sonnet"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn workers_preserving_save_noops_when_values_are_unchanged() {
        let dir = temp_root("workers-noop");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let before = fs::read(ws.workers_path()).unwrap();
        let workers = ws.load_workers().unwrap();
        assert!(!save_workers_preserving_format(&ws.workers_path(), &workers).unwrap());
        assert_eq!(fs::read(ws.workers_path()).unwrap(), before);

        let _ = fs::remove_dir_all(&dir);
    }

    fn task_in(id: &str, state: &str) -> Task {
        crate::yaml::from_str(&format!("id: {id}\ntitle: {id}\nstate: {state}\n")).unwrap()
    }

    fn queue_of(states: &[(&str, &str)]) -> WorkQueue {
        let mut q = WorkQueue::empty();
        q.tasks = states.iter().map(|(id, s)| task_in(id, s)).collect();
        q
    }

    #[test]
    fn ready_for_completion_gates_needs_user_apart_from_deferred() {
        // finding 21: a Deferred task is a settled decision, so the intent may
        // wrap; a NeedsUser task is an OPEN question — the completion report must
        // not fire while one is pending. Both are `is_terminal`, so `drained()`
        // cannot tell them apart; the completion judgment must.
        assert!(queue_of(&[("A", "done"), ("B", "deferred")]).drained());
        assert!(ready_for_completion(&queue_of(&[
            ("A", "done"),
            ("B", "deferred")
        ])));

        assert!(queue_of(&[("A", "done"), ("B", "needs_user")]).drained());
        assert!(
            !ready_for_completion(&queue_of(&[("A", "done"), ("B", "needs_user")])),
            "an open NeedsUser question must gate completion"
        );
        assert!(queue_of(&[("A", "done"), ("B", "partial")]).drained());
        assert!(
            !ready_for_completion(&queue_of(&[("A", "done"), ("B", "partial")])),
            "an unverified Git finish projected as Partial must gate completion"
        );

        // Not drained / empty are never complete.
        assert!(!ready_for_completion(&queue_of(&[
            ("A", "done"),
            ("B", "queued")
        ])));
        assert!(!ready_for_completion(&queue_of(&[("A", "running")])));
        assert!(!ready_for_completion(&WorkQueue::empty()));
        // A fully-Done queue is complete.
        assert!(ready_for_completion(&queue_of(&[
            ("A", "done"),
            ("B", "done")
        ])));
    }

    #[test]
    fn resolve_partial_finalizes_and_records_transition() {
        // finding 23: a merge-conflict Partial is finalized to Done by a single
        // command — state.rs is the sole writer, the transition lands in the
        // audit log, the partial-reason marker is cleared, and a queued dependent
        // is unblocked. No worker is re-invoked (resolve is pure bookkeeping).
        let dir = temp_root("resolve-partial");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);

        let mut queue = WorkQueue::empty();
        queue.intent_id = "intent-live".to_string();
        let mut dependent = task_in("YARD-002", "queued");
        dependent.depends_on = vec!["YARD-001".to_string()];
        queue.tasks = vec![task_in("YARD-001", "partial"), dependent];
        ws.save_queue(&queue).unwrap();

        // A run left behind by the conflicting merge: a partial-reason marker,
        // no worktree line (so no git op is needed for the test).
        let run_dir = ws.runs_dir().join("run-20260710-000000-yard-001");
        fs::create_dir_all(&run_dir).unwrap();
        write_str(&run_dir.join("run.yaml"), "task_id: YARD-001\n").unwrap();
        write_str(&run_dir.join("partial-reason"), "merge_conflict").unwrap();

        let outcome = resolve_partial(&ws, "YARD-001", "merged by hand").unwrap();
        assert!(outcome.cleared_partial_reason);
        assert!(outcome.removed_worktree.is_none());
        assert_eq!(outcome.unblocked, vec!["YARD-002".to_string()]);

        // Queue: the Partial is now Done (the dependent stays Queued, ready).
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].state, TaskState::Done);
        assert_eq!(q.tasks[1].state, TaskState::Queued);
        // The marker is gone.
        assert!(!run_dir.join("partial-reason").exists());
        // The transition is audited: Partial -> Done, actor User, cause Recover.
        let last = ws.latest_transition("YARD-001").unwrap();
        assert_eq!(last.from, TaskState::Partial);
        assert_eq!(last.to, TaskState::Done);
        assert_eq!(last.cause, TransitionCause::Recover);
        assert_eq!(last.actor, TransitionActor::User);
        assert_eq!(last.detail, "merged by hand");
        assert_eq!(last.intent_id, "intent-live");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_partial_rejects_a_non_partial_task() {
        let dir = temp_root("resolve-nonpartial");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        let mut queue = WorkQueue::empty();
        queue.tasks = vec![task_in("YARD-001", "queued")];
        ws.save_queue(&queue).unwrap();

        assert!(resolve_partial(&ws, "YARD-001", "x").is_err());
        assert!(resolve_partial(&ws, "NOPE", "x").is_err());
        // A queued task is untouched by a rejected resolve.
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Queued);

        let _ = fs::remove_dir_all(&dir);
    }
}
