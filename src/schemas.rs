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
// V010-002A deterministic capability coverage and bounded scout policy
// ---------------------------------------------------------------------------

/// The exhaustive plan-time coverage state for one task. `Missing` is the
/// conservative default for legacy or partial records: absent evidence never
/// becomes an implicit claim that the task is covered.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CoverageStatus {
    Covered,
    Weak,
    #[default]
    Missing,
    Stale,
    ExternalToolNeeded,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageConfidence {
    High,
    Medium,
    Low,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageFreshness {
    Fresh,
    Stale,
    NotApplicable,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageEvidenceSource {
    WorkspaceSkillCatalog,
    UserSkillLibrary,
    WorkerReadiness,
    RepoClassification,
    RepoPreset,
    KnowledgeFreshness,
    TypedFailure,
    NeedsUser,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageEvidence {
    #[serde(default)]
    pub source: CoverageEvidenceSource,
    #[serde(default)]
    pub reference: String,
    #[serde(default)]
    pub detail: String,
}

/// Stable, core-authored reason codes. Display text may evolve without
/// changing the persisted decision vocabulary.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageReasonCode {
    CoverageConfirmed,
    WeakContextualMatch,
    SelectedSkillMissing,
    NoReadyWorkerCapability,
    OnlyUnusableSkillMatches,
    StaleKnowledge,
    HumanDecisionRequired,
    #[default]
    InsufficientEvidence,
}

/// A standalone task-keyed record so planning can persist coverage alongside
/// a draft without changing the already-confirmed runtime `Task` contract.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskCapabilityCoverage {
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub status: CoverageStatus,
    #[serde(default)]
    pub evidence: Vec<CoverageEvidence>,
    #[serde(default)]
    pub confidence: CoverageConfidence,
    #[serde(default)]
    pub freshness: CoverageFreshness,
    #[serde(default)]
    pub reason_code: CoverageReasonCode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScoutHardSignal {
    ExplicitResearchRequest,
    SelectedSkillMissing,
    NoReadyWorkerCapability,
    OnlyUnusableSkillMatches,
    CurrentExternalFactDependency,
    MaterialExternalChoiceDependency,
    RepeatedTypedFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScoutSoftSignal {
    ClassifierOrPresetGap,
    WeakContextualMatch,
    UnfamiliarDomain,
    SubthresholdTypedEvidence,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScoutTriggerDecision {
    #[default]
    NoScout,
    Observe,
    Scout,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScoutTrigger {
    #[serde(default)]
    pub decision: ScoutTriggerDecision,
    #[serde(default)]
    pub hard_signals: Vec<ScoutHardSignal>,
    #[serde(default)]
    pub soft_signals: Vec<ScoutSoftSignal>,
}

/// Human judgment remains a NeedsUser question. Executable tool/resource gaps
/// remain capability gaps. Neither is encoded as the other.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CapabilityGap {
    #[default]
    NoGap,
    NeedsUser {
        #[serde(default)]
        question: String,
    },
    ToolOrResource {
        #[serde(default)]
        missing_capabilities: Vec<String>,
    },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScoutDisposition {
    UseExistingSkill,
    AdaptExternalSkillCandidate,
    DraftReusableSkill,
    RecordToolCandidate,
    PreserveOneOffEvidence,
    #[default]
    ReportNoChange,
    AskUser,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResearchSource {
    WorkspaceSkillCatalog,
    UserSkillLibrary,
    ExternalPrimarySource,
}

fn default_research_sources() -> Vec<ResearchSource> {
    vec![
        ResearchSource::WorkspaceSkillCatalog,
        ResearchSource::UserSkillLibrary,
        ResearchSource::ExternalPrimarySource,
    ]
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScoutCandidate {
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub revision: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub freshness: String,
    #[serde(default)]
    pub maintenance: String,
    #[serde(default)]
    pub included_files: Vec<String>,
    #[serde(default)]
    pub static_risk: String,
    #[serde(default)]
    pub authority_requirements: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScoutResult {
    #[serde(default)]
    pub topic: String,
    #[serde(default)]
    pub sources_consulted: Vec<ResearchSource>,
    #[serde(default)]
    pub disposition: ScoutDisposition,
    #[serde(default)]
    pub evidence: Vec<CoverageEvidence>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate: Option<ScoutCandidate>,
    #[serde(default)]
    pub gap: CapabilityGap,
}

fn default_one() -> u32 {
    1
}

fn default_three() -> usize {
    3
}

fn default_thirty() -> u32 {
    30
}

fn default_two() -> usize {
    2
}

fn default_when_needed() -> String {
    "when_needed".to_string()
}

fn default_intent_locked() -> String {
    "intent_locked".to_string()
}

fn default_normalized_topic() -> String {
    "normalized_topic".to_string()
}

fn default_candidate_handling() -> String {
    "record_as_candidate".to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchBudget {
    #[serde(default = "default_one")]
    pub max_cycles: u32,
    #[serde(default = "default_three")]
    pub max_topics_per_cycle: usize,
}

impl Default for ResearchBudget {
    fn default() -> Self {
        Self {
            max_cycles: default_one(),
            max_topics_per_cycle: default_three(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchDedupPolicy {
    #[serde(default = "default_true")]
    pub within_intent: bool,
    #[serde(default = "default_normalized_topic")]
    pub topic_key: String,
}

impl Default for ResearchDedupPolicy {
    fn default() -> Self {
        Self {
            within_intent: true,
            topic_key: default_normalized_topic(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchFreshnessPolicy {
    #[serde(default = "default_thirty")]
    pub cache_ttl_days: u32,
    #[serde(default = "default_true")]
    pub unknown_is_stale: bool,
}

impl Default for ResearchFreshnessPolicy {
    fn default() -> Self {
        Self {
            cache_ttl_days: default_thirty(),
            unknown_is_stale: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchThresholds {
    #[serde(default = "default_two")]
    pub soft_signals_to_scout: usize,
    #[serde(default = "default_two")]
    pub repeated_failure_hard: usize,
}

impl Default for ResearchThresholds {
    fn default() -> Self {
        Self {
            soft_signals_to_scout: default_two(),
            repeated_failure_hard: default_two(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResearchScopeImpact {
    #[default]
    None,
    PlanningUpdateRequired,
    ApprovalRequired,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchEventTemplate {
    #[serde(default)]
    pub research_question: String,
    #[serde(default)]
    pub source_or_anchor: String,
    #[serde(default)]
    pub used_for: String,
    #[serde(default)]
    pub decision_impact: String,
    #[serde(default)]
    pub scope_impact: ResearchScopeImpact,
    #[serde(default)]
    pub drift_detected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchPolicy {
    #[serde(default = "default_one")]
    pub schema_version: u32,
    #[serde(default = "default_when_needed")]
    pub allowed: String,
    #[serde(default = "default_intent_locked")]
    pub mode: String,
    #[serde(default)]
    pub event_template: ResearchEventTemplate,
    #[serde(default = "default_candidate_handling")]
    pub adjacent_idea_handling: String,
    #[serde(default)]
    pub budget: ResearchBudget,
    #[serde(default = "default_research_sources")]
    pub source_order: Vec<ResearchSource>,
    #[serde(default)]
    pub dedup: ResearchDedupPolicy,
    #[serde(default)]
    pub freshness: ResearchFreshnessPolicy,
    #[serde(default)]
    pub thresholds: ResearchThresholds,
}

impl Default for ResearchPolicy {
    fn default() -> Self {
        Self {
            schema_version: default_one(),
            allowed: default_when_needed(),
            mode: default_intent_locked(),
            event_template: ResearchEventTemplate::default(),
            adjacent_idea_handling: default_candidate_handling(),
            budget: ResearchBudget::default(),
            source_order: default_research_sources(),
            dedup: ResearchDedupPolicy::default(),
            freshness: ResearchFreshnessPolicy::default(),
            thresholds: ResearchThresholds::default(),
        }
    }
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

/// Immutable identity of the exact user turn sent to a planning worker. A
/// worker result may become a proposal only while all four fields still match
/// the persisted open session and its journal.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningTurnCas {
    pub session_id: String,
    #[serde(default)]
    pub expected_head: Option<String>,
    pub request_event_id: String,
    pub request_digest: String,
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
    #[serde(default)]
    pub request_event_id: String,
    #[serde(default)]
    pub request_digest: String,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlanningEventType {
    #[serde(rename = "session.opened")]
    SessionOpened,
    #[serde(rename = "user.message")]
    UserMessage,
    #[serde(rename = "worker.message")]
    WorkerMessage,
    #[serde(rename = "draft.proposed")]
    DraftProposed,
    #[serde(rename = "draft.accepted")]
    DraftAccepted,
    #[serde(rename = "draft.revised")]
    DraftRevised,
    #[serde(rename = "draft.rejected")]
    DraftRejected,
    #[serde(rename = "draft.undo")]
    DraftUndo,
    #[serde(rename = "draft.confirm.prepared")]
    DraftConfirmPrepared,
    #[serde(rename = "draft.confirmed")]
    DraftConfirmed,
    #[serde(rename = "action.requested")]
    ActionRequested,
    #[serde(rename = "action.completed")]
    ActionCompleted,
    #[serde(rename = "action.rejected")]
    ActionRejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningEvent {
    pub schema_version: u32,
    pub event_id: String,
    pub session_id: String,
    pub seq: u64,
    #[serde(rename = "type")]
    pub event_type: PlanningEventType,
    pub actor: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub action_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub action_request_digest: String,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanningActionKind {
    Accept,
    Reject,
    Undo,
    Answer,
    Confirm,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanningActionStatus {
    Prepared,
    Completed,
    Rejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanningActionReceipt {
    pub schema_version: u32,
    pub action_id: String,
    pub session_id: String,
    pub action: PlanningActionKind,
    pub request_digest: String,
    pub status: PlanningActionStatus,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub result_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub effect_event_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effect_event_type: Option<PlanningEventType>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub effect_event_digest: String,
    /// Exact effect payload reserved while the receipt is still Prepared. The
    /// immutable effect file is materialized from this value after every crash.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effect_event: Option<PlanningEvent>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub prior_intent_digest: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub prior_queue_digest: String,
}

/// Intent snapshot carrying the activation linkage. Flattening keeps the
/// legacy `intent-contract.yaml` shape readable by older tolerant readers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivatedIntent {
    #[serde(flatten)]
    pub intent: IntentContract,
    /// Durable origin marker for V010-created state. Legacy records default to
    /// false; removing the surrounding linkage from a modern record must not
    /// make it eligible for the legacy scheduler path.
    #[serde(default)]
    pub activation_required: bool,
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
    /// See [`ActivatedIntent::activation_required`]. Both active snapshots
    /// carry the marker so either half of an interrupted promotion fails closed.
    #[serde(default)]
    pub activation_required: bool,
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
    /// Canonical digest of `materialized_queue`. This value and the snapshot
    /// are immutable activation provenance; runtime writers may only project
    /// mutable task state into `tasks`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub materialized_queue_digest: String,
    /// Immutable queue exactly materialized from the confirmed draft. `tasks`
    /// carries mutable runtime state; this snapshot never changes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub materialized_queue: Option<WorkQueue>,
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

    /// The confirmed draft is an immutable base execution contract. Runtime
    /// may advance scheduler-owned fields on those tasks and append separately
    /// receipted user/follow-up tasks, but it may never rewrite, delete, or
    /// reorder the confirmed contracts.
    pub fn runtime_envelope_matches_materialized_with_overlays(
        &self,
        authorized_runs_before: &std::collections::BTreeMap<String, Vec<String>>,
        authorized_capability_clears: &std::collections::BTreeSet<String>,
        authorized_selections: &std::collections::BTreeMap<String, ResolvedWorkerSelection>,
    ) -> bool {
        let Some(materialized) = self.materialized_queue.as_ref() else {
            return false;
        };
        if self.schema_version != materialized.schema_version
            || self.queue_id != materialized.queue_id
            || self.intent_id != materialized.intent_id
            || serde_json::to_vec(&self.selection_policy).ok()
                != serde_json::to_vec(&materialized.selection_policy).ok()
        {
            return false;
        }

        let mut ids = std::collections::BTreeSet::new();
        let mut confirmed = Vec::new();
        let mut saw_runtime_addition = false;
        for activated in &self.tasks {
            if !ids.insert(activated.task.id.as_str()) {
                return false;
            }
            if activated.materialized_by_confirmation_id == self.confirmation_id {
                if saw_runtime_addition {
                    return false;
                }
                confirmed.push(&activated.task);
            } else if activated.materialized_by_confirmation_id.is_empty()
                && matches!(
                    activated.task.provenance.as_str(),
                    "user-added" | "worker-proposed"
                )
            {
                saw_runtime_addition = true;
            } else {
                return false;
            }
        }
        confirmed.len() == materialized.tasks.len()
            && confirmed
                .iter()
                .zip(&materialized.tasks)
                .all(|(runtime, planned)| {
                    if runtime.id != planned.id {
                        return false;
                    }
                    let mut runtime = (*runtime).clone();
                    if let Some(additions) = authorized_runs_before.get(&runtime.id) {
                        let mut expected = planned.depends_on.clone();
                        expected.extend(additions.iter().cloned());
                        if runtime.depends_on != expected {
                            return false;
                        }
                        runtime.depends_on = planned.depends_on.clone();
                    }
                    if authorized_capability_clears.contains(&runtime.id) {
                        if planned.required_capabilities.is_empty()
                            || !runtime.required_capabilities.is_empty()
                        {
                            return false;
                        }
                        runtime.required_capabilities = planned.required_capabilities.clone();
                    }
                    if let Some(selection) = authorized_selections.get(&runtime.id) {
                        let Some(normalized) =
                            selection.normalized_runtime_overlay(planned, &runtime)
                        else {
                            return false;
                        };
                        runtime = normalized;
                    }
                    matches!(
                        (
                            runtime.runtime_contract_digest(),
                            planned.runtime_contract_digest()
                        ),
                        (Ok(runtime), Ok(planned)) if runtime == planned
                    )
                })
    }
}

/// Core-owned proof that a task appended after confirmation entered through an
/// allowed runtime action rather than by editing `work-queue.yaml` directly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeTaskReceipt {
    pub schema_version: u32,
    pub confirmation_id: String,
    pub intent_id: String,
    pub queue_id: String,
    pub task_id: String,
    pub origin: String,
    pub origin_action_id: String,
    #[serde(default)]
    pub ordinal: usize,
    #[serde(default)]
    pub runs_before: Vec<String>,
    pub task_contract_digest: String,
    pub task: Task,
    #[serde(default)]
    pub queue_digest_after: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeTaskCommit {
    pub schema_version: u32,
    pub confirmation_id: String,
    pub task_id: String,
    pub ordinal: usize,
    pub receipt_digest: String,
    pub committed_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeCapabilityReceipt {
    pub schema_version: u32,
    pub confirmation_id: String,
    pub intent_id: String,
    pub queue_id: String,
    pub task_id: String,
    pub action: String,
    pub action_id: String,
    pub target_state: TaskState,
    pub decision_question: String,
    pub original_required_capabilities: Vec<String>,
    pub replacement_required_capabilities: Vec<String>,
    pub queue_digest_after: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeCapabilityCommit {
    pub schema_version: u32,
    pub confirmation_id: String,
    pub task_id: String,
    pub receipt_digest: String,
    pub committed_at: String,
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

/// Workspace-level discriminator for state created by the V010 activation
/// path. It remains after an active snapshot is archived or tampered so a
/// stripped modern record can never become indistinguishable from legacy data.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivationRequirement {
    pub schema_version: u32,
    pub required: bool,
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
    /// Whether this task may leave its resolved worker lineage after retries.
    /// `None` preserves legacy workspace policy; worker-proposed descendants of
    /// an exact lineage always materialize an explicit value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_enabled: Option<bool>,
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
    /// Core-authored provenance for an exact worker/model/fallback lineage.
    /// A task carrying this receipt is validated again at dispatch so a queue
    /// edit cannot silently override the governing decision.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub routing_provenance: Option<RoutingProvenance>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoutingProvenance {
    #[serde(default)]
    pub governing_task_id: String,
    #[serde(default)]
    pub governing_worker_id: String,
    #[serde(default)]
    pub governing_model: String,
    #[serde(default)]
    pub governing_fallback_enabled: bool,
    #[serde(default)]
    pub worker_source: String,
    #[serde(default)]
    pub model_source: String,
    #[serde(default)]
    pub fallback_source: String,
    #[serde(default)]
    pub worker_overridden: bool,
    #[serde(default)]
    pub model_overridden: bool,
    #[serde(default)]
    pub fallback_overridden: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedWorkerSelection {
    #[serde(default)]
    pub worker_id: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub fallback_enabled: bool,
    #[serde(default)]
    pub routing_provenance: RoutingProvenance,
}

impl ResolvedWorkerSelection {
    pub fn from_task(task: &Task) -> Option<Self> {
        let routing_provenance = task.routing_provenance.clone()?;
        if task.preferred_worker.trim().is_empty() || task.model.trim().is_empty() {
            return None;
        }
        Some(Self {
            worker_id: task.preferred_worker.clone(),
            model: task.model.clone(),
            fallback_enabled: task.fallback_enabled?,
            routing_provenance,
        })
    }

    pub fn normalized_runtime_overlay(&self, baseline: &Task, runtime: &Task) -> Option<Task> {
        let provenance = &self.routing_provenance;
        let baseline_model_is_explicit =
            !baseline.model.trim().is_empty() && !baseline.model.eq_ignore_ascii_case("auto");
        let expected_fallback_source = if baseline.fallback_enabled.is_some() {
            "task.fallback_enabled"
        } else if baseline.preferred_worker.trim().is_empty() {
            "routing.unpinned_default"
        } else {
            "workspace.routing.allow_preferred_worker_failover"
        };
        let policy_authorized_failover =
            provenance.worker_source == "failover" && self.fallback_enabled;
        if baseline.routing_provenance.is_some()
            || self.worker_id.trim().is_empty()
            || self.model.trim().is_empty()
            || runtime.preferred_worker != self.worker_id
            || runtime.model != self.model
            || runtime.fallback_enabled != Some(self.fallback_enabled)
            || runtime.routing_provenance.as_ref() != Some(provenance)
            || provenance.governing_task_id != baseline.id
            || provenance.governing_worker_id != self.worker_id
            || provenance.governing_model != self.model
            || provenance.governing_fallback_enabled != self.fallback_enabled
            || provenance.worker_source.trim().is_empty()
            || provenance.model_source
                != if baseline_model_is_explicit {
                    "task.model"
                } else {
                    "worker_profile.model"
                }
            || provenance.fallback_source != expected_fallback_source
            || provenance.worker_overridden != (provenance.worker_source == "run override")
            || provenance.model_overridden != baseline_model_is_explicit
            || provenance.fallback_overridden != baseline.fallback_enabled.is_some()
            || (!baseline.preferred_worker.trim().is_empty()
                && baseline.preferred_worker != self.worker_id
                && !provenance.worker_overridden
                && !policy_authorized_failover)
            || (baseline_model_is_explicit && baseline.model != self.model)
            || baseline
                .fallback_enabled
                .is_some_and(|fallback| fallback != self.fallback_enabled)
        {
            return None;
        }

        let mut normalized = runtime.clone();
        normalized.preferred_worker = baseline.preferred_worker.clone();
        normalized.model = baseline.model.clone();
        normalized.fallback_enabled = baseline.fallback_enabled;
        normalized.routing_provenance = baseline.routing_provenance.clone();
        Some(normalized)
    }
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
    /// Canonical task contract used by activation/runtime-origin receipts.
    /// Scheduler-owned lifecycle metadata is deliberately excluded; everything
    /// that controls worker identity, scope, dependencies, or acceptance stays
    /// exact.
    pub fn runtime_contract_snapshot(&self) -> Self {
        let mut contract = self.clone();
        contract.state = TaskState::Queued;
        contract.priority = 0;
        contract.worker_rationale = None;
        match contract.interaction.take() {
            Some(yaml::Value::Mapping(mut interaction)) => {
                interaction.remove(yaml::Value::String("deferred_by".to_string()));
                interaction.remove(yaml::Value::String("remediation_for".to_string()));
                contract.interaction =
                    (!interaction.is_empty()).then_some(yaml::Value::Mapping(interaction));
            }
            other => contract.interaction = other,
        }
        contract
    }

    pub fn runtime_contract_digest(&self) -> Result<String, serde_json::Error> {
        let bytes = serde_json::to_vec(&self.runtime_contract_snapshot())?;
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in bytes {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Ok(format!("fnv1a64:{hash:016x}"))
    }

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

pub const MAX_PROVIDER_RESPONSE_REFUSAL_PATTERNS: usize = 16;
pub const MAX_PROVIDER_RESPONSE_REFUSAL_PATTERN_BYTES: usize = 256;

impl WorkersFile {
    pub fn validate(&self) -> Result<(), String> {
        for worker in &self.workers {
            let patterns = &worker.provider_response_refusal_patterns;
            if patterns.len() > MAX_PROVIDER_RESPONSE_REFUSAL_PATTERNS {
                return Err(format!(
                    "worker '{}' configures {} provider refusal patterns; maximum is {}",
                    worker.id,
                    patterns.len(),
                    MAX_PROVIDER_RESPONSE_REFUSAL_PATTERNS
                ));
            }
            for pattern in patterns {
                if pattern.trim().is_empty() {
                    return Err(format!(
                        "worker '{}' has an empty provider refusal pattern",
                        worker.id
                    ));
                }
                if pattern.len() > MAX_PROVIDER_RESPONSE_REFUSAL_PATTERN_BYTES {
                    return Err(format!(
                        "worker '{}' provider refusal pattern exceeds {} bytes",
                        worker.id, MAX_PROVIDER_RESPONSE_REFUSAL_PATTERN_BYTES
                    ));
                }
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Routing {
    #[serde(default = "default_codex")]
    pub default_worker: String,
    #[serde(default)]
    pub fallback_order: Vec<String>,
    /// Permit a task that names `preferred_worker` to switch to another worker
    /// after exhausting its own retries. Default false: a pinned provider/model
    /// fails closed instead of silently incurring work or cost elsewhere.
    #[serde(default)]
    pub allow_preferred_worker_failover: bool,
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
            allow_preferred_worker_failover: false,
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
    /// Bounded, case-insensitive literal signatures emitted by this worker's
    /// provider when it refuses to produce a response. Consulted only when the
    /// current attempt wrote no result.json.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub provider_response_refusal_patterns: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputContractCause {
    ProviderResponseRefused,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerOutputLogSpan {
    pub path: String,
    pub byte_start: u64,
    pub byte_end: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputContractIncident {
    pub cause: OutputContractCause,
    pub worker_id: String,
    pub first_attempt_id: String,
    pub first_log_span: WorkerOutputLogSpan,
    pub recovery_consumed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_attempt_id: Option<String>,
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
    /// Durable evidence proposals authored by the worker. Yardlet validates
    /// exact task/attempt/producer linkage and writes canonical declarations.
    #[serde(default)]
    pub artifacts: Vec<ArtifactProposal>,
    /// Live target proposals authored by the worker. These are declarations,
    /// never current-liveness claims; the core records probe observations.
    #[serde(default)]
    pub resources: Vec<RuntimeResourceProposal>,
}

impl RunResult {
    pub fn resource_provenance_errors(&self, attempt_id: &str) -> Vec<String> {
        let mut errors = Vec::new();
        for proposal in &self.artifacts {
            if let Err(error) = proposal.validate_worker_provenance(&self.task_id, attempt_id) {
                errors.push(format!("artifact {}: {error}", proposal.proposal_id));
            }
        }
        for proposal in &self.resources {
            if let Err(error) = proposal.validate_worker_provenance(&self.task_id, attempt_id) {
                errors.push(format!("resource {}: {error}", proposal.proposal_id));
            }
        }
        errors
    }
}

// ---------------------------------------------------------------------------
// V010-004 runtime resources and durable artifacts
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceProducer {
    #[serde(default)]
    pub worker_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactRole {
    File,
    Screenshot,
    GitDiff,
    ValidationOutput,
    ReviewReport,
    Handoff,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactProposal {
    #[serde(default)]
    pub proposal_id: String,
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub attempt_id: String,
    #[serde(default)]
    pub producer: ResourceProducer,
    #[serde(default)]
    pub causation_id: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub digest: String,
    #[serde(default)]
    pub media_type: String,
    pub role: ArtifactRole,
    /// More specific existing task-channel projection label for core-generated
    /// run artifacts. Worker proposals leave this empty and use `role`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub channel_role: String,
    /// Authorship classification: did the worker author the artifact content
    /// (`true`) or did the core/evaluator generate it (`false`)? `None` means
    /// unstated; proposals predating this field deserialize to `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_authored: Option<bool>,
}

impl ArtifactProposal {
    pub fn validate_provenance(&self, task_id: &str, attempt_id: &str) -> Result<(), String> {
        if self.proposal_id.trim().is_empty()
            || self.task_id != task_id
            || self.attempt_id != attempt_id
            || self.producer.worker_id.trim().is_empty()
            || self.causation_id.trim().is_empty()
            || self.path.trim().is_empty()
            || self.digest.trim().is_empty()
            || self.media_type.trim().is_empty()
        {
            return Err("artifact proposal lacks exact task/attempt/producer evidence".into());
        }
        Ok(())
    }

    pub fn validate_worker_provenance(
        &self,
        task_id: &str,
        attempt_id: &str,
    ) -> Result<(), String> {
        self.validate_provenance(task_id, attempt_id)?;
        if self.causation_id != attempt_id {
            return Err("artifact proposal causation must name its exact attempt".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artifact {
    pub schema_version: u32,
    pub artifact_id: String,
    pub proposal_id: String,
    pub session_id: String,
    pub intent_id: String,
    pub task_id: String,
    pub attempt_id: String,
    pub producer: ResourceProducer,
    pub causation_id: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub source_path: String,
    pub digest: String,
    pub media_type: String,
    pub role: ArtifactRole,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub channel_role: String,
    /// Authorship recorded at publication. `None` on records published before
    /// the field existed; recovery replays preserve the first canonical record.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_authored: Option<bool>,
    pub created_event_id: String,
    pub published_seq: u64,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceOwnership {
    Yardlet,
    Worker,
    User,
    External,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceCapability {
    Open,
    Attach,
    Stop,
    Restart,
    Detach,
    Cleanup,
    Reconcile,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RuntimeResourceTarget {
    Terminal {
        terminal_id: String,
        pid: u32,
        start_identity: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        attach_hint: String,
    },
    Process {
        pid: u32,
        start_identity: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        command: Vec<String>,
    },
    Service {
        url: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        health_url: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<u32>,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        start_identity: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        restart_command: Vec<String>,
    },
    Browser {
        url: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        session_id: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        session_probe_url: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<u32>,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        start_identity: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        screenshot_artifact_id: String,
    },
}

impl RuntimeResourceTarget {
    pub fn inferred_capabilities(&self) -> Vec<ResourceCapability> {
        use ResourceCapability as Capability;

        let mut capabilities = match self {
            Self::Terminal { .. } => vec![
                Capability::Open,
                Capability::Attach,
                Capability::Stop,
                Capability::Detach,
                Capability::Cleanup,
                Capability::Reconcile,
            ],
            Self::Process { command, .. } => {
                let mut capabilities = vec![
                    Capability::Open,
                    Capability::Attach,
                    Capability::Stop,
                    Capability::Cleanup,
                    Capability::Reconcile,
                ];
                if !command.is_empty() {
                    capabilities.push(Capability::Restart);
                }
                capabilities
            }
            Self::Service {
                pid,
                restart_command,
                ..
            } => {
                let mut capabilities = vec![Capability::Open, Capability::Reconcile];
                if pid.is_some() {
                    capabilities.extend([Capability::Stop, Capability::Cleanup]);
                    if !restart_command.is_empty() {
                        capabilities.push(Capability::Restart);
                    }
                }
                capabilities
            }
            Self::Browser { .. } => vec![Capability::Open, Capability::Reconcile],
        };
        capabilities.sort_unstable();
        capabilities
    }

    pub fn normalize_capabilities(
        &self,
        declared: &[ResourceCapability],
    ) -> Result<Vec<ResourceCapability>, String> {
        let supported = self.inferred_capabilities();
        if declared.is_empty() {
            return Ok(supported);
        }
        let mut normalized = declared.to_vec();
        normalized.sort_unstable();
        normalized.dedup();
        if let Some(capability) = normalized
            .iter()
            .find(|capability| !supported.contains(capability))
        {
            return Err(format!(
                "resource target cannot support declared capability {capability:?}"
            ));
        }
        Ok(normalized)
    }

    pub fn validate(&self) -> Result<(), String> {
        match self {
            Self::Terminal {
                terminal_id,
                pid,
                start_identity,
                ..
            } => {
                if terminal_id.trim().is_empty() || *pid == 0 || start_identity.trim().is_empty() {
                    return Err(
                        "terminal target requires terminal_id, pid, and start_identity".into(),
                    );
                }
            }
            Self::Process {
                pid,
                start_identity,
                ..
            } => {
                if *pid == 0 || start_identity.trim().is_empty() {
                    return Err("process target requires pid and start_identity".into());
                }
            }
            Self::Service {
                url,
                pid,
                start_identity,
                ..
            } => {
                if url.trim().is_empty() || (pid.is_some() && start_identity.trim().is_empty()) {
                    return Err("service target requires url and identity for any pid".into());
                }
            }
            Self::Browser {
                url,
                pid,
                start_identity,
                ..
            } => {
                if url.trim().is_empty() || (pid.is_some() && start_identity.trim().is_empty()) {
                    return Err("browser target requires url and identity for any pid".into());
                }
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeResourceProposal {
    #[serde(default)]
    pub proposal_id: String,
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub attempt_id: String,
    #[serde(default)]
    pub producer: ResourceProducer,
    #[serde(default)]
    pub causation_id: String,
    #[serde(default)]
    pub ownership: ResourceOwnership,
    #[serde(default)]
    pub capabilities: Vec<ResourceCapability>,
    pub target: RuntimeResourceTarget,
}

impl RuntimeResourceProposal {
    pub fn validate_provenance(&self, task_id: &str, attempt_id: &str) -> Result<(), String> {
        if self.proposal_id.trim().is_empty()
            || self.task_id != task_id
            || self.attempt_id != attempt_id
            || self.producer.worker_id.trim().is_empty()
            || self.causation_id.trim().is_empty()
        {
            return Err("resource proposal lacks exact task/attempt/producer evidence".into());
        }
        self.target.validate()?;
        self.target
            .normalize_capabilities(&self.capabilities)
            .map(|_| ())
    }

    pub fn validate_worker_provenance(
        &self,
        task_id: &str,
        attempt_id: &str,
    ) -> Result<(), String> {
        self.validate_provenance(task_id, attempt_id)?;
        if self.causation_id != attempt_id {
            return Err("resource proposal causation must name its exact attempt".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeResource {
    pub schema_version: u32,
    pub resource_id: String,
    pub proposal_id: String,
    pub session_id: String,
    pub intent_id: String,
    pub task_id: String,
    pub attempt_id: String,
    pub producer: ResourceProducer,
    pub causation_id: String,
    pub ownership: ResourceOwnership,
    #[serde(default)]
    pub capabilities: Vec<ResourceCapability>,
    pub target: RuntimeResourceTarget,
    pub created_event_id: String,
    pub published_seq: u64,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceStatus {
    Unknown,
    Available,
    Live,
    Dead,
    Unavailable,
    Expired,
    Orphaned,
    Unrecoverable,
    Detached,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceObservation {
    pub schema_version: u32,
    pub observation_id: String,
    pub resource_id: String,
    pub task_id: String,
    pub attempt_id: String,
    pub status: ResourceStatus,
    pub observed_at: String,
    #[serde(default)]
    pub current: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub start_identity: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
    pub causation_id: String,
    pub event_id: String,
    pub seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceTaskIndex {
    pub intent_id: String,
    pub task_id: String,
    pub artifacts: Vec<String>,
    pub resources: Vec<String>,
    pub attempts: Vec<String>,
    #[serde(default)]
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceIndex {
    pub schema_version: u32,
    pub canonical_digest: String,
    pub artifacts: Vec<String>,
    pub resources: Vec<String>,
    pub attempts: Vec<String>,
    #[serde(default)]
    pub tasks: Vec<ResourceTaskIndex>,
    #[serde(default)]
    pub tasks_truncated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceOperationKind {
    Discover,
    Inspect,
    Open,
    Attach,
    Stop,
    Restart,
    Detach,
    Cleanup,
    Reconcile,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceOperationRequest {
    pub action_id: String,
    pub operation: ResourceOperationKind,
    #[serde(default)]
    pub intent_id: String,
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub target_id: String,
    pub expected_status: ResourceStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceActionStatus {
    Completed,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceActionRecoveryPhase {
    Prepared,
    Terminated,
    Spawned,
}

impl ResourceActionRecoveryPhase {
    pub fn rank(self) -> u8 {
        match self {
            Self::Prepared => 0,
            Self::Terminated => 1,
            Self::Spawned => 2,
        }
    }
}

/// Durable, non-terminal action progress. The terminal receipt remains an
/// immutable `ResourceActionReceipt`; this snapshot only prevents a recovered
/// stop/restart action from repeating an external side effect.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceActionRecoveryReceipt {
    pub schema_version: u32,
    pub action_id: String,
    pub request_digest: String,
    pub operation: ResourceOperationKind,
    pub intent_id: String,
    pub task_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub target_id: String,
    pub expected_status: ResourceStatus,
    pub requested_event_id: String,
    pub phase: ResourceActionRecoveryPhase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effect_pid: Option<u32>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub effect_start_identity: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "target_type", rename_all = "snake_case")]
pub enum ResourceOpenTarget {
    File {
        path: String,
        media_type: String,
    },
    Url {
        url: String,
    },
    TerminalSession {
        terminal_id: String,
        attach_hint: String,
    },
    ProcessMonitor {
        pid: u32,
    },
    Unavailable {
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "entry_type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum ResourceEntry {
    Artifact {
        artifact: Artifact,
        status: ResourceStatus,
        open_target: ResourceOpenTarget,
    },
    RuntimeResource {
        resource: RuntimeResource,
        status: ResourceStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        last_observation: Option<ResourceObservation>,
        open_target: ResourceOpenTarget,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceActionResult {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub entries: Vec<ResourceEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_target: Option<ResourceOpenTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observation: Option<ResourceObservation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceActionReceipt {
    pub schema_version: u32,
    pub action_id: String,
    pub operation: ResourceOperationKind,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub intent_id: String,
    pub task_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub target_id: String,
    pub request_digest: String,
    pub status: ResourceActionStatus,
    #[serde(default)]
    pub result: ResourceActionResult,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub result_event_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
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
    /// Optional exact model request. Empty/`auto` inherits the governing run.
    #[serde(default)]
    pub model: String,
    /// Optional fallback request. Omission inherits the governing run.
    #[serde(default)]
    pub fallback_enabled: Option<bool>,
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

// ---------------------------------------------------------------------------
// .agents/task-channels/** — V010-003 durable task channel facts/projection
// ---------------------------------------------------------------------------

/// Stable normalized event vocabulary shared by CLI/TUI projections. Unknown
/// strings are retained so additive provider events stay displayable without
/// being mistaken for scheduler evidence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelEventType {
    TaskStateChanged,
    AttemptPrepared,
    WorkerStarted,
    WorkerMessage,
    ToolStarted,
    ToolCompleted,
    WorkerCheckpoint,
    QuestionAsked,
    QuestionClosed,
    UserAnswered,
    ArtifactCreated,
    ResourceDeclared,
    ResourceObserved,
    ResourceStateChanged,
    ValidationStarted,
    ValidationCompleted,
    WorkerCompleted,
    CompletionRecorded,
    ActionRequested,
    ActionCompleted,
    ActionRejected,
    Unknown(String),
}

impl ChannelEventType {
    pub fn as_str(&self) -> &str {
        match self {
            Self::TaskStateChanged => "task.state.changed",
            Self::AttemptPrepared => "attempt.prepared",
            Self::WorkerStarted => "worker.started",
            Self::WorkerMessage => "worker.message",
            Self::ToolStarted => "tool.started",
            Self::ToolCompleted => "tool.completed",
            Self::WorkerCheckpoint => "worker.checkpoint",
            Self::QuestionAsked => "question.asked",
            Self::QuestionClosed => "question.closed",
            Self::UserAnswered => "user.answered",
            Self::ArtifactCreated => "artifact.created",
            Self::ResourceDeclared => "resource.declared",
            Self::ResourceObserved => "resource.observed",
            Self::ResourceStateChanged => "resource.state.changed",
            Self::ValidationStarted => "validation.started",
            Self::ValidationCompleted => "validation.completed",
            Self::WorkerCompleted => "worker.completed",
            Self::CompletionRecorded => "completion.recorded",
            Self::ActionRequested => "action.requested",
            Self::ActionCompleted => "action.completed",
            Self::ActionRejected => "action.rejected",
            Self::Unknown(value) => value,
        }
    }

    pub fn requires_attempt(&self) -> bool {
        matches!(
            self,
            Self::AttemptPrepared
                | Self::WorkerStarted
                | Self::WorkerMessage
                | Self::ToolStarted
                | Self::ToolCompleted
                | Self::WorkerCheckpoint
                | Self::QuestionAsked
                | Self::QuestionClosed
                | Self::ArtifactCreated
                | Self::ResourceDeclared
                | Self::ResourceObserved
                | Self::ResourceStateChanged
                | Self::ValidationStarted
                | Self::ValidationCompleted
                | Self::WorkerCompleted
                | Self::CompletionRecorded
        )
    }
}

impl Serialize for ChannelEventType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for ChannelEventType {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(match value.as_str() {
            "task.state.changed" => Self::TaskStateChanged,
            "attempt.prepared" => Self::AttemptPrepared,
            "worker.started" => Self::WorkerStarted,
            "worker.message" => Self::WorkerMessage,
            "tool.started" => Self::ToolStarted,
            "tool.completed" => Self::ToolCompleted,
            "worker.checkpoint" => Self::WorkerCheckpoint,
            "question.asked" => Self::QuestionAsked,
            "question.closed" => Self::QuestionClosed,
            "user.answered" => Self::UserAnswered,
            "artifact.created" => Self::ArtifactCreated,
            "resource.declared" => Self::ResourceDeclared,
            "resource.observed" => Self::ResourceObserved,
            "resource.state.changed" => Self::ResourceStateChanged,
            "validation.started" => Self::ValidationStarted,
            "validation.completed" => Self::ValidationCompleted,
            "worker.completed" => Self::WorkerCompleted,
            "completion.recorded" => Self::CompletionRecorded,
            "action.requested" => Self::ActionRequested,
            "action.completed" => Self::ActionCompleted,
            "action.rejected" => Self::ActionRejected,
            _ => Self::Unknown(value),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventActorKind {
    System,
    User,
    Worker,
    Surface,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventActor {
    pub kind: EventActorKind,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawEventRef {
    pub artifact_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub stream: String,
    pub byte_start: u64,
    pub byte_end: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelEvent {
    pub schema_version: u32,
    pub event_id: String,
    pub session_id: String,
    pub seq: u64,
    #[serde(rename = "type")]
    pub event_type: ChannelEventType,
    pub recorded_at: String,
    pub actor: EventActor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub causation_id: Option<String>,
    pub correlation_id: String,
    pub task_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attempt_id: Option<String>,
    #[serde(default)]
    pub payload: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_ref: Option<RawEventRef>,
}

impl ChannelEvent {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err("unsupported channel event schema_version".into());
        }
        if self.event_id.is_empty()
            || self.session_id.is_empty()
            || self.seq == 0
            || self.recorded_at.is_empty()
            || self.correlation_id.is_empty()
            || self.task_id.is_empty()
        {
            return Err("channel event is missing required envelope linkage".into());
        }
        if matches!(
            self.actor.kind,
            EventActorKind::Worker | EventActorKind::Surface
        ) && self.actor.id.is_empty()
        {
            return Err("worker/surface actor id is required".into());
        }
        if self.event_type.requires_attempt()
            && self.attempt_id.as_deref().is_none_or(str::is_empty)
        {
            return Err(format!(
                "attempt_id is required for {}",
                self.event_type.as_str()
            ));
        }
        if let Some(raw) = &self.raw_ref {
            if raw.artifact_id.is_empty() || raw.byte_end <= raw.byte_start {
                return Err("raw_ref must name a non-empty exact byte span".into());
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptState {
    Prepared,
    Running,
    NeedsUser,
    Succeeded,
    Failed,
    TimedOut,
    Cancelled,
    Abandoned,
}

impl AttemptState {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::NeedsUser
                | Self::Succeeded
                | Self::Failed
                | Self::TimedOut
                | Self::Cancelled
                | Self::Abandoned
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContinuationMode {
    Fresh,
    NativeResume,
    ExplicitPacket,
    Retry,
    Fallback,
    Redirect,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerAttempt {
    pub schema_version: u32,
    pub attempt_id: String,
    pub session_id: String,
    pub intent_id: String,
    pub task_id: String,
    pub worker_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_session_ref: Option<String>,
    pub state: AttemptState,
    pub continuation: ContinuationMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caused_by_event_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caused_by_action_id: Option<String>,
    pub raw_stdout_ref: String,
    pub raw_stderr_ref: String,
}

impl WorkerAttempt {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1
            || self.attempt_id.is_empty()
            || self.session_id.is_empty()
            || self.intent_id.is_empty()
            || self.task_id.is_empty()
            || self.worker_id.is_empty()
            || self.raw_stdout_ref.is_empty()
            || self.raw_stderr_ref.is_empty()
        {
            return Err("attempt is missing required identity or raw evidence linkage".into());
        }
        if self.continuation == ContinuationMode::NativeResume
            && self.worker_session_ref.as_deref().is_none_or(str::is_empty)
        {
            return Err("native resume requires exact worker_session_ref".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuestionState {
    Open,
    Answered,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    pub schema_version: u32,
    pub question_id: String,
    pub session_id: String,
    pub task_id: String,
    pub attempt_id: String,
    pub asked_event_id: String,
    pub asked_seq: u64,
    pub context_start_seq: u64,
    pub text: String,
    pub state: QuestionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer_id: Option<String>,
}

impl Question {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1
            || self.question_id.is_empty()
            || self.session_id.is_empty()
            || self.task_id.is_empty()
            || self.attempt_id.is_empty()
            || self.asked_event_id.is_empty()
            || self.asked_seq == 0
            || self.context_start_seq == 0
            || self.context_start_seq > self.asked_seq
            || self.text.trim().is_empty()
        {
            return Err("question is missing exact channel position linkage".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answer {
    pub schema_version: u32,
    pub answer_id: String,
    pub question_id: String,
    pub action_id: String,
    pub answered_event_id: String,
    pub text: String,
}

impl Answer {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1
            || self.answer_id.is_empty()
            || self.question_id.is_empty()
            || self.action_id.is_empty()
            || self.answered_event_id.is_empty()
            || self.text.trim().is_empty()
        {
            return Err("answer is missing exact question/action/event linkage".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelActionKind {
    Answer,
    Redirect,
    Retry,
    Stop,
    Resume,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelActionStatus {
    Prepared,
    Completed,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionReceipt {
    pub schema_version: u32,
    pub action_id: String,
    pub session_id: String,
    pub task_id: String,
    pub action: ChannelActionKind,
    pub request_digest: String,
    pub status: ChannelActionStatus,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub result_event_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_attempt_id: Option<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnswerActionRequest {
    pub action_id: String,
    pub answer_id: String,
    pub continuation_attempt_id: String,
    pub session_id: String,
    pub intent_id: String,
    pub task_id: String,
    pub question_id: String,
    pub text: String,
    pub worker_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_session_ref: Option<String>,
    #[serde(default)]
    pub supports_native_resume: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnswerActionOutcome {
    pub receipt: ActionReceipt,
    pub answer: Answer,
    pub attempt: WorkerAttempt,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RedirectActionRequest {
    pub action_id: String,
    pub continuation_attempt_id: String,
    pub session_id: String,
    pub intent_id: String,
    pub task_id: String,
    pub stopped_attempt_id: String,
    pub observed_terminal_state: AttemptState,
    pub reason: String,
    pub guidance: String,
    pub worker_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint_ref: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RedirectActionOutcome {
    pub receipt: ActionReceipt,
    pub attempt: WorkerAttempt,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskChannel {
    pub schema_version: u32,
    pub channel_id: String,
    pub session_id: String,
    pub intent_id: String,
    pub task_id: String,
    pub highest_seq: u64,
    #[serde(default)]
    pub attempts: Vec<WorkerAttempt>,
    #[serde(default)]
    pub questions: Vec<Question>,
    #[serde(default)]
    pub answers: Vec<Answer>,
    #[serde(default)]
    pub events: Vec<ChannelEvent>,
    #[serde(default)]
    pub replay_errors: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskChannelIndex {
    pub schema_version: u32,
    pub channel_id: String,
    pub highest_applied_seq: u64,
    pub retained_from_seq: u64,
    pub event_count: usize,
    #[serde(default)]
    pub tail_events: Vec<ChannelEvent>,
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

    #[test]
    fn worker_refusal_patterns_are_backward_compatible_and_bounded() {
        let legacy: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation: {command: fixture}\n",
        )
        .unwrap();
        assert!(legacy.workers[0]
            .provider_response_refusal_patterns
            .is_empty());
        legacy.validate().unwrap();

        let configured: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nworkers:\n  - id: fixture\n    provider_response_refusal_patterns: ['request refused']\n    invocation: {command: fixture}\n",
        )
        .unwrap();
        assert_eq!(
            configured.workers[0].provider_response_refusal_patterns,
            ["request refused"]
        );
        configured.validate().unwrap();

        for invalid in [
            "schema_version: 1\nworkers:\n  - id: fixture\n    provider_response_refusal_patterns: ['']\n    invocation: {command: fixture}\n",
            "schema_version: 1\nworkers:\n  - id: fixture\n    provider_response_refusal_patterns: ['   ']\n    invocation: {command: fixture}\n",
        ] {
            let workers: WorkersFile = crate::yaml::from_str(invalid).unwrap();
            assert!(workers.validate().is_err());
        }

        let too_many = (0..=MAX_PROVIDER_RESPONSE_REFUSAL_PATTERNS)
            .map(|index| format!("pattern-{index}"))
            .collect::<Vec<_>>();
        let mut workers = legacy.clone();
        workers.workers[0].provider_response_refusal_patterns = too_many;
        assert!(workers.validate().is_err());

        workers.workers[0].provider_response_refusal_patterns =
            vec!["x".repeat(MAX_PROVIDER_RESPONSE_REFUSAL_PATTERN_BYTES + 1)];
        assert!(workers.validate().is_err());
    }

    #[test]
    fn output_contract_incident_uses_stable_typed_cause() {
        let incident = OutputContractIncident {
            cause: OutputContractCause::ProviderResponseRefused,
            worker_id: "fixture".into(),
            first_attempt_id: "run-1".into(),
            first_log_span: WorkerOutputLogSpan {
                path: "worker-output.log".into(),
                byte_start: 11,
                byte_end: 42,
            },
            recovery_consumed: true,
            terminal_attempt_id: Some("run-1-attempt-2".into()),
        };
        let encoded = serde_json::to_value(&incident).unwrap();
        assert_eq!(encoded["cause"], "provider_response_refused");
        assert_eq!(encoded["first_log_span"]["byte_start"], 11);
        assert_eq!(encoded["terminal_attempt_id"], "run-1-attempt-2");
    }
    use crate::yaml;

    #[test]
    fn capability_coverage_round_trips_all_states_and_legacy_defaults_fail_closed() {
        for status in [
            CoverageStatus::Covered,
            CoverageStatus::Weak,
            CoverageStatus::Missing,
            CoverageStatus::Stale,
            CoverageStatus::ExternalToolNeeded,
        ] {
            let record = TaskCapabilityCoverage {
                task_id: "YARD-001".into(),
                status,
                evidence: vec![CoverageEvidence {
                    source: CoverageEvidenceSource::WorkspaceSkillCatalog,
                    reference: "writing-plans".into(),
                    detail: "selected skill is installed".into(),
                }],
                confidence: CoverageConfidence::High,
                freshness: CoverageFreshness::Fresh,
                reason_code: CoverageReasonCode::CoverageConfirmed,
            };
            let encoded = yaml::to_string(&record).unwrap();
            let decoded: TaskCapabilityCoverage = yaml::from_str(&encoded).unwrap();
            assert_eq!(decoded, record);
        }

        let legacy: TaskCapabilityCoverage = yaml::from_str("task_id: legacy\n").unwrap();
        assert_eq!(legacy.status, CoverageStatus::Missing);
        assert!(legacy.evidence.is_empty());
        assert_eq!(legacy.confidence, CoverageConfidence::Unknown);
        assert_eq!(legacy.freshness, CoverageFreshness::Unknown);
        assert_eq!(legacy.reason_code, CoverageReasonCode::InsufficientEvidence);
    }

    #[test]
    fn scout_result_dispositions_round_trip_and_legacy_defaults_are_non_mutating() {
        for disposition in [
            ScoutDisposition::UseExistingSkill,
            ScoutDisposition::AdaptExternalSkillCandidate,
            ScoutDisposition::DraftReusableSkill,
            ScoutDisposition::RecordToolCandidate,
            ScoutDisposition::PreserveOneOffEvidence,
            ScoutDisposition::ReportNoChange,
            ScoutDisposition::AskUser,
        ] {
            let result = ScoutResult {
                topic: "capability gap".into(),
                sources_consulted: vec![ResearchSource::WorkspaceSkillCatalog],
                disposition,
                evidence: vec![],
                candidate: None,
                gap: CapabilityGap::NoGap,
            };
            let encoded = yaml::to_string(&result).unwrap();
            assert_eq!(yaml::from_str::<ScoutResult>(&encoded).unwrap(), result);
        }

        let legacy: ScoutResult = yaml::from_str("topic: legacy\n").unwrap();
        assert_eq!(legacy.disposition, ScoutDisposition::ReportNoChange);
        assert_eq!(legacy.gap, CapabilityGap::NoGap);
        assert!(legacy.sources_consulted.is_empty());
    }

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
    fn runtime_contract_digest_ignores_only_typed_scheduler_metadata() {
        let planned: Task = yaml::from_str(
            r#"
id: YARD-001
title: immutable work
priority: 10
preferred_worker: codex
allowed_scope: [src/state.rs]
interaction:
  planner_note: keep exact
"#,
        )
        .unwrap();
        let planned_digest = planned.runtime_contract_digest().unwrap();

        let mut runtime = planned.clone();
        runtime.state = TaskState::Deferred;
        runtime.priority = -20;
        runtime.worker_rationale = Some("runtime observation".to_string());
        runtime.set_deferred_by(Some(DeferredBy::new("YARD-001")));
        runtime.add_remediation_for("REVIEW");
        assert_eq!(runtime.runtime_contract_digest().unwrap(), planned_digest);

        runtime.allowed_scope = vec!["forged/scope".to_string()];
        assert_ne!(runtime.runtime_contract_digest().unwrap(), planned_digest);

        let mut non_mapping = planned.clone();
        non_mapping.interaction = Some(yaml::Value::String("different".to_string()));
        assert_ne!(
            non_mapping.runtime_contract_digest().unwrap(),
            planned_digest
        );
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

    #[test]
    fn channel_event_enforces_attempt_and_raw_linkage_additively() {
        let event: ChannelEvent = serde_json::from_str(
            r#"{
                "schema_version": 1,
                "event_id": "evt_1",
                "session_id": "ses_1",
                "seq": 1,
                "type": "worker.message",
                "recorded_at": "2026-07-14T00:00:00Z",
                "actor": { "kind": "worker", "id": "codex" },
                "correlation_id": "cor_1",
                "task_id": "YARD-001",
                "attempt_id": "att_1",
                "payload": { "text": "visible progress" },
                "raw_ref": {
                    "artifact_id": "raw_att_1_stdout",
                    "stream": "stdout",
                    "byte_start": 0,
                    "byte_end": 17
                },
                "future_additive_field": true
            }"#,
        )
        .unwrap();

        event.validate().unwrap();
        assert_eq!(event.event_type, ChannelEventType::WorkerMessage);
        assert_eq!(event.attempt_id.as_deref(), Some("att_1"));

        let mut missing_attempt = event.clone();
        missing_attempt.attempt_id = None;
        assert!(missing_attempt
            .validate()
            .unwrap_err()
            .contains("attempt_id"));

        let mut invalid_raw = event;
        invalid_raw.raw_ref.as_mut().unwrap().byte_end = 0;
        assert!(invalid_raw.validate().unwrap_err().contains("raw_ref"));
    }

    #[test]
    fn durable_channel_types_preserve_attempt_and_exact_question_causality() {
        let attempt = WorkerAttempt {
            schema_version: 1,
            attempt_id: "att_2".into(),
            session_id: "ses_1".into(),
            intent_id: "intent_1".into(),
            task_id: "YARD-001".into(),
            worker_id: "codex".into(),
            worker_session_ref: Some("thread-1".into()),
            state: AttemptState::Prepared,
            continuation: ContinuationMode::NativeResume,
            caused_by_event_id: Some("evt_answer".into()),
            caused_by_action_id: Some("act_answer".into()),
            raw_stdout_ref: "attempts/att_2/stdout.log".into(),
            raw_stderr_ref: "attempts/att_2/stderr.log".into(),
        };
        let question = Question {
            schema_version: 1,
            question_id: "qst_1".into(),
            session_id: "ses_1".into(),
            task_id: "YARD-001".into(),
            attempt_id: "att_1".into(),
            asked_event_id: "evt_question".into(),
            asked_seq: 9,
            context_start_seq: 4,
            text: "Which path?".into(),
            state: QuestionState::Open,
            answer_id: None,
        };
        let answer = Answer {
            schema_version: 1,
            answer_id: "ans_1".into(),
            question_id: question.question_id.clone(),
            action_id: "act_answer".into(),
            answered_event_id: "evt_answer".into(),
            text: "Path A".into(),
        };

        attempt.validate().unwrap();
        question.validate().unwrap();
        answer.validate().unwrap();
        assert_eq!(attempt.continuation, ContinuationMode::NativeResume);
        assert_eq!(answer.question_id, question.question_id);
    }
}
