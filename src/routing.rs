//! Deterministic run-time worker resolution.
//!
//! Picks the worker for a task and walks the fallback order to the first ready
//! one. This is mechanism: it never consults telemetry (that only feeds
//! human-approved policy changes), so the choice stays predictable and
//! auditable.
//!
//! Candidate precedence: run override > hard capability rule > learned kind
//! rule > planner preferred > routing default. Then: candidate -> fallback_order
//! -> first ready. Hard capability rules may opt out of fallback when another
//! worker cannot satisfy the capability.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

use crate::guard::{self, Readiness};
use crate::schemas::{BillingPolicy, Task, WorkersFile};
use crate::state::Workspace;

/// Machine-managed learned overrides (written by `yardlet routing apply`), kept in
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

#[derive(Debug)]
pub struct Resolved {
    pub worker_id: String,
    pub bin: PathBuf,
    pub reason: String,
}

pub fn resolve_worker_for_task(
    ws: &Workspace,
    workers: &WorkersFile,
    billing: &BillingPolicy,
    override_w: Option<&str>,
    task: &Task,
) -> Result<Resolved> {
    let overrides = load_overrides(ws);
    let required: Vec<String> = task
        .required_capabilities
        .iter()
        .map(|c| norm_cap(c))
        .filter(|c| !c.is_empty())
        .collect();
    let mut candidate = candidate_for_task(workers, &overrides, override_w, task);

    // Hard capability gate (replaces the old image-keyword router): if the task
    // declares required_capabilities, only workers that provide them may run it.
    // The choice stays deterministic and auditable, driven by user-owned
    // workers.yaml `capabilities` and planner-assigned `required_capabilities`
    // (no magic keywords).
    if !required.is_empty() && !worker_declares(workers, &candidate.worker_id, &required) {
        if candidate.reason == "run override" {
            return Err(anyhow!(
                "worker '{}' was explicitly selected but does not declare the required \
                 capability/capabilities {:?}. Add it to that worker in .agents/workers.yaml \
                 or drop the override.",
                candidate.worker_id,
                required
            ));
        }
        match first_capable(workers, &required) {
            Some(id) => {
                candidate = Candidate {
                    worker_id: id,
                    reason: "capability route",
                }
            }
            None => {
                return Err(anyhow!(
                    "no enabled worker declares the required capability/capabilities \
                     {required:?}. Add it to a worker in .agents/workers.yaml."
                ))
            }
        }
    }

    if candidate.reason == "planner preferred"
        && !task.preferred_worker.trim().is_empty()
        && !workers.routing.allow_preferred_worker_failover
    {
        let pinned = candidate.worker_id.clone();
        return resolve_order(
            workers,
            billing,
            pinned.clone(),
            candidate.reason,
            std::slice::from_ref(&pinned),
        )
        .map_err(|_| {
            anyhow!(
                "preferred worker '{pinned}' is not invocable; cross-worker fallback requires explicit opt-in with routing.allow_preferred_worker_failover"
            )
        });
    }

    resolve_candidate(
        workers,
        billing,
        candidate.worker_id,
        candidate.reason,
        &required,
    )
}

pub fn resolve_failover_worker_for_task(
    workers: &WorkersFile,
    billing: &BillingPolicy,
    failed_worker: &str,
    task: &Task,
) -> Result<Resolved> {
    if !task.preferred_worker.trim().is_empty() && !workers.routing.allow_preferred_worker_failover
    {
        return Err(anyhow!(
            "task pinned preferred worker '{}'; cross-worker failover requires explicit opt-in with routing.allow_preferred_worker_failover",
            task.preferred_worker
        ));
    }
    let required: Vec<String> = task
        .required_capabilities
        .iter()
        .map(|c| norm_cap(c))
        .filter(|c| !c.is_empty())
        .collect();
    let mut order = Vec::new();
    for id in workers
        .routing
        .fallback_order
        .iter()
        .chain(std::iter::once(&workers.routing.default_worker))
        .chain(workers.workers.iter().map(|w| &w.id))
    {
        if id != failed_worker && !order.contains(id) {
            order.push(id.clone());
        }
    }
    if !required.is_empty() {
        order.retain(|id| worker_declares(workers, id, &required));
    }
    if order.is_empty() {
        let cap_note = if required.is_empty() {
            String::new()
        } else {
            format!(" declaring required capability/capabilities {required:?}")
        };
        return Err(anyhow!(
            "no alternate worker{cap_note} after excluding '{failed_worker}'"
        ));
    }
    resolve_order(workers, billing, order[0].clone(), "failover", &order)
}

