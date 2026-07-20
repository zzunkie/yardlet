//! Deterministic, provider-free mechanism fixtures for `yardlet eval fixtures`.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;

use crate::schemas::{
    ConversationTurn, FollowUpTask, RunResult, Task, TaskGoal, TaskState, TurnRole, WorkQueue,
};
use crate::state::Workspace;

static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Serialize)]
pub struct FixtureResult {
    pub id: String,
    pub verdict: String,
    pub evidence: Vec<String>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct FixtureReport {
    pub schema_version: u8,
    pub passed: bool,
    pub passed_count: usize,
    pub failed_count: usize,
    pub fixtures: Vec<FixtureResult>,
}

struct FixtureDef {
    id: &'static str,
    run: fn() -> Result<Vec<String>>,
}

const FIXTURES: &[FixtureDef] = &[
    FixtureDef {
        id: "missing-result-blocks-done",
        run: missing_result_blocks_done,
    },
    FixtureDef {
        id: "validation-failure-blocks-done",
        run: validation_failure_blocks_done,
    },
    FixtureDef {
        id: "canonical-state-write-blocks-done",
        run: canonical_state_write_blocks_done,
    },
    FixtureDef {
        id: "needs-user-transcript-persists",
        run: needs_user_transcript_persists,
    },
    FixtureDef {
        id: "follow-up-tasks-ingest-safely",
        run: follow_up_tasks_ingest_safely,
    },
    FixtureDef {
        id: "recovery-finalizes-stranded-run",
        run: recovery_finalizes_stranded_run,
    },
    FixtureDef {
        id: "rubric-sync-preserves-operational-config",
        run: rubric_sync_preserves_operational_config,
    },
    FixtureDef {
        id: "goal-feedback-is-bounded",
        run: goal_feedback_is_bounded,
    },
    FixtureDef {
        id: "review-waits-for-remediation",
        run: review_waits_for_remediation,
    },
    FixtureDef {
        id: "scout-copy-is-read-only",
        run: scout_copy_is_read_only,
    },
    FixtureDef {
        id: "capability-coverage-trigger-matrix",
        run: capability_coverage_trigger_matrix,
    },
    FixtureDef {
        id: "bounded-capability-scout-contract",
        run: bounded_capability_scout_contract,
    },
    FixtureDef {
        id: "watch-until-path-exists",
        run: watch_until_path_exists,
    },
];

pub fn run(selected: &[String]) -> Result<FixtureReport> {
    let defs: Vec<&FixtureDef> = if selected.is_empty() {
        FIXTURES.iter().collect()
    } else {
        for id in selected {
            if !FIXTURES.iter().any(|fixture| fixture.id == id) {
                bail!("unknown fixture '{id}'");
            }
        }
        FIXTURES
            .iter()
            .filter(|fixture| selected.iter().any(|id| id == fixture.id))
            .collect()
    };

    let fixtures: Vec<FixtureResult> = defs
        .into_iter()
        .map(|fixture| {
            let started = Instant::now();
            match (fixture.run)() {
                Ok(evidence) => FixtureResult {
                    id: fixture.id.to_string(),
                    verdict: "pass".to_string(),
                    evidence,
                    duration_ms: elapsed_ms(started),
                },
                Err(error) => FixtureResult {
                    id: fixture.id.to_string(),
                    verdict: "fail".to_string(),
                    evidence: vec![format!("{error:#}")],
                    duration_ms: elapsed_ms(started),
                },
            }
        })
        .collect();
    report(fixtures)
}

fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u64::MAX as u128) as u64
}

fn report(fixtures: Vec<FixtureResult>) -> Result<FixtureReport> {
    if fixtures.is_empty() {
        bail!("no mechanism fixtures selected");
    }
    let passed_count = fixtures.iter().filter(|f| f.verdict == "pass").count();
    let failed_count = fixtures.len() - passed_count;
    Ok(FixtureReport {
        schema_version: 1,
        passed: failed_count == 0,
        passed_count,
        failed_count,
        fixtures,
    })
}

