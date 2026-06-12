//! Worker packet compiler.
//!
//! Yard compiles one canonical task contract into a worker-specific packet.
//! Codex packets are execution-oriented; Claude Code packets lean toward
//! planning/review. Both prefer anchors over pasted content to save tokens.

use crate::inspect::RepoSummary;
use crate::schemas::{IntentContract, Task};

pub struct PacketInputs<'a> {
    pub worker_id: &'a str,
    pub task: &'a Task,
    pub intent: Option<&'a IntentContract>,
    pub repo: &'a RepoSummary,
    pub run_dir_rel: &'a str,
    /// A question this worker (or a peer) left on a previous run of this task.
    pub prior_question: Option<&'a str>,
    /// The user's answer to that question, when resuming.
    pub user_answer: Option<&'a str>,
    /// Continuation context for a Partial re-run: the previous run's
    /// checkpoint + unmet acceptance, so the worker continues instead of
    /// redoing finished work.
    pub continuation: Option<&'a str>,
    /// Resolved output language for user-facing content ("ko", "en", ...).
    pub language: &'a str,
    /// Local image paths attached to the goal (also passed natively to the CLI).
    pub images: &'a [String],
    /// Workspace-authored role extension (`.agents/agents/<role>.md`), if any.
    pub role_notes: &'a str,
    /// Inlined workspace rules + anchored leftovers (`load_rules`).
    pub rules: &'a (String, Vec<String>),
    /// The skill catalog (`skill_catalog`).
    pub skills: &'a [(String, String)],
}

/// Find existing local image files referenced in `text` (e.g. a path dragged
/// into the input). Whitespace-separated tokens ending in an image extension
/// that resolve to a real file under `cwd` (or absolute).
pub fn detect_images(text: &str, cwd: &std::path::Path) -> Vec<String> {
    const EXTS: &[&str] = &[".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"];
    let mut out: Vec<String> = Vec::new();
    for raw in text.split_whitespace() {
        let tok =
            raw.trim_matches(|c: char| matches!(c, '"' | '\'' | '`' | ',' | '(' | ')' | '<' | '>'));
        let lower = tok.to_lowercase();
        if !EXTS.iter().any(|e| lower.ends_with(e)) {
            continue;
        }
        let p = if std::path::Path::new(tok).is_absolute() {
            std::path::PathBuf::from(tok)
        } else {
            cwd.join(tok)
        };
        if p.is_file() {
            let s = p.to_string_lossy().into_owned();
            if !out.contains(&s) {
                out.push(s);
            }
        }
    }
    out
}

/// Resolve the output language: an explicit config wins; "auto" detects Korean
/// (Hangul) in the sample text, else falls back to English.
pub fn resolve_language(configured: &str, sample: &str) -> String {
    if !configured.is_empty() && configured != "auto" {
        return configured.to_string();
    }
    if sample
        .chars()
        .any(|c| ('\u{AC00}'..='\u{D7A3}').contains(&c))
    {
        "ko".to_string()
    } else {
        "en".to_string()
    }
}

fn language_name(code: &str) -> &str {
    match code {
        "ko" => "Korean",
        "ja" => "Japanese",
        "zh" => "Chinese",
        "es" => "Spanish",
        "fr" => "French",
        "de" => "German",
        _ => "English",
    }
}

/// A directive telling the worker which language user-facing content should use.
/// Returns empty for English (the default), so packets stay lean.
fn language_directive(code: &str) -> String {
    if code == "en" || code.is_empty() {
        return String::new();
    }
    format!(
        "## Language\n\nWrite all user-facing content in {lang}: the plan summary, task titles, \
         acceptance text, the handoff, any question_for_user, and result `compact_summary`. Keep \
         code, identifiers, file paths, commands, and JSON/YAML keys in English.\n\n",
        lang = language_name(code)
    )
}

// ---- role profiles ---------------------------------------------------------
//
// A role is a prompt mode over a worker (plan §13.4), not a separate agent:
// the same Codex/Claude session works under role-specific guidance derived
// from the task kind. Built-ins below; a workspace extends a role by writing
// `.agents/agents/<role>.md` (appended to that role's packets).

