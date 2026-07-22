//! Templates embedded into the binary at compile time.
//!
//! `yardlet init` writes these into a target repo's `.agents/` directory. The
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
pub const HOOKS_README: &str = include_str!("../templates/agents/hooks/README.md");
pub const MEMORY_README: &str = include_str!("../templates/agents/memory/README.md");

/// Parse either the legacy v1 scaffold or the expanded typed policy. Newly
/// added controls have serde defaults, so existing workspaces migrate on read.
pub fn parse_research_policy(text: &str) -> anyhow::Result<crate::schemas::ResearchPolicy> {
    crate::yaml::from_str(text)
}

/// The embedded default is compile-time bundled and validated by unit tests.
pub fn research_policy() -> crate::schemas::ResearchPolicy {
    parse_research_policy(RESEARCH_POLICY).expect("embedded research policy must be valid")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_v1_research_policy_loads_with_explicit_typed_defaults() {
        let legacy = r#"
schema_version: 1
allowed: when_needed
mode: intent_locked
event_template:
  research_question: ""
  source_or_anchor: ""
  used_for: ""
  decision_impact: ""
  scope_impact: none
  drift_detected: false
adjacent_idea_handling: record_as_candidate
"#;
        let policy = parse_research_policy(legacy).unwrap();
        assert_eq!(policy.budget.max_cycles, 1);
        assert_eq!(policy.budget.max_topics_per_cycle, 3);
        assert_eq!(policy.freshness.cache_ttl_days, 30);
        assert!(policy.freshness.unknown_is_stale);
        assert_eq!(policy.thresholds.soft_signals_to_scout, 2);
        assert_eq!(policy.thresholds.repeated_failure_hard, 2);
        assert!(policy.dedup.within_intent);
        assert_eq!(policy.dedup.topic_key, "normalized_topic");
        assert_eq!(
            policy.source_order,
            vec![
                crate::schemas::ResearchSource::WorkspaceSkillCatalog,
                crate::schemas::ResearchSource::UserSkillLibrary,
                crate::schemas::ResearchSource::ExternalPrimarySource,
            ]
        );

        let embedded = research_policy();
        assert_eq!(embedded, policy);
    }
}
