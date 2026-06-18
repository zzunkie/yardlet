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

pub fn resolve_worker_for_task(
    ws: &Workspace,
    workers: &WorkersFile,
    billing: &BillingPolicy,
    override_w: Option<&str>,
    task: &Task,
) -> Result<Resolved> {
    let overrides = load_overrides(ws);
    let candidate = candidate_for_task(workers, &overrides, override_w, task);
    resolve_candidate(
        workers,
        billing,
        candidate.worker_id,
        candidate.reason,
        candidate.strict,
    )
}

fn resolve_candidate(
    workers: &WorkersFile,
    billing: &BillingPolicy,
    candidate: String,
    source: &'static str,
    strict: bool,
) -> Result<Resolved> {
    // Try order: the candidate, then the configured fallback order.
    let mut order = vec![candidate.clone()];
    if !strict {
        for w in &workers.routing.fallback_order {
            if !order.contains(w) {
                order.push(w.clone());
            }
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

struct Candidate {
    worker_id: String,
    reason: &'static str,
    strict: bool,
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
    if let Some(o) = override_w.filter(|s| !s.is_empty()) {
        Candidate {
            worker_id: o.to_string(),
            reason: "run override",
            strict: false,
        }
    } else if is_image_asset_generation_task(task) {
        Candidate {
            worker_id: "codex".to_string(),
            reason: "hard image/asset generation rule",
            strict: true,
        }
    } else {
        let (worker_id, reason) =
            candidate_for(workers, overrides, None, &task.preferred_worker, &task.kind);
        Candidate {
            worker_id,
            reason,
            strict: false,
        }
    }
}

pub fn apply_forced_worker(task: &mut Task) {
    if is_image_asset_generation_task(task) {
        task.preferred_worker = "codex".to_string();
        task.worker_rationale = Some(
            "hard image/asset generation route: Codex has the image-generation capability"
                .to_string(),
        );
    }
}

fn is_image_asset_generation_task(task: &Task) -> bool {
    if task
        .skills
        .iter()
        .any(|s| matches!(s.as_str(), "imagegen" | "game-assets"))
    {
        return true;
    }

    let text = task_text(task).to_lowercase();
    let explicit = [
        "$imagegen",
        "image generation",
        "generate image",
        "generate an image",
        "create image",
        "create an image",
        "edit image",
        "generate/edit images",
        "asset generation",
        "generate asset",
        "create asset",
        "이미지 생성",
        "이미지를 생성",
        "이미지 만들어",
        "이미지 만들",
        "이미지 편집",
        "이미지 수정",
        "에셋 생성",
        "애셋 생성",
        "에셋 만들",
    ]
    .iter()
    .any(|needle| text.contains(needle));
    if explicit {
        return true;
    }

    let create = [
        "generate",
        "create",
        "draw",
        "design",
        "make",
        "produce",
        "render",
        "생성",
        "만들",
        "그려",
        "디자인",
        "제작",
    ]
    .iter()
    .any(|needle| text.contains(needle));
    let asset = [
        "asset",
        "icon",
        "banner",
        "illustration",
        "sprite",
        "sprite sheet",
        "placeholder art",
        "logo",
        "thumbnail",
        "에셋",
        "애셋",
        "아이콘",
        "배너",
        "일러스트",
        "스프라이트",
        "로고",
        "썸네일",
    ]
    .iter()
    .any(|needle| text.contains(needle));

    create && asset
}

fn task_text(task: &Task) -> String {
    let mut text = format!(
        "{} {} {} {}",
        task.kind,
        task.title,
        task.allowed_scope.join(" "),
        task.skills.join(" ")
    );
    if let Some(rationale) = &task.worker_rationale {
        text.push(' ');
        text.push_str(rationale);
    }
    for acceptance in &task.acceptance {
        text.push(' ');
        if let Ok(yaml) = crate::yaml::to_string(acceptance) {
            text.push_str(&yaml);
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::TaskState;

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

    fn task(title: &str) -> Task {
        Task {
            id: "YARD-001".into(),
            title: title.into(),
            state: TaskState::Queued,
            priority: 10,
            risk: "low".into(),
            kind: "implementation".into(),
            preferred_worker: "claude-code".into(),
            model: String::new(),
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
        }
    }

    #[test]
    fn image_asset_generation_forces_codex_before_planner_or_kind_rules() {
        let w = workers();
        let mut ov = RoutingOverrides::default();
        ov.kind_overrides
            .insert("implementation".into(), "claude-code".into());

        let candidate = candidate_for_task(
            &w,
            &ov,
            None,
            &task("Generate sprite sheet assets for the game"),
        );
        assert_eq!(candidate.worker_id, "codex");
        assert_eq!(candidate.reason, "hard image/asset generation rule");
        assert!(candidate.strict);
    }

    #[test]
    fn explicit_run_override_still_wins_over_image_asset_rule() {
        let w = workers();
        let ov = RoutingOverrides::default();
        let candidate =
            candidate_for_task(&w, &ov, Some("claude-code"), &task("Generate icon assets"));
        assert_eq!(candidate.worker_id, "claude-code");
        assert_eq!(candidate.reason, "run override");
        assert!(!candidate.strict);
    }

    #[test]
    fn image_analysis_does_not_trigger_generation_rule() {
        let w = workers();
        let ov = RoutingOverrides::default();
        let candidate = candidate_for_task(
            &w,
            &ov,
            None,
            &task("Analyze the screenshot and generate CSS to match it"),
        );
        assert_eq!(candidate.worker_id, "claude-code");
        assert_eq!(candidate.reason, "planner preferred");
        assert!(!candidate.strict);
    }
}