pub fn ensure_passed(report: &FixtureReport) -> Result<()> {
    if report.passed {
        Ok(())
    } else {
        bail!("{} mechanism fixture(s) failed", report.failed_count)
    }
}

pub fn render_human(report: &FixtureReport) -> String {
    let mut out = format!(
        "Mechanism fixtures: {}/{} passed\n",
        report.passed_count,
        report.fixtures.len()
    );
    for fixture in &report.fixtures {
        let mark = if fixture.verdict == "pass" {
            "PASS"
        } else {
            "FAIL"
        };
        out.push_str(&format!(
            "[{mark}] {} ({} ms)\n",
            fixture.id, fixture.duration_ms
        ));
        for evidence in &fixture.evidence {
            out.push_str(&format!("  - {evidence}\n"));
        }
    }
    out
}

struct FixtureWorkspace {
    root: PathBuf,
    ws: Workspace,
}

impl FixtureWorkspace {
    fn new(id: &str) -> Result<Self> {
        let root = loop {
            let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let candidate = std::env::temp_dir().join(format!(
                "yardlet-eval-{}-{sequence}-{id}",
                std::process::id()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => break candidate,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(error).with_context(|| format!("claiming {}", candidate.display()));
                }
            }
        };
        crate::init::init(&root, false)?;
        Ok(Self {
            ws: Workspace::at(&root),
            root,
        })
    }

    fn init_git(&self) -> Result<()> {
        git(&self.root, &["init", "-q"])?;
        git(&self.root, &["config", "user.name", "Yardlet Fixture"])?;
        git(
            &self.root,
            &["config", "user.email", "fixture@example.invalid"],
        )?;
        git(&self.root, &["add", "."])?;
        git(&self.root, &["commit", "-qm", "fixture baseline"])?;
        Ok(())
    }
}

impl Drop for FixtureWorkspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn git(root: &Path, args: &[&str]) -> Result<()> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(anyhow!(String::from_utf8_lossy(&output.stderr)
            .trim()
            .to_string()))
    }
}

fn task(id: &str, state: TaskState, kind: &str) -> Task {
    Task {
        id: id.to_string(),
        title: id.to_string(),
        state,
        priority: 10,
        risk: "low".to_string(),
        kind: kind.to_string(),
        preferred_worker: String::new(),
        model: String::new(),
        fallback_enabled: None,
        effort: String::new(),
        depends_on: Vec::new(),
        skills: Vec::new(),
        required_capabilities: Vec::new(),
        allowed_scope: vec!["src".to_string()],
        acceptance: Vec::new(),
        goal: None,
        validation: None,
        approval: None,
        interaction: None,
        worker_rationale: None,
        provenance: String::new(),
        routing_provenance: None,
    }
}

fn write_result(run_dir: &Path, run_id: &str, task_id: &str, validation: bool) -> Result<()> {
    let value = serde_json::json!({
        "schema_version": 1,
        "run_id": run_id,
        "task_id": task_id,
        "status": "done",
        "validation": {"commands_run": ["fixture"], "passed": validation, "failures": []},
        "compact_summary": "fixture"
    });
    crate::state::write_str(
        &run_dir.join("result.json"),
        &format!("{}\n", serde_json::to_string_pretty(&value)?),
    )?;
    crate::state::write_str(&run_dir.join("handoff.md"), "# Fixture handoff\n")
}

fn missing_result_blocks_done() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("missing-result")?;
    let (run_id, run_dir) = fixture.ws.claim_run_dir("fixture-missing-result")?;
    crate::state::write_str(&run_dir.join("handoff.md"), "# handoff\n")?;
    let evaluation = crate::evaluator::evaluate(
        &run_dir,
        &run_id,
        &task("FIX-001", TaskState::Running, "implementation"),
        Some(&[]),
    );
    if evaluation.next_task_state != TaskState::Failed
        || !evaluation
            .checks
            .iter()
            .any(|c| c.name == "result_file_present" && !c.passed)
    {
        bail!("missing result did not fail the evaluator")
    }
    Ok(vec![
        "result_file_present=false; next_state=failed".to_string()
    ])
}

