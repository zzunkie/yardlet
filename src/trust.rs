//! Trust report: a deterministic read over run telemetry that answers "how much
//! can I trust a Done here?" — first-pass success vs. Done-after-retry, per-worker
//! reliability, and the distrust signals (no-result runs, user overrides, tasks
//! that never reached Done). Like routing review (policy vs mechanism) it only
//! REPORTS; it never edits policy. Pure aggregation, so it is unit-tested without
//! touching disk.

use std::collections::BTreeMap;

use anyhow::Result;
use serde::Serialize;

use crate::schemas::{
    TaskState, TransitionActor, TransitionCause, TransitionLog, TransitionRecord,
};
use crate::state::Workspace;
use crate::telemetry::{self, RunTelemetry};

fn rate(num: usize, den: usize) -> f64 {
    if den == 0 {
        0.0
    } else {
        num as f64 / den as f64
    }
}

fn is_done(state: &str) -> bool {
    state.eq_ignore_ascii_case("done")
}

fn telemetry_done(run: &RunTelemetry) -> bool {
    is_done(&run.eval_state)
        && matches!(
            run.git_finish_status.as_str(),
            "" | "disabled" | "pushed" | "already_applied"
        )
}

/// Per-worker reliability over its runs.
#[derive(Default, Clone)]
pub struct WorkerTrust {
    pub runs: usize,
    pub done: usize,
    pub partial: usize,
    pub failed: usize,
    /// Runs the worker finished without writing a parseable result.
    pub no_result: usize,
    /// Runs a human had to redirect (telemetry `user_override` present).
    pub overrides: usize,
    pub wall_seconds: u64,
}

impl WorkerTrust {
    pub fn done_rate(&self) -> f64 {
        rate(self.done, self.runs)
    }
}

/// Per-task outcome across however many run attempts it took.
#[derive(Default, Clone)]
pub struct TaskTrust {
    pub attempts: usize,
    /// Some attempt reached Done.
    pub reached_done: bool,
    /// The very first attempt was already Done (no retry needed).
    pub first_pass: bool,
    pub wall_seconds: u64,
    /// State of the most recent attempt (for tasks that never reached Done).
    pub last_state: String,
    /// Workers that ran this task, in first-seen order.
    pub workers: Vec<String>,
}

pub struct TrustReport {
    pub total_runs: usize,
    pub tasks: BTreeMap<String, TaskTrust>,
    pub workers: BTreeMap<String, WorkerTrust>,
    pub total_wall_seconds: u64,
}

impl TrustReport {
    pub fn task_count(&self) -> usize {
        self.tasks.len()
    }
    /// Tasks that reached Done on their first attempt.
    pub fn first_pass_done(&self) -> usize {
        self.tasks.values().filter(|t| t.first_pass).count()
    }
    /// Tasks that reached Done but only after more than one attempt.
    pub fn retried_done(&self) -> usize {
        self.tasks
            .values()
            .filter(|t| t.reached_done && !t.first_pass)
            .count()
    }
    /// Tasks with no Done attempt in telemetry (may have been resolved by other
    /// means; telemetry is per-run, not the queue's last word).
    pub fn unresolved(&self) -> usize {
        self.tasks.values().filter(|t| !t.reached_done).count()
    }
}

/// Fold telemetry (append-order = chronological) into per-task and per-worker
/// trust. Records are read oldest-first so the first record for a task id is its
/// first attempt.
pub fn summarize(runs: &[RunTelemetry]) -> TrustReport {
    let mut tasks: BTreeMap<String, TaskTrust> = BTreeMap::new();
    let mut workers: BTreeMap<String, WorkerTrust> = BTreeMap::new();
    let mut total_wall_seconds = 0u64;

    for r in runs {
        total_wall_seconds += r.wall_seconds;

        let t = tasks.entry(r.task_id.clone()).or_default();
        let first_attempt = t.attempts == 0;
        t.attempts += 1;
        t.wall_seconds += r.wall_seconds;
        t.last_state = r.eval_state.clone();
        if !r.worker.is_empty() && !t.workers.iter().any(|w| w == &r.worker) {
            t.workers.push(r.worker.clone());
        }
        if telemetry_done(r) {
            if first_attempt {
                t.first_pass = true;
            }
            t.reached_done = true;
        }

        if !r.worker.is_empty() {
            let w = workers.entry(r.worker.clone()).or_default();
            w.runs += 1;
            w.wall_seconds += r.wall_seconds;
            if telemetry_done(r) {
                w.done += 1;
            } else if r.eval_state.eq_ignore_ascii_case("partial") {
                w.partial += 1;
            } else if r.eval_state.eq_ignore_ascii_case("failed") {
                w.failed += 1;
            }
            if r.result_status == "no-result" {
                w.no_result += 1;
            }
            if r.user_override.is_some() {
                w.overrides += 1;
            }
        }
    }

    TrustReport {
        total_runs: runs.len(),
        tasks,
        workers,
        total_wall_seconds,
    }
}

fn humanize(secs: u64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    if h > 0 {
        format!("{h}h{m:02}m")
    } else {
        format!("{m}m{:02}s", secs % 60)
    }
}

