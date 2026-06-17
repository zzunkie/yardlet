//! Canonical Yardlet data model.
//!
//! These structs map to the `.agents/*.yaml` files and the per-run JSON
//! artifacts. Logic-bearing fields are typed; loosely-structured policy detail
//! that Yardlet only passes through to workers is kept as `yaml::Value` so the
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
    /// Path to a local skill library (presets/skills layout: presets/*.skills +
    /// skills/<name>/SKILL.md). Empty = none. Read-only; equip links from it
    /// into .agents/skills/ (docs/skills.md S1).
    #[serde(default)]
    pub skill_library: String,
    /// Auto-equip core + detected-preset skills on plan/goal (I4: minimize
    /// intervention). Off = `yard skill suggest` nudges instead. On by default.
    #[serde(default = "default_true")]
    pub auto_equip: bool,
    /// Auto-record worker-proposed skills (a run's harness_suggestions of kind
    /// "skill") into `.agents/skills/` as `source: learned` (docs/skills.md
    /// S3). The deterministic core writes; the eval score later prunes weak
    /// ones. On by default (I4); off routes proposals to manual review.
    #[serde(default = "default_true")]
    pub auto_skill: bool,
    /// Auto-record worker-proposed rules (a run's harness_suggestions of kind
    /// "rule") as `.agents/rules/learned-<slug>.md` — an always-apply
    /// constraint H1 inlines into every packet (harness.md H4). On by default;
    /// reversible (git) and visible via `yard harness review`. Higher-blast
    /// than a skill (rules are always-on, not per-task), so off is the cautious
    /// choice. Unlike learned skills, learned rules are not auto-pruned.
    #[serde(default = "default_true")]
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
}

impl TaskState {
    pub fn glyph(self) -> &'static str {
        match self {
            TaskState::Done => "\u{2713}",    // check
            TaskState::Running => "\u{25b6}", // play
            TaskState::Blocked => "\u{2715}", // x
            TaskState::Failed => "!",
            TaskState::NeedsUser => "?",
            TaskState::Partial => "\u{25d0}", // half-filled circle
            TaskState::Queued => "\u{00b7}",  // middle dot
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
    /// One-line reason the planner chose this task's preferred_worker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_rationale: Option<String>,
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

impl WorkQueue {
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
    /// Per-criterion verdict from a review/verify task — the structured
    /// quality signal Yardlet records instead of trusting prose (docs/skills.md).
    /// Empty for build tasks; populated by reviewer-role runs.
    #[serde(default)]
    pub verdict: Vec<Verdict>,
    /// Reusable lessons this run proposes (harness learning loop, H4). Yardlet
    /// records them; the worker never writes canonical state itself.
    #[serde(default)]
    pub harness_suggestions: Vec<HarnessSuggestion>,
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