fn resolve_candidate(
    workers: &WorkersFile,
    billing: &BillingPolicy,
    candidate: String,
    source: &'static str,
    required: &[String],
) -> Result<Resolved> {
    // Try order: the candidate, then the configured fallback order, restricted
    // to workers that declare every required capability. The restriction (not a
    // hardcoded strict flag) is what keeps a capability-bound task from failing
    // over to a worker that cannot do it.
    let mut order = vec![candidate.clone()];
    for w in &workers.routing.fallback_order {
        if !order.contains(w) {
            order.push(w.clone());
        }
    }
    if !required.is_empty() {
        order.retain(|id| worker_declares(workers, id, required));
    }
    if order.is_empty() {
        return Err(anyhow!(
            "no enabled worker declares the required capability/capabilities {required:?}. \
             Add it to a worker in .agents/workers.yaml."
        ));
    }

    resolve_order(workers, billing, candidate, source, &order)
}

fn resolve_order(
    workers: &WorkersFile,
    billing: &BillingPolicy,
    candidate: String,
    source: &'static str,
    order: &[String],
) -> Result<Resolved> {
    let mut tried = Vec::new();
    for id in order {
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
                    format!("fallback ({candidate} not invocable)")
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
        "no invocable worker among {tried:?}. Run `yardlet worker status` to diagnose. \
         Yardlet did not call an AI API and did not ask for an API key."
    ))
}