/// Render a trust report as a compact, deterministic text block. `intent` is the
/// intent the report is scoped to (when the active intent's runs were isolated);
/// `None` means the cumulative-across-intents view.
pub fn render(report: &TrustReport, intent: Option<&str>) -> String {
    let mut s = String::new();
    let tasks = report.task_count();
    match intent {
        Some(id) => s.push_str(&format!(
            "Trust report — intent {} — {} runs across {} tasks, {} total worker wall\n",
            id,
            report.total_runs,
            tasks,
            humanize(report.total_wall_seconds),
        )),
        None => s.push_str(&format!(
            "Trust report — {} runs across {} tasks, {} total worker wall\n",
            report.total_runs,
            tasks,
            humanize(report.total_wall_seconds),
        )),
    }
    s.push_str(&format!(
        "  first-pass Done:    {}/{} ({:.0}%)\n",
        report.first_pass_done(),
        tasks,
        rate(report.first_pass_done(), tasks) * 100.0,
    ));
    s.push_str(&format!(
        "  Done after retry:   {}/{}\n",
        report.retried_done(),
        tasks,
    ));
    s.push_str(&format!(
        "  no Done in record:  {}/{}\n",
        report.unresolved(),
        tasks,
    ));

    s.push_str("\nBy worker:\n");
    for (worker, w) in &report.workers {
        s.push_str(&format!(
            "  {:<14} {:>3} runs  done {:>3.0}%  (P:{} F:{} no-result:{})  wall {}  overrides {}\n",
            worker,
            w.runs,
            w.done_rate() * 100.0,
            w.partial,
            w.failed,
            w.no_result,
            humanize(w.wall_seconds),
            w.overrides,
        ));
    }

    // Tasks that took more than one attempt — the trust signal worth eyeballing.
    let mut retried: Vec<(&String, &TaskTrust)> = report
        .tasks
        .iter()
        .filter(|(_, t)| t.attempts > 1)
        .collect();
    // Most attempts first; ties by task id for determinism.
    retried.sort_by(|a, b| b.1.attempts.cmp(&a.1.attempts).then(a.0.cmp(b.0)));
    if !retried.is_empty() {
        s.push_str("\nNeeded multiple attempts:\n");
        for (id, t) in retried {
            let outcome = if t.reached_done {
                "done".to_string()
            } else {
                format!("still {}", t.last_state.to_lowercase())
            };
            s.push_str(&format!(
                "  {:<10} {} attempts \u{2192} {}  ({})\n",
                id,
                t.attempts,
                outcome,
                t.workers.join(", "),
            ));
        }
        // The cumulative view spans intents, so a task id reused across intents
        // folds its attempts together. Only warn when that can actually happen —
        // an intent-scoped report has no folding.
        if intent.is_none() {
            s.push_str(
                "\n  (cumulative across intents; a task id reused across intents folds together)\n",
            );
        }
    }

    s
}

/// Pick the runs to report on: prefer the active intent's runs (so a task id
/// reused across intents does not fold together), falling back to the cumulative
/// view when no telemetry carries the active intent yet (e.g. records written
/// before `intent_id` existed). Returns the slice and whether it is intent-scoped.
fn scope_runs(runs: &[RunTelemetry], active: Option<&str>) -> (Vec<RunTelemetry>, bool) {
    if let Some(id) = active.filter(|s| !s.is_empty()) {
        let scoped: Vec<RunTelemetry> =
            runs.iter().filter(|r| r.intent_id == id).cloned().collect();
        if !scoped.is_empty() {
            return (scoped, true);
        }
    }
    (runs.to_vec(), false)
}

/// Read this workspace's telemetry and render its trust report.
pub fn report(ws: &Workspace) -> Result<String> {
    let runs = telemetry::read_runs(ws);
    if runs.is_empty() {
        return Ok("No run telemetry yet. The trust report fills in as runs accrue.\n".to_string());
    }
    let active = ws.load_queue().ok().map(|q| q.intent_id);
    let (slice, scoped) = scope_runs(&runs, active.as_deref());
    let label = scoped.then_some(active.as_deref()).flatten();
    Ok(render(&summarize(&slice), label))
}

// ---- outcome mining (v0.8 Slice 6) -----------------------------------------
//
// Turn deterministic run outcomes into human-applicable harness signals. This
// is distinct from routing review (which suggests worker *selection*) and the
// trust dashboard (raw stats): it crosses a threshold and names a concrete
// harness action to consider. Like everything telemetry-driven it only
// SUGGESTS — a human applies the rule/skill/scope change.

/// One mined, threshold-crossing observation with a suggested harness action.
#[derive(Debug, Clone)]
pub struct MinedObservation {
    pub detail: String,
    pub suggestion: String,
}

const MIN_WORKER_RUNS: usize = 6;
const NO_RESULT_FLOOR: f64 = 0.10;
const MIN_KIND_TASKS: usize = 3;
const RETRY_AVG_FLOOR: f64 = 2.5;

/// Mine telemetry for recurring problem patterns worth a harness change.
pub fn mine(runs: &[RunTelemetry]) -> Vec<MinedObservation> {
    let report = summarize(runs);
    let mut out = Vec::new();

    // 1. No-result hotspots: a worker that often finished without a parseable
    //    result is a packet/output-contract problem (each one wastes a full
    //    attempt) — not a routing one.
    for (worker, w) in &report.workers {
        if w.runs < MIN_WORKER_RUNS {
            continue;
        }
        let rate = w.no_result as f64 / w.runs as f64;
        if rate >= NO_RESULT_FLOOR {
            out.push(MinedObservation {
                detail: format!(
                    "{worker}: {}/{} runs produced no parseable result ({:.0}%)",
                    w.no_result,
                    w.runs,
                    rate * 100.0
                ),
                suggestion:
                    "check this worker's packet/output contract or model — no-result runs burn a \
                     whole attempt"
                        .to_string(),
            });
        }
    }

    // 2. High-retry kinds: a task kind that rarely lands first-pass is
    //    consistently hard — a skill or sharper acceptance may help. Averaged
    //    over tasks that DID reach Done, so it measures effort, not failure.
    let mut task_kind: BTreeMap<String, String> = BTreeMap::new();
    for r in runs {
        if !r.kind.is_empty() {
            task_kind
                .entry(r.task_id.clone())
                .or_insert_with(|| r.kind.clone());
        }
    }
    let mut kind_stats: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for (id, t) in &report.tasks {
        if !t.reached_done {
            continue;
        }
        if let Some(k) = task_kind.get(id) {
            let e = kind_stats.entry(k.clone()).or_default();
            e.0 += t.attempts;
            e.1 += 1;
        }
    }
    for (kind, (sum, n)) in &kind_stats {
        if *n < MIN_KIND_TASKS {
            continue;
        }
        let avg = *sum as f64 / *n as f64;
        if avg >= RETRY_AVG_FLOOR {
            out.push(MinedObservation {
                detail: format!(
                    "kind '{kind}': {n} tasks averaged {avg:.1} attempts to reach Done"
                ),
                suggestion:
                    "consider a skill or sharper acceptance for this kind — it rarely lands \
                     first-pass"
                        .to_string(),
            });
        }
    }

    out
}