/// The role profile a task runs under, derived from its kind.
pub fn role_for(kind: &str) -> &'static str {
    match kind.trim().to_lowercase().as_str() {
        "review" => "reviewer",
        "research" => "researcher",
        "safety" => "security",
        _ => "builder",
    }
}

fn role_guidance(role: &str) -> &'static str {
    match role {
        "reviewer" => {
            "- You are reviewing, not building: read the code in scope and verify it \
             against the acceptance criteria.\n\
             - Every finding needs evidence \u{2014} file and line plus why it is a problem; \
             verify by reading the actual code, not a diff summary.\n\
             - Rate each finding (critical/major/minor) and propose a concrete fix.\n\
             - Do not rewrite the code; only fix something if it is trivial and clearly \
             inside scope.\n\
             - Your findings go in the required report.md, in clear prose.\n\n"
        }
        "researcher" => {
            "- Answer the task's questions from local evidence: read the code, configs, \
             and docs in scope, and cite a path for every claim.\n\
             - Stay intent-locked: gather what the intent needs; do not expand into new work.\n\
             - Prefer primary sources in the repo over assumptions, and say clearly when \
             evidence is missing.\n\
             - Make no production code changes; your deliverables are the result files \
             and report.md.\n\n"
        }
        "security" => {
            "- Audit the scoped code adversarially: authn/authz gaps, injection, unsafe \
             input handling, secrets in code or logs, dangerous defaults.\n\
             - Every finding needs evidence (file and line) and an exploit rationale; mark \
             severity and give a minimal remediation.\n\
             - Do not commit fixes unless trivial and in scope. Never print or move secret \
             values \u{2014} refer to them by path or name only.\n\
             - Your findings go in the required report.md, in clear prose.\n\n"
        }
        _ => {
            "- Stay strictly inside the allowed scope.\n\
             - Make focused changes and run the listed validation locally.\n\
             - You may use your own subagents/parallelism inside this task; the task \
             scope and the boundaries below bind your whole agent tree.\n\
             - Do not ask for code/architecture/diff review.\n\
             - If you hit a genuine blocker or a gated action, stop and report it.\n\n"
        }
    }
}

/// Workspace-authored extension for a role: `.agents/agents/<role>.md`,
/// appended to that role's packets. Empty when absent.
pub fn load_role_notes(root: &std::path::Path, role: &str) -> String {
    std::fs::read_to_string(
        root.join(crate::state::STATE_DIR)
            .join("agents")
            .join(format!("{role}.md")),
    )
    .unwrap_or_default()
}

// ---- shared harness: rules + skill catalog (docs/harness.md, phase H1) -----
//
// The packet is the only injection point every adapter-connected worker
// shares, so workspace rules and the skill catalog ride in it: rules inlined
// (constraints must not be optional), skills as one catalog line each with
// the body read on demand (Hermes-style progressive loading — SKILL.md is
// level 1, deeper files in the skill folder are level 2).

/// Cap for inlined workspace rules; beyond it the remaining files become
/// anchors so a rule pile-up cannot blow up every packet.
const RULES_INLINE_CAP: usize = 4 * 1024;

/// Concatenate `.agents/rules/*.md` (sorted by filename) up to the cap.
/// Returns (inlined text, anchored leftover paths).
pub fn load_rules(root: &std::path::Path) -> (String, Vec<String>) {
    let dir = root.join(crate::state::STATE_DIR).join("rules");
    let mut files: Vec<_> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    files.sort();
    let mut inlined = String::new();
    let mut anchored = Vec::new();
    for f in files {
        let Ok(text) = std::fs::read_to_string(&f) else {
            continue;
        };
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("rule");
        if inlined.len() + text.len() > RULES_INLINE_CAP {
            anchored.push(format!(".agents/rules/{name}"));
            continue;
        }
        inlined.push_str(&format!("### {name}\n{text}\n\n"));
    }
    (inlined.trim().to_string(), anchored)
}