struct Candidate {
    worker_id: String,
    reason: &'static str,
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

fn candidate_for_task(
    workers: &WorkersFile,
    overrides: &RoutingOverrides,
    override_w: Option<&str>,
    task: &Task,
) -> Candidate {
    let (worker_id, reason) = candidate_for(
        workers,
        overrides,
        override_w,
        &task.preferred_worker,
        &task.kind,
    );
    Candidate { worker_id, reason }
}

/// Normalize a capability name for matching: trimmed, lowercase, with spaces and
/// hyphens folded to underscores. Keeps matching exact without forcing an enum
/// (a new worker capability needs no Yardlet code change). Shared with the
/// rubric diff/merge so both compare capabilities the same way routing gates do.
pub(crate) fn norm_cap(s: &str) -> String {
    s.trim().to_lowercase().replace([' ', '-'], "_")
}

/// The set of capabilities declared by ENABLED workers, normalized. A task's
/// `required_capabilities` must be a subset of this to be runnable; any other
/// capability is unsatisfiable (a human decision, or a typo no worker has), and
/// the planner/ingest parks such a task Blocked at queue-creation time rather
/// than letting routing hard-fail when the drain later selects it.
pub(crate) fn declared_capabilities(workers: &WorkersFile) -> std::collections::BTreeSet<String> {
    workers
        .workers
        .iter()
        .filter(|w| w.enabled)
        .flat_map(|w| w.capabilities.iter().map(|c| norm_cap(c)))
        .filter(|c| !c.is_empty())
        .collect()
}

/// The required capabilities (normalized) that NO enabled worker declares — the
/// one definition of "off-vocabulary" shared by the planner's queue-creation
/// park, the run-time backstop, and the `status` view, so all three agree.
pub(crate) fn unsatisfiable_capabilities(
    required: &[String],
    vocab: &std::collections::BTreeSet<String>,
) -> Vec<String> {
    required
        .iter()
        .map(|c| norm_cap(c))
        .filter(|c| !c.is_empty() && !vocab.contains(c))
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateShape {
    Decision,
    ToolGap,
}

/// Legacy queues sometimes encoded a human decision as a fake capability
/// (`user_creative_direction_approval`, `stakeholder_choice`, ...). Current
/// Yardlet represents that as `decision_question` -> NeedsUser. This classifier
/// is deliberately structural: it only recognizes words that name a human
/// judgment/approval, and leaves real tool/license gaps parked as capability
/// gaps. Actor prefixes such as `user_` or `human_` are not enough by
/// themselves because real tool capabilities can use those terms too
/// (`user_agent`, `human_pose_estimation`).
pub fn classify_stale_gate(caps_unsatisfiable: &[String]) -> GateShape {
    let decision_words = [
        "approval",
        "approve",
        "decision",
        "choice",
        "direction",
        "signoff",
        "sign_off",
        "stakeholder",
        "creative",
    ];
    if caps_unsatisfiable.iter().any(|cap| {
        let cap = norm_cap(cap);
        decision_words.iter().any(|word| cap.contains(word))
    }) {
        GateShape::Decision
    } else {
        GateShape::ToolGap
    }
}

/// Whether `worker_id` is an enabled worker declaring EVERY required capability.
/// `required` must already be normalized.
fn worker_declares(workers: &WorkersFile, worker_id: &str, required: &[String]) -> bool {
    workers
        .workers
        .iter()
        .find(|w| w.id == worker_id)
        .filter(|w| w.enabled)
        .map(|w| {
            let have: Vec<String> = w.capabilities.iter().map(|c| norm_cap(c)).collect();
            required.iter().all(|r| have.iter().any(|h| h == r))
        })
        .unwrap_or(false)
}

/// The first enabled worker (declaration order) providing every required
/// capability, if any. `required` must already be normalized.
fn first_capable(workers: &WorkersFile, required: &[String]) -> Option<String> {
    workers
        .workers
        .iter()
        .find(|w| {
            w.enabled && {
                let have: Vec<String> = w.capabilities.iter().map(|c| norm_cap(c)).collect();
                required.iter().all(|r| have.iter().any(|h| h == r))
            }
        })
        .map(|w| w.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workers() -> WorkersFile {
        crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: codex\n  fallback_order: [codex, claude-code]\nworkers:\n  - id: codex\n    capabilities: [image_generation]\n    invocation: { command: codex }\n  - id: claude-code\n    invocation: { command: claude }\n",
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

    #[test]
    fn norm_cap_folds_case_and_separators() {
        assert_eq!(norm_cap(" Image-Generation "), "image_generation");
        assert_eq!(norm_cap("image generation"), "image_generation");
    }

    #[test]
    fn capability_gate_matches_only_declaring_workers() {
        let w = workers();
        let need = vec!["image_generation".to_string()];
        // codex declares it; claude-code does not.
        assert!(worker_declares(&w, "codex", &need));
        assert!(!worker_declares(&w, "claude-code", &need));
        // routes to the declaring worker regardless of declaration order.
        assert_eq!(first_capable(&w, &need).as_deref(), Some("codex"));
        // no worker declares an unknown capability.
        assert!(first_capable(&w, &["sorcery".to_string()]).is_none());
    }

    #[test]
    fn capability_gate_requires_all_listed_capabilities() {
        let w = workers();
        // codex has image_generation but not "video"; both required -> no match.
        let need = vec!["image_generation".to_string(), "video".to_string()];
        assert!(!worker_declares(&w, "codex", &need));
        assert!(first_capable(&w, &need).is_none());
    }

    #[test]
    fn stale_gate_classifier_distinguishes_decision_from_tool_gap() {
        assert_eq!(
            classify_stale_gate(&["user-creative-direction-approval".to_string()]),
            GateShape::Decision
        );
        assert_eq!(
            classify_stale_gate(&["licensed_3d_asset_intake".to_string()]),
            GateShape::ToolGap
        );
        assert_eq!(
            classify_stale_gate(&["human_pose_estimation".to_string()]),
            GateShape::ToolGap
        );
        assert_eq!(
            classify_stale_gate(&["user_agent".to_string()]),
            GateShape::ToolGap
        );
    }

    #[test]
    fn failover_excludes_failed_worker_and_keeps_capability_gate() {
        let w: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: first\n  fallback_order: [first, second, third]\nworkers:\n  - id: first\n    capabilities: [image_generation]\n    invocation: { command: bash }\n  - id: second\n    capabilities: [image_generation]\n    invocation: { command: bash }\n  - id: third\n    invocation: { command: bash }\n",
        )
        .unwrap();
        let task: Task =
            crate::yaml::from_str("id: T\ntitle: t\nrequired_capabilities: [image-generation]\n")
                .unwrap();

        let resolved =
            resolve_failover_worker_for_task(&w, &BillingPolicy::default(), "first", &task)
                .unwrap();
        assert_eq!(resolved.worker_id, "second");

        let w_without_alternate: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: first\n  fallback_order: [first, third]\nworkers:\n  - id: first\n    capabilities: [image_generation]\n    invocation: { command: bash }\n  - id: third\n    invocation: { command: bash }\n",
        )
        .unwrap();
        let err = resolve_failover_worker_for_task(
            &w_without_alternate,
            &BillingPolicy::default(),
            "first",
            &task,
        )
        .unwrap_err()
        .to_string();
        assert!(
            err.contains("no alternate worker") && err.contains("image_generation"),
            "the failed worker must stay excluded and only capable alternatives may be tried: {err}"
        );
    }

    #[test]
    fn preferred_worker_failover_requires_explicit_opt_in() {
        let mut w: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: first\n  fallback_order: [first, second]\nworkers:\n  - id: first\n    invocation: { command: bash }\n  - id: second\n    invocation: { command: bash }\n",
        )
        .unwrap();
        let task: Task = crate::yaml::from_str(
            "id: T\ntitle: t\npreferred_worker: first\nmodel: pinned-model\n",
        )
        .unwrap();

        let error = resolve_failover_worker_for_task(&w, &BillingPolicy::default(), "first", &task)
            .unwrap_err()
            .to_string();

        assert!(
            error.contains("preferred worker") && error.contains("opt-in"),
            "a pinned task must fail closed instead of changing workers: {error}"
        );

        w.routing.allow_preferred_worker_failover = true;
        let resolved =
            resolve_failover_worker_for_task(&w, &BillingPolicy::default(), "first", &task)
                .unwrap();
        assert_eq!(resolved.worker_id, "second");
    }

    #[test]
    fn preferred_worker_initial_resolution_requires_explicit_fallback_opt_in() {
        let mut workers: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: ready\n  fallback_order: [missing, ready]\nworkers:\n  - id: missing\n    invocation: { command: yardlet-definitely-missing-worker-command }\n  - id: ready\n    invocation: { command: bash }\n",
        )
        .unwrap();
        let task: Task = crate::yaml::from_str(
            "id: T\ntitle: t\npreferred_worker: missing\nmodel: pinned-model\n",
        )
        .unwrap();
        let root = std::env::temp_dir().join(format!(
            "yard-routing-preferred-initial-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let workspace = Workspace::at(&root);

        let error =
            resolve_worker_for_task(&workspace, &workers, &BillingPolicy::default(), None, &task)
                .unwrap_err()
                .to_string();
        assert!(error.contains("preferred worker") && error.contains("opt-in"));

        workers.routing.allow_preferred_worker_failover = true;
        let resolved =
            resolve_worker_for_task(&workspace, &workers, &BillingPolicy::default(), None, &task)
                .unwrap();
        assert_eq!(resolved.worker_id, "ready");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn failover_uses_remaining_order_for_readiness_without_readding_failed_worker() {
        let w: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nrouting:\n  default_worker: failed\n  fallback_order: [failed, missing, ready]\nworkers:\n  - id: failed\n    invocation: { command: bash }\n  - id: missing\n    invocation: { command: yardlet-definitely-missing-worker-command }\n  - id: ready\n    invocation: { command: bash }\n",
        )
        .unwrap();
        let task: Task = crate::yaml::from_str("id: T\ntitle: t\n").unwrap();

        let resolved =
            resolve_failover_worker_for_task(&w, &BillingPolicy::default(), "failed", &task)
                .unwrap();

        assert_eq!(resolved.worker_id, "ready");
        assert_eq!(resolved.reason, "fallback (missing not invocable)");
    }
}