// ==== Trust Report v2: autonomy from the state-transition audit log ==========
//
// v1 (above) folds run *attempts* from telemetry. v2 folds the task *state
// machine* recorded in `.agents/transitions/` — the only record where a Done
// that was later reopened (false-done) or a human DECISION/CHORE touch is
// visible — and cross-checks the same run telemetry. Like v1 it only REPORTS;
// it never edits policy or state. Pure over its inputs, so it is unit-tested
// without touching disk. Every number traces to a specific recorded transition
// or run (see `AutonomyReport::sources`), never a hand-tally.

/// How trustworthy a task's Done is, judged from its recorded history. This is
/// the "can I trust a Done?" split.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DoneTrust {
    /// Reached Done on a clean path and stayed there — no wrong turn first,
    /// never reopened. The Done is evidence-backed.
    EvidenceBacked,
    /// Reached Done, but only after a wrong turn (Failed/Partial/Blocked) — the
    /// loop went wrong then recovered. The Done is real; it cost a correction.
    RecoveredAfterWrong,
    /// Marked Done, then transitioned back OUT of Done — a premature Done caught
    /// and reopened. The worst trust signal (transition-only: telemetry attempts
    /// never un-Done).
    FalseDoneCaught,
    /// No Done in the record yet.
    Unresolved,
}

/// A human intervention is either a DECISION the loop legitimately owed the
/// human, or a CHORE — mechanical un-sticking the loop should absorb itself.
/// Driving the chore share to zero is the visible autonomy goal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TouchKind {
    Decision,
    Chore,
}

/// Classify a human-touch transition by its cause. `Defer` (a deliberate "set
/// this aside") and `DecisionSeed` (a real question the loop routed to the
/// human) are decisions the loop rightly owed. Everything else a human had to
/// do — `Revive` (un-park a stalled task), `Recover` (salvage an abandoned
/// run) — is mechanical toil the self-healing loop should have handled.
pub fn classify_touch(cause: TransitionCause) -> TouchKind {
    match cause {
        TransitionCause::Defer | TransitionCause::DecisionSeed => TouchKind::Decision,
        _ => TouchKind::Chore,
    }
}

/// Is this transition a human intervention we count? A `User`-actor move (a
/// hand defer/revive/recover) or a seeded decision the loop owed the human.
/// System/Worker moves under the auto-drain are the loop doing its job, not an
/// intervention.
fn is_human_touch(rec: &TransitionRecord) -> bool {
    matches!(rec.actor, TransitionActor::User) || rec.cause == TransitionCause::DecisionSeed
}

/// A wrong turn: a state a trustworthy Done should not have passed through.
fn is_wrong_state(s: TaskState) -> bool {
    matches!(
        s,
        TaskState::Failed | TaskState::Partial | TaskState::Blocked
    )
}

/// Classify a single task's Done-trust from its transition timeline alone
/// (records are append-order = chronological). Used for tasks that have a
/// transition log; telemetry-only tasks fall back to the attempt heuristic.
pub fn classify_transitions(records: &[TransitionRecord]) -> DoneTrust {
    let mut reached_done = false;
    let mut wrong_before_done = false;
    let mut seen_wrong = false;
    let mut false_done = false;
    for rec in records {
        if rec.from == TaskState::Done && rec.to != TaskState::Done {
            false_done = true;
        }
        match rec.to {
            TaskState::Done => {
                if seen_wrong && !reached_done {
                    wrong_before_done = true;
                }
                reached_done = true;
            }
            s if is_wrong_state(s) => seen_wrong = true,
            _ => {}
        }
    }
    if false_done {
        DoneTrust::FalseDoneCaught
    } else if reached_done && wrong_before_done {
        DoneTrust::RecoveredAfterWrong
    } else if reached_done {
        DoneTrust::EvidenceBacked
    } else {
        DoneTrust::Unresolved
    }
}

/// Per-intent human-touch split. The chore share is the headline the goal
/// drives to zero.
#[derive(Debug, Clone, Default, Serialize)]
pub struct IntentTouch {
    pub decisions: usize,
    pub chores: usize,
}

impl IntentTouch {
    pub fn total(&self) -> usize {
        self.decisions + self.chores
    }
    pub fn chore_ratio(&self) -> f64 {
        rate(self.chores, self.total())
    }
}

/// The v2 autonomy + trust report. Every field is a count folded from recorded
/// transitions and/or runs — never a manual aggregate.
#[derive(Debug, Clone, Default)]
pub struct AutonomyReport {
    // ---- "Can I trust a Done?" — per (intent, task) instance -------------
    pub evidence_backed: usize,
    pub recovered: usize,
    pub false_done_caught: usize,
    pub unresolved: usize,
    pub task_instances: usize,
    /// Task ids flagged with a Done -> non-Done reversal (traceable list).
    pub false_done_tasks: Vec<String>,