fn validation_failure_blocks_done() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("validation-failure")?;
    let (run_id, run_dir) = fixture.ws.claim_run_dir("fixture-validation-failure")?;
    write_result(&run_dir, &run_id, "FIX-002", false)?;
    let evaluation = crate::evaluator::evaluate(
        &run_dir,
        &run_id,
        &task("FIX-002", TaskState::Running, "implementation"),
        Some(&[]),
    );
    if evaluation.next_task_state != TaskState::Failed
        || !evaluation
            .checks
            .iter()
            .any(|c| c.name == "reported_validation" && !c.passed)
    {
        bail!("reported validation failure did not block Done")
    }
    Ok(vec![
        "reported_validation=false; next_state=failed".to_string()
    ])
}

fn canonical_state_write_blocks_done() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("canonical-write")?;
    let (run_id, run_dir) = fixture.ws.claim_run_dir("fixture-canonical-write")?;
    write_result(&run_dir, &run_id, "FIX-003", true)?;
    let changed = vec![".agents/work-queue.yaml".to_string()];
    let evaluation = crate::evaluator::evaluate(
        &run_dir,
        &run_id,
        &task("FIX-003", TaskState::Running, "implementation"),
        Some(&changed),
    );
    if evaluation.next_task_state != TaskState::Failed
        || !evaluation
            .checks
            .iter()
            .any(|c| c.name == "forbidden_paths_untouched" && !c.passed)
    {
        bail!("canonical state write did not fail closed")
    }
    Ok(vec![
        "forbidden_paths_untouched=false; next_state=failed".to_string()
    ])
}

fn needs_user_transcript_persists() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("needs-user")?;
    crate::state::append_conversation_turn(
        &fixture.ws,
        "FIX-004",
        ConversationTurn {
            role: TurnRole::Worker,
            text: "Which option?".to_string(),
            run_id: "fixture-run".to_string(),
            ts: String::new(),
        },
    )?;
    crate::state::append_conversation_turn(
        &fixture.ws,
        "FIX-004",
        ConversationTurn {
            role: TurnRole::User,
            text: "Option A".to_string(),
            run_id: String::new(),
            ts: String::new(),
        },
    )?;
    let transcript = fixture.ws.load_conversation("FIX-004");
    if transcript.turns.len() != 2 || transcript.turns[1].text != "Option A" {
        bail!("conversation transcript did not round-trip")
    }
    Ok(vec![format!(
        "{} preserved turn(s) in {}",
        transcript.turns.len(),
        fixture.ws.conversation_path("FIX-004").display()
    )])
}

fn follow_up_tasks_ingest_safely() -> Result<Vec<String>> {
    let mut queue = WorkQueue::empty();
    let follow_up = FollowUpTask {
        title: "Add fixture coverage".to_string(),
        reason: "a deterministic gap was found".to_string(),
        kind: "implementation".to_string(),
        risk: "low".to_string(),
        allowed_scope: vec!["tests".to_string()],
        acceptance: vec!["fixture passes".to_string()],
        ..Default::default()
    };
    let ids = crate::planner::ingest_follow_ups(
        &mut queue,
        &["src".to_string()],
        &[follow_up.clone(), follow_up],
        None,
    );
    let Some(added) = queue.tasks.first() else {
        bail!("follow-up was not ingested")
    };
    if ids != ["YARD-001"] || queue.tasks.len() != 1 || added.provenance != "worker-proposed" {
        bail!("follow-up ids, dedup, or provenance were unsafe")
    }
    Ok(vec![
        "one deduplicated worker-proposed task received a core-owned id".to_string(),
    ])
}