/// The skill catalog: (name, description) from every
/// `.agents/skills/<name>/SKILL.md` frontmatter, sorted by name.
pub fn skill_catalog(root: &std::path::Path) -> Vec<(String, String)> {
    let dir = root.join(crate::state::STATE_DIR).join("skills");
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let skill_md = entry.path().join("SKILL.md");
        let Ok(text) = std::fs::read_to_string(&skill_md) else {
            continue;
        };
        let dir_name = entry.file_name().to_string_lossy().into_owned();
        let name = frontmatter_field(&text, "name").unwrap_or(dir_name);
        let description = frontmatter_field(&text, "description").unwrap_or_default();
        out.push((name, description));
    }
    out.sort();
    out
}

/// A top-level scalar field from a leading YAML frontmatter block.
fn frontmatter_field(text: &str, key: &str) -> Option<String> {
    let rest = text.strip_prefix("---")?;
    let block = rest.split("\n---").next()?;
    block.lines().find_map(|l| {
        l.strip_prefix(key)
            .and_then(|r| r.trim_start().strip_prefix(':'))
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    })
}

/// Render the shared-harness sections (workspace rules + skill catalog) that
/// every packet — execution and planning — carries identically.
fn push_harness_sections(
    p: &mut String,
    rules: &(String, Vec<String>),
    skills: &[(String, String)],
    required_skills: &[String],
) {
    let (inlined, anchored) = rules;
    if !inlined.is_empty() || !anchored.is_empty() {
        p.push_str("## Workspace rules (always apply)\n\n");
        if !inlined.is_empty() {
            p.push_str(inlined);
            p.push_str("\n\n");
        }
        for a in anchored {
            p.push_str(&format!("- also read and follow: `{a}`\n"));
        }
        if !anchored.is_empty() {
            p.push('\n');
        }
    }
    if !skills.is_empty() {
        p.push_str("## Skills (read on demand)\n\n");
        p.push_str(
            "Reusable procedures for this workspace. Before work a skill clearly applies \
             to, read `.agents/skills/<name>/SKILL.md` first (the folder may hold deeper \
             reference files \u{2014} read those only as needed):\n",
        );
        for (name, desc) in skills {
            p.push_str(&format!("- {name} \u{2014} {desc}\n"));
        }
        if !required_skills.is_empty() {
            p.push_str("\nRequired for THIS task (read before starting):\n");
            for s in required_skills {
                p.push_str(&format!("- `.agents/skills/{s}/SKILL.md`\n"));
            }
        }
        p.push('\n');
    }
}

