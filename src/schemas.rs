//! Canonical Yard data model.
//!
//! These structs map to the `.agents/*.yaml` files and the per-run JSON
//! artifacts. Logic-bearing fields are typed; loosely-structured policy detail
//! that Yard only passes through to workers is kept as `yaml::Value` so the
//! model does not over-constrain user-edited files.

use serde::{Deserialize, Serialize};

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
    /// request), "ko", "en", etc. Yard's own CLI/TUI chrome stays English.
    #[serde(default = "default_language")]
    pub language: String,
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
}

impl TaskState {
    pub fn glyph(self) -> &'static str {
        match self {
            TaskState::Done => "\u{2713}",    // check
            TaskState::Running => "\u{25b6}", // play
            TaskState::Blocked => "\u{2715}", // x
            TaskState::Failed => "!",
            TaskState::NeedsUser => "?",
            TaskState::Queued => "\u{00b7}", // middle dot
        }
    }
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
    #[serde(default)]
    pub allowed_scope: Vec<String>,
    #[serde(default)]
    pub acceptance: Vec<yaml::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub validation: Option<yaml::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval: Option<yaml::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction: Option<yaml::Value>,
}

impl Task {
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
    pub routing: yaml::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerProfile {
    pub id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub role_strengths: Vec<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ValidationResult {
    #[serde(default)]
    pub commands_run: Vec<String>,
    #[serde(default)]
    pub passed: bool,
    #[serde(default)]
    pub failures: Vec<String>,
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
    }
}