fn recovery_finalizes_stranded_run() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("recovery")?;
    fixture.init_git()?;
    let mut queue = WorkQueue::empty();
    queue.intent_id = "fixture-intent".to_string();
    queue
        .tasks
        .push(task("FIX-006", TaskState::Running, "implementation"));
    fixture.ws.save_queue(&queue)?;
    let (run_id, run_dir) = fixture.ws.claim_run_dir("run-fixture-recovery")?;
    write_result(&run_dir, &run_id, "FIX-006", true)?;
    crate::state::save_yaml(
        &run_dir.join("run.yaml"),
        &crate::run::RunRecord {
            schema_version: 1,
            run_id: run_id.clone(),
            task_id: "FIX-006".to_string(),
            intent_id: "fixture-intent".to_string(),
            worker: "fixture".to_string(),
            state: "running".to_string(),
            started_at: chrono::Local::now().to_rfc3339(),
            completed_at: None,
            worktree: ".".to_string(),
            ..Default::default()
        },
    )?;
    crate::state::write_str(&run_dir.join("worker.pid"), &u32::MAX.to_string())?;
    let messages = crate::run::recover_orphans(&fixture.ws);
    let recovered = fixture.ws.load_queue()?;
    if recovered.tasks[0].state != TaskState::Done {
        bail!(
            "recovery left the stranded task in {:?}",
            recovered.tasks[0].state
        )
    }
    Ok(vec![format!(
        "recovery finalized FIX-006 as done ({})",
        messages.join("; ")
    )])
}

fn rubric_sync_preserves_operational_config() -> Result<Vec<String>> {
    let workspace: crate::schemas::WorkersFile = crate::yaml::from_str(
        r#"
schema_version: 1
workers:
  - id: codex
    best_for: local wording
    model: local-model
    effort: low
    invocation: { command: local-codex, args: [--local] }
    limits: { max_wall_minutes: 99, max_retries: 7 }
  - id: local-only
    invocation: { command: local-worker }
routing:
  default_worker: local-only
  fallback_order: [local-only, codex]
"#,
    )?;
    let template = crate::rubric::template_workers()?;
    let (merged, _) = crate::rubric::merge(&workspace, &template, false);
    let before = serde_json::to_value(&workspace)?;
    let after = serde_json::to_value(&merged)?;
    for pointer in [
        "/workers/0/model",
        "/workers/0/effort",
        "/workers/0/invocation",
        "/workers/0/limits",
        "/routing",
        "/workers/1",
    ] {
        if before.pointer(pointer) != after.pointer(pointer) {
            bail!("rubric sync changed operational field {pointer}")
        }
    }
    Ok(vec![
        "model, effort, invocation, limits, routing, and local worker preserved".to_string(),
    ])
}

fn goal_feedback_is_bounded() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("goal-feedback")?;
    let mut task = task("FIX-008", TaskState::Running, "review");
    task.acceptance = vec![crate::yaml::Value::String("parser tests pass".to_string())];
    task.goal = Some(TaskGoal {
        condition: "all acceptance passes".to_string(),
        max_feedback_cycles: 1,
        feedback_policy: "inject_failed_checks".to_string(),
    });
    let evaluation = crate::evaluator::Evaluation {
        run_id: "feedback-1".to_string(),
        task_id: task.id.clone(),
        status: "partial".to_string(),
        checks: vec![crate::evaluator::fatal_failure(
            "review_criteria_pass",
            "criteria failed: AC-001",
        )],
        next_task_state: TaskState::Partial,
    };
    let result: RunResult = serde_json::from_value(serde_json::json!({
        "schema_version": 1,
        "run_id": "feedback-1",
        "task_id": "FIX-008",
        "status": "partial",
        "compact_summary": "review failed",
        "verdict": [{"criterion_id": "AC-001", "pass": false, "evidence": "parser.rs:42"}]
    }))?;
    let run1 = fixture.ws.runs_dir().join("feedback-1");
    std::fs::create_dir_all(&run1)?;
    let first = crate::run::feedback_for_run(
        &fixture.ws,
        &run1,
        "feedback-1",
        "fixture-intent",
        &task,
        &evaluation,
        Some(&result),
    )
    .context("first feedback cycle")?;
    crate::state::write_str(&run1.join("feedback.json"), &serde_json::to_string(&first)?)?;
    let run2 = fixture.ws.runs_dir().join("feedback-2");
    std::fs::create_dir_all(&run2)?;
    let second = crate::run::feedback_for_run(
        &fixture.ws,
        &run2,
        "feedback-2",
        "fixture-intent",
        &task,
        &evaluation,
        Some(&result),
    )
    .context("second feedback cycle")?;
    if crate::run::feedback_next_state(&first) != TaskState::Partial
        || crate::run::feedback_next_state(&second) != TaskState::NeedsUser
        || second
            .question_for_user
            .as_deref()
            .map(str::trim)
            .is_none_or(|question| question.is_empty())
        || !second
            .unmet_acceptance
            .iter()
            .any(|v| v.contains("parser.rs:42"))
    {
        bail!("goal feedback did not retry once then stop with exact evidence")
    }
    Ok(vec![
        "cycle 1 retries; cycle 2 reaches needs_user with AC evidence and an actionable question"
            .to_string(),
    ])
}

