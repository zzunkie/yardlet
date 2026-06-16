//! Explicit skill authoring (docs/skills.md S2/S3): `yard skill research`,
//! `create`, and `apply`. A researcher-role worker drafts a candidate SKILL.md
//! into an ISOLATED run dir; Yard (the deterministic core) is the sole writer
//! that installs it. This path never touches the live `intent-contract.yaml` /
//! `work-queue.yaml` — the queue isolation the S3 deferral called for: it runs
//! a one-off worker (like the planner) but derives no canonical intent/queue.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::Deserialize;

use crate::skills::{self, AuthorOutcome};
use crate::state::{write_str, Workspace};
use crate::{guard, inspect, packet, workers};

/// The worker-authored skill draft (shape of `skill-result.json`).
#[derive(Debug, Default, Deserialize)]
struct SkillResult {
    #[serde(default)]
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    rationale: String,
}

/// What an authoring command did, for a one-line CLI report.
pub struct SkillReport {
    pub run_id: String,
    pub name: String,
    pub lines: Vec<String>,
}

/// Run a researcher worker to draft a skill for `subject` in `mode`
/// (`"research"` | `"create"`). Returns `(run_id, run_dir_rel, worker_id,
/// draft)`. Installs nothing — the caller decides. Isolated: writes only into
/// the run dir, never the intent/queue.
fn draft(
    ws: &Workspace,
    mode: &str,
    subject: &str,
) -> Result<(String, String, String, SkillResult)> {
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;

    let (profile, bin, worker_id) = crate::planner::pick_ready_worker(&workers, &billing, None)?;

    let run_id = format!("skill-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");

    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    let language = packet::resolve_language(&config.language, subject);
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let packet_text = packet::compile_skill(
        mode,
        subject,
        &summary,
        &run_dir_rel,
        &language,
        &harness,
        &worker_id,
    );
    write_str(&workers::packet_path(&run_dir), &packet_text)?;

    let env = guard::sanitized_worker_env_for(&billing, &profile.invocation.pass_env)
        .map_err(|e| anyhow!(e))?;
    let timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
    let outcome = workers::spawn(
        &profile,
        &bin,
        &packet_text,
        &ws.root,
        &env,
        &run_dir.join("worker-output.log"),
        timeout,
        false, // authoring a skill never needs elevated access
        &[],
        None,
        false,
    )?;

    let result_path = run_dir.join("skill-result.json");
    let raw = std::fs::read_to_string(&result_path).with_context(|| {
        format!(
            "skill worker did not write {} ({}). Inspect {}/worker-output.log",
            result_path.display(),
            outcome.note,
            run_dir_rel
        )
    })?;
    let result: SkillResult =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", result_path.display()))?;
    if result.body.trim().is_empty() {
        bail!(
            "skill worker produced an empty body. See {}",
            result_path.display()
        );
    }
    Ok((run_id, run_dir_rel, worker_id, result))
}

/// `yard skill research "<topic>"` — draft a candidate SKILL.md into the run
/// dir and install NOTHING. The user inspects it and runs `yard skill apply
/// <run-id>` to install.
pub fn research(ws: &Workspace, topic: &str) -> Result<SkillReport> {
    let (run_id, run_dir_rel, worker_id, r) = draft(ws, "research", topic)?;
    let name = if r.name.trim().is_empty() {
        topic.trim()
    } else {
        r.name.trim()
    };
    let desc = if r.description.trim().is_empty() {
        name
    } else {
        r.description.trim()
    };
    // Persist a readable draft alongside the JSON for inspection (run-dir only).
    let draft_md = format!(
        "---\nname: {name}\ndescription: {desc}\nsource: candidate\n---\n{}\n",
        r.body.trim()
    );
    write_str(&ws.runs_dir().join(&run_id).join("SKILL.md"), &draft_md)?;

    let mut lines = vec![
        format!("drafted by {worker_id} \u{2014} nothing installed yet"),
        format!("draft: {run_dir_rel}/SKILL.md"),
        format!("install with: yard skill apply {run_id}"),
    ];
    if !r.rationale.trim().is_empty() {
        lines.push(format!("rationale: {}", r.rationale.trim()));
    }
    Ok(SkillReport {
        run_id,
        name: name.to_string(),
        lines,
    })
}

