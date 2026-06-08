//! A read-only snapshot of workspace state, shared by `yard status` and the TUI.

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
}

#[derive(Serialize, Clone)]
pub struct WorkerLine {
    pub id: String,
    pub readiness: String,
    pub version: Option<String>,
    pub billing_env_present: usize,
    pub detail: String,
}

impl Snapshot {
    pub fn load(ws: &Workspace) -> Result<Snapshot> {
        let config = ws.load_config()?;
        let intent = ws.load_intent()?;
        let queue = ws.load_queue()?;
        let billing = ws.load_billing()?;
        let workers_file = ws.load_workers()?;

        let workers = workers_file
            .workers
            .iter()
            .map(|p| {
                let s = guard::probe(p, &billing);
                WorkerLine {
                    id: s.id,
                    readiness: s.readiness.label().to_string(),
                    version: s.version,
                    billing_env_present: s.billing_env_present.len(),
                    detail: s.detail,
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

        Ok(Snapshot {
            config,
            intent,
            queue,
            workers,
            planner,
            pending,
        })
    }

    pub fn count(&self, state: TaskState) -> usize {
        self.queue.tasks.iter().filter(|t| t.state == state).count()
    }

    pub fn workers_ready(&self) -> usize {
        self.workers
            .iter()
            .filter(|w| w.readiness == "ready")
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

    /// JSON view for `yard status --json`.
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
                "total": self.queue.tasks.len(),
            },
            "workers": self.workers,
        })
    }
}
