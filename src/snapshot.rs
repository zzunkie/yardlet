//! A read-only snapshot of workspace state, shared by `yardlet status` and the TUI.

use anyhow::Result;
use serde::Serialize;

use crate::guard;
use std::collections::BTreeMap;

use crate::schemas::{
    IntentContract, RunnableClass, Task, TaskState, TransitionRecord, WorkQueue, YardConfig,
};
use crate::state::Workspace;

pub struct Snapshot {
    pub config: YardConfig,
    pub intent: Option<IntentContract>,
    pub queue: WorkQueue,
    pub workers: Vec<WorkerLine>,
    /// The configured planning worker (routing primary).
    pub planner: String,
    /// (task id, question) for the first task waiting on the user, if any.
    pub pending: Option<(String, String)>,
    /// The ambiguity-gate state, when the intent is gated: (open questions,
    /// interview turns so far).
    pub gate: Option<(Vec<String>, u32)>,
    /// Task ids that are gated and not yet granted approval.
    pub approvals_needed: Vec<String>,
    /// Capabilities the enabled workers declare (already parsed from
    /// workers.yaml here, so callers need not re-read it).
    pub capabilities: std::collections::BTreeSet<String>,
    pub last_transitions: BTreeMap<String, TransitionRecord>,
    /// Read-only effective-state diagnostics for canonical Running tasks whose
    /// exact worker identity is no longer live.
    pub recovery_required: Vec<RecoveryRequired>,
    /// Runs (latest per task, current intent) that persisted worktree
    /// harness-copy warnings as evidence. Absence of the evidence file means
    /// preparation was clean, so such runs never appear here.
    pub harness_copy_warnings: Vec<HarnessCopyWarning>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HarnessCopyWarning {
    pub task_id: String,
    pub run_id: String,
    pub warning_count: usize,
    /// Evidence path relative to the run directory.
    pub evidence: String,
}

/// Read-only count of a run's persisted harness-copy warnings; None when the
/// run left no warnings evidence (preparation was clean).
pub(crate) fn harness_copy_warning_count(run_dir: &std::path::Path) -> Option<usize> {
    let text =
        std::fs::read_to_string(run_dir.join(crate::state::HARNESS_COPY_WARNINGS_FILE)).ok()?;
    Some(text.lines().filter(|l| !l.trim().is_empty()).count())
}

#[derive(Debug, Clone, Serialize)]
pub struct RecoveryRequired {
    pub task_id: String,
    pub run_id: String,
    pub canonical_state: String,
    pub effective_state: String,
    pub reason: String,
    pub action: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct QueueHealth {
    pub runnable: usize,
    pub running: usize,
    pub waiting_decision: usize,
    pub waiting_approval: usize,
    pub waiting_dependency: usize,
    pub waiting_capability: usize,
    pub held: usize,
    pub set_aside: usize,
    pub done: usize,
    pub total: usize,
}

#[derive(Serialize, Clone)]
pub struct WorkerLine {
    pub id: String,
    pub readiness: String,
    pub version: Option<String>,
    pub billing_env_present: usize,
    /// True when AI-billing env is present AND the policy is strict (`block`),
    /// so the worker would hard-stop at run time. Distinguishes a real block
    /// from the default scrub (present-but-removed-before-spawn).
    pub billing_blocked: bool,
    /// Model this worker runs with (alias or full id); empty = the CLI default.
    pub model: String,
    pub detail: String,
    pub enabled: bool,
}

impl Snapshot {
    pub fn load(ws: &Workspace) -> Result<Snapshot> {
        Self::load_inner(ws, None)
    }

    /// Reload the cheap state (yaml files) while reusing a previous worker
    /// probe. `load` spawns each worker CLI with `--version`, which blocks the
    /// caller for ~100ms — too slow for the TUI's once-a-second refresh.
    pub fn load_reusing_workers(ws: &Workspace, workers: Vec<WorkerLine>) -> Result<Snapshot> {
        Self::load_inner(ws, Some(workers))
    }

