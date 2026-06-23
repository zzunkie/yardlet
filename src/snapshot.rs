//! A read-only snapshot of workspace state, shared by `yardlet status` and the TUI.

use anyhow::Result;
use serde::Serialize;

use crate::guard;
use crate::schemas::{IntentContract, Task, TaskState, WorkQueue, YardConfig};
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

        let approvals_needed = queue
            .tasks
            .iter()
            .filter(|t| t.approval_required() && !crate::approvals::is_granted(ws, &t.id))
            .map(|t| t.id.clone())
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
        })
    }

    pub fn count(&self, state: TaskState) -> usize {
        self.queue.tasks.iter().filter(|t| t.state == state).count()
    }

    pub fn workers_ready(&self) -> usize {
        self.workers
            .iter()
            .filter(|w| w.readiness == "invocable")
            .count()
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
        serde_json::json!({
            "product": self.config.product,
            "workspace_id": self.config.workspace_id,
            "planner": self.planner,
            "pending": self.pending.as_ref().map(|(id, q)| serde_json::json!({"task": id, "question": q})),
            "intent": self.intent_summary(),
            "queue": {
                "queued": self.count(TaskState::Queued),
                "running": self.count(TaskState::Running),
                "done": self.count(TaskState::Done),
                "blocked": self.count(TaskState::Blocked),
                "failed": self.count(TaskState::Failed),
                "needs_user": self.count(TaskState::NeedsUser),
                "deferred": self.count(TaskState::Deferred),
                "total": self.queue.tasks.len(),
            },
            "workers": self.workers,
        })
    }
}
