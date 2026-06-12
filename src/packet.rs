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
    /// Resolved output language for user-facing content ("ko", "en", ...).
    pub language: &'a str,
    /// Local image paths attached to the goal (also passed natively to the CLI).
    pub images: &'a [String],
    /// Workspace-authored role extension (`.agents/agents/<role>.md`), if any.
    pub role_notes: &'a str,
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
pub fn compile_planning(
    request: &str,
    repo: &RepoSummary,
    run_dir_rel: &str,
    language: &str,
    worker_guidance: &str,
    images: &[String],
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
            language: "en",
            images: &[],
            role_notes,
        })
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