pub fn compile(inputs: &PacketInputs) -> String {
    let role = role_for(&inputs.task.kind);
    let mut p = String::new();

    p.push_str(&format!("# Yard task packet: {}\n\n", inputs.task.id));
    p.push_str(&format!(
        "You are a hidden Yard worker ({}) acting as the {role}. Do the work below and \
         leave structured artifacts. Console prose is not enough.\n\n",
        inputs.worker_id
    ));

    // Intent / scope.
    if let Some(intent) = inputs.intent {
        p.push_str("## Intent\n\n");
        if !intent.summary.is_empty() {
            p.push_str(&format!("{}\n\n", intent.summary));
        }
        if !intent.allowed_scope.is_empty() {
            p.push_str("Allowed scope:\n");
            for s in &intent.allowed_scope {
                p.push_str(&format!("- {s}\n"));
            }
            p.push('\n');
        }
        if !intent.out_of_scope.is_empty() {
            p.push_str("Out of scope (do not touch):\n");
            for s in &intent.out_of_scope {
                p.push_str(&format!("- {s}\n"));
            }
            p.push('\n');
        }
    }

    // Shared harness: rules every worker must follow + the skill catalog.
    push_harness_sections(&mut p, inputs.rules, inputs.skills, &inputs.task.skills);

    // Task.
    p.push_str("## Task\n\n");
    p.push_str(&format!(
        "**{}** ({})\n\n",
        inputs.task.title, inputs.task.kind
    ));
    if !inputs.task.allowed_scope.is_empty() {
        p.push_str("Task scope:\n");
        for s in &inputs.task.allowed_scope {
            p.push_str(&format!("- {s}\n"));
        }
        p.push('\n');
    }
    if !inputs.task.acceptance.is_empty() {
        p.push_str("Acceptance:\n");
        for a in &inputs.task.acceptance {
            if let Some(s) = a.as_str() {
                p.push_str(&format!("- {s}\n"));
            }
        }
        p.push('\n');
    }

    // Attached images (also passed to the worker natively where supported).
    if !inputs.images.is_empty() {
        p.push_str("## Attached images\n\n");
        p.push_str("The user attached these local images; read/inspect them as needed:\n");
        for img in inputs.images {
            p.push_str(&format!("- {img}\n"));
        }
        p.push('\n');
    }

    // Continuation context: a previous run of this task ended Partial.
    if let Some(cont) = inputs.continuation {
        p.push_str("## Continuing a partial run\n\n");
        p.push_str(
            "A previous run completed PART of this task. Continue from the checkpoint \
             below \u{2014} do not redo finished work; close the remaining gaps and meet \
             the acceptance criteria.\n\n",
        );
        p.push_str(cont.trim());
        p.push_str("\n\n");
    }

    // Resume context: the user answered a question from a prior run.
    if let Some(answer) = inputs.user_answer {
        p.push_str("## Continuing after a question\n\n");
        if let Some(q) = inputs.prior_question {
            p.push_str(&format!("You previously stopped and asked:\n> {q}\n\n"));
        }
        p.push_str(&format!(
            "The user has now answered:\n> {answer}\n\nUse this answer to finish the task. Do \
             not ask the same question again.\n\n"
        ));
    }

    // Evidence anchors (not pasted content).
    p.push_str("## Read anchors (do not load unrelated docs)\n\n");
    p.push_str("- .agents/intent-contract.yaml\n");
    p.push_str("- .agents/work-queue.yaml\n");
    p.push_str(&format!(
        "- {}/evidence/repo-summary.md\n",
        inputs.run_dir_rel
    ));
    p.push('\n');

    // Local environment hint.
    p.push_str("## Local environment\n\n");
    if !inputs.repo.test_commands.is_empty() {
        p.push_str(&format!(
            "Validation candidates: {}\n",
            inputs.repo.test_commands.join(", ")
        ));
    }
    if !inputs.repo.package_managers.is_empty() {
        p.push_str(&format!(
            "Package managers: {}\n",
            inputs.repo.package_managers.join(", ")
        ));
    }
    p.push('\n');

    // Role guidance: how this kind of task is worked, regardless of worker.
    p.push_str(&format!("## How to work \u{2014} role: {role}\n\n"));
    p.push_str(role_guidance(role));
    if !inputs.role_notes.trim().is_empty() {
        p.push_str("### Workspace role notes\n\n");
        p.push_str(inputs.role_notes.trim());
        p.push_str("\n\n");
    }

    // Boundaries: proceed freely on safe work, stop before dangerous actions.
    p.push_str("## Boundaries \u{2014} proceed freely, but stop before dangerous actions\n\n");
    p.push_str(
        "Work freely on safe, reversible, local changes (edit/create files, run tests and \
         linters, local read-only queries) without asking. But STOP and report it \u{2014} set \
         `status` to `needs_user`, explain in `question_for_user` \u{2014} before any of these \
         dangerous or irreversible actions, and do not attempt them:\n\
         - deleting/overwriting files outside the workspace, or mass/irreversible deletion\n\
         - git push, force-push, or tag push\n\
         - deploy, publish, release, or package publish (npm/cargo/pip publish, etc.)\n\
         - production database or infrastructure access or changes\n\
         - sending external messages/emails/posts, or calling external mutating APIs\n\
         - purchases, payments, or account changes\n\
         - reading, writing, or exposing secrets/credentials, or editing CI secrets\n\
         If a needed local action is denied by the sandbox (e.g. network or a package install), \
         also stop and report what you need instead of trying to bypass it.\n\n",
    );

    // Output language.
    p.push_str(&language_directive(inputs.language));

    // Output contract.
    p.push_str("## Required output\n\n");
    p.push_str(&format!(
        "Write these files (paths relative to repo root):\n\
         - `{rd}/result.json`\n\
         - `{rd}/handoff.md`\n\
         - `{rd}/validation.log` (if you ran validation)\n\n",
        rd = inputs.run_dir_rel
    ));
    // Non-code tasks (research/review/safety) deliver findings as prose; require
    // a human-readable report so there's an artifact a person can actually read.
    let kind = inputs.task.kind.trim();
    if !kind.is_empty() && !kind.eq_ignore_ascii_case("implementation") {
        p.push_str(&format!(
            "Because this task is `{kind}` (not implementation), also write \
             `{rd}/report.md` \u{2014} your findings/results in clear prose for a person to \
             read, not just the JSON summary.\n\n",
            rd = inputs.run_dir_rel
        ));
    }
    p.push_str("`result.json` shape:\n\n");
    p.push_str(RESULT_SCHEMA_HINT);
    p
}

