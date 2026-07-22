//! Deterministic plan-time capability coverage and bounded-scout triggering.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::guard::WorkerCapabilityReadiness;
use crate::schemas::{
    CapabilityGap, CoverageConfidence, CoverageEvidence, CoverageEvidenceSource, CoverageFreshness,
    CoverageReasonCode, CoverageStatus, ResearchPolicy, ScoutHardSignal, ScoutResult,
    ScoutSoftSignal, ScoutTrigger, ScoutTriggerDecision, Task, TaskCapabilityCoverage,
};
use crate::skills::{Classification, SkillCatalogProjection};

/// Typed observations supplied by planning/history projection. Booleans name
/// independent signals; repeated observations use counts so thresholds remain
/// policy-owned rather than inferred from prose.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityDiscoverySignals {
    #[serde(default)]
    pub explicit_research_request: bool,
    #[serde(default)]
    pub only_unusable_skill_matches: bool,
    #[serde(default)]
    pub current_external_fact_dependency: bool,
    #[serde(default)]
    pub material_external_choice_dependency: bool,
    #[serde(default)]
    pub weak_contextual_match: bool,
    #[serde(default)]
    pub unfamiliar_domain: bool,
    #[serde(default)]
    pub typed_failure_count: usize,
    #[serde(default)]
    pub typed_needs_user_count: usize,
    #[serde(default)]
    pub knowledge_freshness: CoverageFreshness,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision_question: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CapabilityDiscoveryInput {
    pub task: Task,
    pub skill_catalog: SkillCatalogProjection,
    pub worker_readiness: Vec<WorkerCapabilityReadiness>,
    pub repo_classification: Classification,
    pub signals: CapabilityDiscoverySignals,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityDiscoveryOutcome {
    pub coverage: TaskCapabilityCoverage,
    pub trigger: ScoutTrigger,
    #[serde(default)]
    pub gap: CapabilityGap,
    /// Filled only by the later isolated scout orchestration step. Core
    /// coverage assessment always returns `None` and performs no research.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scout_result: Option<ScoutResult>,
}

fn norm_skill(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn normalized_set(values: &[String]) -> BTreeSet<String> {
    values
        .iter()
        .map(|value| norm_skill(value))
        .filter(|value| !value.is_empty())
        .collect()
}

/// Evaluate one task from already-snapshotted local inputs. No filesystem,
/// network, worker invocation, or state mutation occurs in this pure step.
pub fn assess(
    input: &CapabilityDiscoveryInput,
    policy: &ResearchPolicy,
) -> CapabilityDiscoveryOutcome {
    let workspace_skills = normalized_set(&input.skill_catalog.workspace);
    let user_skills = normalized_set(&input.skill_catalog.user_library);
    let selected_skills = normalized_set(&input.task.skills);
    let ready_capabilities =
        crate::routing::ready_capabilities_from_projection(&input.worker_readiness);
    let required_capabilities: BTreeSet<String> = input
        .task
        .required_capabilities
        .iter()
        .map(|capability| crate::routing::norm_cap(capability))
        .filter(|capability| !capability.is_empty())
        .collect();

    let missing_skills: Vec<String> = selected_skills
        .difference(&workspace_skills)
        .cloned()
        .collect();
    let missing_capabilities: Vec<String> = required_capabilities
        .difference(&ready_capabilities)
        .cloned()
        .collect();

    let mut evidence = Vec::new();
    for skill in &selected_skills {
        let (source, detail) = if workspace_skills.contains(skill) {
            (
                CoverageEvidenceSource::WorkspaceSkillCatalog,
                "selected skill is installed",
            )
        } else if user_skills.contains(skill) {
            (
                CoverageEvidenceSource::UserSkillLibrary,
                "selected skill is available but not installed",
            )
        } else {
            (
                CoverageEvidenceSource::WorkspaceSkillCatalog,
                "selected skill is absent from local catalogs",
            )
        };
        evidence.push(CoverageEvidence {
            source,
            reference: skill.clone(),
            detail: detail.to_string(),
        });
    }
    for capability in &required_capabilities {
        evidence.push(CoverageEvidence {
            source: CoverageEvidenceSource::WorkerReadiness,
            reference: capability.clone(),
            detail: if ready_capabilities.contains(capability) {
                "declared by a guard-ready worker"
            } else {
                "no guard-ready worker declares this capability"
            }
            .to_string(),
        });
    }
    for preset in &input.repo_classification.presets {
        evidence.push(CoverageEvidence {
            source: CoverageEvidenceSource::RepoPreset,
            reference: preset.clone(),
            detail: "deterministic repository preset".to_string(),
        });
    }
    for reference in &input.repo_classification.evidence {
        evidence.push(CoverageEvidence {
            source: CoverageEvidenceSource::RepoClassification,
            reference: reference.clone(),
            detail: "repository classification evidence".to_string(),
        });
    }
    evidence.push(CoverageEvidence {
        source: CoverageEvidenceSource::KnowledgeFreshness,
        reference: format!("{:?}", input.signals.knowledge_freshness).to_ascii_lowercase(),
        detail: "typed knowledge freshness observation".to_string(),
    });
    if input.signals.typed_failure_count > 0 {
        evidence.push(CoverageEvidence {
            source: CoverageEvidenceSource::TypedFailure,
            reference: input.signals.typed_failure_count.to_string(),
            detail: "typed failure observations".to_string(),
        });
    }
    if input.signals.typed_needs_user_count > 0
        || input
            .signals
            .decision_question
            .as_deref()
            .is_some_and(|question| !question.trim().is_empty())
    {
        evidence.push(CoverageEvidence {
            source: CoverageEvidenceSource::NeedsUser,
            reference: input.signals.typed_needs_user_count.to_string(),
            detail: "typed human-decision evidence".to_string(),
        });
    }

    let classifier_or_preset_gap = input.repo_classification.no_match
        || input.repo_classification.presets.is_empty()
        || !input.repo_classification.conflicts.is_empty();
    let failure_threshold = policy.thresholds.repeated_failure_hard.max(1);
    let stale_knowledge = input.signals.knowledge_freshness == CoverageFreshness::Stale
        || (input.signals.current_external_fact_dependency
            && input.signals.knowledge_freshness == CoverageFreshness::Unknown
            && policy.freshness.unknown_is_stale);

    let decision_question = input
        .signals
        .decision_question
        .as_deref()
        .map(str::trim)
        .filter(|question| !question.is_empty());
    let gap = if let Some(question) = decision_question {
        CapabilityGap::NeedsUser {
            question: question.to_string(),
        }
    } else if !missing_capabilities.is_empty() {
        CapabilityGap::ToolOrResource {
            missing_capabilities: missing_capabilities.clone(),
        }
    } else {
        CapabilityGap::NoGap
    };

    let (status, confidence, reason_code) = if decision_question.is_some() {
        (
            CoverageStatus::Missing,
            CoverageConfidence::High,
            CoverageReasonCode::HumanDecisionRequired,
        )
    } else if !missing_capabilities.is_empty() {
        (
            CoverageStatus::ExternalToolNeeded,
            CoverageConfidence::High,
            CoverageReasonCode::NoReadyWorkerCapability,
        )
    } else if !missing_skills.is_empty() {
        (
            CoverageStatus::Missing,
            CoverageConfidence::High,
            CoverageReasonCode::SelectedSkillMissing,
        )
    } else if input.signals.only_unusable_skill_matches {
        (
            CoverageStatus::Stale,
            CoverageConfidence::High,
            CoverageReasonCode::OnlyUnusableSkillMatches,
        )
    } else if stale_knowledge {
        (
            CoverageStatus::Stale,
            CoverageConfidence::High,
            CoverageReasonCode::StaleKnowledge,
        )
    } else if classifier_or_preset_gap
        || input.signals.weak_contextual_match
        || input.signals.unfamiliar_domain
        || (input.signals.typed_failure_count > 0
            && input.signals.typed_failure_count < failure_threshold)
        || input.signals.typed_needs_user_count > 0
    {
        (
            CoverageStatus::Weak,
            CoverageConfidence::Low,
            CoverageReasonCode::WeakContextualMatch,
        )
    } else {
        (
            CoverageStatus::Covered,
            CoverageConfidence::High,
            CoverageReasonCode::CoverageConfirmed,
        )
    };

    let mut hard = BTreeSet::new();
    if input.signals.explicit_research_request {
        hard.insert(ScoutHardSignal::ExplicitResearchRequest);
    }
    if !missing_skills.is_empty() {
        hard.insert(ScoutHardSignal::SelectedSkillMissing);
    }
    if !missing_capabilities.is_empty() {
        hard.insert(ScoutHardSignal::NoReadyWorkerCapability);
    }
    if input.signals.only_unusable_skill_matches {
        hard.insert(ScoutHardSignal::OnlyUnusableSkillMatches);
    }
    if input.signals.current_external_fact_dependency {
        hard.insert(ScoutHardSignal::CurrentExternalFactDependency);
    }
    if input.signals.material_external_choice_dependency {
        hard.insert(ScoutHardSignal::MaterialExternalChoiceDependency);
    }
    if input.signals.typed_failure_count >= failure_threshold {
        hard.insert(ScoutHardSignal::RepeatedTypedFailure);
    }

    let mut soft = BTreeSet::new();
    if classifier_or_preset_gap {
        soft.insert(ScoutSoftSignal::ClassifierOrPresetGap);
    }
    if input.signals.weak_contextual_match {
        soft.insert(ScoutSoftSignal::WeakContextualMatch);
    }
    if input.signals.unfamiliar_domain {
        soft.insert(ScoutSoftSignal::UnfamiliarDomain);
    }
    if (input.signals.typed_failure_count > 0
        && input.signals.typed_failure_count < failure_threshold)
        || input.signals.typed_needs_user_count > 0
    {
        soft.insert(ScoutSoftSignal::SubthresholdTypedEvidence);
    }

    let hard_signals: Vec<_> = hard.into_iter().collect();
    let soft_signals: Vec<_> = soft.into_iter().collect();
    let decision = if !hard_signals.is_empty()
        || soft_signals.len() >= policy.thresholds.soft_signals_to_scout.max(1)
    {
        ScoutTriggerDecision::Scout
    } else if soft_signals.is_empty() {
        ScoutTriggerDecision::NoScout
    } else {
        ScoutTriggerDecision::Observe
    };

    CapabilityDiscoveryOutcome {
        coverage: TaskCapabilityCoverage {
            task_id: input.task.id.clone(),
            status,
            evidence,
            confidence,
            freshness: input.signals.knowledge_freshness,
            reason_code,
        },
        trigger: ScoutTrigger {
            decision,
            hard_signals,
            soft_signals,
        },
        gap,
        scout_result: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::guard::{Readiness, WorkerCapabilityReadiness};
    use crate::schemas::{
        CapabilityGap, CoverageFreshness, CoverageStatus, ResearchPolicy, ScoutHardSignal,
        ScoutSoftSignal, ScoutTriggerDecision, Task,
    };
    use crate::skills::{Classification, SkillCatalogProjection};

    type InputMutation = Box<dyn Fn(&mut CapabilityDiscoveryInput)>;

    fn task(yaml: &str) -> Task {
        crate::yaml::from_str(yaml).unwrap()
    }

    fn covered_input() -> CapabilityDiscoveryInput {
        CapabilityDiscoveryInput {
            task: task(
                "id: T\ntitle: implement\nskills: [writing-plans]\nrequired_capabilities: [shell]\n",
            ),
            skill_catalog: SkillCatalogProjection {
                workspace: vec!["writing-plans".into()],
                user_library: vec![],
                workspace_unusable: vec![],
            },
            worker_readiness: vec![WorkerCapabilityReadiness {
                worker_id: "codex".into(),
                readiness: Readiness::Ready,
                capabilities: vec!["Shell".into()],
            }],
            repo_classification: Classification {
                presets: vec!["cli-rust".into()],
                evidence: vec!["Cargo.toml".into()],
                conflicts: vec![],
                no_match: false,
            },
            signals: CapabilityDiscoverySignals {
                knowledge_freshness: CoverageFreshness::Fresh,
                ..Default::default()
            },
        }
    }

    #[test]
    fn actual_inputs_deterministically_produce_all_five_coverage_states() {
        let policy = ResearchPolicy::default();

        let covered = assess(&covered_input(), &policy);
        assert_eq!(covered.coverage.status, CoverageStatus::Covered);
        assert_eq!(
            covered.coverage.reason_code,
            crate::schemas::CoverageReasonCode::CoverageConfirmed
        );

        let mut weak = covered_input();
        weak.signals.weak_contextual_match = true;
        let weak = assess(&weak, &policy);
        assert_eq!(weak.coverage.status, CoverageStatus::Weak);
        assert_eq!(
            weak.coverage.reason_code,
            crate::schemas::CoverageReasonCode::WeakContextualMatch
        );

        let mut missing = covered_input();
        missing.task.skills = vec!["not-installed".into()];
        let missing = assess(&missing, &policy);
        assert_eq!(missing.coverage.status, CoverageStatus::Missing);
        assert_eq!(
            missing.coverage.reason_code,
            crate::schemas::CoverageReasonCode::SelectedSkillMissing
        );

        let mut stale = covered_input();
        stale.signals.knowledge_freshness = CoverageFreshness::Stale;
        let stale = assess(&stale, &policy);
        assert_eq!(stale.coverage.status, CoverageStatus::Stale);
        assert_eq!(
            stale.coverage.reason_code,
            crate::schemas::CoverageReasonCode::StaleKnowledge
        );

        let mut external = covered_input();
        external.task.required_capabilities = vec!["browser-control".into()];
        let external = assess(&external, &policy);
        assert_eq!(external.coverage.status, CoverageStatus::ExternalToolNeeded);
        assert_eq!(
            external.coverage.reason_code,
            crate::schemas::CoverageReasonCode::NoReadyWorkerCapability
        );

        for outcome in [covered, weak, missing, stale, external] {
            assert!(!outcome.coverage.evidence.is_empty());
            assert_ne!(
                outcome.coverage.confidence,
                crate::schemas::CoverageConfidence::Unknown
            );
        }
    }

    #[test]
    fn every_hard_signal_triggers_scout_by_itself() {
        let cases: Vec<(&str, InputMutation)> = vec![
            (
                "explicit research",
                Box::new(|i| i.signals.explicit_research_request = true),
            ),
            (
                "selected skill missing",
                Box::new(|i| i.task.skills = vec!["absent".into()]),
            ),
            (
                "no ready capability",
                Box::new(|i| i.task.required_capabilities = vec!["browser".into()]),
            ),
            (
                "only unusable matches",
                Box::new(|i| i.signals.only_unusable_skill_matches = true),
            ),
            (
                "current external fact",
                Box::new(|i| i.signals.current_external_fact_dependency = true),
            ),
            (
                "material external choice",
                Box::new(|i| i.signals.material_external_choice_dependency = true),
            ),
            (
                "repeated typed failure",
                Box::new(|i| i.signals.typed_failure_count = 2),
            ),
        ];
        for (name, mutate) in cases {
            let mut input = covered_input();
            mutate(&mut input);
            let outcome = assess(&input, &ResearchPolicy::default());
            assert_eq!(
                outcome.trigger.decision,
                ScoutTriggerDecision::Scout,
                "{name}"
            );
            assert_eq!(outcome.trigger.hard_signals.len(), 1, "{name}");
        }
    }

    #[test]
    fn soft_signals_are_deduplicated_before_thresholding() {
        let policy = ResearchPolicy::default();
        let cases = [
            (false, false, ScoutTriggerDecision::NoScout, 0),
            (true, false, ScoutTriggerDecision::Observe, 1),
            (true, true, ScoutTriggerDecision::Scout, 2),
        ];
        for (weak, unfamiliar, expected, count) in cases {
            let mut input = covered_input();
            input.signals.weak_contextual_match = weak;
            input.signals.unfamiliar_domain = unfamiliar;
            let result = assess(&input, &policy);
            assert_eq!(result.trigger.decision, expected);
            assert_eq!(result.trigger.soft_signals.len(), count);
        }

        let mut duplicate = covered_input();
        duplicate.repo_classification.no_match = true;
        duplicate.repo_classification.presets.clear();
        duplicate.repo_classification.conflicts = vec!["preset gap".into()];
        let result = assess(&duplicate, &policy);
        assert_eq!(
            result.trigger.soft_signals,
            vec![ScoutSoftSignal::ClassifierOrPresetGap]
        );
        assert_eq!(result.trigger.decision, ScoutTriggerDecision::Observe);
    }

    #[test]
    fn each_soft_signal_is_one_observation_and_any_independent_pair_scouts() {
        let cases: Vec<(&str, InputMutation)> = vec![
            (
                "classifier or preset gap",
                Box::new(|input| {
                    input.repo_classification.no_match = true;
                    input.repo_classification.presets.clear();
                }),
            ),
            (
                "weak contextual match",
                Box::new(|input| input.signals.weak_contextual_match = true),
            ),
            (
                "unfamiliar domain",
                Box::new(|input| input.signals.unfamiliar_domain = true),
            ),
            (
                "subthreshold typed evidence",
                Box::new(|input| {
                    input.signals.typed_failure_count = 1;
                    input.signals.typed_needs_user_count = 1;
                }),
            ),
        ];

        for (name, mutate) in &cases {
            let mut input = covered_input();
            mutate(&mut input);
            let trigger = assess(&input, &ResearchPolicy::default()).trigger;
            assert_eq!(trigger.decision, ScoutTriggerDecision::Observe, "{name}");
            assert_eq!(trigger.soft_signals.len(), 1, "{name}");
        }

        let mut pair = covered_input();
        cases[0].1(&mut pair);
        cases[3].1(&mut pair);
        let trigger = assess(&pair, &ResearchPolicy::default()).trigger;
        assert_eq!(trigger.decision, ScoutTriggerDecision::Scout);
        assert_eq!(trigger.soft_signals.len(), 2);
    }

    #[test]
    fn human_decision_and_tool_gap_remain_distinct_typed_outcomes() {
        let mut decision = covered_input();
        decision.signals.decision_question = Some("A와 B 중 무엇을 선택할까요?".into());
        decision.signals.material_external_choice_dependency = true;
        let result = assess(&decision, &ResearchPolicy::default());
        assert!(matches!(result.gap, CapabilityGap::NeedsUser { .. }));
        assert!(result
            .trigger
            .hard_signals
            .contains(&ScoutHardSignal::MaterialExternalChoiceDependency));

        let mut tool = covered_input();
        tool.task.required_capabilities = vec!["licensed asset intake".into()];
        let result = assess(&tool, &ResearchPolicy::default());
        assert!(matches!(result.gap, CapabilityGap::ToolOrResource { .. }));
        assert!(result
            .trigger
            .hard_signals
            .contains(&ScoutHardSignal::NoReadyWorkerCapability));
    }

    #[test]
    fn workspace_projection_uses_real_catalog_policy_and_guard_readiness() {
        let root = std::env::temp_dir().join(format!(
            "yard-capability-discovery-live-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let skill = root.join(".agents/skills/local-skill/SKILL.md");
        std::fs::create_dir_all(skill.parent().unwrap()).unwrap();
        std::fs::write(&skill, "local skill").unwrap();
        let workspace = crate::state::Workspace::at(&root);
        let library = crate::skills::Library::open("").unwrap();
        let workers: crate::schemas::WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nworkers:\n  - id: ready\n    capabilities: [shell]\n    invocation: { command: bash }\n  - id: unavailable\n    capabilities: [browser-control]\n    invocation: { command: yardlet-definitely-missing-command }\n",
        )
        .unwrap();
        let task = task(
            "id: LIVE\ntitle: use browser\nskills: [local-skill]\nrequired_capabilities: [browser control]\n",
        );
        let classification = Classification {
            presets: vec!["cli-rust".into()],
            evidence: vec!["Cargo.toml".into()],
            conflicts: vec![],
            no_match: false,
        };

        let billing = crate::schemas::BillingPolicy::default();
        let policy = crate::templates::research_policy();
        // The same real projections the planner composes feed the pure core.
        let worker_readiness = crate::guard::capability_readiness_projection(&workers, &billing);
        let ready_capabilities =
            crate::routing::ready_capabilities_from_projection(&worker_readiness);
        let input = CapabilityDiscoveryInput {
            task,
            skill_catalog: crate::skills::capability_catalog_projection(
                &workspace,
                &library,
                "sandboxed",
                &ready_capabilities,
            ),
            worker_readiness,
            repo_classification: classification,
            signals: CapabilityDiscoverySignals {
                knowledge_freshness: CoverageFreshness::Fresh,
                ..Default::default()
            },
        };
        let result = assess(&input, &policy);

        assert_eq!(result.coverage.status, CoverageStatus::ExternalToolNeeded);
        assert!(matches!(
            result.gap,
            CapabilityGap::ToolOrResource {
                ref missing_capabilities
            } if missing_capabilities == &["browser_control"]
        ));
        assert!(result.coverage.evidence.iter().any(|evidence| {
            evidence.reference == "browser_control"
                && evidence.detail.contains("no guard-ready worker")
        }));
        assert!(result
            .trigger
            .hard_signals
            .contains(&ScoutHardSignal::NoReadyWorkerCapability));
        let _ = std::fs::remove_dir_all(&root);
    }
}