/// `yard skill create <name> [--from "<topic>"]` — author and INSTALL a skill.
/// The user-given `name` wins (predictable); `from` adds context for the worker.
pub fn create(ws: &Workspace, name: &str, from: Option<&str>) -> Result<SkillReport> {
    let subject = match from {
        Some(t) if !t.trim().is_empty() => format!("Name: {name}\n\nContext / topic: {}", t.trim()),
        _ => format!("Name: {name}"),
    };
    let (run_id, _run_dir_rel, _worker_id, r) = draft(ws, "create", &subject)?;
    install(ws, run_id, name, &r.description, &r.body, &r.rationale)
}

/// `yard skill apply <run-id>` — install a skill previously drafted by
/// `yard skill research`. Reads that run's `skill-result.json`; Yard writes it.
pub fn apply(ws: &Workspace, run_id: &str) -> Result<SkillReport> {
    let run_dir = ws.runs_dir().join(run_id);
    let result_path = run_dir.join("skill-result.json");
    let raw = std::fs::read_to_string(&result_path).with_context(|| {
        format!(
            "no skill draft at {} (is the run id right? try `yard skill research` first)",
            result_path.display()
        )
    })?;
    let r: SkillResult =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", result_path.display()))?;
    if r.name.trim().is_empty() || r.body.trim().is_empty() {
        bail!(
            "draft in {} has no name/body to install",
            result_path.display()
        );
    }
    install(
        ws,
        run_id.to_string(),
        r.name.trim(),
        &r.description,
        &r.body,
        &r.rationale,
    )
}

/// Install an authored draft through the deterministic skill writer and build
/// the one-line report.
fn install(
    ws: &Workspace,
    run_id: String,
    name: &str,
    description: &str,
    body: &str,
    rationale: &str,
) -> Result<SkillReport> {
    let mut lines = Vec::new();
    let installed = match skills::install_authored_skill(ws, name, description, body) {
        AuthorOutcome::Written(slug) => {
            lines.push(format!(
                ".agents/skills/{slug}/SKILL.md written (source: created)"
            ));
            slug
        }
        AuthorOutcome::Exists(slug) => {
            lines.push(format!(
                "skill '{slug}' already exists \u{2014} not overwritten (unequip it first to replace)"
            ));
            slug
        }
        AuthorOutcome::Invalid => bail!("authored skill had an empty name or body"),
    };
    if !rationale.trim().is_empty() {
        lines.push(format!("rationale: {}", rationale.trim()));
    }
    Ok(SkillReport {
        run_id,
        name: installed,
        lines,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // `apply` reads a draft's skill-result.json and installs it — exercisable
    // without a live worker by hand-writing the draft file the worker would.
    #[test]
    fn apply_installs_a_drafted_skill_as_created() {
        let ws_root = std::env::temp_dir().join(format!("yard-skill-apply-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&ws_root);
        let ws = Workspace::at(&ws_root);
        let run_id = "skill-20260616-000000";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let draft = serde_json::json!({
            "name": "Browser Evidence",
            "description": "Capture and cite screenshots",
            "body": "## When to use\nVisual checks.\n## Steps\n1. shot\n2. cite",
            "rationale": "3 runs stalled on screenshots",
        });
        std::fs::write(run_dir.join("skill-result.json"), draft.to_string()).unwrap();

        let report = apply(&ws, run_id).unwrap();
        assert_eq!(report.name, "browser-evidence");

        let md = std::fs::read_to_string(
            ws.agents_dir()
                .join("skills")
                .join("browser-evidence")
                .join("SKILL.md"),
        )
        .unwrap();
        assert!(md.contains("name: browser-evidence"));
        assert!(md.contains("description: Capture and cite screenshots"));
        // created, not learned: a user-chosen skill is never auto-pruned.
        assert!(md.contains("source: created"));
        assert!(!md.contains("source: learned"));
        assert!(md.contains("## Steps"));
        assert!(skills::installed(&ws).contains(&"browser-evidence".to_string()));

        // applying again does not clobber the now-installed skill.
        let again = apply(&ws, run_id).unwrap();
        assert!(again.lines.iter().any(|l| l.contains("already exists")));

        let _ = std::fs::remove_dir_all(&ws_root);
    }

    #[test]
    fn apply_errors_on_a_missing_run() {
        let ws_root = std::env::temp_dir().join(format!("yard-skill-miss-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&ws_root);
        let ws = Workspace::at(&ws_root);
        assert!(apply(&ws, "nope-does-not-exist").is_err());
        let _ = std::fs::remove_dir_all(&ws_root);
    }
}