/// Compile a planning-gate packet: turn a raw natural-language request into a
/// structured plan written to `planning-result.json` in the run directory.
///
/// The worker authors only the plan content; Yard owns the canonical
/// `.agents/intent-contract.yaml` and `.agents/work-queue.yaml` files it
/// derives from the result. The worker therefore only needs write access to
/// the run directory.
#[allow(clippy::too_many_arguments)]
pub fn compile_planning(
    request: &str,
    repo: &RepoSummary,
    run_dir_rel: &str,
    language: &str,
    worker_guidance: &str,
    images: &[String],
    rules: &(String, Vec<String>),
    skills: &[(String, String)],
) -> String {
    let mut p = String::new();
    p.push_str("# Yard planning gate\n\n");
    p.push_str(
        "You are a hidden Yard planning worker. Turn the request below into a bounded, \
         checkable work contract. Do NOT implement anything in this run.\n\n",
    );

    p.push_str("## Request (verbatim)\n\n");
    p.push_str(request);
    p.push_str("\n\n");

    if !images.is_empty() {
        p.push_str("## Attached images\n\n");
        for img in images {
            p.push_str(&format!("- {img}\n"));
        }
        p.push('\n');
    }

    p.push_str("## Local environment (evidence, not a task list)\n\n");
    p.push_str(&format!("- root: `{}`\n", repo.root));
    if !repo.package_managers.is_empty() {
        p.push_str(&format!(
            "- package managers: {}\n",
            repo.package_managers.join(", ")
        ));
    }
    if !repo.test_commands.is_empty() {
        p.push_str(&format!(
            "- test commands: {}\n",
            repo.test_commands.join(", ")
        ));
    }
    p.push_str(&format!("- top level: {}\n\n", repo.top_level.join(", ")));

    // The same shared harness execution packets carry: planning must respect
    // workspace rules, and seeing the skill catalog lets it assign task.skills.
    push_harness_sections(&mut p, rules, skills, &[]);

    p.push_str("## Rules\n\n");
    p.push_str(
        "- Produce a goal summary, allowed scope, explicit out-of-scope, and a small tree of \
         checkable acceptance criteria.\n\
         - Break the work into a few bounded tasks. Each task: title, kind \
         (research|implementation|review|safety), risk (low|medium|high), preferred_worker \
         (one of the worker ids under Worker selection), model, effort, depends_on, \
         allowed_scope, acceptance.\n\
         - Cut tasks COARSE, along scope boundaries: each task is one bounded worker session \
         with its own disjoint allowed_scope and independently checkable acceptance. Do NOT \
         split work that shares context into micro-tasks \u{2014} the worker can parallelize \
         internally (subagents) within one task. A good split: tasks could run in any order \
         or in parallel without reading each other's changes.\n\
         - Set `depends_on` to the ids of tasks whose OUTPUT this task genuinely needs \
         (earlier tasks only). Leave it empty for independent tasks \u{2014} independent \
         tasks may run in parallel. Order alone is not a dependency.\n\
         - If a workspace skill (see Skills above) clearly applies to a task, list its \
         name in that task's `skills` so the worker reads it before starting.\n\
         - Default model and effort to \"auto\" (let the chosen worker decide). Set them \
         only when a task clearly needs a stronger or cheaper model, or more or less \
         reasoning. Effort levels: minimal|low|medium|high (or \"auto\").\n\
         - Do not expand the goal. Keep out-of-scope strict (payments, auth redesign, production \
         DB, deploy) unless the request demands them.\n\
         - Ask at most 2 questions, and only about product intent / scope / acceptance priority. \
         Put them in `questions_for_user`; do NOT block on them, proceed with explicit \
         assumptions otherwise.\n\
         - Never ask the user to review code, architecture, or diffs.\n\n",
    );

    if !worker_guidance.is_empty() {
        p.push_str("## Worker selection\n\n");
        p.push_str(worker_guidance);
        p.push_str(
            "\nFor each task, set `preferred_worker` to the best fit and give a one-line \
             `worker_rationale`. Weigh the cost bias: prefer the cheaper worker for routine, \
             well-scoped work; reserve the pricier one for hard, ambiguous, or broad tasks.\n\n",
        );
    }

    p.push_str(&language_directive(language));

    p.push_str("## Required output\n\n");
    p.push_str(&format!(
        "Write exactly one file: `{run_dir_rel}/planning-result.json`, matching this shape:\n\n"
    ));
    p.push_str(PLANNING_SCHEMA_HINT);
    p
}

