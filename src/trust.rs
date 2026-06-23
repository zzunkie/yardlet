//! Trust report: a deterministic read over run telemetry that answers "how much
//! can I trust a Done here?" — first-pass success vs. Done-after-retry, per-worker
//! reliability, and the distrust signals (no-result runs, user overrides, tasks
//! that never reached Done). Like routing review (policy vs mechanism) it only
//! REPORTS; it never edits policy. Pure aggregation, so it is unit-tested without
//! touching disk.

use std::collections::BTreeMap;

use anyhow::Result;

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
        if is_done(&r.eval_state) {
            if first_attempt {
                t.first_pass = true;
            }
            t.reached_done = true;
        }

        if !r.worker.is_empty() {
            let w = workers.entry(r.worker.clone()).or_default();
            w.runs += 1;
            w.wall_seconds += r.wall_seconds;
            if is_done(&r.eval_state) {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(task: &str, worker: &str, status: &str, eval: &str, wall: u64) -> RunTelemetry {
        RunTelemetry {
            ts: String::new(),
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
}
