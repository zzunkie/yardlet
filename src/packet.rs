//! Worker packet compiler.
//!
//! Yardlet compiles one canonical task contract into a worker-specific packet.
//! Codex packets are execution-oriented; Claude Code packets lean toward
//! planning/review. Both prefer anchors over pasted content to save tokens.

use crate::inspect::RepoSummary;
use crate::schemas::{ConversationTurn, IntentContract, Task, TurnRole};

pub struct PacketInputs<'a> {
    pub worker_id: &'a str,
    pub task: &'a Task,
    pub intent: Option<&'a IntentContract>,
    pub repo: &'a RepoSummary,
    pub run_dir_rel: &'a str,
    /// The conversation transcript when resuming a task that paused for the
    /// user (oldest turn first). Empty unless this is a conversational resume.
    pub conversation: &'a [ConversationTurn],
    /// Continuation context for a Partial re-run: the previous run's
    /// checkpoint + unmet acceptance, so the worker continues instead of
    /// redoing finished work.
    pub continuation: Option<&'a str>,
    /// Set when this packet continues the SAME session that just finished
    /// the named task (P1 chaining): the worker should reuse its context.
    pub chained_from: Option<&'a str>,
    /// Resolved output language for user-facing content ("ko", "en", ...).
    pub language: &'a str,
    /// Local image paths attached to the goal (also passed natively to the CLI).
    pub images: &'a [String],
    /// Workspace-authored role extension (`.agents/agents/<role>.md`), if any.
    pub role_notes: &'a str,
    /// The discovered workspace harness (`discover_harness`); projected
    /// per worker at compile time.
    pub harness: &'a Harness,
    /// This task's gated action was already approved by a human for THIS run
    /// (an approval grant is present and will be consumed). The packet then
    /// tells the worker to proceed and finish without re-gating or re-asking,
    /// so a single human decision carries the task to completion.
    pub approved: bool,
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
             - Emit a structured `verdict` (one entry per acceptance criterion, \
             pass/fail + evidence) in result.json; never pass a criterion you could \
             not actually verify.\n\
             - If ANY criterion fails, do NOT just stop at a wall of fail \u{2014} set \
             `status` to `partial` and PROPOSE the fix in `follow_up_tasks`: one \
             implementation task scoped to the failing findings, with `acceptance` \
             listing exactly what must change (a builder, not you, will do it). \
             Yardlet runs that fix, then re-runs THIS review to verify, with bounded \
             retries. If you cannot name a concrete fix, set `status` to `needs_user` \
             and ask instead.\n\
             - Do not rewrite the code yourself; only fix something if it is trivial \
             and clearly inside scope.\n\
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
             - Emit a structured `verdict` (per criterion, pass/fail + evidence) in \
             result.json; if any criterion fails set `status` to `needs_user`, not `done`.\n\
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

// ---- shared harness: discovery + worker-aware projection (H1 + A1) ---------
//
// The packet is the only injection point every adapter-connected worker
// shares, so workspace rules and the skill catalog ride in it: rules inlined
// (constraints must not be optional), skills as one catalog line each with
// the body read on demand (Hermes-style progressive loading — SKILL.md is
// level 1, deeper files in the skill folder are level 2).
//
// A1 (docs/absorption.md): a repo that already has agent assets gets them
// as harness the moment Yardlet runs. Discovery is read-only (nothing is
// copied into .agents/), and projection is worker-aware: a worker that
// natively consumes a source (claude-code reads CLAUDE.md and
// .claude/skills; codex reads AGENTS.md) must not receive it twice.

/// Cap for inlined workspace rules; beyond it the remaining files become
/// anchors so a rule pile-up cannot blow up every packet.
const RULES_INLINE_CAP: usize = 4 * 1024;

/// One always-apply rule source (a file), with the workers that already read
/// it natively (those workers get nothing — token discipline).
pub struct HarnessRule {
    /// Display label and read anchor, repo-relative (e.g. "CLAUDE.md").
    pub origin: String,
    pub text: String,
    pub native_to: Vec<String>,
}

/// One catalog skill, with its SKILL.md anchor path.
pub struct HarnessSkill {
    pub name: String,
    pub description: String,
    /// Repo-relative SKILL.md path (".agents/skills/x/SKILL.md" or borrowed).
    pub path: String,
    pub native_to: Vec<String>,
    /// `core` / `overlay` for Yardlet-managed built-ins. User-owned and
    /// discovered skills are `None` and remain visible under legacy behavior.
    pub managed_layer: Option<String>,
}

/// One project-memory doc: a durable fact or decision about this workspace,
/// surfaced as an index line with the body read on demand (the same
/// progressive-disclosure discipline as skills — v0.8 T1).
pub struct HarnessMemory {
    pub title: String,
    pub summary: String,
    /// Repo-relative anchor (".agents/memory/x.md").
    pub path: String,
    /// Landmark paths this fact depends on (frontmatter `look_at:`). Used by
    /// `yardlet memory` to flag a doc as possibly stale when a landmark changed
    /// in git after the doc did. Empty = no staleness signal.
    pub look_at: Vec<String>,
}

#[derive(Default)]
pub struct Harness {
    pub rules: Vec<HarnessRule>,
    pub skills: Vec<HarnessSkill>,
    pub memory: Vec<HarnessMemory>,
}

pub struct MemoryRefreshTarget {
    pub slug: String,
    pub title: String,
    pub summary: String,
    pub path: String,
    pub look_at: Vec<String>,
}

/// Pull a memory doc's index line — title, one-line summary, and any `look_at:`
/// landmark paths — from `name:`/`title:`, `description:`/`summary:`, and
/// `look_at:`/`paths:` frontmatter when present, else the first `# ` heading and
/// first prose line. Bodies are never inlined.
fn parse_memory_doc(text: &str, fallback: &str) -> (String, String, Vec<String>) {
    let unquote = |s: &str| s.trim().trim_matches(['"', '\'']).to_string();
    let mut title = String::new();
    let mut summary = String::new();
    let mut look_at: Vec<String> = Vec::new();
    let mut lines = text.lines();
    let mut fm: Vec<&str> = Vec::new();
    let mut body: Vec<&str> = Vec::new();
    if text.trim_start().starts_with("---") {
        for l in lines.by_ref() {
            if l.trim() == "---" {
                break; // opening fence
            }
        }
        for l in lines.by_ref() {
            if l.trim() == "---" {
                break; // closing fence
            }
            fm.push(l);
        }
    }
    for l in lines {
        body.push(l);
    }

    let mut i = 0;
    while i < fm.len() {
        let t = fm[i].trim();
        if let Some(v) = t.strip_prefix("name:").or_else(|| t.strip_prefix("title:")) {
            if title.is_empty() {
                title = unquote(v);
            }
        } else if let Some(v) = t
            .strip_prefix("description:")
            .or_else(|| t.strip_prefix("summary:"))
        {
            if summary.is_empty() {
                summary = unquote(v);
            }
        } else if let Some(v) = t
            .strip_prefix("look_at:")
            .or_else(|| t.strip_prefix("paths:"))
        {
            let v = v.trim();
            if v.is_empty() {
                // Multi-line list: consume the following `- item` lines.
                while i + 1 < fm.len() {
                    if let Some(item) = fm[i + 1].trim().strip_prefix("- ") {
                        look_at.push(unquote(item));
                        i += 1;
                    } else {
                        break;
                    }
                }
            } else {
                // Inline: `[a, b]` or `a, b`.
                for part in v.trim_start_matches('[').trim_end_matches(']').split(',') {
                    let p = unquote(part);
                    if !p.is_empty() {
                        look_at.push(p);
                    }
                }
            }
        }
        i += 1;
    }

    if title.is_empty() {
        title = body
            .iter()
            .find_map(|l| l.trim().strip_prefix("# ").map(|h| h.trim().to_string()))
            .unwrap_or_else(|| fallback.to_string());
    }
    if summary.is_empty() {
        summary = body
            .iter()
            .map(|l| l.trim())
            .find(|l| !l.is_empty() && !l.starts_with('#'))
            .unwrap_or("")
            .to_string();
    }
    const CAP: usize = 140;
    if summary.chars().count() > CAP {
        summary = summary.chars().take(CAP - 1).collect::<String>() + "\u{2026}";
    }
    (title, summary, look_at)
}