    // ---- Human interventions — decision vs chore -------------------------
    pub decisions: usize,
    pub chores: usize,
    pub per_intent: BTreeMap<String, IntentTouch>,

    // ---- Unnecessary loop stops (waste) ----------------------------------
    /// Every transition INTO NeedsUser (the loop halted for a human).
    pub loop_stops: usize,
    /// Stops that were a genuine seeded decision the loop owed (good stops).
    pub decision_stops: usize,
    /// Stops for approval/pause friction, not a real question — reducible waste.
    pub wasted_stops: usize,

    // ---- Provenance (each number is backed by this many records) ---------
    pub transitions_read: usize,
    pub runs_read: usize,
}

impl AutonomyReport {
    /// Task instances that ever reached Done (the denominator for "of the Dones,
    /// how many were clean?").
    pub fn done_reached(&self) -> usize {
        self.evidence_backed + self.recovered + self.false_done_caught
    }
    /// Evidence-backed Dones as a share of all Dones — the trustworthy-Done rate.
    pub fn trustworthy_done_rate(&self) -> f64 {
        rate(self.evidence_backed, self.done_reached())
    }
    pub fn human_touches(&self) -> usize {
        self.decisions + self.chores
    }
    /// Chore share of all human touches — the number the autonomy goal drives to
    /// zero. 0.0 when there were no touches (nothing to reduce).
    pub fn chore_ratio(&self) -> f64 {
        rate(self.chores, self.human_touches())
    }

    /// Machine-readable projection for `yardlet trust --json`. Nested so a reader
    /// can map each number back to its source (transitions vs runs).
    pub fn to_json(&self) -> serde_json::Value {
        let per_intent: serde_json::Map<String, serde_json::Value> = self
            .per_intent
            .iter()
            .map(|(id, t)| {
                (
                    id.clone(),
                    serde_json::json!({
                        "decisions": t.decisions,
                        "chores": t.chores,
                        "chore_ratio": round2(t.chore_ratio()),
                    }),
                )
            })
            .collect();
        serde_json::json!({
            "done_trust": {
                "evidence_backed": self.evidence_backed,
                "recovered": self.recovered,
                "false_done_caught": self.false_done_caught,
                "unresolved": self.unresolved,
                "task_instances": self.task_instances,
                "trustworthy_done_rate": round2(self.trustworthy_done_rate()),
                "false_done_tasks": self.false_done_tasks,
            },
            "human_touches": {
                "decisions": self.decisions,
                "chores": self.chores,
                "total": self.human_touches(),
                "chore_ratio": round2(self.chore_ratio()),
                "per_intent": per_intent,
            },
            "loop_stops": {
                "total": self.loop_stops,
                "owed_decisions": self.decision_stops,
                "wasted": self.wasted_stops,
            },
            "sources": {
                "transitions_read": self.transitions_read,
                "runs_read": self.runs_read,
            },
        })
    }
}