    fn load_inner(ws: &Workspace, cached_workers: Option<Vec<WorkerLine>>) -> Result<Snapshot> {
        // A snapshot is a trusted projection used by both status and every TUI
        // action. Never expose canonical state until its activation provenance
        // and immutable runtime envelope have passed the shared fail-closed gate.
        crate::planning::validate_active_activation(ws)?;
        let config = ws.load_config()?;
        let intent = ws.load_intent()?;
        // Sort for display (active work on top, done at the bottom); in-memory
        // only, the on-disk queue order is unchanged.
        let mut queue = ws.load_queue()?;
        queue.sort_for_display();
        let billing = ws.load_billing()?;
        let workers_file = ws.load_workers()?;
        let policy = billing.worker_invocation.ai_billing_env_policy.clone();

        // The enabled flag, model, and billing-policy posture are always re-read
        // from config (cheap and user-editable); only the expensive probe
        // (spawning `--version`) is reused from the cache, matched by worker id.
        let workers = workers_file
            .workers
            .iter()
            .map(|p| {
                if !p.enabled {
                    return WorkerLine {
                        id: p.id.clone(),
                        readiness: "disabled".to_string(),
                        version: None,
                        billing_env_present: 0,
                        billing_blocked: false,
                        model: p.model.clone(),
                        detail: "disabled (toggle on the Home workers panel)".to_string(),
                        enabled: false,
                    };
                }
                if let Some(c) = cached_workers.as_ref().and_then(|cw| {
                    cw.iter()
                        .find(|w| w.id == p.id && w.readiness != "disabled")
                }) {
                    return WorkerLine {
                        enabled: true,
                        model: p.model.clone(),
                        billing_blocked: guard::billing_blocked(&policy, c.billing_env_present),
                        ..c.clone()
                    };
                }
                let s = guard::probe(p, &billing);
                let present = s.billing_env_present.len();
                WorkerLine {
                    id: s.id,
                    readiness: s.readiness.label().to_string(),
                    version: s.version,
                    billing_env_present: present,
                    billing_blocked: guard::billing_blocked(&policy, present),
                    model: p.model.clone(),
                    detail: s.detail,
                    enabled: true,
                }
            })
            .collect();

        let planner = {
            let primary = &workers_file.routing.planning_gate.primary;
            if primary.is_empty() {
                "codex".to_string()
            } else {
                primary.clone()
            }
        };

        let pending = queue
            .tasks
            .iter()
            .find(|t| t.state == TaskState::NeedsUser)
            .map(|t| {
                let q = crate::run::latest_question_for(ws, &t.id).unwrap_or_default();
                (t.id.clone(), q)
            });

        let gate = intent
            .as_ref()
            .filter(|i| crate::planner::intent_gated(i, config.ambiguity_gate))
            .map(|i| (i.open_questions.clone(), i.interview_turns));

        // Approval is only "needed" for a task that could still run: a Done or
        // Deferred (or Blocked/Running) task keeps its approval flag but must not
        // light up the status bar. Only pending, runnable-next states count.
        let approvals_needed = queue
            .tasks
            .iter()
            .filter(|t| {
                t.approval_required()
                    && matches!(
                        t.state,
                        TaskState::Queued
                            | TaskState::NeedsUser
                            | TaskState::Partial
                            | TaskState::Failed
                    )
                    && !crate::approvals::is_granted(ws, &t.id)
            })
            .map(|t| t.id.clone())
            .collect();

        let capabilities = crate::routing::declared_capabilities(&workers_file);
        let last_transitions = queue
            .tasks
            .iter()
            .filter_map(|task| {
                ws.latest_transition_for_intent(&task.id, &queue.intent_id)
                    .map(|rec| (task.id.clone(), rec))
            })
            .collect();
        let recovery_required = queue
            .tasks
            .iter()
            .filter(|task| task.state == TaskState::Running)
            .filter_map(|task| {
                let Some((run_id, run_dir)) =
                    crate::run::latest_run_for_intent(ws, &task.id, &queue.intent_id)
                else {
                    return Some(RecoveryRequired {
                        task_id: task.id.clone(),
                        run_id: String::new(),
                        canonical_state: "running".to_string(),
                        effective_state: "interrupted".to_string(),
                        reason: "canonical task is Running but has no recorded run".to_string(),
                        action: "yardlet recover".to_string(),
                    });
                };
                crate::run::stale_running_reason(&run_dir, &task.id, &queue.intent_id).map(
                    |reason| RecoveryRequired {
                        task_id: task.id.clone(),
                        run_id,
                        canonical_state: "running".to_string(),
                        effective_state: "interrupted".to_string(),
                        reason,
                        action: "yardlet recover".to_string(),
                    },
                )
            })
            .collect();
        let harness_copy_warnings = queue
            .tasks
            .iter()
            .filter_map(|task| {
                let (run_id, run_dir) =
                    crate::run::latest_run_for_intent(ws, &task.id, &queue.intent_id)?;
                let warning_count = harness_copy_warning_count(&run_dir)?;
                Some(HarnessCopyWarning {
                    task_id: task.id.clone(),
                    run_id,
                    warning_count,
                    evidence: crate::state::HARNESS_COPY_WARNINGS_FILE.to_string(),
                })
            })
            .collect();

        Ok(Snapshot {
            config,
            intent,
            queue,
            workers,
            planner,
            pending,
            gate,
            approvals_needed,
            capabilities,
            last_transitions,
            recovery_required,
            harness_copy_warnings,
        })
    }