fn review_waits_for_remediation() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("review-remediation-order")?;
    let mut review = task("FIX-REVIEW", TaskState::Failed, "review");
    review.priority = 10;
    let mut remediation = task("FIX-REMEDIATION", TaskState::Queued, "implementation");
    remediation.priority = 20;
    remediation.approval = Some(crate::yaml::from_str("required: true")?);
    let mut unrelated = task("FIX-QUESTION", TaskState::NeedsUser, "implementation");
    unrelated.priority = 1;
    let mut queue = WorkQueue::empty();
    queue.intent_id = "fixture-intent".to_string();
    queue.tasks = vec![review, remediation, unrelated];
    fixture.ws.save_queue(&queue)?;

    crate::run::requeue_review(
        &fixture.ws,
        &mut queue,
        "FIX-REVIEW",
        TaskState::Queued,
        &["FIX-REMEDIATION".to_string()],
    )?;
    let caps = std::collections::BTreeSet::new();
    let queued = fixture.ws.load_queue()?;
    if crate::run::select_next_ready(&queued, &caps, |_| false)?.is_some()
        || !crate::parallel::ready_independent(&queued, 4).is_empty()
    {
        bail!("review escaped while linked remediation awaited approval")
    }
    let approved = crate::run::select_next_ready(&queued, &caps, |id| id == "FIX-REMEDIATION")?;
    if approved != Some(1) {
        bail!("approval did not select remediation first: {approved:?}")
    }

    let mut running = queued;
    running.tasks[1].state = TaskState::Running;
    fixture.ws.save_queue(&running)?;
    if crate::run::select_next_ready(&running, &caps, |_| false)?.is_some()
        || !crate::parallel::ready_independent(&running, 4).is_empty()
    {
        bail!("review escaped while remediation was running")
    }

    crate::state::write_str(
        &fixture.root.join("remediation-observed.txt"),
        "remediation complete\n",
    )?;
    running.tasks[1].state = TaskState::Done;
    fixture.ws.save_queue(&running)?;
    let serial = crate::run::select_next_ready(&running, &caps, |_| false)?;
    let parallel = crate::parallel::ready_independent(&running, 4);
    if serial != Some(0) || parallel != [0] || running.tasks[2].state != TaskState::NeedsUser {
        bail!(
            "terminal remediation or unrelated NeedsUser did not release review: serial={serial:?}, parallel={parallel:?}"
        )
    }

    Ok(vec![
        "approval-pending and running remediation held sequential review".to_string(),
        "review and remediation never shared a parallel batch".to_string(),
        "remediation completion released review despite unrelated needs_user".to_string(),
    ])
}

