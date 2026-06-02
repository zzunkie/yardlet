//! Templates embedded into the binary at compile time.
//!
//! `yard init` writes these into a target repo's `.agents/` directory. The
//! binary is therefore self-contained and does not need a source checkout to
//! initialize a workspace.

pub const BILLING_POLICY: &str = include_str!("../templates/agents/billing-policy.yaml");
pub const TOOL_POLICY: &str = include_str!("../templates/agents/tool-policy.yaml");
pub const APPROVAL_POLICY: &str = include_str!("../templates/agents/approval-policy.yaml");
pub const INTERACTION_POLICY: &str = include_str!("../templates/agents/interaction-policy.yaml");
pub const RESEARCH_POLICY: &str = include_str!("../templates/agents/research-policy.yaml");
pub const WORKERS: &str = include_str!("../templates/agents/workers.yaml");
pub const WORK_QUEUE: &str = include_str!("../templates/agents/work-queue.yaml");
pub const PLANNING_GATE_SKILL: &str =
    include_str!("../templates/agents/skills/planning-gate/SKILL.md");