    pub fn workers_ready(&self) -> usize {
        self.workers
            .iter()
            .filter(|w| w.readiness == "invocable")
            .count()
    }

    pub fn task_class(&self, task: &Task) -> RunnableClass {
        let approved =
            task.approval_required() && !self.approvals_needed.iter().any(|id| id == &task.id);
        self.queue
            .runnable_class(task, approved, &self.capabilities)
    }

    pub fn health(&self) -> QueueHealth {
        let mut health = QueueHealth {
            total: self.queue.tasks.len(),
            ..QueueHealth::default()
        };
        for task in &self.queue.tasks {
            match self.task_class(task) {
                RunnableClass::Runnable => health.runnable += 1,
                RunnableClass::Running => health.running += 1,
                RunnableClass::WaitingDecision => health.waiting_decision += 1,
                RunnableClass::WaitingApproval => health.waiting_approval += 1,
                RunnableClass::WaitingDependency => health.waiting_dependency += 1,
                RunnableClass::WaitingCapability => health.waiting_capability += 1,
                RunnableClass::Held => health.held += 1,
                RunnableClass::SetAside => health.set_aside += 1,
                RunnableClass::Done => health.done += 1,
            }
        }
        health
    }

    pub fn intent_summary(&self) -> &str {
        self.intent
            .as_ref()
            .map(|i| i.summary.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("(no intent yet — open New Work)")
    }

    pub fn tasks(&self) -> &[Task] {
        &self.queue.tasks
    }

    /// JSON view for `yardlet status --json`.
    pub fn to_json(&self) -> serde_json::Value {
        let health = self.health();
        let mut json = serde_json::json!({
            "product": self.config.product,
            "workspace_id": self.config.workspace_id,
            "planner": self.planner,
            "pending": self.pending.as_ref().map(|(id, q)| serde_json::json!({"task": id, "question": q})),
            "intent": self.intent_summary(),
            "queue": {
                "runnable": health.runnable,
                "running": health.running,
                "waiting_decision": health.waiting_decision,
                "waiting_approval": health.waiting_approval,
                "waiting_dependency": health.waiting_dependency,
                "waiting_capability": health.waiting_capability,
                "held": health.held,
                "set_aside": health.set_aside,
                "done": health.done,
                "total": health.total,
            },
            "tasks": self.queue.tasks.iter().map(|task| {
                serde_json::json!({
                    "id": task.id,
                    "state": format!("{:?}", task.state),
                    "class": self.task_class(task),
                    "last_transition": self.last_transitions.get(&task.id),
                })
            }).collect::<Vec<_>>(),
            "recovery_required": self.recovery_required,
            "workers": self.workers,
        });
        // Only runs that persisted warnings add the key, so a workspace whose
        // runs prepared cleanly keeps its JSON output byte-identical.
        if !self.harness_copy_warnings.is_empty() {
            json["harness_copy_warnings"] = serde_json::json!(self.harness_copy_warnings);
        }
        json
    }
}

#[cfg(test)]
pub(crate) fn reused_task_id_fixture(name: &str) -> (Workspace, Snapshot, String) {
    let root = std::env::temp_dir().join(format!("yard-snapshot-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let ws = Workspace::at(&root);
    std::fs::create_dir_all(ws.agents_dir()).unwrap();
    std::fs::write(
        ws.config_path(),
        r#"schema_version: 1
product: yardlet
workspace_id: snapshot-test
created_at: "2026-07-12T00:00:00Z"
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: intent-current
"#,
    )
    .unwrap();
    std::fs::write(ws.billing_path(), crate::templates::BILLING_POLICY).unwrap();
    std::fs::write(
        ws.workers_path(),
        "schema_version: 1\nworkers: []\nrouting: {}\n",
    )
    .unwrap();

    let mut queue = WorkQueue::empty();
    queue.queue_id = "queue-intent-current".into();
    queue.intent_id = "intent-current".into();
    queue.tasks.push(
        crate::yaml::from_str(
            "id: SHARED\ntitle: Reused task id\nstate: needs_user\npriority: 10\n",
        )
        .unwrap(),
    );
    ws.save_queue(&queue).unwrap();

    std::fs::create_dir_all(ws.transitions_dir()).unwrap();
    let historical = r#"task_id: SHARED
records:
  - task_id: SHARED
    intent_id: intent-old
    from: queued
    to: needs_user
    cause: run_outcome
    detail: STALE INTENT REASON
    actor:
      kind: system
    ts: "2026-07-11T00:00:00+09:00"
"#
    .to_string();
    std::fs::write(ws.transition_path("SHARED"), &historical).unwrap();

    let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
    (ws, snapshot, historical)
}

#[cfg(test)]
pub(crate) fn corrupt_activated_state_fixture(name: &str) -> Workspace {
    let root = std::env::temp_dir().join(format!(
        "yard-snapshot-corrupt-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    let ws = Workspace::at(&root);
    std::fs::create_dir_all(ws.agents_dir()).unwrap();
    std::fs::write(
        ws.config_path(),
        r#"schema_version: 1
product: yardlet
workspace_id: corrupt-snapshot-test
created_at: "2026-07-14T00:00:00Z"
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: intent-corrupt-test
"#,
    )
    .unwrap();
    std::fs::write(ws.billing_path(), crate::templates::BILLING_POLICY).unwrap();
    std::fs::write(
        ws.workers_path(),
        "schema_version: 1\nworkers: []\nrouting: {}\n",
    )
    .unwrap();

    let content: crate::schemas::PlanningDraftContent = crate::yaml::from_str(
        r#"
intent:
  schema_version: 1
  id: intent-corrupt-test
  source: user
  raw_request: reject corrupt active state
  summary: reject corrupt active state
  allowed_scope: [src]
  out_of_scope: [docs]
  acceptance: [fail closed]
  ambiguity: low
  status: accepted
queue:
  schema_version: 1
  queue_id: queue-intent-corrupt-test
  intent_id: intent-corrupt-test
  tasks:
    - id: YARD-001
      title: reject corrupt active state
      state: queued
      allowed_scope: [src]
      acceptance: [fail closed]
      approval:
        required: true
"#,
    )
    .unwrap();
    crate::planning::activate_express_draft(&ws, "reject corrupt active state", content).unwrap();

    let mut queue = ws.load_activated_queue().unwrap().unwrap();
    queue.tasks[0].task.title = "forged active task".to_string();
    let lock = ws.acquire_planning_lock().unwrap();
    ws.save_activated_queue_snapshot_locked(&lock, &queue)
        .unwrap();
    drop(lock);
    ws
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{TaskState, TransitionActor, TransitionCause};

    #[test]
    fn live_projection_uses_only_the_queue_intent_transition() {
        let (ws, stale_only, historical) = reused_task_id_fixture("intent-scope");
        assert!(!stale_only.last_transitions.contains_key("SHARED"));
        assert_eq!(
            std::fs::read_to_string(ws.transition_path("SHARED")).unwrap(),
            historical
        );

        crate::state::append_transition(
            &ws,
            crate::state::transition(
                "SHARED",
                TaskState::Queued,
                TaskState::NeedsUser,
                TransitionCause::RunOutcome,
                "CURRENT INTENT REASON",
                TransitionActor::System,
            ),
        )
        .unwrap();
        let current = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        assert_eq!(
            current.last_transitions.get("SHARED").unwrap().detail,
            "CURRENT INTENT REASON"
        );
        let preserved = std::fs::read_to_string(ws.transition_path("SHARED")).unwrap();
        assert!(preserved.contains("STALE INTENT REASON"));
        assert!(preserved.contains("CURRENT INTENT REASON"));

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn snapshot_rejects_corrupt_activated_state_before_projecting_it() {
        let ws = corrupt_activated_state_fixture("validation-gate");

        let error = Snapshot::load_reusing_workers(&ws, Vec::new())
            .err()
            .expect("corrupt activated state must not produce a snapshot")
            .to_string();

        assert!(error.contains("unconfirmed_or_inconsistent"), "{error}");
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn issue_29_dead_worker_is_projected_as_recovery_required_without_writes() {
        let (ws, _, _) = reused_task_id_fixture("dead-worker-status");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        let run_id = "run-issue-29-dead-worker";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(
            run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\ntask_id: SHARED\nintent_id: intent-current\nworker: fixture\nstate: running\nstarted_at: \"2026-07-23T00:00:00Z\"\nworktree: .\n"
            ),
        )
        .unwrap();
        std::fs::write(run_dir.join("worker.pid"), u32::MAX.to_string()).unwrap();
        std::fs::write(
            run_dir.join("worker-process.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\nattempt_id: att-dead\nworker_id: fixture\npid: {}\nprocess_start_marker: definitely-not-live\nstate: running\n",
                u32::MAX
            ),
        )
        .unwrap();

        let queue_before = std::fs::read(ws.queue_path()).unwrap();
        let run_before = std::fs::read(run_dir.join("run.yaml")).unwrap();
        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        let json = snapshot.to_json();

        assert_eq!(json["queue"]["running"], 1);
        let diagnostic = &json["recovery_required"][0];
        assert_eq!(diagnostic["task_id"], "SHARED");
        assert_eq!(diagnostic["run_id"], run_id);
        assert_eq!(diagnostic["effective_state"], "interrupted");
        assert_eq!(diagnostic["action"], "yardlet recover");
        assert_eq!(std::fs::read(ws.queue_path()).unwrap(), queue_before);
        assert_eq!(std::fs::read(run_dir.join("run.yaml")).unwrap(), run_before);

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn issue_29_newer_historical_run_does_not_mask_live_current_intent_worker() {
        let (ws, _, _) = reused_task_id_fixture("live-current-worker");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        let current_run_id = "run-issue-29-live-current";
        let current_run_dir = ws.runs_dir().join(current_run_id);
        std::fs::create_dir_all(&current_run_dir).unwrap();
        std::fs::write(
            current_run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {current_run_id}\ntask_id: SHARED\nintent_id: intent-current\nworker: fixture\nstate: running\nstarted_at: \"2026-07-23T00:00:00Z\"\n"
            ),
        )
        .unwrap();
        let pid = std::process::id();
        std::fs::write(current_run_dir.join("worker.pid"), pid.to_string()).unwrap();
        std::fs::write(
            current_run_dir.join("worker-process.yaml"),
            format!(
                "schema_version: 1\nrun_id: {current_run_id}\nattempt_id: att-live\nworker_id: fixture\npid: {pid}\nprocess_start_marker: {}\nstate: running\n",
                crate::workers::process_start_marker(pid).unwrap()
            ),
        )
        .unwrap();

        let stale_run_id = "run-issue-29-newer-old-intent";
        let stale_run_dir = ws.runs_dir().join(stale_run_id);
        std::fs::create_dir_all(&stale_run_dir).unwrap();
        std::fs::write(
            stale_run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {stale_run_id}\ntask_id: SHARED\nintent_id: intent-old\nworker: fixture\nstate: running\nstarted_at: \"2099-01-01T00:00:00Z\"\n"
            ),
        )
        .unwrap();

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        assert!(
            snapshot.recovery_required.is_empty(),
            "a newer historical run must not mask the verified live worker for the current intent"
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn issue_29_finalized_run_is_not_diagnosed_as_a_dead_worker() {
        let (ws, _, _) = reused_task_id_fixture("finalized-worker-status");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        let run_id = "run-issue-29-finalized";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(
            run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\ntask_id: SHARED\nintent_id: intent-current\nworker: fixture\nstate: done\ncompleted_at: \"2026-07-23T00:01:00Z\"\n"
            ),
        )
        .unwrap();

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        assert!(snapshot.recovery_required.is_empty());
        assert!(snapshot.to_json()["recovery_required"]
            .as_array()
            .unwrap()
            .is_empty());

        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn write_done_run_for_current_intent(ws: &Workspace, run_id: &str) -> std::path::PathBuf {
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(
            run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\ntask_id: SHARED\nintent_id: intent-current\nworker: fixture\nstate: done\nstarted_at: \"2026-07-23T00:00:00Z\"\ncompleted_at: \"2026-07-23T00:01:00Z\"\n"
            ),
        )
        .unwrap();
        run_dir
    }

    #[test]
    fn harness_copy_warnings_evidence_is_surfaced_in_the_readonly_projection() {
        let (ws, _, _) = reused_task_id_fixture("harness-copy-warnings");
        let run_id = "run-harness-copy-warnings";
        let run_dir = write_done_run_for_current_intent(&ws, run_id);
        std::fs::create_dir_all(run_dir.join("evidence")).unwrap();
        std::fs::write(
            run_dir.join("evidence/harness-copy-warnings.log"),
            "copy_dir: skipped symlink 'a' -> 'b'\ncopy_dir: skipped symlink 'c' -> 'd'\n",
        )
        .unwrap();

        let queue_before = std::fs::read(ws.queue_path()).unwrap();
        let run_before = std::fs::read(run_dir.join("run.yaml")).unwrap();
        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();

        let warning = snapshot
            .harness_copy_warnings
            .first()
            .expect("a run with harness-copy-warnings evidence must be projected");
        assert_eq!(warning.task_id, "SHARED");
        assert_eq!(warning.run_id, run_id);
        assert_eq!(warning.warning_count, 2);
        assert_eq!(warning.evidence, "evidence/harness-copy-warnings.log");

        let json = snapshot.to_json();
        assert_eq!(json["harness_copy_warnings"][0]["task_id"], "SHARED");
        assert_eq!(json["harness_copy_warnings"][0]["run_id"], run_id);
        assert_eq!(json["harness_copy_warnings"][0]["warning_count"], 2);

        // Read-only projection: surfacing the evidence must not rewrite any
        // canonical state or run record.
        assert_eq!(std::fs::read(ws.queue_path()).unwrap(), queue_before);
        assert_eq!(std::fs::read(run_dir.join("run.yaml")).unwrap(), run_before);

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn runs_without_harness_copy_warnings_leave_the_projection_unchanged() {
        let (ws, _, _) = reused_task_id_fixture("harness-copy-clean");
        write_done_run_for_current_intent(&ws, "run-harness-copy-clean");

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        assert!(snapshot.harness_copy_warnings.is_empty());
        assert!(
            snapshot.to_json().get("harness_copy_warnings").is_none(),
            "a clean run must not grow a new status key"
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn write_prepare_window_run(ws: &Workspace, run_id: &str, started_at: &str) {
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(
            run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\ntask_id: SHARED\nintent_id: intent-current\nworker: fixture\nstate: running\nstarted_at: \"{started_at}\"\nworktree: .\n"
            ),
        )
        .unwrap();
        std::fs::write(
            run_dir.join("worker-process.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\nattempt_id: att-prepare\nworker_id: fixture\npid: 0\nstate: prepared\n"
            ),
        )
        .unwrap();
    }

    #[test]
    fn issue_29_fresh_dispatch_prepare_window_is_not_flagged_as_stale() {
        let (ws, _, _) = reused_task_id_fixture("prepare-window-fresh");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        write_prepare_window_run(
            &ws,
            "run-issue-29-prepare-fresh",
            &chrono::Local::now().to_rfc3339(),
        );

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        assert!(
            snapshot.recovery_required.is_empty(),
            "a just-started dispatch still in its prepared/pid=0 window must not be \
             diagnosed as interrupted: {:?}",
            snapshot.recovery_required
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn write_run_without_provenance_file(ws: &Workspace, run_id: &str, started_at: &str) {
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(
            run_dir.join("run.yaml"),
            format!(
                "schema_version: 1\nrun_id: {run_id}\ntask_id: SHARED\nintent_id: intent-current\nworker: fixture\nstate: running\nstarted_at: \"{started_at}\"\nworktree: .\n"
            ),
        )
        .unwrap();
    }

    #[test]
    fn issue_29_fresh_run_without_provenance_file_is_not_flagged_as_stale() {
        let (ws, _, _) = reused_task_id_fixture("provenance-pre-window-fresh");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        write_run_without_provenance_file(
            &ws,
            "run-issue-29-provenance-pre-fresh",
            &chrono::Local::now().to_rfc3339(),
        );

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        assert!(
            snapshot.recovery_required.is_empty(),
            "a just-started run whose worker-process.yaml is not written yet must not \
             be diagnosed as interrupted: {:?}",
            snapshot.recovery_required
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn issue_29_old_run_with_lost_provenance_is_still_diagnosed() {
        let (ws, _, _) = reused_task_id_fixture("provenance-lost-old");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        let run_id = "run-issue-29-provenance-lost";
        write_run_without_provenance_file(&ws, run_id, "2026-01-01T00:00:00+00:00");

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        let diagnostic = snapshot
            .recovery_required
            .first()
            .expect("a run whose provenance never appeared must be diagnosed once stale");
        assert_eq!(diagnostic.task_id, "SHARED");
        assert_eq!(diagnostic.run_id, run_id);
        assert_eq!(diagnostic.effective_state, "interrupted");
        assert!(
            diagnostic.reason.contains("provenance is missing"),
            "reason should name the lost provenance: {}",
            diagnostic.reason
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn issue_29_stalled_dispatch_preparation_is_still_diagnosed() {
        let (ws, _, _) = reused_task_id_fixture("prepare-window-stalled");
        let mut queue = ws.load_queue().unwrap();
        queue.tasks[0].state = TaskState::Running;
        ws.save_queue(&queue).unwrap();

        let run_id = "run-issue-29-prepare-stalled";
        write_prepare_window_run(&ws, run_id, "2026-01-01T00:00:00+00:00");

        let snapshot = Snapshot::load_reusing_workers(&ws, Vec::new()).unwrap();
        let diagnostic = snapshot
            .recovery_required
            .first()
            .expect("a dispatch that never left preparation must be diagnosed once stale");
        assert_eq!(diagnostic.task_id, "SHARED");
        assert_eq!(diagnostic.run_id, run_id);
        assert_eq!(diagnostic.effective_state, "interrupted");
        assert!(
            diagnostic.reason.contains("dispatch preparation"),
            "reason should name the stalled prepare window: {}",
            diagnostic.reason
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }
}