fn round2(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

/// A telemetry instance keyed by (intent, task): reused task ids across intents
/// do not fold. Ordered by first-seen so `first_ts`/`last_ts` bound its window.
#[derive(Default)]
struct Instance {
    task: String,
    attempts: usize,
    reached_done: bool,
    first_pass: bool,
    first_ts: String,
}

/// Fold run telemetry + transition logs into the v2 autonomy report. Pure over
/// its inputs. Done-trust is keyed per (intent, task) from telemetry (so reused
/// ids stay separate) with false-done overlaid from transition reversals;
/// task ids that appear only in transitions are classified from the log alone.
pub fn autonomy(runs: &[RunTelemetry], logs: &[TransitionLog]) -> AutonomyReport {
    let mut rep = AutonomyReport {
        runs_read: runs.len(),
        transitions_read: logs.iter().map(|l| l.records.len()).sum(),
        ..Default::default()
    };

    // task_id -> latest intent seen in telemetry. Legacy transition records
    // carry no intent, so those fall back to the intent that last ran the task.
    let mut task_intent: BTreeMap<String, String> = BTreeMap::new();
    for r in runs {
        if !r.intent_id.is_empty() {
            task_intent.insert(r.task_id.clone(), r.intent_id.clone());
        }
    }

    // ---- Done trust: build per (intent, task) instances from telemetry ----
    let mut order: Vec<(String, String)> = Vec::new();
    let mut insts: BTreeMap<(String, String), Instance> = BTreeMap::new();
    for r in runs {
        let key = (r.intent_id.clone(), r.task_id.clone());
        let inst = insts.entry(key.clone()).or_insert_with(|| {
            order.push(key.clone());
            Instance {
                task: r.task_id.clone(),
                ..Default::default()
            }
        });
        let first = inst.attempts == 0;
        inst.attempts += 1;
        if first {
            inst.first_ts = r.ts.clone();
        }
        if telemetry_done(r) {
            if first {
                inst.first_pass = true;
            }
            inst.reached_done = true;
        }
    }

    // Reversal timestamps per task id (a Done -> non-Done move). Attribute each
    // to whichever instance's window [first_ts, next first_ts) contains it.
    let mut reversals: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for log in logs {
        for rec in &log.records {
            if rec.from == TaskState::Done && rec.to != TaskState::Done {
                reversals
                    .entry(rec.task_id.clone())
                    .or_default()
                    .push(rec.ts.clone());
            }
        }
    }
    for v in reversals.values_mut() {
        v.sort();
    }
    if !reversals.is_empty() {
        rep.false_done_tasks = reversals.keys().cloned().collect();
    }

    // Per task id, the sorted instance start times (to bound each window).
    let mut starts_by_task: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for key in &order {
        if let Some(inst) = insts.get(key) {
            starts_by_task
                .entry(inst.task.clone())
                .or_default()
                .push(inst.first_ts.clone());
        }
    }
    for v in starts_by_task.values_mut() {
        v.sort();
    }

    for key in &order {
        let inst = &insts[key];
        rep.task_instances += 1;
        let flagged = reversal_in_window(&reversals, &starts_by_task, &inst.task, &inst.first_ts);
        let trust = if flagged {
            DoneTrust::FalseDoneCaught
        } else if inst.reached_done && inst.first_pass {
            DoneTrust::EvidenceBacked
        } else if inst.reached_done {
            DoneTrust::RecoveredAfterWrong
        } else {
            DoneTrust::Unresolved
        };
        tally_done_trust(&mut rep, trust);
    }

    // Task ids that appear ONLY in transitions (no telemetry instance): classify
    // Done-trust straight from the log so a transition-only workspace still
    // reports. Attributed to the mapped intent, else "" (unknown).
    let telemetry_tasks: std::collections::BTreeSet<String> =
        insts.values().map(|i| i.task.clone()).collect();
    for log in logs {
        if telemetry_tasks.contains(&log.task_id) || log.task_id.is_empty() {
            continue;
        }
        rep.task_instances += 1;
        tally_done_trust(&mut rep, classify_transitions(&log.records));
    }

    // ---- Human interventions: decision vs chore --------------------------
    for log in logs {
        for rec in &log.records {
            if !is_human_touch(rec) {
                continue;
            }
            let intent = if rec.intent_id.is_empty() {
                task_intent.get(&rec.task_id).cloned().unwrap_or_default()
            } else {
                rec.intent_id.clone()
            };
            let bucket = rep.per_intent.entry(intent).or_default();
            match classify_touch(rec.cause) {
                TouchKind::Decision => {
                    rep.decisions += 1;
                    bucket.decisions += 1;
                }
                TouchKind::Chore => {
                    rep.chores += 1;
                    bucket.chores += 1;
                }
            }
        }
    }
    // A telemetry user_override is a human redirecting a run — a chore.
    for r in runs {
        if r.user_override.is_some() {
            rep.chores += 1;
            rep.per_intent
                .entry(r.intent_id.clone())
                .or_default()
                .chores += 1;
        }
    }

    // ---- Unnecessary loop stops (waste) ----------------------------------
    for log in logs {
        for rec in &log.records {
            if rec.to == TaskState::NeedsUser && rec.from != TaskState::NeedsUser {
                rep.loop_stops += 1;
                if rec.cause == TransitionCause::DecisionSeed {
                    rep.decision_stops += 1;
                } else {
                    rep.wasted_stops += 1;
                }
            }
        }
    }

    rep
}

/// Does a Done-reversal for `task` fall inside the instance that started at
/// `first_ts` (i.e. between it and the next instance's start)? Attributes a
/// reversal to the exact (intent, task) instance that was live when it happened.
fn reversal_in_window(
    reversals: &BTreeMap<String, Vec<String>>,
    starts_by_task: &BTreeMap<String, Vec<String>>,
    task: &str,
    first_ts: &str,
) -> bool {
    let Some(revs) = reversals.get(task) else {
        return false;
    };
    let starts = starts_by_task.get(task);
    // Upper bound of this window = the next instance's start, if any.
    let next_start = starts.and_then(|s| {
        s.iter()
            .filter(|t| t.as_str() > first_ts)
            .min()
            .map(|s| s.as_str())
    });
    revs.iter()
        .any(|ts| ts.as_str() >= first_ts && next_start.map(|n| ts.as_str() < n).unwrap_or(true))
}

fn tally_done_trust(rep: &mut AutonomyReport, trust: DoneTrust) {
    match trust {
        DoneTrust::EvidenceBacked => rep.evidence_backed += 1,
        DoneTrust::RecoveredAfterWrong => rep.recovered += 1,
        DoneTrust::FalseDoneCaught => rep.false_done_caught += 1,
        DoneTrust::Unresolved => rep.unresolved += 1,
    }
}

/// Read this workspace's transitions + telemetry and fold the v2 report.
pub fn autonomy_report(ws: &Workspace) -> AutonomyReport {
    autonomy(&telemetry::read_runs(ws), &ws.load_all_transition_logs())
}

/// Render the v2 autonomy report as a compact, deterministic text block. Shown
/// under the v1 worker table by `yardlet trust`, and in the TUI trust panel.
pub fn render_autonomy(rep: &AutonomyReport) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "Autonomy & trust (v2) \u{2014} from {} run(s) + {} transition record(s)\n",
        rep.runs_read, rep.transitions_read,
    ));

    let n = rep.task_instances;
    s.push_str(&format!("\nCan I trust a Done?  ({n} task-runs)\n"));
    if n == 0 {
        s.push_str("  (no runs recorded yet)\n");
    } else {
        s.push_str(&format!(
            "  evidence-backed   {:>4}/{}  ({:.0}%)  clean Done, never reopened\n",
            rep.evidence_backed,
            n,
            rate(rep.evidence_backed, n) * 100.0,
        ));
        s.push_str(&format!(
            "  recovered         {:>4}/{}           Done after a wrong turn\n",
            rep.recovered, n,
        ));
        s.push_str(&format!(
            "  false-done caught {:>4}/{}           marked Done, later reopened\n",
            rep.false_done_caught, n,
        ));
        s.push_str(&format!(
            "  unresolved        {:>4}/{}           no Done in the record yet\n",
            rep.unresolved, n,
        ));
        s.push_str(&format!(
            "  trustworthy-Done rate: {:.0}%  (evidence-backed of {} Done)\n",
            rep.trustworthy_done_rate() * 100.0,
            rep.done_reached(),
        ));
        if !rep.false_done_tasks.is_empty() {
            s.push_str(&format!(
                "  reopened: {}\n",
                rep.false_done_tasks.join(", ")
            ));
        }
    }

    s.push_str("\nHuman interventions \u{2014} decision vs chore  (goal: chore \u{2192} 0)\n");
    if rep.human_touches() == 0 {
        s.push_str("  none recorded \u{2014} the loop needed no hand un-sticking\n");
    } else {
        s.push_str(&format!(
            "  decisions {}   chores {}   chore-ratio {:.0}%\n",
            rep.decisions,
            rep.chores,
            rep.chore_ratio() * 100.0,
        ));
        for (intent, t) in &rep.per_intent {
            if t.total() == 0 {
                continue;
            }
            let label = if intent.is_empty() {
                "(unattributed)"
            } else {
                intent
            };
            s.push_str(&format!(
                "    {:<28} decisions {}  chores {}  ({:.0}% chore)\n",
                label,
                t.decisions,
                t.chores,
                t.chore_ratio() * 100.0,
            ));
        }
    }

    s.push_str("\nUnnecessary loop stops (waste)\n");
    s.push_str(&format!(
        "  loop stops {}   owed decisions {}   wasted {}\n",
        rep.loop_stops, rep.decision_stops, rep.wasted_stops,
    ));
    if rep.wasted_stops > 0 {
        s.push_str("  (wasted = halted for approval/pause friction, not a real question)\n");
    }

    s
}