fn scout_copy_is_read_only() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("scout-copy")?;
    let source = fixture.root.join("source");
    let target = fixture.root.join("scout-copy");
    crate::init::init(&source, false)?;
    crate::state::write_str(&source.join("project.txt"), "live\n")?;
    std::fs::create_dir_all(source.join(".agents/runs/old"))?;
    crate::state::write_str(&source.join(".agents/runs/old/result.json"), "{}\n")?;
    crate::memory::copy_scout_workspace_for_fixture(&source, &target)?;
    crate::state::write_str(&target.join("project.txt"), "scout edit\n")?;
    if std::fs::read_to_string(source.join("project.txt"))? != "live\n"
        || target.join(".agents/runs").exists()
    {
        bail!("scout copy mutated or exposed runtime state")
    }
    Ok(vec![
        "isolated copy mutation left source unchanged and omitted runtime artifacts".to_string(),
    ])
}

fn watch_until_path_exists() -> Result<Vec<String>> {
    let fixture = FixtureWorkspace::new("watch-until")?;
    crate::state::write_str(&fixture.root.join("ready.flag"), "ready\n")?;
    let (status, observations, reason) =
        crate::watch::evaluate_path_exists_for_fixture(&fixture.root, PathBuf::from("ready.flag"));
    if status != "satisfied" || observations.len() != 1 || !observations[0].condition_met {
        bail!("watch did not satisfy the existing path condition")
    }
    Ok(vec![format!("{status} after one observation: {reason}")])
}

fn capability_input() -> crate::capability_discovery::CapabilityDiscoveryInput {
    crate::capability_discovery::CapabilityDiscoveryInput {
        task: Task {
            skills: vec!["planning-gate".to_string()],
            required_capabilities: vec!["shell".to_string()],
            ..task("CAP-001", TaskState::Queued, "implementation")
        },
        skill_catalog: crate::skills::SkillCatalogProjection {
            workspace: vec!["planning-gate".to_string()],
            user_library: Vec::new(),
        },
        worker_readiness: vec![crate::guard::WorkerCapabilityReadiness {
            worker_id: "fixture-worker".to_string(),
            readiness: crate::guard::Readiness::Ready,
            capabilities: vec!["shell".to_string()],
        }],
        repo_classification: crate::skills::Classification {
            presets: vec!["cli-rust".to_string()],
            evidence: vec!["Cargo.toml".to_string()],
            conflicts: Vec::new(),
            no_match: false,
        },
        signals: crate::capability_discovery::CapabilityDiscoverySignals {
            knowledge_freshness: crate::schemas::CoverageFreshness::Fresh,
            ..Default::default()
        },
    }
}

