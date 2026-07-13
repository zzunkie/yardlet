//! Canonical Yardlet data model.
//!
//! These structs map to the `.agents/*.yaml` files and the per-run JSON
//! artifacts. Logic-bearing fields are typed; loosely-structured policy detail
//! that Yardlet only passes through to workers is kept as `yaml::Value` so the
//! model does not over-constrain user-edited files.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashSet};

use crate::yaml;

fn default_true() -> bool {
    true
}

fn default_language() -> String {
    "auto".to_string()
}

// ---------------------------------------------------------------------------
// .agents/yard.yaml
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct YardConfig {
    pub schema_version: u32,
    pub product: String,
    pub workspace_id: String,
    pub created_at: String,
    pub state_dir: String,
    pub default_interface: String,
    pub canonical_queue: String,
    pub current_intent: String,
    /// User-facing output language for worker content: "auto" (detect from the
    /// request), "ko", "en", etc. Yardlet's own CLI/TUI chrome stays English.
    #[serde(default = "default_language")]
    pub language: String,
    /// Default worker permission: "sandboxed" (local-only, network blocked) or
    /// "full" (drop the sandbox so commands/network run freely; the worker still
    /// self-gates dangerous actions). Lets a user opt into autonomy once instead
    /// of passing --bypass per run.
    #[serde(default = "default_access")]
    pub default_access: String,
    /// How many independent tasks the auto-drain may run at once (each in its
    /// own git worktree). 1 = sequential (default).
    #[serde(default = "default_parallel")]
    pub max_parallel: usize,
    /// Auto-switch the OS input source to an ASCII layout on shortcut screens
    /// (and restore the IME for text input), so single-key shortcuts work
    /// while a CJK IME is on. macOS only; ignored elsewhere.
    #[serde(default = "default_true")]
    pub auto_ime: bool,
    /// Refuse to start runs while the planner's own ambiguity score is
    /// "high" — answer its questions (interview) or override. On by default.
    #[serde(default = "default_true")]
    pub ambiguity_gate: bool,
    /// Fold agent assets the repo already has (CLAUDE.md/AGENTS.md,
    /// .claude/skills, .cursor/rules, copilot-instructions) into the shared
    /// worker harness, worker-aware (docs/absorption.md A1). On by default.
    #[serde(default = "default_true")]
    pub harness_discovery: bool,
    /// Optional path to an additional local skill library (presets/skills
    /// layout). Empty = the managed built-in library only. External libraries
    /// stay read-only and join the built-in catalog (docs/skills.md S1).
    #[serde(default)]
    pub skill_library: String,
    /// Auto-equip core + detected-preset skills on plan/goal (I4: minimize
    /// intervention). Off = `yardlet skill suggest` nudges instead. On by default.
    #[serde(default = "default_true")]
    pub auto_equip: bool,
    /// Auto-record worker-proposed skills (a run's harness_suggestions of kind
    /// "skill") into `.agents/skills/` as `source: learned` (docs/skills.md
    /// S3). The deterministic core writes; the eval score later prunes weak
    /// ones. On by default (I4); off routes proposals to manual review.
    #[serde(default = "default_true")]
    pub auto_skill: bool,
    /// Auto-record worker-proposed rules (a run's harness_suggestions of kind
    /// "rule") as `.agents/rules/learned-<slug>.md`, an always-apply constraint
    /// H1 inlines into every packet (harness.md H4). OFF by default: rules are
    /// always-on (not per-task) and not auto-pruned, so one wrong learned rule
    /// degrades every later packet. Promote rules by hand instead. Reversible
    /// (git) and visible via `yardlet harness review`.
    #[serde(default)]
    pub auto_rule: bool,
    /// Auto-prune learned skills whose eval score stays below the floor over
    /// enough runs (the self-correction half of the loop, S4). Reversible
    /// (git keeps the file). On by default (I4); off = review surfaces them.
    #[serde(default = "default_true")]
    pub auto_prune: bool,
    /// Run workspace-owned hooks (`.agents/hooks/pre-run.d/*` before a worker
    /// spawns, `post-run.d/*` during evaluation; docs/harness.md H3). A
    /// non-zero pre-run hook blocks the run; a non-zero post-run hook blocks
    /// Done. On by default; the dirs are empty until you add executables.
    #[serde(default = "default_true")]
    pub hooks: bool,
    /// Opt in to autonomous git commits of completed serial work. Serial workers
    /// always run in a run-owned worktree. When this is OFF, a changed worktree
    /// is retained as Partial with no commit or merge. When ON, Yardlet commits
    /// only that isolated diff (excluding `.agents/`) and merges it sequentially.
    /// The parallel path is unaffected: batch integration always commits its
    /// isolated worktrees. Remote push is a separate default-off policy below.
    /// OFF by default, since it writes to the user's git history.
    #[serde(default)]
    pub auto_commit: bool,
    /// User-owned, default-off policy for finishing an owned Yardlet merge by
    /// pushing its exact OID to one explicit branch ref. Legacy configs omit
    /// this block and therefore deserialize to a disabled policy.
    #[serde(default)]
    pub git_finish: GitFinishPolicy,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GitFinishPolicy {
    /// No remote command is run unless this is explicitly true.
    #[serde(default)]
    pub auto_push: bool,
    /// Git remote name only. URLs are never copied into run records.
    #[serde(default)]
    pub remote: String,
    /// Fully qualified branch ref, for example `refs/heads/main`.
    #[serde(default)]
    pub target_ref: String,
    /// Workspace-owned checks, executed in this exact order before push.
    #[serde(default)]
    pub pre_push_checks: Vec<GitFinishCheck>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GitFinishCheck {
    pub name: String,
    pub command: String,
}

fn default_access() -> String {
    "sandboxed".to_string()
}

fn default_parallel() -> usize {
    1
}

// ---------------------------------------------------------------------------
// .agents/intent-contract.yaml
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentContract {
    pub schema_version: u32,
    pub id: String,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub raw_request: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub allowed_scope: Vec<String>,
    #[serde(default)]
    pub out_of_scope: Vec<String>,
    #[serde(default)]
    pub acceptance: Vec<yaml::Value>,
    /// Local image paths attached to this goal (passed to the worker natively:
    /// codex `-i`, claude reads them), so Yardlet does not lose the CLIs' vision.
    #[serde(default)]
    pub images: Vec<String>,
    /// The planner's own ambiguity self-report: low | medium | high.
    /// "high" gates the run until the interview lowers it (absorption.md A2).
    #[serde(default)]
    pub ambiguity: String,
    /// Questions the planner still has (shown by the interview gate).
    #[serde(default)]
    pub open_questions: Vec<String>,
    /// Interview Q->A pairs accumulated across re-plans.
    #[serde(default)]
    pub clarifications: Vec<String>,
    /// How many interview turns have run (hard cap applies).
    #[serde(default)]
    pub interview_turns: u32,
    #[serde(default)]
    pub status: String,
}

// ---------------------------------------------------------------------------
// .agents/work-queue.yaml
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkQueue {
    pub schema_version: u32,
    pub queue_id: String,
    #[serde(default)]
    pub intent_id: String,
    #[serde(default)]
    pub selection_policy: SelectionPolicy,
    #[serde(default)]
    pub tasks: Vec<Task>,
}

// ---------------------------------------------------------------------------
// V010-002 conversational planning and exact activation
// ---------------------------------------------------------------------------

/// Immutable plan content shown to the user before confirmation. The active
/// records add activation provenance around this exact payload; they never
/// re-plan or rewrite it during promotion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningDraftContent {
    pub intent: IntentContract,
    pub queue: WorkQueue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanningLifecycle {
    Open,
    Confirmed,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningSession {
    pub schema_version: u32,
    pub session_id: String,
    pub workspace_id: String,
    pub lifecycle: PlanningLifecycle,
    pub intent_id: String,
    pub queue_id: String,
    pub initial_request: String,
    #[serde(default)]
    pub current_head: Option<String>,
    #[serde(default)]
    pub confirmation_id: Option<String>,
    pub next_seq: u64,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SemanticDiffEntry {
    pub field: String,
    pub before: serde_json::Value,
    pub after: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningProposal {
    pub schema_version: u32,
    pub proposal_id: String,
    pub session_id: String,
    #[serde(default)]
    pub expected_head: Option<String>,
    pub producer_worker_id: String,
    pub attempt_id: String,
    pub rationale: String,
    pub content_digest: String,
    pub content: PlanningDraftContent,
    #[serde(default)]
    pub semantic_diff: Vec<SemanticDiffEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DraftRevision {
    pub schema_version: u32,
    pub draft_revision_id: String,
    pub session_id: String,
    pub proposal_id: String,
    #[serde(default)]
    pub parent_revision_id: Option<String>,
    pub content_digest: String,
    pub content: PlanningDraftContent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningEvent {
    pub schema_version: u32,
    pub event_id: String,
    pub session_id: String,
    pub seq: u64,
    #[serde(rename = "type")]
    pub event_type: String,
    pub actor: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub action_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub message: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub proposal_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub draft_revision_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub related_revision_id: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningActionReceipt {
    pub schema_version: u32,
    pub action_id: String,
    pub session_id: String,
    pub action: String,
    pub request_digest: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub result_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
}

/// Intent snapshot carrying the activation linkage. Flattening keeps the
/// legacy `intent-contract.yaml` shape readable by older tolerant readers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivatedIntent {
    #[serde(flatten)]
    pub intent: IntentContract,
    #[serde(default)]
    pub planning_session_id: String,
    #[serde(default)]
    pub confirmation_id: String,
    #[serde(default)]
    pub draft_revision_id: String,
    #[serde(default)]
    pub draft_content_digest: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivatedTask {
    #[serde(flatten)]
    pub task: Task,
    #[serde(default)]
    pub materialized_by_confirmation_id: String,
}

/// Queue snapshot carrying activation and per-task materialization linkage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivatedQueue {
    pub schema_version: u32,
    pub queue_id: String,
    #[serde(default)]
    pub intent_id: String,
    #[serde(default)]
    pub selection_policy: SelectionPolicy,
    #[serde(default)]
    pub tasks: Vec<ActivatedTask>,
    #[serde(default)]
    pub planning_session_id: String,
    #[serde(default)]
    pub confirmation_id: String,
    #[serde(default)]
    pub draft_revision_id: String,
    #[serde(default)]
    pub draft_content_digest: String,
}

impl ActivatedQueue {
    pub fn as_work_queue(&self) -> WorkQueue {
        WorkQueue {
            schema_version: self.schema_version,
            queue_id: self.queue_id.clone(),
            intent_id: self.intent_id.clone(),
            selection_policy: self.selection_policy.clone(),
            tasks: self.tasks.iter().map(|task| task.task.clone()).collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivationReceipt {
    pub schema_version: u32,
    pub confirmation_id: String,
    pub action_id: String,
    pub session_id: String,
    pub draft_revision_id: String,
    pub draft_content_digest: String,
    pub intent_id: String,
    pub queue_id: String,
    pub intent_digest: String,
    pub queue_digest: String,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SelectionPolicy {
    #[serde(default = "default_order")]
    pub default_order: String,
    #[serde(default)]
    pub require_planning_gate: bool,
    #[serde(default = "default_true")]
    pub skip_if_blocked: bool,
    #[serde(default = "default_true")]
    pub skip_if_approval_required: bool,
}

fn default_order() -> String {
    "priority_then_created_at".to_string()
}

impl Default for SelectionPolicy {
    fn default() -> Self {
        Self {
            default_order: default_order(),
            require_planning_gate: true,
            skip_if_blocked: true,
            skip_if_approval_required: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskState {
    #[default]
    Queued,
    Running,
    Done,
    Blocked,
    Failed,
    NeedsUser,
    /// Ran but did not fully complete — acceptance not met or a blocker found.
    Partial,
    /// Consciously set aside by a human decision (`yardlet defer`): not pending,
    /// not done. Acknowledged work that will not run this cycle (e.g. a P0
    /// ceiling needing user-provided input or a capability no worker declares).
    /// Skipped by the scheduler like Blocked, but it reads as a decision, not a
    /// problem, and lets an intent wrap with the deferral recorded.
    Deferred,
}

impl TaskState {
    /// A terminal state won't run again on its own: the scheduler never picks it
    /// and the drain is finished with it. `Queued`/`Running` are the only live
    /// states. `Done`/`Deferred` are settled resolutions; `Blocked`/`Failed`/
    /// `NeedsUser`/`Partial` are settled-with-a-hold (a human may still act, but
    /// the auto-drain will not advance them without one). This is the shared
    /// judgment behind [`WorkQueue::drained`] and the holds-included completion
    /// view.
    pub fn is_terminal(self) -> bool {
        !matches!(self, TaskState::Queued | TaskState::Running)
    }

    pub fn glyph(self) -> &'static str {
        match self {
            TaskState::Done => "\u{2713}",    // check
            TaskState::Running => "\u{25b6}", // play
            TaskState::Blocked => "\u{2715}", // x
            TaskState::Failed => "!",
            TaskState::NeedsUser => "?",
            TaskState::Partial => "\u{25d0}",  // half-filled circle
            TaskState::Deferred => "\u{00bb}", // double angle: set aside
            TaskState::Queued => "\u{00b7}",   // middle dot
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunnableClass {
    Runnable,
    WaitingDecision,
    WaitingApproval,
    WaitingDependency,
    WaitingCapability,
    Held,
    SetAside,
    Running,
    Done,
}

impl RunnableClass {
    pub fn label(self) -> &'static str {
        match self {
            RunnableClass::Runnable => "ready",
            RunnableClass::WaitingDecision => "awaiting decision",
            RunnableClass::WaitingApproval => "awaiting approval",
            RunnableClass::WaitingDependency => "blocked on deps",
            RunnableClass::WaitingCapability => "needs worker",
            RunnableClass::Held => "held",
            RunnableClass::SetAside => "set aside",
            RunnableClass::Running => "running",
            RunnableClass::Done => "done",
        }
    }

    pub fn is_runnable(self) -> bool {
        self == RunnableClass::Runnable
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransitionRecord {
    pub task_id: String,
    #[serde(default)]
    pub intent_id: String,
    pub from: TaskState,
    pub to: TaskState,
    pub cause: TransitionCause,
    pub detail: String,
    pub actor: TransitionActor,
    pub ts: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransitionCause {
    RunOutcome,
    CapabilityPark,
    StaleMigration,
    Defer,
    Revive,
    TidyDefer,
    Wrap,
    DecisionSeed,
    Recover,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "id")]
pub enum TransitionActor {
    System,
    User,
    Worker(String),
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TransitionLog {
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub records: Vec<TransitionRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub state: TaskState,
    #[serde(default)]
    pub priority: i64,
    #[serde(default)]
    pub risk: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub preferred_worker: String,
    /// Optional per-task model override. Empty or "auto" = fall back to the
    /// worker profile's model, then the CLI's own default.
    #[serde(default)]
    pub model: String,
    /// Optional per-task reasoning effort. Empty or "auto" = worker default.
    /// codex: minimal|low|medium|high.
    #[serde(default)]
    pub effort: String,
    /// Task ids that must be Done before this task may run. Empty = independent
    /// (eligible to run in parallel with other independent tasks).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub depends_on: Vec<String>,
    /// Workspace skills (`.agents/skills/<name>/`) the worker must read before
    /// starting this task. Planner-assigned from the catalog.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skills: Vec<String>,
    /// Executable affordances this task requires (e.g. `image_generation`).
    /// Planner-assigned. Routing constrains the candidate AND fallback set to
    /// workers whose `capabilities` declare every entry here; if none qualify
    /// the run fails with a clear message rather than silently mis-routing.
    /// Replaces the old hardcoded image-keyword router (no magic keywords).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub required_capabilities: Vec<String>,
    #[serde(default)]
    pub allowed_scope: Vec<String>,
    #[serde(default)]
    pub acceptance: Vec<yaml::Value>,
    /// First-class completion contract for the task. Older queues omit this
    /// field and retain the legacy one-feedback-retry behavior through the
    /// accessors below.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub goal: Option<TaskGoal>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub validation: Option<yaml::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval: Option<yaml::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction: Option<yaml::Value>,
    /// One-line reason the planner chose this task's preferred_worker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_rationale: Option<String>,
    /// How this task entered the queue. Empty = planner/express goal (the
    /// default). `worker-proposed` = ingested from a run's result.json
    /// `follow_up_tasks` (propose -> ingest). Kept visible so an enqueued
    /// follow-up is a tracked CANDIDATE, never a silent expansion of the
    /// current task.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub provenance: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskGoal {
    #[serde(default)]
    pub condition: String,
    #[serde(default = "default_max_feedback_cycles")]
    pub max_feedback_cycles: u32,
    #[serde(default = "default_feedback_policy")]
    pub feedback_policy: String,
}

fn default_max_feedback_cycles() -> u32 {
    2
}

fn default_feedback_policy() -> String {
    "inject_failed_checks".to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeferredBy {
    pub group_id: String,
    pub root_task_id: String,
}

impl DeferredBy {
    pub fn new(root_task_id: &str) -> Self {
        Self {
            group_id: format!("defer:{root_task_id}"),
            root_task_id: root_task_id.to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeferOutcome {
    pub group_id: String,
    pub deferred: Vec<String>,
    pub stranded: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviveOutcome {
    pub revived: Vec<String>,
    pub blocked_dependencies: Vec<ReviveBlockedDependency>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviveBlockedDependency {
    pub task_id: String,
    pub dependency_id: String,
    pub dependency_state: TaskState,
}

impl Task {
    /// Queues written before `goal` existed used a hard two-attempt cap, which
    /// meant one feedback retry after the initial run. Keep that behavior for
    /// old tasks while new goal contracts default to two feedback cycles.
    pub fn max_feedback_cycles(&self) -> u32 {
        self.goal
            .as_ref()
            .map(|g| g.max_feedback_cycles)
            .unwrap_or(1)
    }

    pub fn injects_failed_checks(&self) -> bool {
        self.goal
            .as_ref()
            .map(|g| g.feedback_policy == "inject_failed_checks")
            .unwrap_or(true)
    }

    /// Does this task require an explicit approval before it may run?
    pub fn approval_required(&self) -> bool {
        match &self.approval {
            Some(yaml::Value::Mapping(m)) => m
                .get(yaml::Value::String("required".into()))
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            _ => false,
        }
    }

    /// Validation-bearing tasks run on the serial path because parallel
    /// worktrees intentionally skip workspace validation. This keeps a failed
    /// check from bypassing the feedback contract merely due to scheduling.
    pub fn has_validation(&self) -> bool {
        self.validation.is_some()
    }

    /// Whether this task was created to remediate `review_id` before that
    /// review runs again. The relation lives in the existing extensible
    /// `interaction` map so old queue files remain fully compatible.
    pub fn remediates_review(&self, review_id: &str) -> bool {
        self.interaction
            .as_ref()
            .and_then(|value| value.get("remediation_for"))
            .and_then(yaml::Value::as_sequence)
            .is_some_and(|ids| ids.iter().any(|id| id.as_str() == Some(review_id)))
    }

    pub fn add_remediation_for(&mut self, review_id: &str) {
        let key = yaml::Value::String("remediation_for".to_string());
        let mut root = match self.interaction.take() {
            Some(yaml::Value::Mapping(mapping)) => mapping,
            _ => serde_yaml_ng::Mapping::new(),
        };
        let ids = root
            .entry(key)
            .or_insert_with(|| yaml::Value::Sequence(Vec::new()));
        if !ids
            .as_sequence()
            .is_some_and(|values| values.iter().any(|id| id.as_str() == Some(review_id)))
        {
            if !matches!(ids, yaml::Value::Sequence(_)) {
                *ids = yaml::Value::Sequence(Vec::new());
            }
            ids.as_sequence_mut()
                .expect("remediation_for was normalized to a sequence")
                .push(yaml::Value::String(review_id.to_string()));
        }
        self.interaction = Some(yaml::Value::Mapping(root));
    }

    pub fn deferred_by(&self) -> Option<DeferredBy> {
        let deferred = self.interaction.as_ref()?.get("deferred_by")?;
        Some(DeferredBy {
            group_id: deferred.get("group_id")?.as_str()?.to_string(),
            root_task_id: deferred.get("root_task_id")?.as_str()?.to_string(),
        })
    }

    pub fn set_deferred_by(&mut self, deferred_by: Option<DeferredBy>) {
        let key = yaml::Value::String("deferred_by".to_string());
        match deferred_by {
            Some(deferred_by) => {
                let mut root = match self.interaction.take() {
                    Some(yaml::Value::Mapping(m)) => m,
                    _ => serde_yaml_ng::Mapping::new(),
                };
                let mut nested = serde_yaml_ng::Mapping::new();
                nested.insert(
                    yaml::Value::String("group_id".to_string()),
                    yaml::Value::String(deferred_by.group_id),
                );
                nested.insert(
                    yaml::Value::String("root_task_id".to_string()),
                    yaml::Value::String(deferred_by.root_task_id),
                );
                root.insert(key, yaml::Value::Mapping(nested));
                self.interaction = Some(yaml::Value::Mapping(root));
            }
            None => match self.interaction.take() {
                Some(yaml::Value::Mapping(mut root)) => {
                    root.remove(&key);
                    self.interaction = (!root.is_empty()).then_some(yaml::Value::Mapping(root));
                }
                other => {
                    self.interaction = other;
                }
            },
        }
    }
}

impl WorkQueue {
    /// An empty queue: no tasks, default selection policy. Returned when no
    /// `work-queue.yaml` exists yet. The queue is runtime state, not config, so
    /// a fresh checkout (or one that gitignores the queue) legitimately has none
    /// and must not error.
    pub fn empty() -> Self {
        WorkQueue {
            schema_version: 1,
            queue_id: "queue-initial".to_string(),
            intent_id: String::new(),
            selection_policy: SelectionPolicy::default(),
            tasks: Vec::new(),
        }
    }

    /// Has the queue drained? True when every task has reached a terminal state
    /// ([`TaskState::is_terminal`]) — Done, Deferred, or another settled/held
    /// state. An empty queue is trivially drained. This is a pure judgment with
    /// no scheduler side effects: it says the drain has nothing left to run, so
    /// the intent can be wrapped and archived. Holds (NeedsUser/Blocked/Deferred)
    /// count as terminal, which is why the completion view is holds-included: a
    /// queue can be "drained" while still carrying tasks a human set aside.
    pub fn drained(&self) -> bool {
        self.tasks.iter().all(|t| t.state.is_terminal())
    }

    /// Are all of `task`'s dependencies Done? A dependency id that does not
    /// exist in the queue is treated as met (a planner typo must not deadlock
    /// the queue forever).
    pub fn deps_met(&self, task: &Task) -> bool {
        task.depends_on.iter().all(|dep| {
            self.tasks
                .iter()
                .find(|t| &t.id == dep)
                .map(|t| t.state == TaskState::Done)
                .unwrap_or(true)
        })
    }

    pub fn runnable_class(
        &self,
        task: &Task,
        approved: bool,
        cap_vocab: &BTreeSet<String>,
    ) -> RunnableClass {
        match task.state {
            TaskState::Running => RunnableClass::Running,
            TaskState::Done => RunnableClass::Done,
            TaskState::Deferred => RunnableClass::SetAside,
            TaskState::NeedsUser => RunnableClass::WaitingDecision,
            TaskState::Failed | TaskState::Partial => RunnableClass::Held,
            TaskState::Blocked => {
                let missing = crate::routing::unsatisfiable_capabilities(
                    &task.required_capabilities,
                    cap_vocab,
                );
                if missing.is_empty() {
                    RunnableClass::Held
                } else {
                    RunnableClass::WaitingCapability
                }
            }
            TaskState::Queued => {
                let missing = crate::routing::unsatisfiable_capabilities(
                    &task.required_capabilities,
                    cap_vocab,
                );
                if !missing.is_empty() {
                    RunnableClass::WaitingCapability
                } else if task.approval_required() && !approved {
                    RunnableClass::WaitingApproval
                } else if !self.deps_met(task) {
                    RunnableClass::WaitingDependency
                } else {
                    RunnableClass::Runnable
                }
            }
        }
    }

    pub fn is_runnable_now(
        &self,
        task: &Task,
        approved: bool,
        cap_vocab: &BTreeSet<String>,
    ) -> bool {
        self.runnable_class(task, approved, cap_vocab).is_runnable()
    }

    /// A review waits only while one of its explicitly linked remediation
    /// tasks is live. Terminal remediation states release this soft barrier,
    /// including human holds, so the review cannot be stranded forever.
    pub fn has_active_remediation_for(&self, review_id: &str) -> bool {
        self.tasks
            .iter()
            .any(|task| task.remediates_review(review_id) && !task.state.is_terminal())
    }

    /// Queued tasks stranded by setting `task_id` aside. This mirrors the
    /// queue-drain stuck-chain rule: growth is Queued-only and transitive.
    pub fn stranded_by(&self, task_id: &str) -> Vec<String> {
        let mut dead: HashSet<String> = HashSet::new();
        dead.insert(task_id.to_string());
        loop {
            let mut grew = false;
            for t in &self.tasks {
                if t.state == TaskState::Queued
                    && !dead.contains(&t.id)
                    && t.depends_on.iter().any(|d| dead.contains(d))
                {
                    dead.insert(t.id.clone());
                    grew = true;
                }
            }
            if !grew {
                break;
            }
        }
        self.tasks
            .iter()
            .filter(|t| t.id != task_id && dead.contains(&t.id))
            .map(|t| t.id.clone())
            .collect()
    }

    pub fn defer_task(
        &mut self,
        task_id: &str,
        cascade: bool,
        reason: &str,
    ) -> Result<DeferOutcome, String> {
        let Some(target) = self.tasks.iter().find(|t| t.id == task_id) else {
            return Err(format!("task '{task_id}' not found in the queue"));
        };
        match target.state {
            TaskState::Done => return Err(format!("{task_id} is already done; nothing to defer")),
            TaskState::Running => {
                return Err(format!(
                    "{task_id} is running; let it finish or recover it first"
                ))
            }
            _ => {}
        }

        let stranded = self.stranded_by(task_id);
        let mut deferred = vec![task_id.to_string()];
        if cascade {
            deferred.extend(stranded.iter().cloned());
        }
        let group = DeferredBy::new(task_id);
        let reason = reason.trim();
        for t in self.tasks.iter_mut().filter(|t| deferred.contains(&t.id)) {
            t.state = TaskState::Deferred;
            t.set_deferred_by(Some(group.clone()));
            if t.id == task_id && !reason.is_empty() {
                let note = format!("deferred by you: {reason}");
                t.worker_rationale = Some(match t.worker_rationale.take() {
                    Some(r) if !r.trim().is_empty() => format!("{r}\n{note}"),
                    _ => note,
                });
            }
        }

        Ok(DeferOutcome {
            group_id: group.group_id,
            deferred,
            stranded,
        })
    }

    pub fn revive_task(&mut self, task_id: &str, group: bool) -> Result<ReviveOutcome, String> {
        let Some(target) = self.tasks.iter().find(|t| t.id == task_id) else {
            return Err(format!("task '{task_id}' not found in the queue"));
        };
        match target.state {
            TaskState::Done => return Err(format!("{task_id} is already done; cannot revive")),
            TaskState::Running => return Err(format!("{task_id} is running; cannot revive")),
            TaskState::Deferred => {}
            other => {
                return Err(format!(
                    "{task_id} is {other:?}; only Deferred tasks can be revived"
                ))
            }
        }

        let group_id = target.deferred_by().map(|d| d.group_id);
        let revive_ids: Vec<String> = if group {
            if let Some(group_id) = group_id {
                self.tasks
                    .iter()
                    .filter(|t| {
                        t.state == TaskState::Deferred
                            && t.deferred_by().is_some_and(|d| d.group_id == group_id)
                    })
                    .map(|t| t.id.clone())
                    .collect()
            } else {
                vec![task_id.to_string()]
            }
        } else {
            vec![task_id.to_string()]
        };

        for t in self.tasks.iter_mut().filter(|t| revive_ids.contains(&t.id)) {
            t.state = TaskState::Queued;
            t.set_deferred_by(None);
        }

        let revived_set: HashSet<&str> = revive_ids.iter().map(String::as_str).collect();
        let mut blocked_dependencies = Vec::new();
        for t in self
            .tasks
            .iter()
            .filter(|t| revived_set.contains(t.id.as_str()))
        {
            for dep in &t.depends_on {
                if let Some(dep_task) = self.tasks.iter().find(|candidate| &candidate.id == dep) {
                    if matches!(
                        dep_task.state,
                        TaskState::Deferred
                            | TaskState::Failed
                            | TaskState::Blocked
                            | TaskState::NeedsUser
                            | TaskState::Partial
                    ) {
                        blocked_dependencies.push(ReviveBlockedDependency {
                            task_id: t.id.clone(),
                            dependency_id: dep_task.id.clone(),
                            dependency_state: dep_task.state,
                        });
                    }
                }
            }
        }

        Ok(ReviveOutcome {
            revived: revive_ids,
            blocked_dependencies,
        })
    }

    /// Sort tasks for display so what needs attention is on top and finished
    /// work sinks to the bottom: group by state (running first, then the
    /// needs-attention states, then queued, then done), and within each group by
    /// ascending `priority` (the scheduler's `select_next` key), ties kept in
    /// insertion order. So the running task and the next-to-run queued task sit
    /// at the top instead of below a long completed history. Display-only: the
    /// on-disk queue keeps its insertion / positional-insert order untouched.
    pub fn sort_for_display(&mut self) {
        fn rank(s: &TaskState) -> u8 {
            match s {
                TaskState::Running => 0,
                TaskState::NeedsUser => 1,
                TaskState::Blocked => 2,
                TaskState::Failed => 3,
                TaskState::Partial => 4,
                TaskState::Queued => 5,
                TaskState::Deferred => 6,
                TaskState::Done => 7,
            }
        }
        self.tasks.sort_by(|a, b| {
            rank(&a.state)
                .cmp(&rank(&b.state))
                .then(a.priority.cmp(&b.priority))
        });
    }
}

// ---------------------------------------------------------------------------
// .agents/workers.yaml
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkersFile {
    pub schema_version: u32,
    #[serde(default)]
    pub workers: Vec<WorkerProfile>,
    #[serde(default)]
    pub routing: Routing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Routing {
    #[serde(default = "default_codex")]
    pub default_worker: String,
    #[serde(default)]
    pub fallback_order: Vec<String>,
    /// Human cost dial read by the planner: cheap | balanced | quality.
    #[serde(default = "default_cost_bias")]
    pub cost_bias: String,
    #[serde(default)]
    pub planning_gate: GateRoute,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GateRoute {
    #[serde(default)]
    pub primary: String,
    #[serde(default)]
    pub fallback: String,
}

fn default_codex() -> String {
    "codex".to_string()
}

fn default_cost_bias() -> String {
    "balanced".to_string()
}

impl Default for Routing {
    fn default() -> Self {
        Self {
            default_worker: default_codex(),
            fallback_order: vec!["codex".to_string(), "claude-code".to_string()],
            cost_bias: default_cost_bias(),
            planning_gate: GateRoute::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerProfile {
    pub id: String,
    /// A disabled worker is skipped by routing and planning (toggle from the
    /// Home workers panel). Default on.
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub role_strengths: Vec<String>,
    /// Executable affordances this worker provides (e.g. `image_generation`).
    /// User-owned in workers.yaml. Distinct from `best_for` (a soft planner
    /// rubric) and `skills` (harness docs a worker reads): routing treats a
    /// task's `required_capabilities` as a HARD, deterministic constraint and
    /// only considers workers that declare every required capability. Names are
    /// normalized (lowercase, snake_case) before matching.
    #[serde(default)]
    pub capabilities: Vec<String>,
    /// Task characteristics this worker is good at (planner rubric; policy).
    #[serde(default)]
    pub best_for: String,
    /// Task characteristics to steer AWAY from this worker (negative planner
    /// rubric; policy). Best when contrastive with other workers' `best_for`.
    #[serde(default)]
    pub not_for: String,
    /// Relative subscription cost pressure: low | high (planner rubric).
    #[serde(default)]
    pub cost_weight: String,
    /// Model to run this worker with (alias or full id). Empty = CLI default.
    #[serde(default)]
    pub model: String,
    /// Reasoning effort level (codex: minimal|low|medium|high; claude: per CLI).
    /// Empty = CLI default.
    #[serde(default)]
    pub effort: String,
    #[serde(default)]
    pub billing: Billing,
    pub invocation: Invocation,
    #[serde(default)]
    pub limits: Limits,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Billing {
    #[serde(default)]
    pub mode: String,
}

impl Default for Billing {
    fn default() -> Self {
        Self {
            mode: "subscription_backed_only".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Invocation {
    pub command: String,
    #[serde(default)]
    pub supports_noninteractive: bool,
    #[serde(default)]
    pub output_contract: String,
    /// Generic adapter template for workers without a built-in adapter
    /// (codex and claude-code have first-class ones; any other id uses these).
    /// Placeholders: `{run_dir}`, `{model}`, `{effort}`, `{image}`. The task
    /// packet always arrives on stdin; the binary must support `--version`
    /// (the readiness probe) and be able to write files in the workspace.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Appended when running sandboxed (the default access level).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sandbox_args: Vec<String>,
    /// Appended instead of `sandbox_args` when full access was granted.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub full_access_args: Vec<String>,
    /// Appended once per attached image, e.g. ["-i", "{image}"].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub image_args: Vec<String>,
    /// Appended when a model is set, e.g. ["--model", "{model}"].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub model_args: Vec<String>,
    /// Appended when an effort is set, e.g. ["--effort", "{effort}"].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub effort_args: Vec<String>,
    /// Env vars passed through to THIS worker even when the billing policy
    /// scrubs them (e.g. ["OPENAI_API_KEY"] for an API-backed worker CLI).
    /// Explicit per-worker opt-in; zero-key remains the default and Yardlet
    /// itself never reads or stores the values.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pass_env: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Limits {
    #[serde(default = "default_wall")]
    pub max_wall_minutes: u32,
    #[serde(default)]
    pub max_retries: u32,
}

fn default_wall() -> u32 {
    45
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_wall_minutes: default_wall(),
            max_retries: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// .agents/billing-policy.yaml
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BillingPolicy {
    pub schema_version: u32,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub worker_invocation: WorkerInvocationBilling,
    #[serde(default)]
    pub blocked_worker_env_names: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerInvocationBilling {
    #[serde(default = "default_env_policy")]
    pub ai_billing_env_policy: String,
    #[serde(default = "default_true")]
    pub never_print_secret_values: bool,
    #[serde(default = "default_stop")]
    pub if_no_worker_ready: String,
    #[serde(default = "default_stop")]
    pub if_auth_ambiguous: String,
}

fn default_env_policy() -> String {
    "scrub_or_block".to_string()
}

fn default_stop() -> String {
    "stop".to_string()
}

impl Default for WorkerInvocationBilling {
    fn default() -> Self {
        Self {
            ai_billing_env_policy: default_env_policy(),
            never_print_secret_values: true,
            if_no_worker_ready: default_stop(),
            if_auth_ambiguous: default_stop(),
        }
    }
}

// ---------------------------------------------------------------------------
// Per-run result.json (written by the worker contract)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunResult {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub status: String,
    #[serde(default)]
    pub intent_adherence: IntentAdherence,
    #[serde(default)]
    pub changes: Changes,
    #[serde(default)]
    pub validation: ValidationResult,
    #[serde(default)]
    pub question_for_user: Option<String>,
    #[serde(default)]
    pub compact_summary: String,
    /// Per-criterion verdict from a review/verify task — the structured
    /// quality signal Yardlet records instead of trusting prose (docs/skills.md).
    /// Empty for build tasks; populated by reviewer-role runs.
    #[serde(default)]
    pub verdict: Vec<Verdict>,
    /// Reusable lessons this run proposes (harness learning loop, H4). Yardlet
    /// records them; the worker never writes canonical state itself.
    #[serde(default)]
    pub harness_suggestions: Vec<HarnessSuggestion>,
    /// Follow-up tasks this run PROPOSES for the queue (propose -> ingest). The
    /// worker authors intent here instead of editing `.agents/work-queue.yaml`;
    /// Yardlet assigns ids/priority and is the sole writer of the queue.
    #[serde(default)]
    pub follow_up_tasks: Vec<FollowUpTask>,
}

/// A follow-up task a worker PROPOSES in its result (propose -> ingest). A
/// strict subset of the planner `PlanTask`: the worker authors intent; Yardlet
/// assigns `id`, `state`, and `priority` and stays the sole writer of the
/// queue. `reason` is the audit trail (why this follow-up exists). Every field
/// defaults so a malformed entry never crashes the whole result parse — empty
/// `title` entries are dropped at ingestion.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FollowUpTask {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub risk: String,
    #[serde(default)]
    pub allowed_scope: Vec<String>,
    #[serde(default)]
    pub acceptance: Vec<String>,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default)]
    pub depends_on: Vec<String>,
    #[serde(default)]
    pub preferred_worker: String,
    #[serde(default)]
    pub required_capabilities: Vec<String>,
    /// If set, this follow-up is a HUMAN DECISION (a choice/approval only the
    /// user can make), not work a worker can do unattended. Yardlet ingests it
    /// as `NeedsUser` with this text as the seeded question, and `yardlet answer`
    /// resolves it — instead of the decision being mis-filed as a fake
    /// `required_capabilities` entry that would park the task `Blocked` with no
    /// clean resolver. Reserve `required_capabilities` for a worker's
    /// tool/skill/license need; a human decision is a question, never a capability.
    #[serde(default)]
    pub decision_question: String,
    #[serde(default)]
    pub worker_rationale: Option<String>,
    /// Where to place this task. `"next"` = run before the tasks already
    /// waiting (a priority nudge, soft ordering). `""` / `"end"` (default) =
    /// append after them. For a HARD "run before X" guarantee use `runs_before`.
    #[serde(default)]
    pub insert: String,
    /// Ids of existing queued tasks that must WAIT for this new one: Yardlet
    /// injects a dependency so each named task depends on this task (true
    /// "insert between"). Self-references, unknown ids, and entries that would
    /// form a dependency cycle are dropped.
    #[serde(default)]
    pub runs_before: Vec<String>,
}

/// The proposed-but-unrun follow-ups an intent leaves behind, preserved under
/// `.agents/intents/<id>/follow-up-tasks.yaml` when the intent is archived so the
/// record of "what a run said to do next" survives the reset. A preserved entry
/// can later be promoted into a fresh intent + queue seed (the same
/// `FollowUpTask` shape the queue ingests). Every field defaults so a partial or
/// legacy file still loads.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PreservedFollowUps {
    #[serde(default)]
    pub schema_version: u32,
    /// The archived intent these follow-ups were proposed under.
    #[serde(default)]
    pub intent_id: String,
    #[serde(default)]
    pub tasks: Vec<FollowUpTask>,
}

// ---------------------------------------------------------------------------
// .agents/conversations/<task_id>.yaml — needs_user conversation transcript
// ---------------------------------------------------------------------------

/// Who authored a conversation turn on a task paused for the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnRole {
    /// The worker's user-facing message (its `question_for_user`).
    Worker,
    /// The user's reply (a clarifying question or the actual decision).
    User,
}

/// One turn in a task's `needs_user` conversation. Yardlet is the sole writer:
/// the worker authors its message via `question_for_user`, the user replies via
/// `yardlet answer`, and the core records both here.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationTurn {
    pub role: TurnRole,
    pub text: String,
    /// The run that produced a worker turn; empty for user turns. Used to
    /// dedupe so a retried run does not double-record the same message.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub run_id: String,
    /// RFC3339 timestamp the turn was recorded.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub ts: String,
}

/// The append-only transcript of a task's conversation with the user. Persisted
/// per task so a resume can thread the whole exchange back to the worker
/// (conversational memory), not just the last question.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Conversation {
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub turns: Vec<ConversationTurn>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Verdict {
    /// The acceptance-criterion id being judged (e.g. "AC-004").
    #[serde(default)]
    pub criterion_id: String,
    pub pass: bool,
    /// Evidence for the verdict — a path, a line, a screenshot ref.
    #[serde(default)]
    pub evidence: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessSuggestion {
    /// "rule" | "skill".
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub content: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IntentAdherence {
    #[serde(default)]
    pub drift_detected: bool,
    #[serde(default)]
    pub notes: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Changes {
    #[serde(default)]
    pub files_modified: Vec<String>,
    #[serde(default)]
    pub files_created: Vec<String>,
    #[serde(default)]
    pub files_deleted: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    #[serde(default)]
    pub commands_run: Vec<String>,
    #[serde(default)]
    pub passed: bool,
    #[serde(default)]
    pub failures: Vec<String>,
}

impl Default for ValidationResult {
    fn default() -> Self {
        Self {
            commands_run: Vec::new(),
            // An omitted validation block means "no worker-reported failure",
            // not "validation failed". Explicit `passed: false` is the signal
            // the evaluator turns into deterministic feedback.
            passed: true,
            failures: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::yaml;

    #[test]
    fn parses_seed_style_queue() {
        let src = r#"
schema_version: 1
queue_id: q
tasks:
  - id: YARD-001
    title: first
    state: queued
    priority: 10
    preferred_worker: codex
    acceptance:
      - one
  - id: YARD-002
    title: second
    state: done
    approval:
      required: true
"#;
        let q: WorkQueue = yaml::from_str(src).unwrap();
        assert_eq!(q.tasks.len(), 2);
        assert_eq!(q.tasks[0].state, TaskState::Queued);
        assert_eq!(q.tasks[1].state, TaskState::Done);
        assert!(!q.tasks[0].approval_required());
        assert!(q.tasks[1].approval_required());
        // selection_policy defaults applied when absent
        assert!(q.selection_policy.skip_if_approval_required);
    }

    #[test]
    fn is_terminal_only_queued_and_running_are_live() {
        assert!(!TaskState::Queued.is_terminal());
        assert!(!TaskState::Running.is_terminal());
        // Done + Deferred are settled; the held states are terminal too.
        for s in [
            TaskState::Done,
            TaskState::Deferred,
            TaskState::Blocked,
            TaskState::Failed,
            TaskState::NeedsUser,
            TaskState::Partial,
        ] {
            assert!(s.is_terminal(), "{s:?} should read as terminal");
        }
    }

    #[test]
    fn remediation_relation_round_trips_and_only_live_tasks_hold_review() {
        let mut remediation: Task = yaml::from_str("id: FIX\ntitle: fix\n").unwrap();
        remediation.add_remediation_for("REVIEW");
        remediation.add_remediation_for("REVIEW");
        let encoded = yaml::to_string(&remediation).unwrap();
        let decoded: Task = yaml::from_str(&encoded).unwrap();
        assert!(decoded.remediates_review("REVIEW"));
        assert_eq!(encoded.matches("REVIEW").count(), 1);

        let mut queue = WorkQueue::empty();
        queue.tasks.push(decoded);
        assert!(queue.has_active_remediation_for("REVIEW"));
        queue.tasks[0].state = TaskState::NeedsUser;
        assert!(!queue.has_active_remediation_for("REVIEW"));
    }

    #[test]
    fn drained_counts_done_deferred_and_holds_but_not_queued() {
        fn q(states: &[TaskState]) -> WorkQueue {
            let mut queue = WorkQueue::empty();
            for (i, &state) in states.iter().enumerate() {
                let mut t: Task = yaml::from_str(&format!("id: T{i}\ntitle: t{i}")).unwrap();
                t.state = state;
                queue.tasks.push(t);
            }
            queue
        }
        // Empty queue is trivially drained.
        assert!(WorkQueue::empty().drained());
        // Done + Deferred + a NeedsUser hold: all terminal -> drained (the
        // holds-included completion case).
        assert!(q(&[TaskState::Done, TaskState::Deferred, TaskState::NeedsUser]).drained());
        // A single still-Queued task keeps the queue un-drained even amid Done.
        assert!(!q(&[TaskState::Done, TaskState::Queued]).drained());
        // A Running task is live, not drained.
        assert!(!q(&[TaskState::Running]).drained());
    }

    #[test]
    fn runnable_class_splits_ready_from_waiting_buckets() {
        let mut queue = WorkQueue::empty();
        let ready: Task = yaml::from_str("id: READY\ntitle: ready\n").unwrap();
        let mut dep: Task = yaml::from_str("id: DEP\ntitle: dep\ndepends_on: [READY]\n").unwrap();
        dep.state = TaskState::Queued;
        let mut approval: Task =
            yaml::from_str("id: APPROVE\ntitle: approve\napproval:\n  required: true\n").unwrap();
        approval.state = TaskState::Queued;
        let mut capability: Task =
            yaml::from_str("id: CAP\ntitle: cap\nrequired_capabilities: [video]\n").unwrap();
        capability.state = TaskState::Queued;
        let mut needs: Task = yaml::from_str("id: ASK\ntitle: ask\n").unwrap();
        needs.state = TaskState::NeedsUser;
        let mut blocked: Task = yaml::from_str("id: BLOCK\ntitle: block\n").unwrap();
        blocked.state = TaskState::Blocked;
        queue.tasks = vec![ready, dep, approval, capability, needs, blocked];
        let caps = BTreeSet::from(["image_generation".to_string()]);

        assert_eq!(
            queue.runnable_class(&queue.tasks[0], false, &caps),
            RunnableClass::Runnable
        );
        assert_eq!(
            queue.runnable_class(&queue.tasks[1], false, &caps),
            RunnableClass::WaitingDependency
        );
        assert_eq!(
            queue.runnable_class(&queue.tasks[2], false, &caps),
            RunnableClass::WaitingApproval
        );
        assert_eq!(
            queue.runnable_class(&queue.tasks[3], false, &caps),
            RunnableClass::WaitingCapability
        );
        assert_eq!(
            queue.runnable_class(&queue.tasks[4], false, &caps),
            RunnableClass::WaitingDecision
        );
        assert_eq!(
            queue.runnable_class(&queue.tasks[5], false, &caps),
            RunnableClass::Held
        );
    }

    #[test]
    fn task_state_snake_case_roundtrip() {
        let t: TaskState = yaml::from_str("needs_user").unwrap();
        assert_eq!(t, TaskState::NeedsUser);
        assert_eq!(yaml::to_string(&t).unwrap().trim(), "needs_user");
    }

    #[test]
    fn missing_optional_fields_default() {
        let t: Task = yaml::from_str("id: X\ntitle: T").unwrap();
        assert_eq!(t.state, TaskState::Queued); // #[default]
        assert_eq!(t.priority, 0);
        assert!(t.preferred_worker.is_empty());
        assert!(t.provenance.is_empty());
        assert!(t.deferred_by().is_none());
    }

    #[test]
    fn cascade_defer_marks_transitive_queued_closure_with_group() {
        let mut q: WorkQueue = yaml::from_str(
            r#"
schema_version: 1
queue_id: q
tasks:
  - id: A
    title: root
    state: queued
  - id: B
    title: child
    state: queued
    depends_on: [A]
  - id: C
    title: grandchild
    state: queued
    depends_on: [B]
  - id: D
    title: already failed
    state: failed
    depends_on: [A]
  - id: E
    title: behind failed
    state: queued
    depends_on: [D]
"#,
        )
        .unwrap();

        let outcome = q.defer_task("A", true, "park the chain").unwrap();

        assert_eq!(outcome.deferred, vec!["A", "B", "C"]);
        assert_eq!(outcome.stranded, vec!["B", "C"]);
        for id in ["A", "B", "C"] {
            let task = q.tasks.iter().find(|t| t.id == id).unwrap();
            assert_eq!(task.state, TaskState::Deferred);
            assert_eq!(
                task.deferred_by().map(|d| d.group_id),
                Some("defer:A".to_string())
            );
        }
        assert_eq!(
            q.tasks.iter().find(|t| t.id == "D").unwrap().state,
            TaskState::Failed
        );
        assert_eq!(
            q.tasks.iter().find(|t| t.id == "E").unwrap().state,
            TaskState::Queued
        );
    }

    #[test]
    fn plain_defer_only_marks_target_but_reports_stranded() {
        let mut q: WorkQueue = yaml::from_str(
            r#"
schema_version: 1
queue_id: q
tasks:
  - id: A
    title: root
    state: queued
  - id: B
    title: child
    state: queued
    depends_on: [A]
"#,
        )
        .unwrap();

        let outcome = q.defer_task("A", false, "").unwrap();

        assert_eq!(outcome.deferred, vec!["A"]);
        assert_eq!(outcome.stranded, vec!["B"]);
        assert_eq!(q.tasks[0].state, TaskState::Deferred);
        assert_eq!(q.tasks[1].state, TaskState::Queued);
    }

    #[test]
    fn revive_group_restores_deferred_group_and_warns_on_unrunnable_deps() {
        let mut q: WorkQueue = yaml::from_str(
            r#"
schema_version: 1
queue_id: q
tasks:
  - id: A
    title: root
    state: deferred
    interaction:
      deferred_by:
        group_id: defer:A
        root_task_id: A
  - id: B
    title: child
    state: deferred
    depends_on: [A]
    interaction:
      deferred_by:
        group_id: defer:A
        root_task_id: A
  - id: C
    title: unrelated
    state: deferred
    interaction:
      deferred_by:
        group_id: defer:C
        root_task_id: C
  - id: F
    title: failed dependency
    state: failed
  - id: G
    title: blocked child
    state: deferred
    depends_on: [F]
    interaction:
      deferred_by:
        group_id: defer:A
        root_task_id: A
"#,
        )
        .unwrap();

        let outcome = q.revive_task("B", true).unwrap();

        assert_eq!(outcome.revived, vec!["A", "B", "G"]);
        assert_eq!(q.tasks[0].state, TaskState::Queued);
        assert_eq!(q.tasks[1].state, TaskState::Queued);
        assert_eq!(q.tasks[2].state, TaskState::Deferred);
        assert!(q.tasks[0].deferred_by().is_none());
        assert_eq!(
            outcome.blocked_dependencies,
            vec![ReviveBlockedDependency {
                task_id: "G".to_string(),
                dependency_id: "F".to_string(),
                dependency_state: TaskState::Failed,
            }]
        );
    }

    #[test]
    fn revive_refuses_done_and_running_tasks() {
        let mut q: WorkQueue = yaml::from_str(
            r#"
schema_version: 1
queue_id: q
tasks:
  - id: A
    title: done
    state: done
  - id: B
    title: running
    state: running
"#,
        )
        .unwrap();

        assert!(q
            .revive_task("A", false)
            .unwrap_err()
            .contains("already done"));
        assert!(q.revive_task("B", false).unwrap_err().contains("running"));
    }

    // A worker proposes follow-ups in result.json; parsing must be tolerant
    // (every FollowUpTask field defaults), so a minimal entry, a rich one, and
    // a malformed one missing its title all deserialize.
    #[test]
    fn follow_up_tasks_parse_tolerantly() {
        let src = r#"{
            "schema_version": 1,
            "run_id": "run-x",
            "task_id": "YARD-001",
            "status": "done",
            "follow_up_tasks": [
                { "title": "add tests", "reason": "coverage gap" },
                { "title": "refactor parser", "reason": "duplication",
                  "kind": "implementation", "risk": "low",
                  "acceptance": ["no dupes"], "depends_on": ["YARD-001"] },
                { "reason": "no title, should still parse" }
            ]
        }"#;
        let r: RunResult = serde_json::from_str(src).unwrap();
        assert_eq!(r.follow_up_tasks.len(), 3);
        assert_eq!(r.follow_up_tasks[0].title, "add tests");
        assert_eq!(r.follow_up_tasks[0].reason, "coverage gap");
        assert_eq!(
            r.follow_up_tasks[1].depends_on,
            vec!["YARD-001".to_string()]
        );
        assert!(r.follow_up_tasks[2].title.is_empty());
    }

    // A result.json with no follow_up_tasks field at all still parses (the
    // field defaults to empty) — back-compat with pre-0.6.2 workers.
    #[test]
    fn result_without_follow_up_tasks_defaults_empty() {
        let r: RunResult = serde_json::from_str(
            r#"{ "schema_version": 1, "run_id": "r", "task_id": "t", "status": "done" }"#,
        )
        .unwrap();
        assert!(r.follow_up_tasks.is_empty());
    }

    #[test]
    fn task_goal_is_optional_and_round_trips_when_present() {
        let legacy: WorkQueue = yaml::from_str(
            "schema_version: 1\nqueue_id: q\ntasks:\n  - id: A\n    title: legacy\n",
        )
        .unwrap();
        assert!(legacy.tasks[0].goal.is_none());
        assert_eq!(legacy.tasks[0].max_feedback_cycles(), 1);

        let queue: WorkQueue = yaml::from_str(
            "schema_version: 1\nqueue_id: q\ntasks:\n  - id: A\n    title: goal\n    goal:\n      condition: all checks pass\n      max_feedback_cycles: 3\n      feedback_policy: inject_failed_checks\n",
        )
        .unwrap();
        assert_eq!(queue.tasks[0].max_feedback_cycles(), 3);
        let encoded = yaml::to_string(&queue).unwrap();
        assert!(encoded.contains("condition: all checks pass"));
        assert!(encoded.contains("max_feedback_cycles: 3"));
    }
}
