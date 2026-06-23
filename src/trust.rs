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

/// Render a trust report as a compact, deterministic text block.
pub fn render(report: &TrustReport) -> String {
    let mut s = String::new();
    let tasks = report.task_count();
    s.push_str(&format!(
        "Trust report — {} runs across {} tasks, {} total worker wall\n",
        report.total_runs,
        tasks,
        humanize(report.total_wall_seconds),
    ));
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
        // Telemetry is workspace-cumulative and carries no intent id yet, so a
        // task id reused across intents folds its attempts together here. Until
        // run telemetry records an intent id, read the heavy-retry rows as
        // per-id-across-the-workspace, not necessarily one intent's retries.
        s.push_str(
            "\n  (cumulative across intents; a task id reused across intents folds together)\n",
        );
    }

    s
}

/// Read this workspace's telemetry and render its trust report.
pub fn report(ws: &Workspace) -> Result<String> {
    let runs = telemetry::read_runs(ws);
    if runs.is_empty() {
        return Ok("No run telemetry yet. The trust report fills in as runs accrue.\n".to_string());
    }
    Ok(render(&summarize(&runs)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(task: &str, worker: &str, status: &str, eval: &str, wall: u64) -> RunTelemetry {
        RunTelemetry {
            ts: String::new(),
            task_id: task.into(),
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

        // Render is non-empty and lists the retried task.
        let out = render(&r);
        assert!(out.contains("Needed multiple attempts"));
        assert!(out.contains("B "));
    }

    #[test]
    fn empty_telemetry_renders_zeroes() {
        let r = summarize(&[]);
        assert_eq!(r.task_count(), 0);
        assert_eq!(r.first_pass_done(), 0);
        // No divide-by-zero in render.
        let _ = render(&r);
    }
}