/// Discover the workspace harness. Yardlet-native `.agents/` sources always
/// load; with `discovery` on (the default), assets the repo already has for
/// other agent tooling join in, in precedence order — `.agents` first, and a
/// canonical-path dedup so symlinked copies (e.g. CLAUDE.md -> AGENTS.md)
/// merge into one entry whose native set covers both readers.
pub fn discover_harness(root: &std::path::Path, discovery: bool) -> Harness {
    let mut h = Harness::default();
    let mut seen_rule_paths: Vec<(std::path::PathBuf, usize)> = Vec::new();

    let push_rule = |h: &mut Harness,
                     seen: &mut Vec<(std::path::PathBuf, usize)>,
                     file: &std::path::Path,
                     origin: String,
                     native: Option<&str>| {
        let Ok(text) = std::fs::read_to_string(file) else {
            return;
        };
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        let canon = file.canonicalize().unwrap_or_else(|_| file.to_path_buf());
        if let Some((_, idx)) = seen.iter().find(|(c, _)| *c == canon) {
            // Same file under another name (symlink): merge the native set.
            if let Some(n) = native {
                let entry = &mut h.rules[*idx];
                if !entry.native_to.iter().any(|w| w == n) {
                    entry.native_to.push(n.to_string());
                }
            }
            return;
        }
        seen.push((canon, h.rules.len()));
        h.rules.push(HarnessRule {
            origin,
            text,
            native_to: native.map(|n| vec![n.to_string()]).unwrap_or_default(),
        });
    };

    // 1. Yardlet-native rules (always on).
    let rules_dir = root.join(crate::state::STATE_DIR).join("rules");
    let mut files: Vec<_> = std::fs::read_dir(&rules_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    files.sort();
    for f in &files {
        let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("rule");
        push_rule(
            &mut h,
            &mut seen_rule_paths,
            f,
            format!(".agents/rules/{name}"),
            None,
        );
    }

    // 1b. Yardlet-native skills (always on).
    collect_skills(
        &mut h,
        &root.join(crate::state::STATE_DIR).join("skills"),
        ".agents/skills",
        &[],
    );

    // 1c. Project memory (always on): durable workspace facts/decisions, each
    // surfaced as one index line with the body read on demand. The generated
    // index.yaml is skipped here (only .md docs are read).
    let mem_dir = root.join(crate::state::STATE_DIR).join("memory");
    let mut mfiles: Vec<_> = std::fs::read_dir(&mem_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    mfiles.sort();
    for f in &mfiles {
        let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("memory");
        // The scaffolded README documents the convention; it is not a fact.
        if name.eq_ignore_ascii_case("README.md") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(f) else {
            continue;
        };
        if text.trim().is_empty() {
            continue;
        }
        let stem = f.file_stem().and_then(|n| n.to_str()).unwrap_or(name);
        let (title, summary, look_at) = parse_memory_doc(&text, stem);
        h.memory.push(HarnessMemory {
            title,
            summary,
            path: format!(".agents/memory/{name}"),
            look_at,
        });
    }

    if discovery {
        // 2. Root instruction files other agents already use.
        push_rule(
            &mut h,
            &mut seen_rule_paths,
            &root.join("AGENTS.md"),
            "AGENTS.md".to_string(),
            Some("codex"),
        );
        push_rule(
            &mut h,
            &mut seen_rule_paths,
            &root.join("CLAUDE.md"),
            "CLAUDE.md".to_string(),
            Some("claude-code"),
        );
        // 3. Claude Code skills (same SKILL.md format).
        collect_skills(
            &mut h,
            &root.join(".claude/skills"),
            ".claude/skills",
            &["claude-code"],
        );
        // 4. Cursor rules.
        let cursor = root.join(".cursor/rules");
        let mut cfiles: Vec<_> = std::fs::read_dir(&cursor)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "md" || x == "mdc"))
            .collect();
        cfiles.sort();
        for f in &cfiles {
            let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("rule");
            push_rule(
                &mut h,
                &mut seen_rule_paths,
                f,
                format!(".cursor/rules/{name}"),
                None,
            );
        }
        // 5. Copilot instructions.
        push_rule(
            &mut h,
            &mut seen_rule_paths,
            &root.join(".github/copilot-instructions.md"),
            ".github/copilot-instructions.md".to_string(),
            None,
        );
    }
    h.skills.sort_by(|a, b| a.name.cmp(&b.name));
    h
}

/// Scan one skills directory into the harness, skipping names already taken
/// by a higher-precedence source and files already seen via symlink.
fn collect_skills(h: &mut Harness, dir: &std::path::Path, prefix: &str, native_to: &[&str]) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let skill_md = entry.path().join("SKILL.md");
        let Ok(text) = std::fs::read_to_string(&skill_md) else {
            continue;
        };
        let dir_name = entry.file_name().to_string_lossy().into_owned();
        let name = frontmatter_field(&text, "name").unwrap_or(dir_name.clone());
        if h.skills.iter().any(|s| s.name == name) {
            continue; // precedence: first source wins
        }
        h.skills.push(HarnessSkill {
            name,
            description: frontmatter_field(&text, "description").unwrap_or_default(),
            path: format!("{prefix}/{dir_name}/SKILL.md"),
            native_to: native_to.iter().map(|s| s.to_string()).collect(),
            managed_layer: std::fs::read_to_string(entry.path().join(".yardlet-managed.yaml"))
                .ok()
                .and_then(|marker| {
                    marker.lines().find_map(|line| {
                        line.strip_prefix("layer:")
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                            .map(str::to_string)
                    })
                }),
        });
    }
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

