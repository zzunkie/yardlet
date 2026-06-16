//! Deterministic run-time worker resolution.
//!
//! Picks the worker for a task and walks the fallback order to the first ready
//! one. This is mechanism: it never consults telemetry (that only feeds
//! human-approved policy changes), so the choice stays predictable and
//! auditable.
//!
//! Candidate precedence: run override > learned kind rule > planner preferred >
//! routing default. Then: candidate -> fallback_order -> first ready.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

use crate::guard::{self, Readiness};
use crate::schemas::{BillingPolicy, WorkersFile};
use crate::state::Workspace;

/// Machine-managed learned overrides (written by `yard routing apply`), kept in
/// a separate file so the human-owned `workers.yaml` keeps its comments.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct RoutingOverrides {
    #[serde(default)]
    pub kind_overrides: HashMap<String, String>,
}

pub fn overrides_path(ws: &Workspace) -> PathBuf {
    ws.agents_dir().join("routing-overrides.yaml")
}

pub fn load_overrides(ws: &Workspace) -> RoutingOverrides {
    std::fs::read_to_string(overrides_path(ws))
        .ok()
        .and_then(|t| crate::yaml::from_str(&t).ok())
        .unwrap_or_default()
}

pub struct Resolved {
    pub worker_id: String,
    pub bin: PathBuf,
    pub reason: String,
}

pub fn resolve_worker(
    ws: &Workspace,
    workers: &WorkersFile,
    billing: &BillingPolicy,
    override_w: Option<&str>,
    preferred: &str,
    kind: &str,
) -> Result<Resolved> {
    let overrides = load_overrides(ws);
    let (candidate, source) = candidate_for(workers, &overrides, override_w, preferred, kind);

    // Try order: the candidate, then the configured fallback order.
    let mut order = vec![candidate.clone()];
    for w in &workers.routing.fallback_order {
        if !order.contains(w) {
            order.push(w.clone());
        }
    }

    let mut tried = Vec::new();
    for id in &order {
        let Some(profile) = workers.workers.iter().find(|w| &w.id == id) else {
            continue;
        };
        if !profile.enabled {
            continue;
        }
        tried.push(id.clone());
        let status = guard::probe(profile, billing);
        if status.readiness == Readiness::Ready {
            if let Some(bin) = status.binary_path {
                let reason = if id == &candidate {
                    source.to_string()
                } else {
                    format!("fallback ({candidate} not ready)")
                };
                return Ok(Resolved {
                    worker_id: id.clone(),
                    bin,
                    reason,
                });
            }
        }
    }
    Err(anyhow!(
        "no ready worker among {tried:?}. Run `yard worker status` to diagnose. \
         Yardlet did not call an AI API and did not ask for an API key."
    ))
}

/// The pre-readiness candidate and why it was chosen. Pure, so it is unit-tested.
pub fn candidate_for(
    workers: &WorkersFile,
    overrides: &RoutingOverrides,
    override_w: Option<&str>,
    preferred: &str,
    kind: &str,
) -> (String, &'static str) {
    if let Some(o) = override_w.filter(|s| !s.is_empty()) {
        (o.to_string(), "run override")
    } else if let Some(k) = overrides.kind_overrides.get(kind).filter(|s| !s.is_empty()) {
        (k.clone(), "learned kind rule")
    } else if !preferred.is_empty() {
        (preferred.to_string(), "planner preferred")
    } else {
        (workers.routing.default_worker.clone(), "default")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workers() -> WorkersFile {
        crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: codex\n  fallback_order: [codex, claude-code]\n",
        )
        .unwrap()
    }

    #[test]
    fn candidate_precedence() {
        let w = workers();
        let mut ov = RoutingOverrides::default();
        ov.kind_overrides
            .insert("refactor".into(), "claude-code".into());

        // run override beats everything
        assert_eq!(
            candidate_for(&w, &ov, Some("codex"), "claude-code", "refactor").0,
            "codex"
        );
        // learned kind rule beats planner preferred
        assert_eq!(
            candidate_for(&w, &ov, None, "codex", "refactor").0,
            "claude-code"
        );
        // planner preferred when no kind rule
        assert_eq!(
            candidate_for(&w, &ov, None, "claude-code", "implementation").0,
            "claude-code"
        );
        // default when nothing else
        assert_eq!(
            candidate_for(&w, &ov, None, "", "implementation").0,
            "codex"
        );
    }
}