const PLANNING_SCHEMA_HINT: &str = r#"```json
{
  "summary": "One sentence describing the goal in product terms.",
  "allowed_scope": ["..."],
  "out_of_scope": ["..."],
  "acceptance": [
    { "id": "AC-001", "statement": "...", "evidence": ["..."] }
  ],
  "ambiguity": { "score": "low|medium|high", "open_questions": ["..."] },
  "tasks": [
    {
      "id": "YARD-001",
      "title": "...",
      "kind": "research|implementation|review|safety",
      "risk": "low|medium|high",
      "preferred_worker": "<a worker id from Worker selection>",
      "model": "auto",
      "effort": "auto",
      "depends_on": ["YARD-001"],
      "skills": ["<skill name from the catalog, when one applies>"],
      "worker_rationale": "one line: why this worker fits this task",
      "allowed_scope": ["..."],
      "acceptance": ["..."]
    }
  ],
  "questions_for_user": ["a short, high-level question — only if something is genuinely ambiguous"]
}
```
"#;

const RESULT_SCHEMA_HINT: &str = r#"```json
{
  "schema_version": 1,
  "run_id": "<run-id>",
  "task_id": "<task-id>",
  "status": "done | partial | blocked | failed | needs_user",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "Short resume summary for the next run."
}
```
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_korean_and_respects_config() {
        assert_eq!(resolve_language("auto", "관리자 주문 검색"), "ko");
        assert_eq!(resolve_language("auto", "add admin order search"), "en");
        // an explicit config wins over detection
        assert_eq!(resolve_language("en", "관리자"), "en");
        assert_eq!(resolve_language("ko", "english text"), "ko");
    }

    #[test]
    fn directive_empty_for_english_only() {
        assert!(language_directive("en").is_empty());
        assert!(language_directive("").is_empty());
        assert!(language_directive("ko").contains("Korean"));
    }

    #[test]
    fn rules_inline_with_cap_and_anchor_overflow() {
        let root = std::env::temp_dir().join(format!("yard-h1-rules-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let dir = root.join(".agents/rules");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a-style.md"), "# Style\nMatch surrounding code.").unwrap();
        std::fs::write(dir.join("b-big.md"), "x".repeat(5000)).unwrap(); // over the cap
        let (inlined, anchored) = load_rules(&root);
        assert!(inlined.contains("a-style.md"));
        assert!(inlined.contains("Match surrounding code."));
        assert_eq!(anchored, vec![".agents/rules/b-big.md".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn skill_catalog_reads_frontmatter() {
        let root = std::env::temp_dir().join(format!("yard-h1-skills-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let dir = root.join(".agents/skills/deploy-check");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            "---\nname: deploy-check\ndescription: Verify a deploy end to end.\n---\n# body",
        )
        .unwrap();
        let cat = skill_catalog(&root);
        assert_eq!(
            cat,
            vec![(
                "deploy-check".to_string(),
                "Verify a deploy end to end.".to_string()
            )]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn packet_carries_rules_catalog_and_required_skills() {
        let mut task = crate::schemas::Task {
            id: "YARD-1".into(),
            title: "t".into(),
            state: Default::default(),
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            depends_on: vec![],
            skills: vec!["deploy-check".into()],
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
        };
        let repo = crate::inspect::RepoSummary::default();
        let rules = (
            "### team.md\nNever push without review.".to_string(),
            vec![".agents/rules/overflow.md".to_string()],
        );
        let skills = vec![(
            "deploy-check".to_string(),
            "Verify a deploy end to end.".to_string(),
        )];
        let p = compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            prior_question: None,
            user_answer: None,
            continuation: None,
            language: "en",
            images: &[],
            role_notes: "",
            rules: &rules,
            skills: &skills,
        });
        assert!(p.contains("## Workspace rules (always apply)"));
        assert!(p.contains("Never push without review."));
        assert!(p.contains(".agents/rules/overflow.md"));
        assert!(p.contains("## Skills (read on demand)"));
        assert!(p.contains("deploy-check \u{2014} Verify a deploy end to end."));
        assert!(p.contains("Required for THIS task"));
        assert!(p.contains(".agents/skills/deploy-check/SKILL.md"));

        // Planning packets carry the same harness sections.
        task.skills.clear();
        let plan = compile_planning(
            "do a thing",
            &repo,
            ".agents/runs/plan-x",
            "en",
            "",
            &[],
            &rules,
            &skills,
        );
        assert!(plan.contains("## Workspace rules (always apply)"));
        assert!(plan.contains("## Skills (read on demand)"));
    }

    #[test]
    fn kinds_map_to_role_profiles() {
        assert_eq!(role_for("review"), "reviewer");
        assert_eq!(role_for("Research"), "researcher");
        assert_eq!(role_for("safety"), "security");
        assert_eq!(role_for("implementation"), "builder");
        assert_eq!(role_for(""), "builder"); // unknown/empty defaults to builder
    }

    fn packet_for(kind: &str, role_notes: &str) -> String {
        let task = crate::schemas::Task {
            id: "YARD-1".into(),
            title: "t".into(),
            state: Default::default(),
            priority: 0,
            risk: String::new(),
            kind: kind.into(),
            preferred_worker: String::new(),
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
        };
        let repo = crate::inspect::RepoSummary::default();
        compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            prior_question: None,
            user_answer: None,
            continuation: None,
            language: "en",
            images: &[],
            role_notes,
            rules: &(String::new(), vec![]),
            skills: &[],
        })
    }

    #[test]
    fn continuation_section_renders_for_partial_reruns() {
        let task = crate::schemas::Task {
            id: "YARD-1".into(),
            title: "t".into(),
            state: Default::default(),
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
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
        };
        let repo = crate::inspect::RepoSummary::default();
        let p = compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            prior_question: None,
            user_answer: None,
            continuation: Some("- Checkpoint: AC-004 unmet (wrong background)"),
            language: "en",
            images: &[],
            role_notes: "",
            rules: &(String::new(), vec![]),
            skills: &[],
        });
        assert!(p.contains("## Continuing a partial run"));
        assert!(p.contains("do not redo finished work"));
        assert!(p.contains("AC-004 unmet"));
    }

    #[test]
    fn packet_carries_role_guidance_and_workspace_notes() {
        let review = packet_for("review", "");
        assert!(review.contains("role: reviewer"));
        assert!(review.contains("reviewing, not building"));
        assert!(!review.contains("Workspace role notes"));

        let build = packet_for("implementation", "Prefer small commits.");
        assert!(build.contains("role: builder"));
        assert!(build.contains("Workspace role notes"));
        assert!(build.contains("Prefer small commits."));
    }

    #[test]
    fn detects_only_existing_image_paths() {
        let dir = std::env::temp_dir().join(format!("yard-img-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("shot.png"), b"x").unwrap();
        let found = detect_images("see shot.png and notes.txt", &dir);
        assert_eq!(found.len(), 1);
        assert!(found[0].ends_with("shot.png"));
        // a referenced-but-missing image is not attached
        assert!(detect_images("see missing.jpg", &dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