/// Render the shared-harness sections for one worker: rules it does not
/// already read natively (inlined up to the cap, then anchored) and the
/// skill catalog (minus natively-loaded skills), with required-skill anchors.
fn push_harness_sections(
    p: &mut String,
    harness: &Harness,
    worker_id: &str,
    required_skills: &[String],
    active_managed: &[String],
) {
    let native = |list: &[String]| list.iter().any(|w| w == worker_id);

    let mut inlined = String::new();
    let mut anchored: Vec<&str> = Vec::new();
    for r in &harness.rules {
        if native(&r.native_to) {
            continue;
        }
        if inlined.len() + r.text.len() > RULES_INLINE_CAP {
            anchored.push(&r.origin);
            continue;
        }
        inlined.push_str(&format!("### {}\n{}\n\n", r.origin, r.text));
    }
    let inlined = inlined.trim();
    if !inlined.is_empty() || !anchored.is_empty() {
        p.push_str("## Workspace rules (always apply)\n\n");
        if !inlined.is_empty() {
            p.push_str(inlined);
            p.push_str("\n\n");
        }
        for a in &anchored {
            p.push_str(&format!("- also read and follow: `{a}`\n"));
        }
        if !anchored.is_empty() {
            p.push('\n');
        }
    }

    let skills: Vec<&HarnessSkill> = harness
        .skills
        .iter()
        .filter(|s| !native(&s.native_to))
        .filter(|s| match s.managed_layer.as_deref() {
            Some("core") => true,
            Some("overlay") => active_managed.iter().any(|name| name == &s.name),
            Some(_) => false,
            None => true,
        })
        .collect();
    if !skills.is_empty() {
        p.push_str("## Skills (read on demand)\n\n");
        p.push_str(
            "Reusable procedures for this workspace. Before work a skill clearly applies \
             to, read its SKILL.md first (the folder may hold deeper reference files \
             \u{2014} read those only as needed):\n",
        );
        for s in &skills {
            p.push_str(&format!(
                "- {} \u{2014} {} (`{}`)\n",
                s.name, s.description, s.path
            ));
        }
        if !required_skills.is_empty() {
            p.push_str("\nRequired for THIS task (read before starting):\n");
            for name in required_skills {
                let path = harness
                    .skills
                    .iter()
                    .find(|s| &s.name == name)
                    .map(|s| s.path.clone())
                    .unwrap_or_else(|| format!(".agents/skills/{name}/SKILL.md"));
                p.push_str(&format!("- `{path}`\n"));
            }
        }
        p.push('\n');
    }

    // Project memory: durable workspace facts as an index, bodies on demand
    // (progressive disclosure). Not native to any worker, so always projected.
    if !harness.memory.is_empty() {
        p.push_str("## Project memory (read on demand)\n\n");
        p.push_str(
            "Durable facts and decisions about this workspace. Read an entry's file when it \
             bears on the task:\n",
        );
        for m in &harness.memory {
            if m.summary.is_empty() {
                p.push_str(&format!("- {} (`{}`)\n", m.title, m.path));
            } else {
                p.push_str(&format!(
                    "- {} \u{2014} {} (`{}`)\n",
                    m.title, m.summary, m.path
                ));
            }
        }
        p.push('\n');
    }
}