fn capability_coverage_trigger_matrix() -> Result<Vec<String>> {
    use crate::schemas::{ScoutHardSignal, ScoutSoftSignal, ScoutTriggerDecision};

    let policy = crate::schemas::ResearchPolicy::default();
    type Mutation = fn(&mut crate::capability_discovery::CapabilityDiscoveryInput);
    let hard_cases: [(&str, ScoutHardSignal, Mutation); 7] = [
        (
            "explicit_research_request",
            ScoutHardSignal::ExplicitResearchRequest,
            |input| input.signals.explicit_research_request = true,
        ),
        (
            "selected_skill_missing",
            ScoutHardSignal::SelectedSkillMissing,
            |input| input.task.skills = vec!["absent-skill".to_string()],
        ),
        (
            "no_ready_worker_capability",
            ScoutHardSignal::NoReadyWorkerCapability,
            |input| input.task.required_capabilities = vec!["quantum-probe".to_string()],
        ),
        (
            "only_unusable_skill_matches",
            ScoutHardSignal::OnlyUnusableSkillMatches,
            |input| input.signals.only_unusable_skill_matches = true,
        ),
        (
            "current_external_fact_dependency",
            ScoutHardSignal::CurrentExternalFactDependency,
            |input| input.signals.current_external_fact_dependency = true,
        ),
        (
            "material_external_choice_dependency",
            ScoutHardSignal::MaterialExternalChoiceDependency,
            |input| input.signals.material_external_choice_dependency = true,
        ),
        (
            "repeated_typed_failure",
            ScoutHardSignal::RepeatedTypedFailure,
            |input| input.signals.typed_failure_count = 2,
        ),
    ];
    for (name, expected, mutate) in hard_cases {
        let mut input = capability_input();
        mutate(&mut input);
        let outcome = crate::capability_discovery::assess(&input, &policy);
        if outcome.trigger.decision != ScoutTriggerDecision::Scout
            || outcome.trigger.hard_signals != vec![expected]
        {
            bail!(
                "hard signal {name} diverged: decision={:?}, signals={:?}",
                outcome.trigger.decision,
                outcome.trigger.hard_signals
            );
        }
    }

    let zero = capability_input();
    let zero = crate::capability_discovery::assess(&zero, &policy);
    if zero.trigger.decision != ScoutTriggerDecision::NoScout
        || !zero.trigger.soft_signals.is_empty()
    {
        bail!("zero-soft boundary diverged: {:?}", zero.trigger);
    }

    let mut one = capability_input();
    one.signals.weak_contextual_match = true;
    let one = crate::capability_discovery::assess(&one, &policy);
    if one.trigger.decision != ScoutTriggerDecision::Observe
        || one.trigger.soft_signals != vec![ScoutSoftSignal::WeakContextualMatch]
    {
        bail!("one-soft boundary diverged: {:?}", one.trigger);
    }

    let mut two = capability_input();
    two.signals.weak_contextual_match = true;
    two.signals.unfamiliar_domain = true;
    let two = crate::capability_discovery::assess(&two, &policy);
    if two.trigger.decision != ScoutTriggerDecision::Scout
        || two.trigger.soft_signals
            != vec![
                ScoutSoftSignal::WeakContextualMatch,
                ScoutSoftSignal::UnfamiliarDomain,
            ]
    {
        bail!("two-soft boundary diverged: {:?}", two.trigger);
    }

    // Multiple observations of one category remain one independent signal.
    let mut dedup = capability_input();
    dedup.repo_classification.no_match = true;
    dedup.repo_classification.presets.clear();
    dedup.repo_classification.conflicts = vec!["a".to_string(), "b".to_string()];
    let dedup = crate::capability_discovery::assess(&dedup, &policy);
    if dedup.trigger.decision != ScoutTriggerDecision::Observe
        || dedup.trigger.soft_signals != vec![ScoutSoftSignal::ClassifierOrPresetGap]
    {
        bail!("soft category dedup diverged: {:?}", dedup.trigger);
    }

    Ok(vec![
        "7/7 hard signals independently produced scout".to_string(),
        "soft boundaries were 0=no_scout, 1=observe, 2=scout".to_string(),
        "repeated observations of one soft category deduplicated before thresholding".to_string(),
    ])
}