/// Full trust report text: the v1 worker/attempt table plus the v2 autonomy
/// block. Used by `yardlet trust` (no --json) and the TUI trust panel so both
/// surfaces show identical numbers.
pub fn report_text(ws: &Workspace) -> Result<String> {
    let mut s = report(ws)?;
    s.push('\n');
    s.push_str(&render_autonomy(&autonomy_report(ws)));
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(task: &str, worker: &str, status: &str, eval: &str, wall: u64) -> RunTelemetry {
        RunTelemetry {
            ts: String::new(),
            run_id: String::new(),
            task_id: task.into(),
            intent_id: String::new(),
            kind: "implementation".into(),
            risk: "low".into(),
            worker: worker.into(),
            chosen_reason: String::new(),
            result_status: status.into(),
            eval_state: eval.into(),
            wall_seconds: wall,
            user_override: None,
            skills: vec![],
            verdict_pass: None,
            feedback_cycle: 0,
            max_feedback_cycles: 0,
            feedback_retryable: false,
            git_finish_status: String::new(),
        }
    }

    #[test]
    fn first_pass_vs_retry_vs_unresolved() {
        let runs = vec![
            // A: done on the first attempt.
            rec("A", "codex", "done", "Done", 100),
            // B: failed (no-result) then done — a retry recovery.
            rec("B", "claude-code", "no-result", "Failed", 200),
            rec("B", "claude-code", "done", "Done", 300),
            // C: only ever partial — never reached Done.
            rec("C", "codex", "partial", "Partial", 50),
        ];
        let r = summarize(&runs);
        assert_eq!(r.total_runs, 4);
        assert_eq!(r.task_count(), 3);
        assert_eq!(r.first_pass_done(), 1); // A
        assert_eq!(r.retried_done(), 1); // B
        assert_eq!(r.unresolved(), 1); // C
        assert_eq!(r.total_wall_seconds, 650);

        // B is a retry: 2 attempts, reached done, not first-pass.
        let b = &r.tasks["B"];
        assert_eq!(b.attempts, 2);
        assert!(b.reached_done && !b.first_pass);

        // Per-worker: claude-code did B (1 done, 1 failed, 1 no-result).
        let cc = &r.workers["claude-code"];
        assert_eq!(cc.runs, 2);
        assert_eq!(cc.done, 1);
        assert_eq!(cc.failed, 1);
        assert_eq!(cc.no_result, 1);
        assert!((cc.done_rate() - 0.5).abs() < 1e-9);

        // Render is non-empty and lists the retried task; cumulative view warns
        // about cross-intent folding.
        let out = render(&r, None);
        assert!(out.contains("Needed multiple attempts"));
        assert!(out.contains("B "));
        assert!(out.contains("cumulative across intents"));
        // An intent-scoped render names the intent and drops the folding caveat.
        let scoped = render(&r, Some("intent-x"));
        assert!(scoped.contains("intent intent-x"));
        assert!(!scoped.contains("cumulative across intents"));
    }

    #[test]
    fn unverified_git_finish_cannot_contribute_a_done() {
        let mut pending = rec("A", "codex", "done", "Done", 1);
        pending.git_finish_status = "prepared".into();
        let mut verified = rec("B", "codex", "done", "Done", 1);
        verified.git_finish_status = "already_applied".into();

        let report = summarize(&[pending, verified]);

        assert!(!report.tasks["A"].reached_done);
        assert!(report.tasks["B"].reached_done);
    }

    #[test]
    fn scope_prefers_active_intent_then_falls_back() {
        let mut a = rec("A", "codex", "done", "Done", 10);
        a.intent_id = "i1".into();
        let mut b = rec("B", "codex", "done", "Done", 10);
        b.intent_id = "i2".into();
        let legacy = rec("C", "codex", "done", "Done", 10); // intent_id == ""
        let runs = vec![a, b, legacy];

        // Active intent with matching runs -> scoped to just those.
        let (slice, scoped) = scope_runs(&runs, Some("i2"));
        assert!(scoped);
        assert_eq!(slice.len(), 1);
        assert_eq!(slice[0].task_id, "B");

        // Active intent with no telemetry yet -> cumulative fallback.
        let (slice, scoped) = scope_runs(&runs, Some("i9"));
        assert!(!scoped);
        assert_eq!(slice.len(), 3);

        // No active intent -> cumulative.
        let (slice, scoped) = scope_runs(&runs, None);
        assert!(!scoped);
        assert_eq!(slice.len(), 3);
    }

    #[test]
    fn mine_flags_no_result_workers_and_high_retry_kinds() {
        let mut runs = Vec::new();
        // Worker "flaky": 8 runs over 8 tasks, 2 produced no result (25%).
        for i in 0..8 {
            let (status, eval) = if i < 2 {
                ("no-result", "Failed")
            } else {
                ("done", "Done")
            };
            runs.push(rec(&format!("N{i}"), "flaky", status, eval, 1));
        }
        // Kind "research": 3 tasks, each needing 3 attempts (2 fail then done).
        for t in 0..3 {
            for a in 0..3 {
                let (status, eval) = if a < 2 {
                    ("failed", "Failed")
                } else {
                    ("done", "Done")
                };
                let mut r = rec(&format!("R{t}"), "builder", status, eval, 1);
                r.kind = "research".into();
                runs.push(r);
            }
        }

        let obs = mine(&runs);
        assert_eq!(obs.len(), 2, "{obs:?}");
        assert!(
            obs.iter()
                .any(|o| o.detail.contains("flaky") && o.detail.contains("no parseable")),
            "{obs:?}"
        );
        assert!(
            obs.iter()
                .any(|o| o.detail.contains("research") && o.detail.contains("3.0 attempts")),
            "{obs:?}"
        );

        // Below thresholds -> nothing mined (a clean workspace is quiet).
        let quiet = vec![
            rec("A", "codex", "done", "Done", 1),
            rec("B", "codex", "done", "Done", 1),
        ];
        assert!(mine(&quiet).is_empty());
    }

    #[test]
    fn empty_telemetry_renders_zeroes() {
        let r = summarize(&[]);
        assert_eq!(r.task_count(), 0);
        assert_eq!(r.first_pass_done(), 0);
        // No divide-by-zero in render.
        let _ = render(&r, None);
    }

    // ---- v2 autonomy ------------------------------------------------------

    fn run(task: &str, intent: &str, eval: &str, ts: &str) -> RunTelemetry {
        let mut r = rec(task, "codex", "done", eval, 1);
        r.intent_id = intent.into();
        r.ts = ts.into();
        r
    }

    fn tr(
        task: &str,
        from: TaskState,
        to: TaskState,
        cause: TransitionCause,
        actor: TransitionActor,
        ts: &str,
    ) -> TransitionRecord {
        TransitionRecord {
            task_id: task.into(),
            intent_id: String::new(),
            from,
            to,
            cause,
            detail: String::new(),
            actor,
            ts: ts.into(),
        }
    }

    fn tlog(task: &str, records: Vec<TransitionRecord>) -> TransitionLog {
        TransitionLog {
            task_id: task.into(),
            records,
        }
    }

    #[test]
    fn done_trust_three_way_split_across_sources() {
        // A: first-pass Done (evidence). B: Failed then Done (recovered).
        // C: only Partial (unresolved). All in one intent, from telemetry.
        let runs = vec![
            run("A", "i1", "Done", "t01"),
            run("B", "i1", "Failed", "t02"),
            run("B", "i1", "Done", "t03"),
            run("C", "i1", "Partial", "t04"),
        ];
        // D: transition-only, reached Done then reopened (false-done).
        let logs = vec![tlog(
            "D",
            vec![
                tr(
                    "D",
                    TaskState::Running,
                    TaskState::Done,
                    TransitionCause::RunOutcome,
                    TransitionActor::Worker("r".into()),
                    "t05",
                ),
                tr(
                    "D",
                    TaskState::Done,
                    TaskState::Queued,
                    TransitionCause::RunOutcome,
                    TransitionActor::System,
                    "t06",
                ),
            ],
        )];

        let rep = autonomy(&runs, &logs);
        assert_eq!(rep.task_instances, 4);
        assert_eq!(rep.evidence_backed, 1, "A");
        assert_eq!(rep.recovered, 1, "B");
        assert_eq!(rep.unresolved, 1, "C");
        assert_eq!(rep.false_done_caught, 1, "D");
        assert_eq!(rep.false_done_tasks, vec!["D".to_string()]);
        assert_eq!(rep.done_reached(), 3);
        // Numbers survive a render pass (no panic / divide-by-zero).
        assert!(render_autonomy(&rep).contains("false-done caught    1/4"));
    }

    #[test]
    fn false_done_overlay_attributes_to_the_live_instance() {
        // Task A runs Done in i1 (t01), then is reused and runs Done in i2 (t10).
        // A reversal at t03 (Done->Failed) belongs to the i1 window, not i2.
        let runs = vec![run("A", "i1", "Done", "t01"), run("A", "i2", "Done", "t10")];
        let logs = vec![tlog(
            "A",
            vec![
                tr(
                    "A",
                    TaskState::Running,
                    TaskState::Done,
                    TransitionCause::RunOutcome,
                    TransitionActor::Worker("r1".into()),
                    "t02",
                ),
                tr(
                    "A",
                    TaskState::Done,
                    TaskState::Failed,
                    TransitionCause::RunOutcome,
                    TransitionActor::System,
                    "t03",
                ),
                tr(
                    "A",
                    TaskState::Running,
                    TaskState::Done,
                    TransitionCause::RunOutcome,
                    TransitionActor::Worker("r2".into()),
                    "t11",
                ),
            ],
        )];
        let rep = autonomy(&runs, &logs);
        assert_eq!(rep.task_instances, 2);
        assert_eq!(
            rep.false_done_caught, 1,
            "the i1 instance is the reopened one"
        );
        assert_eq!(rep.evidence_backed, 1, "the i2 instance stays clean");
    }

    #[test]
    fn human_touches_split_decision_vs_chore_per_intent() {
        // Legacy transition records have no intent, so map tasks to intents via
        // telemetry, then classify their user touches.
        let runs = vec![
            run("A", "i1", "Done", "t01"),
            run("B", "i1", "Done", "t02"),
            run("C", "i2", "Done", "t03"),
            {
                let mut o = run("Z", "i2", "Done", "t04");
                o.user_override = Some("human redirected the worker".into());
                o
            },
        ];
        let logs = vec![
            tlog(
                "A",
                vec![tr(
                    "A",
                    TaskState::Queued,
                    TaskState::Deferred,
                    TransitionCause::Defer,
                    TransitionActor::User,
                    "t05",
                )],
            ),
            tlog(
                "B",
                vec![tr(
                    "B",
                    TaskState::Deferred,
                    TaskState::Queued,
                    TransitionCause::Revive,
                    TransitionActor::User,
                    "t06",
                )],
            ),
            tlog(
                "C",
                vec![tr(
                    "C",
                    TaskState::Queued,
                    TaskState::NeedsUser,
                    TransitionCause::DecisionSeed,
                    TransitionActor::System,
                    "t07",
                )],
            ),
        ];
        let rep = autonomy(&runs, &logs);
        // A defer = decision, B revive = chore, C seeded decision = decision,
        // Z override = chore.
        assert_eq!(rep.decisions, 2);
        assert_eq!(rep.chores, 2);
        assert_eq!(rep.human_touches(), 4);
        assert!((rep.chore_ratio() - 0.5).abs() < 1e-9);
        // Per intent: i1 = 1 decision (defer) + 1 chore (revive).
        let i1 = &rep.per_intent["i1"];
        assert_eq!((i1.decisions, i1.chores), (1, 1));
        // i2 = 1 decision (seed) + 1 chore (override).
        let i2 = &rep.per_intent["i2"];
        assert_eq!((i2.decisions, i2.chores), (1, 1));
    }

    #[test]
    fn human_touches_prefer_transition_intent_over_telemetry_mapping() {
        let runs = vec![run("A", "telemetry-intent", "Done", "t01")];
        let mut touch = tr(
            "A",
            TaskState::Queued,
            TaskState::Deferred,
            TransitionCause::Defer,
            TransitionActor::User,
            "t02",
        );
        touch.intent_id = "transition-intent".to_string();

        let rep = autonomy(&runs, &[tlog("A", vec![touch])]);

        assert_eq!(rep.decisions, 1);
        assert_eq!(rep.per_intent["transition-intent"].decisions, 1);
        assert!(!rep.per_intent.contains_key("telemetry-intent"));
    }

    #[test]
    fn waste_counts_needsuser_stops_by_cause() {
        let logs = vec![
            // A owed decision (good stop).
            tlog(
                "A",
                vec![tr(
                    "A",
                    TaskState::Queued,
                    TaskState::NeedsUser,
                    TransitionCause::DecisionSeed,
                    TransitionActor::System,
                    "t01",
                )],
            ),
            // B approval/pause friction (wasted stop).
            tlog(
                "B",
                vec![tr(
                    "B",
                    TaskState::Running,
                    TaskState::NeedsUser,
                    TransitionCause::RunOutcome,
                    TransitionActor::System,
                    "t02",
                )],
            ),
        ];
        let rep = autonomy(&[], &logs);
        assert_eq!(rep.loop_stops, 2);
        assert_eq!(rep.decision_stops, 1);
        assert_eq!(rep.wasted_stops, 1);
    }

    #[test]
    fn to_json_is_traceable_and_matches_render() {
        let runs = vec![
            run("A", "i1", "Done", "t01"),
            run("B", "i1", "Failed", "t02"),
        ];
        let logs = vec![tlog(
            "A",
            vec![tr(
                "A",
                TaskState::Queued,
                TaskState::Deferred,
                TransitionCause::Defer,
                TransitionActor::User,
                "t03",
            )],
        )];
        let rep = autonomy(&runs, &logs);
        let j = rep.to_json();
        // Each number is backed by a source count.
        assert_eq!(j["sources"]["runs_read"], 2);
        assert_eq!(j["sources"]["transitions_read"], 1);
        assert_eq!(j["done_trust"]["evidence_backed"], 1);
        assert_eq!(j["done_trust"]["unresolved"], 1);
        assert_eq!(j["human_touches"]["decisions"], 1);
        assert_eq!(j["human_touches"]["per_intent"]["i1"]["decisions"], 1);
        // The JSON serializes without error.
        assert!(serde_json::to_string(&j).is_ok());
    }

    #[test]
    fn empty_autonomy_is_all_zeroes_and_safe() {
        let rep = autonomy(&[], &[]);
        assert_eq!(rep.task_instances, 0);
        assert_eq!(rep.human_touches(), 0);
        assert_eq!(rep.chore_ratio(), 0.0);
        assert_eq!(rep.trustworthy_done_rate(), 0.0);
        // Renders without panic; JSON is valid.
        let _ = render_autonomy(&rep);
        assert!(serde_json::to_string(&rep.to_json()).is_ok());
    }
}
