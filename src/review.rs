//! Routing review: aggregate run telemetry and *suggest* worker-routing policy
//! changes. It never edits policy itself — applying a suggestion is an explicit,
//! human-gated action (`yardlet routing apply`).

use std::collections::{BTreeMap, BTreeSet};

use anyhow::Result;

use crate::routing::{self, RoutingOverrides};
use crate::schemas::WorkersFile;
use crate::state::Workspace;
use crate::telemetry::RunTelemetry;

const MIN_SAMPLES: usize = 4;
const MARGIN: f64 = 0.20;
const OVERRIDE_THRESHOLD: usize = 2;

#[derive(Default, Clone, Copy)]
pub struct Stat {
    pub total: usize,
    pub success: usize,
}

impl Stat {
    pub fn rate(&self) -> f64 {
        if self.total == 0 {
            0.0
        } else {
            self.success as f64 / self.total as f64
        }
    }
}

pub struct Suggestion {
    pub kind: String,
    pub to: String,
    pub reason: String,
}

/// Success stats keyed by (task kind, worker).
pub fn aggregate(runs: &[RunTelemetry]) -> BTreeMap<(String, String), Stat> {
    let mut m: BTreeMap<(String, String), Stat> = BTreeMap::new();
    for r in runs {
        if r.kind.is_empty() {
            continue;
        }
        let e = m.entry((r.kind.clone(), r.worker.clone())).or_default();
        e.total += 1;
        if r.eval_state.eq_ignore_ascii_case("done") {
            e.success += 1;
        }
    }
    m
}

/// Propose kind overrides from observed success and user overrides. Pure, so it
/// is unit-tested without touching disk.
pub fn suggest(
    runs: &[RunTelemetry],
    workers: &WorkersFile,
    overrides: &RoutingOverrides,
) -> Vec<Suggestion> {
    let stats = aggregate(runs);
    let kinds: BTreeSet<String> = runs
        .iter()
        .map(|r| r.kind.clone())
        .filter(|k| !k.is_empty())
        .collect();

    let mut out = Vec::new();
    for kind in kinds {
        let current = overrides
            .kind_overrides
            .get(&kind)
            .cloned()
            .unwrap_or_else(|| workers.routing.default_worker.clone());

        // Best worker by success rate with enough samples.
        let mut best: Option<(String, f64)> = None;
        for w in &workers.workers {
            if let Some(s) = stats.get(&(kind.clone(), w.id.clone())) {
                if s.total >= MIN_SAMPLES {
                    let rate = s.rate();
                    if best.as_ref().map(|(_, r)| rate > *r).unwrap_or(true) {
                        best = Some((w.id.clone(), rate));
                    }
                }
            }
        }

        let mut suggested = false;
        if let Some((bw, brate)) = &best {
            if bw != &current {
                let cur_rate = stats
                    .get(&(kind.clone(), current.clone()))
                    .map(|s| s.rate())
                    .unwrap_or(0.0);
                if brate - cur_rate >= MARGIN {
                    out.push(Suggestion {
                        kind: kind.clone(),
                        to: bw.clone(),
                        reason: format!(
                            "{bw} succeeds {:.0}% vs {current} {:.0}% on '{kind}'",
                            brate * 100.0,
                            cur_rate * 100.0
                        ),
                    });
                    suggested = true;
                }
            }
        }
        if suggested {
            continue;
        }

        // Override-driven: the user keeps forcing a different worker.
        let mut override_counts: BTreeMap<String, usize> = BTreeMap::new();
        for r in runs.iter().filter(|r| r.kind == kind) {
            if let Some(ov) = &r.user_override {
                if let Some(to) = ov.split("->").nth(1) {
                    *override_counts.entry(to.to_string()).or_default() += 1;
                }
            }
        }
        for (w, c) in override_counts {
            if c >= OVERRIDE_THRESHOLD && w != current {
                out.push(Suggestion {
                    kind: kind.clone(),
                    to: w.clone(),
                    reason: format!("you overrode to {w} {c}x on '{kind}'"),
                });
            }
        }
    }
    out
}

/// Count suggestions cheaply (for the status nudge).
pub fn pending_count(ws: &Workspace) -> usize {
    let runs = crate::telemetry::read_runs(ws);
    if runs.is_empty() {
        return 0;
    }
    let (Ok(workers), overrides) = (ws.load_workers(), routing::load_overrides(ws)) else {
        return 0;
    };
    suggest(&runs, &workers, &overrides).len()
}

/// Apply a single override (human-gated). Writes the machine-managed file,
/// leaving the human-owned workers.yaml (and its comments) untouched.
pub fn set_kind_override(ws: &Workspace, kind: &str, worker: &str) -> Result<()> {
    let mut ov = routing::load_overrides(ws);
    ov.kind_overrides
        .insert(kind.to_string(), worker.to_string());
    crate::state::save_yaml(&routing::overrides_path(ws), &ov)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(kind: &str, worker: &str, done: bool, ovr: Option<&str>) -> RunTelemetry {
        RunTelemetry {
            ts: String::new(),
            task_id: "t".into(),
            intent_id: String::new(),
            kind: kind.into(),
            risk: String::new(),
            worker: worker.into(),
            chosen_reason: String::new(),
            result_status: String::new(),
            eval_state: if done { "Done".into() } else { "Failed".into() },
            wall_seconds: 0,
            user_override: ovr.map(|s| s.to_string()),
            skills: vec![],
            verdict_pass: None,
            feedback_cycle: 0,
            max_feedback_cycles: 0,
            feedback_retryable: false,
            git_finish_status: String::new(),
        }
    }

    fn workers() -> WorkersFile {
        crate::yaml::from_str(
            "schema_version: 1\nworkers:\n  - {id: codex, invocation: {command: codex}}\n  - {id: claude-code, invocation: {command: claude}}\nrouting:\n  default_worker: codex\n",
        )
        .unwrap()
    }

    #[test]
    fn suggests_better_worker_by_success_rate() {
        let mut runs = Vec::new();
        // codex fails refactor, claude succeeds, enough samples each
        for _ in 0..4 {
            runs.push(run("refactor", "codex", false, None));
            runs.push(run("refactor", "claude-code", true, None));
        }
        let s = suggest(&runs, &workers(), &RoutingOverrides::default());
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].kind, "refactor");
        assert_eq!(s[0].to, "claude-code");
    }

    #[test]
    fn no_suggestion_without_enough_samples() {
        let runs = vec![
            run("impl", "codex", false, None),
            run("impl", "claude-code", true, None),
        ];
        assert!(suggest(&runs, &workers(), &RoutingOverrides::default()).is_empty());
    }

    #[test]
    fn suggests_from_user_overrides() {
        let runs = vec![
            run("docs", "claude-code", true, Some("codex->claude-code")),
            run("docs", "claude-code", true, Some("codex->claude-code")),
        ];
        let s = suggest(&runs, &workers(), &RoutingOverrides::default());
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].to, "claude-code");
    }
}