pub fn compile(inputs: &PacketInputs) -> String {
    let role = role_for(&inputs.task.kind);
    let mut p = String::new();

    p.push_str(&format!("# Yardlet task packet: {}\n\n", inputs.task.id));
    p.push_str(&format!(
        "You are a hidden Yardlet worker ({}) acting as the {role}. Do the work below and \
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

    // Shared harness: rules every worker must follow + the skill catalog,
    // projected for this worker (native sources are skipped).
    push_harness_sections(
        &mut p,
        inputs.harness,
        inputs.worker_id,
        &inputs.task.skills,
        &inputs.task.skills,
    );

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
    if let Some(goal) = &inputs.task.goal {
        p.push_str("Goal condition:\n");
        p.push_str(&format!("- condition: {}\n", goal.condition));
        p.push_str(&format!(
            "- feedback cycles: at most {} ({})\n\n",
            goal.max_feedback_cycles, goal.feedback_policy
        ));
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

    // Hot chain: same session, next task.
    if let Some(prev) = inputs.chained_from {
        p.push_str(&format!(
            "## Same session, next task\n\nYou just completed task {prev} in this session. \
             The packet below is the NEXT task; reuse everything you already know about \
             this repo \u{2014} do not re-explore what you have already read \u{2014} but treat \
             the new task's scope and acceptance as the contract.\n\n"
        ));
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

    // Resume context: a conversation with the user (this task paused as
    // needs_user). Thread the whole exchange back so the worker has memory of
    // it, then let the worker decide whether the latest message is the decision
    // (proceed) or another question (answer it and stay needs_user).
    if !inputs.conversation.is_empty() {
        p.push_str("## Conversation with the user\n\n");
        p.push_str(
            "This task paused to talk with the user. The full exchange so far, oldest \
             first:\n\n",
        );
        for turn in inputs.conversation {
            let who = match turn.role {
                TurnRole::Worker => "you",
                TurnRole::User => "user",
            };
            for (i, line) in turn.text.trim().lines().enumerate() {
                if i == 0 {
                    p.push_str(&format!("> [{who}] {line}\n"));
                } else {
                    p.push_str(&format!(">   {line}\n"));
                }
            }
        }
        p.push_str(
            "\nRespond to the user's latest message:\n\
             - If it gives you the decision or information you needed, proceed and complete the \
             task. Do not redo work finished in an earlier turn.\n\
             - If it is a question, or you still lack what you need to finish, do NOT force \
             completion: put your full user-facing reply (the explanation plus the specific \
             choice you need) in `question_for_user`, keep it self-contained (the user may not \
             see report.md), and return status `needs_user`.\n\n",
        );
    }

    // Evidence anchors (not pasted content).
    p.push_str("## Read anchors (do not load unrelated docs)\n\n");
    p.push_str("- .agents/intent-contract.yaml (read-only)\n");
    p.push_str("- .agents/work-queue.yaml (read-only; do NOT write it)\n");
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
    p.push_str(
        "Yardlet itself captures change evidence around the worker run. Do not initialize a \
         repository, create commits, or otherwise reshape version-control state just to satisfy \
         validation; make the requested file changes and write the required artifacts.\n\n",
    );

    // Human-approved action: a grant is present for this run. Tell the worker to
    // carry the approval through to completion so one decision finishes the task,
    // rather than stopping again to re-ask for the thing already approved.
    if inputs.approved {
        p.push_str("## Approved action\n\n");
        p.push_str(
            "A human has ALREADY approved this task's gated action for this run. Proceed and \
             complete it: do not re-gate it, do not re-ask for approval, and do not return \
             `needs_user` for the action that was approved \u{2014} carrying out the approved \
             action here is exactly what was authorized. Only a genuinely NEW dangerous action \
             beyond that approval (per the boundaries above) still stops for the user; the \
             approved action itself must be finished, not deferred.\n\n",
        );
    }

    // Done-first status rule: non-blocking leftovers should not pause the queue.
    p.push_str("## Completion status rule\n\n");
    p.push_str(
        "Use `status: \"needs_user\"` only when a missing user answer, approval, or gated action \
         blocks the task's acceptance criteria. If the acceptance criteria are met, return \
         `status: \"done\"` even when minor cleanup, optional choices, or adjacent work remains. \
         Record those non-blocking leftovers as notes in the handoff/checkpoint and, when they \
         are real future work, propose them in `follow_up_tasks`.\n\n",
    );

    // Queue ownership (propose -> ingest): workers never write the queue.
    p.push_str("## Proposing follow-up work\n\n");
    p.push_str(
        "If you find adjacent work worth doing later, do NOT edit \
         `.agents/work-queue.yaml` \u{2014} Yardlet owns the queue. PROPOSE it in `result.json` \
         under `follow_up_tasks`: each entry needs a `title` and a `reason` (why it exists), \
         plus optional `kind`, `risk`, `allowed_scope`, `acceptance`, `skills`, `depends_on`, \
         `preferred_worker`, `required_capabilities`, `decision_question`. Yardlet assigns the id \
         and priority, validates, dedups, and enqueues it as a tracked candidate. Stay within \
         THIS task's scope; a follow-up is a candidate for later, not license to expand the \
         current task.\n\n",
    );
    p.push_str(
        "`required_capabilities` names TOOLS A WORKER NEEDS (e.g. image generation) and gates \
         routing to a worker that declares them. A follow-up that is really a HUMAN DECISION \u{2014} \
         a choice or approval only the user can make (pick A vs B, sign off on a direction) \u{2014} \
         is NOT a capability: never invent one like `user-creative-direction-approval` for it. \
         Instead set `decision_question` to what to ask; Yardlet ingests the follow-up as \
         `needs_user` with that question and resumes it once the user answers, instead of parking \
         it Blocked with no resolver. Use `required_capabilities` only for a genuine tool / asset \
         / license gap a worker lacks (there Blocked-until-a-worker-is-added is the right \
         outcome).\n\n",
    );
    p.push_str(
        "If a follow-up must run BEFORE work already queued (e.g. you hit a capability \
         ceiling and a worker with the right `required_capabilities`/`preferred_worker` should \
         take over first), set its `runs_before` to the ids of the existing tasks that depend on \
         it \u{2014} Yardlet makes those tasks wait for it (a true \"insert between\"). For a softer \
         \"just run this next\" nudge without hard dependencies, set `insert: \"next\"`.\n\n",
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
/// The worker authors only proposal content. Yardlet records an immutable
/// draft revision after explicit acceptance, and active intent/queue snapshots
/// only after explicit confirmation. The worker therefore only needs write
/// access to the run directory.
#[allow(clippy::too_many_arguments)]
pub fn compile_planning(
    request: &str,
    current_intent: Option<&IntentContract>,
    repo: &RepoSummary,
    run_dir_rel: &str,
    language: &str,
    worker_guidance: &str,
    images: &[String],
    harness: &Harness,
    planner_worker_id: &str,
) -> String {
    let mut p = String::new();
    p.push_str("# Yardlet planning gate\n\n");
    p.push_str(
        "You are a hidden Yardlet planning worker. Turn the request below into a bounded, \
         checkable replacement proposal. Do NOT implement anything in this run and do not \
         write active intent or queue state.\n\n",
    );

    p.push_str("## Request (verbatim)\n\n");
    p.push_str(request);
    p.push_str("\n\n");

    if let Some(intent) = current_intent {
        p.push_str("## Current intent (same planning thread)\n\n");
        p.push_str(&format!("- id: `{}`\n", intent.id));
        if !intent.summary.is_empty() {
            p.push_str(&format!("- summary: {}\n", intent.summary));
        }
        if !intent.allowed_scope.is_empty() {
            p.push_str("- allowed scope:\n");
            for item in &intent.allowed_scope {
                p.push_str(&format!("  - {item}\n"));
            }
        }
        if !intent.out_of_scope.is_empty() {
            p.push_str("- out of scope:\n");
            for item in &intent.out_of_scope {
                p.push_str(&format!("  - {item}\n"));
            }
        }
        if !intent.acceptance.is_empty() {
            p.push_str("- acceptance:\n");
            for item in &intent.acceptance {
                if let Some(item) = item.as_str() {
                    p.push_str(&format!("  - {item}\n"));
                }
            }
        }
        p.push('\n');
    }

    p.push_str("## Planning input boundary\n\n");
    p.push_str(
        "- The request and, when present, the current intent above are the task context.\n\
         - The local environment below is a bounded repository summary, not permission to mine \
         operational history.\n\
         - Do not inspect or inline `.agents/runs/**`, `worker-output.log`, checkpoints, handoffs, \
         telemetry, or archived intents unless the request or current intent names a specific \
         artifact as required evidence. Preserve all such history in place.\n\
         - Workspace rules, skill entries, and project-memory entries are the harness inputs; \
         follow their progressive read-on-demand instructions.\n\n",
    );

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

    let classification = crate::skills::classify_repo(repo, request);
    p.push_str("## Deterministic repository classification\n\n");
    if classification.no_match {
        p.push_str("- presets: no-match (core only; record as a gap candidate)\n");
    } else {
        p.push_str(&format!(
            "- presets: {}\n",
            classification.presets.join(", ")
        ));
    }
    for evidence in &classification.evidence {
        p.push_str(&format!("- evidence: {evidence}\n"));
    }
    for conflict in &classification.conflicts {
        p.push_str(&format!("- conflict: {conflict}\n"));
    }
    p.push_str("- authority: classification grants no network, secret, browser, push, deploy, or external mutation permission\n\n");

    // The same shared harness execution packets carry: planning must respect
    // workspace rules, and seeing the skill catalog lets it assign task.skills.
    let active_overlays = crate::skills::detect_overlay_skills(request, &classification);
    push_harness_sections(&mut p, harness, planner_worker_id, &[], &active_overlays);

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
         - If any task is high-risk or the plan has 3+ tasks, END with a review-kind \
         task that verifies the intent's acceptance criteria against the workspace \
         (per-criterion pass/fail). If you omit it, Yardlet appends one.\n\
         - Default model and effort to \"auto\" (let the chosen worker decide). Set them \
         only when a task clearly needs a stronger or cheaper model, or more or less \
         reasoning. Effort levels: minimal|low|medium|high (or \"auto\").\n\
         - Do not expand the goal. Keep out-of-scope strict (payments, auth redesign, production \
         DB, deploy) unless the request demands them.\n\
         - Score `ambiguity` honestly: \"high\" means you would still be guessing product \
         behavior or architecture \u{2014} it pauses the run and starts an interview with \
         the user; put what you need answered in `ambiguity.open_questions`.\n\
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
             `worker_rationale`. Follow the profiles' positive and negative boundaries. Use \
             cost as a tie-breaker, not a proxy for task breadth: broad work with executable \
             terminal feedback can still belong to an execution specialist, while bounded \
             work dominated by synthesis, visual interpretation, or judgment can belong to \
             a reasoning specialist. When a separate final verifier exists, prefer a different \
             worker from the builder when one is available.\n\n",
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

/// Compile a skill-authoring packet (docs/skills.md S2/S3). A researcher-role
/// worker studies the subject against this repo and writes a candidate skill to
/// `skill-result.json` in the run dir; Yardlet (not the worker) installs it. This
/// run touches no canonical intent/queue state — the queue isolation S3 wanted.
/// `mode` is `"research"` (propose name + rationale, install nothing) or
/// `"create"` (author the named skill for installation).
pub fn compile_skill(
    mode: &str,
    subject: &str,
    repo: &RepoSummary,
    run_dir_rel: &str,
    language: &str,
    harness: &Harness,
    worker_id: &str,
) -> String {
    let mut p = String::new();
    p.push_str("# Yardlet skill authoring\n\n");
    p.push_str(&format!(
        "You are a hidden Yardlet worker ({worker_id}) acting as the researcher. Author ONE \
         reusable skill \u{2014} a portable SKILL.md (frontmatter + a concise procedure) \u{2014} \
         for THIS repository. Do NOT implement repo changes in this run; your only deliverable \
         is the skill draft written to the result file.\n\n",
    ));

    if mode == "create" {
        p.push_str(&format!(
            "## Skill to create\n\n{subject}\n\nAuthor that skill: the procedure a future \
             worker in this repo should follow for the capability. Keep the name you were given \
             unless it is clearly wrong.\n\n"
        ));
    } else {
        p.push_str(&format!(
            "## Topic to research\n\n{subject}\n\nIdentify the skill this repo needs for that \
             topic, give it a short kebab-case `name`, and draft it. If a skill in the catalog \
             below already covers it, say so in `rationale` and still draft the best version.\n\n"
        ));
    }

    p.push_str("## This repository (evidence)\n\n");
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

    // Show the existing skill catalog so the worker doesn't duplicate one.
    push_harness_sections(
        &mut p,
        harness,
        worker_id,
        &["writing-skills".to_string()],
        &["writing-skills".to_string()],
    );

    p.push_str("## How to write the skill\n\n");
    p.push_str(
        "- Make it a reusable PROCEDURE, not a one-off answer: when to use it, the steps, and \
         how to verify success.\n\
         - Fit it to THIS repo's conventions (the evidence above); cite concrete paths/commands \
         where it helps.\n\
         - Keep it tight \u{2014} a focused half-page beats an exhaustive essay. One skill, one \
         capability; don't duplicate a skill already in the catalog above.\n\
         - `description` is one line for the catalog: what the skill is for, so a planner can \
         match it to a task.\n\
         - Network may be unavailable (sandbox); draft from the repo and your own knowledge, and \
         note in `rationale` if a source you would want is unreachable.\n\n",
    );

    p.push_str(&language_directive(language));

    p.push_str("## Required output\n\n");
    p.push_str(&format!(
        "Write exactly one file: `{run_dir_rel}/skill-result.json`, matching this shape:\n\n"
    ));
    p.push_str(SKILL_SCHEMA_HINT);
    p
}

/// Compile a one-off project-memory authoring packet. The worker writes only a
/// draft JSON file in the isolated run directory; Yardlet core later writes the
/// canonical `.agents/memory` docs through `state.rs`.
pub fn compile_memory(
    mode: &str,
    repo: &RepoSummary,
    run_dir_rel: &str,
    language: &str,
    harness: &Harness,
    worker_id: &str,
    targets: &[MemoryRefreshTarget],
) -> String {
    let mut p = String::new();
    p.push_str("# Yardlet project-memory drafting\n\n");
    p.push_str(&format!(
        "You are a hidden Yardlet worker ({worker_id}) acting as the researcher. Draft \
         project-memory documents for THIS repository. Do NOT edit `.agents/memory/`, \
         `index.yaml`, README files, or any canonical state. Your only deliverable is \
         `{run_dir_rel}/memory-result.json`; Yardlet core writes canonical memory through \
         `src/state.rs` after parsing your draft.\n\n"
    ));

    p.push_str("## This repository (evidence)\n\n");
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

    push_harness_sections(&mut p, harness, worker_id, &[], &[]);

    if mode == "refresh" {
        p.push_str("## Refresh targets\n\n");
        if targets.is_empty() {
            p.push_str("No targets were selected. Return an empty `documents` array.\n\n");
        } else {
            p.push_str(
                "Refresh ONLY the target slugs below. Read each target file and its `look_at` \
                 landmarks before drafting. Keep each returned document's `slug` exactly as \
                 listed so Yardlet can update only the selected canonical file.\n\n",
            );
            for t in targets {
                p.push_str(&format!(
                    "- slug: `{}`\n  path: `{}`\n  title: {}\n",
                    t.slug, t.path, t.title
                ));
                if !t.summary.is_empty() {
                    p.push_str(&format!("  summary: {}\n", t.summary));
                }
                if !t.look_at.is_empty() {
                    p.push_str("  look_at:\n");
                    for path in &t.look_at {
                        p.push_str(&format!("    - `{path}`\n"));
                    }
                }
            }
            p.push('\n');
        }
    } else {
        p.push_str("## Initialize memory\n\n");
        p.push_str(
            "Scan the repo for durable, non-obvious facts or decisions a future worker would \
             otherwise rediscover. Prefer a small starter set over exhaustive notes. Do not \
             copy AGENTS.md rules or facts directly derivable from filenames; memory is for \
             decisions, gotchas, and invariants.\n\n",
        );
    }

    p.push_str("## Drafting rules\n\n");
    p.push_str(
        "- Return one document per durable fact or decision.\n\
         - Use a stable kebab-case `slug`; for refresh, reuse the target slug exactly.\n\
         - `title` and `summary` become the packet index line.\n\
         - `look_at` should list repo-relative landmark paths whose later edits may stale the memory.\n\
         - `body` is Markdown body only: no YAML frontmatter and no top-level `#` heading.\n\
         - If there is nothing worth recording, return an empty `documents` array and explain why in `rationale`.\n\n",
    );

    p.push_str(&language_directive(language));

    p.push_str("## Required output\n\n");
    p.push_str(&format!(
        "Write exactly one file: `{run_dir_rel}/memory-result.json`, matching this shape:\n\n"
    ));
    p.push_str(MEMORY_SCHEMA_HINT);
    p
}

pub fn compile_memory_scout(
    topic: &str,
    brief: &str,
    worker_id: &str,
    run_dir_rel: &str,
) -> String {
    format!(
        "# Yardlet read-only memory scout\n\nYou are a hidden Yardlet worker ({worker_id}) acting as the `{topic}` scout. Inspect the isolated workspace copy for {brief}. The copy is disposable and cannot mutate the live project or canonical `.agents` state. Do not attempt to edit project files. Write exactly one independent report to `{run_dir_rel}/scout-result.json`.\n\nReturn the same JSON shape as project memory drafting:\n\n{MEMORY_SCHEMA_HINT}\nOnly include durable, non-obvious facts. `look_at` paths must be normalized repo-relative paths. An empty `documents` array is valid when no candidate has durable value.\n"
    )
}

const SKILL_SCHEMA_HINT: &str = r#"```json
{
  "name": "kebab-case-skill-name",
  "description": "One line: what this skill is for (planner-matchable).",
  "body": "Markdown procedure. Use headings like ## When to use, ## Steps, ## Verify. This becomes the SKILL.md body verbatim.",
  "rationale": "Why this skill, what gap it fills, and any source you could not reach."
}
```

Do NOT put YAML frontmatter inside `body` — Yardlet writes the `name`/`description`
frontmatter itself. `body` is just the Markdown procedure.
"#;

const MEMORY_SCHEMA_HINT: &str = r#"```json
{
  "documents": [
    {
      "slug": "short-kebab-case-slug",
      "title": "Human-readable memory title",
      "summary": "One-line packet index summary.",
      "look_at": ["src/example.rs", "docs/example.md"],
      "body": "Markdown body only. No YAML frontmatter and no top-level H1."
    }
  ],
  "rationale": "Why these memories were drafted or why none were needed."
}
```
"#;

const PLANNING_SCHEMA_HINT: &str = r#"```json
{
  "summary": "One sentence describing the goal in product terms.",
  "rationale": "Why this complete replacement proposal answers the latest user turn.",
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
      "required_capabilities": ["<a worker capability this task hard-requires; omit if none>"],
      "goal": {
        "condition": "the explicit condition that proves this task complete",
        "max_feedback_cycles": 2,
        "feedback_policy": "inject_failed_checks"
      },
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
  "compact_summary": "Short resume summary for the next run.",
  "verdict": [
    { "criterion_id": "AC-001", "pass": true, "evidence": "path/screenshot + why" }
  ],
  "harness_suggestions": [
    { "kind": "rule|skill", "title": "...", "content": "short, imperative, reusable" }
  ],
  "follow_up_tasks": [
    { "title": "...", "reason": "why this follow-up exists",
      "kind": "implementation|review|...", "risk": "low|medium|high",
      "acceptance": ["..."], "allowed_scope": ["..."], "depends_on": [],
      "preferred_worker": "", "required_capabilities": [],
      "decision_question": "<set ONLY if this is a human choice/approval; Yardlet asks the user, leave \"\" otherwise>",
      "insert": "end|next", "runs_before": [] }
  ]
}
```

`verdict` is REQUIRED for review/safety tasks: one entry per acceptance
criterion you checked, judged against the ACTUAL workspace (read the code,
run it, look at the screenshots) — not a restatement of intent. `pass: false`
with concrete evidence is the whole point; do not pass a criterion you could
not verify. Build tasks may leave `verdict` empty. Fill `harness_suggestions`
only when you learned something reusable about THIS repo. A "skill" suggestion
should be a self-contained procedure (how to do a recurring task in this repo)
that a future worker could follow; a "rule" is a short always-apply constraint.
Leave `follow_up_tasks` empty unless you found adjacent work worth queueing for
later; never edit `.agents/work-queue.yaml` yourself — Yardlet ingests these.
Use `needs_user` only when the question blocks acceptance. If acceptance is met,
finish with `done` and leave non-blocking leftovers as handoff/checkpoint notes
or `follow_up_tasks`.
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
    fn discovery_finds_native_and_borrowed_sources() {
        let root = std::env::temp_dir().join(format!("yard-a1-disc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".agents/rules")).unwrap();
        std::fs::create_dir_all(root.join(".agents/skills/native-skill")).unwrap();
        std::fs::create_dir_all(root.join(".claude/skills/borrowed-skill")).unwrap();
        std::fs::create_dir_all(root.join(".cursor/rules")).unwrap();
        std::fs::create_dir_all(root.join(".github")).unwrap();
        std::fs::write(root.join(".agents/rules/team.md"), "Ours first.").unwrap();
        std::fs::write(root.join("AGENTS.md"), "Repo agent instructions.").unwrap();
        std::fs::write(root.join("CLAUDE.md"), "Claude instructions.").unwrap();
        std::fs::write(
            root.join(".claude/skills/borrowed-skill/SKILL.md"),
            "---\nname: borrowed-skill\ndescription: From claude dir.\n---\nbody",
        )
        .unwrap();
        std::fs::write(
            root.join(".agents/skills/native-skill/SKILL.md"),
            "---\nname: native-skill\ndescription: Ours.\n---\nbody",
        )
        .unwrap();
        std::fs::write(root.join(".cursor/rules/style.mdc"), "Cursor style rule.").unwrap();
        std::fs::write(
            root.join(".github/copilot-instructions.md"),
            "Copilot notes.",
        )
        .unwrap();

        let h = discover_harness(&root, true);
        let origins: Vec<&str> = h.rules.iter().map(|r| r.origin.as_str()).collect();
        assert_eq!(
            origins,
            vec![
                ".agents/rules/team.md",
                "AGENTS.md",
                "CLAUDE.md",
                ".cursor/rules/style.mdc",
                ".github/copilot-instructions.md"
            ]
        );
        let names: Vec<&str> = h.skills.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, vec!["borrowed-skill", "native-skill"]);
        let borrowed = h
            .skills
            .iter()
            .find(|s| s.name == "borrowed-skill")
            .unwrap();
        assert_eq!(borrowed.path, ".claude/skills/borrowed-skill/SKILL.md");
        assert_eq!(borrowed.native_to, vec!["claude-code".to_string()]);

        // Discovery off: only .agents sources remain.
        let h = discover_harness(&root, false);
        assert_eq!(h.rules.len(), 1);
        assert_eq!(h.skills.len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_claude_md_merges_into_one_rule_native_to_both() {
        let root = std::env::temp_dir().join(format!("yard-a1-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("AGENTS.md"), "Shared instructions.").unwrap();
        std::os::unix::fs::symlink(root.join("AGENTS.md"), root.join("CLAUDE.md")).unwrap();

        let h = discover_harness(&root, true);
        assert_eq!(h.rules.len(), 1);
        let r = &h.rules[0];
        assert_eq!(r.origin, "AGENTS.md");
        assert!(r.native_to.contains(&"codex".to_string()));
        assert!(r.native_to.contains(&"claude-code".to_string()));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn discovers_project_memory_as_index_with_bodies_on_demand() {
        // v0.8 Project Memory: .agents/memory/*.md docs are discovered (always
        // on, even with foreign-tool discovery off) and projected as an index —
        // title + one-line summary + anchor — with bodies NEVER inlined.
        let root = std::env::temp_dir().join(format!("yard-mem-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".agents/memory")).unwrap();
        // Frontmatter doc: title/summary from name:/description:, plus a
        // multi-line look_at: landmark list.
        std::fs::write(
            root.join(".agents/memory/decisions.md"),
            "---\nname: v0.8 decisions\ndescription: Loop-engineering tracks and the finalize_run \
             foundation.\nlook_at:\n  - src/run.rs\n  - docs/v0.8-decisions.md\n---\n\n# inner \
             heading\n\nLONGBODY that must not be inlined.",
        )
        .unwrap();
        // Heading-only doc: title from `# `, summary from the first prose line.
        std::fs::write(
            root.join(".agents/memory/conventions.md"),
            "# Coding conventions\n\nMatch the surrounding code; small typed structs.",
        )
        .unwrap();
        // The generated index is skipped (not a .md doc); the scaffolded README
        // documents the convention and is not itself a memory fact.
        std::fs::write(root.join(".agents/memory/index.yaml"), "ignored: true").unwrap();
        std::fs::write(
            root.join(".agents/memory/README.md"),
            "# Project memory\nDocs.",
        )
        .unwrap();

        // Memory is always-on, so discovery=false still finds it (sorted by file).
        let h = discover_harness(&root, false);
        let titles: Vec<&str> = h.memory.iter().map(|m| m.title.as_str()).collect();
        assert_eq!(titles, vec!["Coding conventions", "v0.8 decisions"]);
        assert_eq!(h.memory[1].path, ".agents/memory/decisions.md");
        assert_eq!(
            h.memory[1].look_at,
            vec![
                "src/run.rs".to_string(),
                "docs/v0.8-decisions.md".to_string()
            ]
        );
        assert!(h.memory[0].look_at.is_empty()); // heading-only doc has none
        assert_eq!(
            h.memory[1].summary,
            "Loop-engineering tracks and the finalize_run foundation."
        );
        assert_eq!(
            h.memory[0].summary,
            "Match the surrounding code; small typed structs."
        );

        // The packet projects the index but never the body.
        let mut p = String::new();
        push_harness_sections(&mut p, &h, "codex", &[], &[]);
        assert!(p.contains("## Project memory (read on demand)"));
        assert!(p.contains("v0.8 decisions"));
        assert!(p.contains(".agents/memory/decisions.md"));
        assert!(
            !p.contains("LONGBODY"),
            "memory bodies must stay on-demand, not inlined: {p}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn memory_packet_keeps_worker_to_draft_only() {
        let repo = RepoSummary {
            root: "/tmp/repo".to_string(),
            git: Default::default(),
            package_managers: vec!["cargo".to_string()],
            test_commands: vec!["cargo test".to_string()],
            top_level: vec!["src".to_string(), ".agents".to_string()],
        };
        let h = Harness::default();
        let packet = compile_memory(
            "refresh",
            &repo,
            ".agents/runs/memory-1",
            "en",
            &h,
            "codex",
            &[MemoryRefreshTarget {
                slug: "stale-doc".to_string(),
                title: "Stale doc".to_string(),
                summary: "Needs refresh".to_string(),
                path: ".agents/memory/stale-doc.md".to_string(),
                look_at: vec!["src/lib.rs".to_string()],
            }],
        );
        assert!(packet.contains("Do NOT edit `.agents/memory/`"));
        assert!(packet.contains("`.agents/runs/memory-1/memory-result.json`"));
        assert!(packet.contains("Keep each returned document's `slug` exactly as listed"));
        assert!(packet.contains("\"slug\": \"short-kebab-case-slug\""));
        assert!(packet.contains("src/state.rs"));
    }

    #[test]
    fn projection_skips_natively_consumed_sources() {
        let harness = Harness {
            rules: vec![
                HarnessRule {
                    origin: "CLAUDE.md".into(),
                    text: "Claude-native rule body.".into(),
                    native_to: vec!["claude-code".into()],
                },
                HarnessRule {
                    origin: ".cursor/rules/style.md".into(),
                    text: "Cursor rule body.".into(),
                    native_to: vec![],
                },
            ],
            skills: vec![HarnessSkill {
                name: "borrowed-skill".into(),
                description: "From claude dir.".into(),
                path: ".claude/skills/borrowed-skill/SKILL.md".into(),
                native_to: vec!["claude-code".into()],
                managed_layer: None,
            }],
            memory: vec![],
        };
        let mut for_claude = String::new();
        push_harness_sections(&mut for_claude, &harness, "claude-code", &[], &[]);
        assert!(!for_claude.contains("Claude-native rule body."));
        assert!(for_claude.contains("Cursor rule body."));
        assert!(!for_claude.contains("borrowed-skill"));

        let mut for_codex = String::new();
        push_harness_sections(&mut for_codex, &harness, "codex", &[], &[]);
        assert!(for_codex.contains("Claude-native rule body."));
        assert!(for_codex.contains("borrowed-skill"));
        assert!(for_codex.contains(".claude/skills/borrowed-skill/SKILL.md"));
    }

    #[test]
    fn rules_overflow_becomes_anchors() {
        let harness = Harness {
            rules: vec![
                HarnessRule {
                    origin: "small.md".into(),
                    text: "fits".into(),
                    native_to: vec![],
                },
                HarnessRule {
                    origin: "big.md".into(),
                    text: "x".repeat(5000),
                    native_to: vec![],
                },
            ],
            skills: vec![],
            memory: vec![],
        };
        let mut out = String::new();
        push_harness_sections(&mut out, &harness, "codex", &[], &[]);
        assert!(out.contains("### small.md"));
        assert!(out.contains("also read and follow: `big.md`"));
        assert!(!out.contains("xxxxxxxxxx"));
    }

    #[test]
    fn packet_carries_rules_catalog_and_required_skills() {
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
            skills: vec!["deploy-check".into()],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        };
        let repo = crate::inspect::RepoSummary::default();
        let harness = Harness {
            rules: vec![HarnessRule {
                origin: "team.md".into(),
                text: "Never push without review.".into(),
                native_to: vec![],
            }],
            skills: vec![HarnessSkill {
                name: "deploy-check".into(),
                description: "Verify a deploy end to end.".into(),
                path: ".agents/skills/deploy-check/SKILL.md".into(),
                native_to: vec![],
                managed_layer: None,
            }],
            memory: vec![],
        };
        let p = compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            conversation: &[],
            continuation: None,
            chained_from: None,
            language: "en",
            images: &[],
            role_notes: "",
            harness: &harness,
            approved: false,
        });
        assert!(p.contains("## Workspace rules (always apply)"));
        assert!(p.contains("Never push without review."));
        assert!(p.contains("## Skills (read on demand)"));
        assert!(p.contains("deploy-check \u{2014} Verify a deploy end to end."));
        assert!(p.contains("Required for THIS task"));
        assert!(p.contains(".agents/skills/deploy-check/SKILL.md"));

        // Planning packets carry the same harness sections.
        let plan = compile_planning(
            "do a thing",
            None,
            &repo,
            ".agents/runs/plan-x",
            "en",
            "",
            &[],
            &harness,
            "codex",
        );
        assert!(plan.contains("## Workspace rules (always apply)"));
        assert!(plan.contains("## Skills (read on demand)"));
    }

    #[test]
    fn planning_packet_routes_by_acceptance_surface_and_independent_review() {
        let repo = crate::inspect::RepoSummary::default();
        let plan = compile_planning(
            "plan and build",
            None,
            &repo,
            ".agents/runs/plan-routing",
            "en",
            "- codex: terminal execution.\n- claude-code: synthesis.\n",
            &[],
            &Harness::default(),
            "codex",
        );

        assert!(plan.contains("cost as a tie-breaker, not a proxy for task breadth"));
        assert!(plan.contains("broad work with executable terminal feedback"));
        assert!(plan.contains("prefer a different worker from the builder"));
    }

    #[test]
    fn planning_packet_projects_only_the_supplied_current_intent() {
        let intent = IntentContract {
            schema_version: 1,
            id: "intent-current".into(),
            source: "user".into(),
            raw_request: "original current request".into(),
            summary: "current intent summary".into(),
            allowed_scope: vec!["src/packet.rs".into()],
            out_of_scope: vec!["release".into()],
            acceptance: vec![crate::yaml::Value::String("packet stays bounded".into())],
            images: vec![],
            ambiguity: "low".into(),
            open_questions: vec![],
            clarifications: vec![],
            interview_turns: 0,
            status: "accepted".into(),
        };
        let plan = compile_planning(
            "refine the current plan",
            Some(&intent),
            &crate::inspect::RepoSummary::default(),
            ".agents/runs/plan-current",
            "en",
            "",
            &[],
            &Harness::default(),
            "codex",
        );

        assert!(plan.contains("## Current intent (same planning thread)"));
        assert!(plan.contains("`intent-current`"));
        assert!(plan.contains("current intent summary"));
        assert!(plan.contains("src/packet.rs"));
        assert!(plan.contains("packet stays bounded"));
        assert!(plan.contains("## Planning input boundary"));
        assert!(plan.contains("Do not inspect or inline `.agents/runs/**`"));

        let fresh = compile_planning(
            "start unrelated work",
            None,
            &crate::inspect::RepoSummary::default(),
            ".agents/runs/plan-fresh",
            "en",
            "",
            &[],
            &Harness::default(),
            "codex",
        );
        assert!(!fresh.contains("intent-current"));
        assert!(!fresh.contains("current intent summary"));
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
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        };
        let repo = crate::inspect::RepoSummary::default();
        compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            conversation: &[],
            continuation: None,
            chained_from: None,
            language: "en",
            images: &[],
            role_notes,
            harness: &Harness::default(),
            approved: false,
        })
    }

    fn packet_with_approval(approved: bool) -> String {
        let mut task = crate::schemas::Task {
            id: "YARD-APV".into(),
            title: "delete the legacy table".into(),
            state: Default::default(),
            priority: 0,
            risk: "high".into(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        };
        task.approval = Some(crate::yaml::from_str("required: true").unwrap());
        let repo = crate::inspect::RepoSummary::default();
        compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            conversation: &[],
            continuation: None,
            chained_from: None,
            language: "en",
            images: &[],
            role_notes: "",
            harness: &Harness::default(),
            approved,
        })
    }

    #[test]
    fn approved_packet_tells_worker_to_finish_without_regating() {
        // AC-001: an approved run's packet carries a "proceed and complete, do
        // not re-gate or re-ask" directive; an unapproved one does not.
        let approved = packet_with_approval(true);
        assert!(approved.contains("## Approved action"));
        assert!(approved.contains("ALREADY approved"));
        assert!(approved.contains("do not re-ask for approval"));
        assert!(approved.contains("`needs_user`"));

        let plain = packet_with_approval(false);
        assert!(!plain.contains("## Approved action"));
    }

    #[test]
    fn chained_packet_tells_the_worker_to_reuse_its_context() {
        let task = crate::schemas::Task {
            id: "YARD-2".into(),
            title: "t".into(),
            state: Default::default(),
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            depends_on: vec!["YARD-1".into()],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        };
        let repo = crate::inspect::RepoSummary::default();
        let p = compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            conversation: &[],
            continuation: None,
            chained_from: Some("YARD-1"),
            language: "en",
            images: &[],
            role_notes: "",
            harness: &Harness::default(),
            approved: false,
        });
        assert!(p.contains("## Same session, next task"));
        assert!(p.contains("completed task YARD-1 in this session"));
        assert!(p.contains("do not re-explore"));
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
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: Some(crate::schemas::TaskGoal {
                condition: "all parser checks pass".into(),
                max_feedback_cycles: 2,
                feedback_policy: "inject_failed_checks".into(),
            }),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        };
        let repo = crate::inspect::RepoSummary::default();
        let p = compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            conversation: &[],
            continuation: Some("- Checkpoint: AC-004 unmet (wrong background)"),
            chained_from: None,
            language: "en",
            images: &[],
            role_notes: "",
            harness: &Harness::default(),
            approved: false,
        });
        assert!(p.contains("## Continuing a partial run"));
        assert!(p.contains("do not redo finished work"));
        assert!(p.contains("AC-004 unmet"));
        assert!(p.contains("Goal condition:"));
        assert!(p.contains("all parser checks pass"));
        assert!(p.contains("at most 2 (inject_failed_checks)"));
    }

    #[test]
    fn conversation_renders_transcript_and_lets_the_worker_decide() {
        let task = crate::schemas::Task {
            id: "YARD-1".into(),
            title: "decide renderer".into(),
            state: Default::default(),
            priority: 0,
            risk: String::new(),
            kind: "review".into(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        };
        let repo = crate::inspect::RepoSummary::default();
        let turns = vec![
            ConversationTurn {
                role: TurnRole::Worker,
                text: "Forward+ or GL Compatibility?".into(),
                run_id: "run-1".into(),
                ts: String::new(),
            },
            ConversationTurn {
                role: TurnRole::User,
                text: "what is Forward+?".into(),
                run_id: String::new(),
                ts: String::new(),
            },
        ];
        let p = compile(&PacketInputs {
            worker_id: "codex",
            task: &task,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/run-x",
            conversation: &turns,
            continuation: None,
            chained_from: None,
            language: "en",
            images: &[],
            role_notes: "",
            harness: &Harness::default(),
            approved: false,
        });
        assert!(p.contains("## Conversation with the user"));
        assert!(p.contains("[you] Forward+ or GL Compatibility?"));
        assert!(p.contains("[user] what is Forward+?"));
        // Worker-decides stance: it may answer and stay needs_user, or proceed.
        assert!(p.contains("question_for_user"));
        assert!(p.contains("needs_user"));
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
    fn packet_instructs_done_for_nonblocking_leftovers() {
        let p = packet_for("implementation", "");
        assert!(p.contains("## Completion status rule"));
        assert!(p.contains("Use `status: \"needs_user\"` only when"));
        assert!(p.contains("If the acceptance criteria are met, return"));
        assert!(p.contains("`status: \"done\"`"));
        assert!(p.contains("propose them in `follow_up_tasks`"));
        assert!(p.contains("finish with `done` and leave non-blocking leftovers"));
    }

    #[test]
    fn packet_assigns_change_evidence_to_yardlet_not_git_setup() {
        let p = packet_for("implementation", "");
        assert!(p.contains("Yardlet itself captures change evidence around the worker run."));
        assert!(p.contains("Do not initialize a repository, create commits"));
        assert!(!p.contains("git init"));
        assert!(!p.contains("git commit"));
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