fn bounded_capability_scout_contract() -> Result<Vec<String>> {
    use crate::schemas::{ResearchSource, ScoutDisposition};

    let policy = crate::schemas::ResearchPolicy::default();
    let topics = vec![
        "alpha topic".to_string(),
        " alpha   topic ".to_string(),
        "beta topic".to_string(),
        "gamma topic".to_string(),
        "delta topic".to_string(),
    ];
    let packet = crate::packet::compile_scout(&crate::packet::ScoutPacketInputs {
        intent_id: "intent-fixture",
        request_digest: "digest-fixture",
        topics: &topics,
        policy: &policy,
        workspace_skills: &["planning-gate".to_string()],
        user_library_skills: &["user-candidate".to_string()],
        run_dir_rel: ".agents/runs/scout-fixture",
    })?;
    if packet.matches("- alpha topic\n").count() != 1
        || !packet.contains("- beta topic\n")
        || !packet.contains("- gamma topic\n")
        || packet.contains("- delta topic\n")
        || !packet.contains("maximum research cycles: 1")
        || !packet.contains("maximum topics this cycle: 3")
        || !packet
            .contains("workspace_skill_catalog -> user_skill_library -> external_primary_source")
        || packet.contains("work-queue.yaml")
    {
        bail!("compiled scout packet violated dedup, budget, order, or queue isolation");
    }

    let raw = r#"{
      "schema_version": 1,
      "intent_id": "intent-fixture",
      "request_digest": "digest-fixture",
      "cycle": 1,
      "results": [{
        "topic": "alpha topic",
        "sources_consulted": ["workspace_skill_catalog", "user_skill_library", "external_primary_source"],
        "disposition": "adapt_external_skill_candidate",
        "candidate": {
          "source": "https://example.invalid/original",
          "revision": "rev-1",
          "license": "",
          "freshness": "2026-07-21",
          "maintenance": "active",
          "included_files": ["SKILL.md"],
          "static_risk": "low",
          "authority_requirements": ["network"]
        },
        "gap": {"kind": "no_gap"}
      }]
    }"#;
    let normalized = crate::packet::normalize_scout_output(
        raw,
        "intent-fixture",
        "digest-fixture",
        &["alpha topic".to_string()],
        &policy,
    )?;
    if normalized.len() != 1
        || normalized[0].disposition != ScoutDisposition::ReportNoChange
        || normalized[0].candidate.is_some()
    {
        bail!("incomplete external authority did not fail closed");
    }

    let reversed = raw.replace(
        "\"workspace_skill_catalog\", \"user_skill_library\"",
        "\"user_skill_library\", \"workspace_skill_catalog\"",
    );
    if crate::packet::normalize_scout_output(
        &reversed,
        "intent-fixture",
        "digest-fixture",
        &["alpha topic".to_string()],
        &policy,
    )
    .is_ok()
    {
        bail!("reordered sources were accepted");
    }
    if crate::packet::normalize_scout_output(
        raw,
        "other-intent",
        "digest-fixture",
        &["alpha topic".to_string()],
        &policy,
    )
    .is_ok()
    {
        bail!("intent mismatch was accepted");
    }
    if normalized[0].sources_consulted
        != vec![
            ResearchSource::WorkspaceSkillCatalog,
            ResearchSource::UserSkillLibrary,
            ResearchSource::ExternalPrimarySource,
        ]
    {
        bail!("normalized source evidence changed order");
    }

    Ok(vec![
        "packet enforced 1 cycle, 3 unique topics, and local-first source order".to_string(),
        "intent mismatch and reordered sources were rejected".to_string(),
        "incomplete external authority normalized to report_no_change without a candidate"
            .to_string(),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_ids_are_unique_and_full_suite_passes_twice() {
        let mut ids: Vec<_> = FIXTURES.iter().map(|f| f.id).collect();
        let count = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), count);

        let first = run(&[]).unwrap();
        let second = run(&[]).unwrap();
        assert!(first.passed, "{}", render_human(&first));
        assert!(second.passed, "{}", render_human(&second));
    }

    #[test]
    fn failed_fixture_cannot_be_hidden_by_passing_siblings() {
        let report = report(vec![
            FixtureResult {
                id: "passing".into(),
                verdict: "pass".into(),
                evidence: vec![],
                duration_ms: 1,
            },
            FixtureResult {
                id: "intentional-failure".into(),
                verdict: "fail".into(),
                evidence: vec!["injected".into()],
                duration_ms: 1,
            },
        ])
        .unwrap();
        assert!(!report.passed);
        assert_eq!(report.failed_count, 1);
        assert!(ensure_passed(&report).is_err());
    }

    #[test]
    fn human_and_json_renderers_share_the_same_report() {
        let report = run(&["watch-until-path-exists".to_string()]).unwrap();
        let human = render_human(&report);
        let json = serde_json::to_string(&report).unwrap();
        assert!(human.contains("[PASS] watch-until-path-exists"));
        assert!(json.contains("\"verdict\":\"pass\""));
        assert_eq!(report.passed_count, 1);
    }
}
