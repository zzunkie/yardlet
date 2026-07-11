//! Skill toolbox (docs/skills.md S1): classify a repo and equip skills from a
//! local library. Deterministic — no LLM, no worker. The library is read-only;
//! equip places skills under `.agents/skills/` (a symlink on unix, a copy
//! otherwise). Everything here is reversible (`unequip`, git).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::inspect::RepoSummary;
use crate::state::Workspace;

/// Top-level signal file → preset. All matching presets contribute; `core`
/// always applies. A wrong guess is cheap (unequip / git), so this leans
/// toward equipping rather than withholding.
const SIGNALS: &[(&str, &str)] = &[
    ("project.godot", "game"),
    ("package.json", "web-ui"),
    ("Dockerfile", "infra"),
    ("docker-compose.yml", "infra"),
    ("Cargo.toml", "cli-tool"),
    ("go.mod", "backend-api"),
    ("pyproject.toml", "data-science"),
    ("requirements.txt", "data-science"),
];

/// Candidate presets for a repo, from its deterministic summary. `core` first.
pub fn detect_presets(repo: &RepoSummary) -> Vec<String> {
    let mut out = vec!["core".to_string()];
    for f in &repo.top_level {
        for (sig, preset) in SIGNALS {
            if f == sig && !out.iter().any(|p| p == preset) {
                out.push((*preset).to_string());
            }
        }
    }
    out
}

/// Expand `~/` and `~` to $HOME.
fn expand_home(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(h) = std::env::var_os("HOME") {
            return PathBuf::from(h).join(rest);
        }
    }
    if p == "~" {
        if let Some(h) = std::env::var_os("HOME") {
            return PathBuf::from(h);
        }
    }
    PathBuf::from(p)
}

/// A read-only skill library in presets/skills layout: `presets/<name>.skills`
/// (whitespace-separated skill names) and `skills/<name>/SKILL.md`.
pub struct Library {
    root: PathBuf,
}

impl Library {
    /// Open the configured library, if the path is set and is a directory.
    pub fn open(config_path: &str) -> Option<Library> {
        let p = config_path.trim();
        if p.is_empty() {
            return None;
        }
        let root = expand_home(p);
        root.is_dir().then_some(Library { root })
    }

    /// Skill names listed in `presets/<preset>.skills` (whitespace-separated).
    pub fn preset_skills(&self, preset: &str) -> Vec<String> {
        std::fs::read_to_string(self.root.join("presets").join(format!("{preset}.skills")))
            .map(|t| t.split_whitespace().map(str::to_string).collect())
            .unwrap_or_default()
    }

    /// Does the library hold this skill (a `skills/<name>/SKILL.md`)?
    pub fn has(&self, name: &str) -> bool {
        self.skill_dir(name).join("SKILL.md").is_file()
    }

    fn skill_dir(&self, name: &str) -> PathBuf {
        self.root.join("skills").join(name)
    }

    /// Every skill name the library can provide (for `list`).
    pub fn all_skills(&self) -> Vec<String> {
        let mut out: Vec<String> = std::fs::read_dir(self.root.join("skills"))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().join("SKILL.md").is_file())
            .filter_map(|e| e.file_name().to_str().map(str::to_string))
            .collect();
        out.sort();
        out
    }

    /// Resolve an argument that is either a preset (expands to its skills) or a
    /// single skill name (returned as-is).
    pub fn resolve(&self, arg: &str) -> Vec<String> {
        let preset = self.preset_skills(arg);
        if !preset.is_empty() {
            preset
        } else {
            vec![arg.to_string()]
        }
    }
}

/// Skills currently equipped in this workspace (`.agents/skills/<name>/`).
pub fn installed(ws: &Workspace) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(ws.agents_dir().join("skills"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().join("SKILL.md").is_file())
        .filter_map(|e| e.file_name().to_str().map(str::to_string))
        .collect();
    out.sort();
    out
}

/// Skills the detected presets want but that aren't equipped yet (and that the
/// library can actually provide). `suggest = (detected presets' skills ∩
/// library) − installed`.
pub fn suggest(ws: &Workspace, library: &Library, repo: &RepoSummary) -> Vec<String> {
    let have: BTreeSet<String> = installed(ws).into_iter().collect();
    let mut want: BTreeSet<String> = BTreeSet::new();
    for preset in detect_presets(repo) {
        for name in library.preset_skills(&preset) {
            if library.has(&name) && !have.contains(&name) {
                want.insert(name);
            }
        }
    }
    want.into_iter().collect()
}

/// Outcome of equipping one skill.
pub enum EquipResult {
    Added,
    AlreadyPresent,
    NotInLibrary,
    Failed(String),
}

/// Equip skills by name from the library into `.agents/skills/`. Idempotent.
pub fn equip(ws: &Workspace, library: &Library, names: &[String]) -> Vec<(String, EquipResult)> {
    let dir = ws.agents_dir().join("skills");
    let _ = std::fs::create_dir_all(&dir);
    names
        .iter()
        .map(|name| {
            let outcome = if !library.has(name) {
                EquipResult::NotInLibrary
            } else {
                let dst = dir.join(name);
                if dst.join("SKILL.md").is_file() {
                    EquipResult::AlreadyPresent
                } else {
                    match link_or_copy(&library.skill_dir(name), &dst) {
                        Ok(()) => EquipResult::Added,
                        Err(e) => EquipResult::Failed(e),
                    }
                }
            };
            (name.clone(), outcome)
        })
        .collect()
}

/// Remove an equipped skill (the symlink or copied dir). Reversible: re-equip.
pub fn unequip(ws: &Workspace, name: &str) -> Result<bool, String> {
    let dst = ws.agents_dir().join("skills").join(name);
    if !dst.exists() {
        return Ok(false);
    }
    let meta = std::fs::symlink_metadata(&dst).map_err(|e| e.to_string())?;
    let r = if meta.file_type().is_symlink() {
        std::fs::remove_file(&dst)
    } else {
        std::fs::remove_dir_all(&dst)
    };
    r.map(|_| true).map_err(|e| e.to_string())
}

/// Auto-equip on plan/goal when configured: equip core + detected presets'
/// skills that aren't already present. Returns the names newly added (for a
/// one-line report). No-op when `auto_equip` is off or no library is set.
pub fn auto_equip(ws: &Workspace, repo: &RepoSummary) -> Vec<String> {
    let Ok(cfg) = ws.load_config() else {
        return Vec::new();
    };
    if !cfg.auto_equip {
        return Vec::new();
    }
    let Some(library) = Library::open(&cfg.skill_library) else {
        return Vec::new();
    };
    let want = suggest(ws, &library, repo);
    equip(ws, &library, &want)
        .into_iter()
        .filter_map(|(n, o)| matches!(o, EquipResult::Added).then_some(n))
        .collect()
}

// ---- skill score + auto-prune (docs/skills.md S4) --------------------------
//
// The self-correction half of the auto-write loop: judge each skill by the
// runs that DECLARED it, using the deterministic quality signals telemetry
// already records (eval state, structured review verdicts) — not declare
// counts. A skill injected often whose work keeps failing scores DOWN. This
// is what makes auto-writing safe: bad skills get pruned automatically.

/// A skill's aggregate evidence across the runs that declared it.
pub struct SkillScore {
    pub name: String,
    pub runs: u32,
    /// Runs whose task ended Done.
    pub done: u32,
    /// Verdict criteria passed / total across declaring runs that produced a
    /// verdict (the cross-task quality signal when a reviewer judged the work).
    pub verdict_pass: u32,
    pub verdict_total: u32,
}

impl SkillScore {
    /// 0.0–1.0. Prefer verdict pass-through (a real reviewer judged it) when
    /// available, else the Done rate. Unscored (no runs) reads as 1.0 so a
    /// freshly-equipped skill isn't pruned before it's had a chance.
    pub fn value(&self) -> f64 {
        if self.verdict_total > 0 {
            self.verdict_pass as f64 / self.verdict_total as f64
        } else if self.runs > 0 {
            self.done as f64 / self.runs as f64
        } else {
            1.0
        }
    }
}

/// Score every equipped skill from telemetry. Skills with no declaring runs
/// still appear (value 1.0, runs 0) so `review` can show them.
pub fn scores(ws: &Workspace) -> Vec<SkillScore> {
    use std::collections::HashMap;
    let runs = crate::telemetry::read_runs(ws);
    let mut agg: HashMap<String, SkillScore> = HashMap::new();
    for name in installed(ws) {
        agg.insert(
            name.clone(),
            SkillScore {
                name,
                runs: 0,
                done: 0,
                verdict_pass: 0,
                verdict_total: 0,
            },
        );
    }
    for r in &runs {
        for sk in &r.skills {
            if let Some(s) = agg.get_mut(sk) {
                s.runs += 1;
                if r.eval_state == "Done" {
                    s.done += 1;
                }
                if let Some((p, t)) = r.verdict_pass {
                    s.verdict_pass += p as u32;
                    s.verdict_total += t as u32;
                }
            }
        }
    }
    let mut out: Vec<SkillScore> = agg.into_values().collect();
    out.sort_by(|a, b| a.value().partial_cmp(&b.value()).unwrap());
    out
}

/// Minimum runs before a learned skill can be pruned (don't judge on noise).
const PRUNE_MIN_RUNS: u32 = 3;
/// Score floor below which a learned skill is pruned.
const PRUNE_FLOOR: f64 = 0.34;

/// Is this skill workspace-authored/learned (`source: learned`) rather than a
/// library equip? Auto-prune only unequips; for a learned in-repo skill that
/// means deleting the dir, so we only auto-prune learned ones (library skills
/// the user chose stay until they unequip).
pub(crate) fn is_learned(ws: &Workspace, name: &str) -> bool {
    std::fs::read_to_string(ws.agents_dir().join("skills").join(name).join("SKILL.md"))
        .map(|t| t.contains("source: learned"))
        .unwrap_or(false)
}

/// Auto-prune (S4): unequip learned skills that scored below the floor over
/// enough runs. Reversible (git keeps the file). Returns pruned names. No-op
/// when `auto_prune` is off.
pub fn auto_prune(ws: &Workspace) -> Vec<String> {
    if !ws.load_config().map(|c| c.auto_prune).unwrap_or(false) {
        return Vec::new();
    }
    let mut pruned = Vec::new();
    for s in scores(ws) {
        if s.runs >= PRUNE_MIN_RUNS && s.value() < PRUNE_FLOOR && is_learned(ws, &s.name) {
            if let Ok(true) = unequip(ws, &s.name) {
                pruned.push(s.name);
            }
        }
    }
    pruned
}

/// Slugify a suggestion title into a skill directory name.
fn slug(title: &str) -> String {
    let s: String = title
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let s = s.trim_matches('-').to_string();
    let collapsed: String = s
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    collapsed
        .chars()
        .take(48)
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

/// The single deterministic writer for every authored skill: slugify the
/// name, refuse to clobber an existing skill, and write
/// `.agents/skills/<slug>/SKILL.md` with frontmatter (`name`, `description`,
/// `source`) over the given body. Returns the slug if newly written; `None`
/// if the slug or body is empty, or a skill of that slug already exists.
/// `source` distinguishes a `learned` skill (auto-prunable) from a `created`
/// one (user-chosen, kept like a library equip).
fn write_skill(
    ws: &Workspace,
    name_or_title: &str,
    description: &str,
    body: &str,
    source: &str,
) -> Option<String> {
    let name = slug(name_or_title);
    if name.is_empty() || body.trim().is_empty() {
        return None;
    }
    let dst = ws.agents_dir().join("skills").join(&name);
    if dst.exists() {
        return None; // already equipped/learned/created; don't overwrite
    }
    let desc = description.trim();
    let desc = if desc.is_empty() {
        name_or_title.trim()
    } else {
        desc
    };
    let md = format!(
        "---\nname: {name}\ndescription: {desc}\nsource: {source}\n---\n{}\n",
        body.trim()
    );
    std::fs::create_dir_all(&dst).ok()?;
    crate::state::write_str(&dst.join("SKILL.md"), &md).ok()?;
    Some(name)
}

/// Record a worker-proposed skill (H4 / docs/skills.md S3): a run's
/// `harness_suggestions` entry of kind "skill" becomes a real
/// `.agents/skills/<slug>/SKILL.md` — the worker proposed the *content*, Yardlet
/// (the deterministic core) does the writing. Marked `source: learned` so the
/// score loop can later judge and prune it. Returns the slug if newly written.
/// Skips if a skill of that name is already present (no clobber).
pub fn record_suggested_skill(ws: &Workspace, title: &str, content: &str) -> Option<String> {
    write_skill(ws, title, title, content, "learned")
}

/// Outcome of explicitly authoring a skill (`yardlet skill create` / `apply`).
pub enum AuthorOutcome {
    /// Newly written; carries the installed slug.
    Written(String),
    /// A skill of this slug is already equipped; left untouched.
    Exists(String),
    /// The name or body was empty.
    Invalid,
}

/// Install an explicitly authored skill (docs/skills.md S2/S3 `create`/`apply`).
/// The worker authored the content; Yardlet (the deterministic core) is the sole
/// writer. Tagged `source: created` — NOT `learned` — so it is user-chosen and
/// never auto-pruned (it persists like a library equip until `unequip`).
pub fn install_authored_skill(
    ws: &Workspace,
    name: &str,
    description: &str,
    body: &str,
) -> AuthorOutcome {
    let name_slug = slug(name);
    if name_slug.is_empty() || body.trim().is_empty() {
        return AuthorOutcome::Invalid;
    }
    if ws.agents_dir().join("skills").join(&name_slug).exists() {
        return AuthorOutcome::Exists(name_slug);
    }
    match write_skill(ws, name, description, body, "created") {
        Some(s) => AuthorOutcome::Written(s),
        None => AuthorOutcome::Invalid,
    }
}

/// Record every skill-kind suggestion from a run, when `auto_skill` is on.
/// Returns the slugs written (for a one-line report).
pub fn record_run_suggestions(
    ws: &Workspace,
    suggestions: &[crate::schemas::HarnessSuggestion],
) -> Vec<String> {
    if !ws.load_config().map(|c| c.auto_skill).unwrap_or(false) {
        return Vec::new();
    }
    suggestions
        .iter()
        .filter(|s| s.kind.eq_ignore_ascii_case("skill"))
        .filter_map(|s| record_suggested_skill(ws, &s.title, &s.content))
        .collect()
}

/// Record every rule-kind suggestion from a run, when `auto_rule` is on
/// (harness.md H4, the rule half of the learning loop). A rule becomes
/// `.agents/rules/learned-<slug>.md` — plain markdown H1 inlines into every
/// packet (no frontmatter; the `learned-` prefix marks provenance). The worker
/// proposed it; Yardlet (the deterministic core) writes it. No clobber. Returns
/// the slugs written. Unlike learned skills these are not auto-pruned (an
/// always-on rule has no per-task attribution to score), but they are
/// reversible (git) and surfaced by `yardlet harness review`.
pub fn record_run_rules(
    ws: &Workspace,
    suggestions: &[crate::schemas::HarnessSuggestion],
) -> Vec<String> {
    if !ws.load_config().map(|c| c.auto_rule).unwrap_or(false) {
        return Vec::new();
    }
    let dir = ws.agents_dir().join("rules");
    suggestions
        .iter()
        .filter(|s| s.kind.eq_ignore_ascii_case("rule"))
        .filter_map(|s| {
            let name = slug(&s.title);
            if name.is_empty() || s.content.trim().is_empty() {
                return None;
            }
            let file = dir.join(format!("learned-{name}.md"));
            if file.exists() {
                return None; // no clobber
            }
            std::fs::create_dir_all(&dir).ok()?;
            let body = format!("# {}\n\n{}\n", s.title.trim(), s.content.trim());
            crate::state::write_str(&file, &body).ok()?;
            Some(name)
        })
        .collect()
}

/// Learned rule files (`.agents/rules/learned-*.md`) in this workspace, for
/// `yardlet harness review`. Returns bare names (without the `.md`).
pub fn learned_rules(ws: &Workspace) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(ws.agents_dir().join("rules"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(str::to_string))
        .filter(|n| n.starts_with("learned-") && n.ends_with(".md"))
        .map(|n| n.trim_end_matches(".md").to_string())
        .collect();
    out.sort();
    out
}

#[cfg(unix)]
fn link_or_copy(src: &Path, dst: &Path) -> Result<(), String> {
    // Absolute target so the link resolves from anywhere (incl. worktrees).
    let target = src.canonicalize().map_err(|e| e.to_string())?;
    std::os::unix::fs::symlink(target, dst).map_err(|e| e.to_string())
}

#[cfg(not(unix))]
fn link_or_copy(src: &Path, dst: &Path) -> Result<(), String> {
    copy_dir(src, dst).map_err(|e| e.to_string())
}

#[cfg(not(unix))]
fn copy_dir(src: &Path, dst: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for e in std::fs::read_dir(src)? {
        let e = e?;
        let to = dst.join(e.file_name());
        if e.path().is_dir() {
            copy_dir(&e.path(), &to)?;
        } else {
            std::fs::copy(e.path(), to)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo_with(top: &[&str]) -> RepoSummary {
        RepoSummary {
            top_level: top.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn classification_maps_signals_to_presets() {
        assert_eq!(
            detect_presets(&repo_with(&["project.godot", "scenes"])),
            vec!["core", "game"]
        );
        let p = detect_presets(&repo_with(&["Dockerfile", "docker-compose.yml", "go.mod"]));
        assert_eq!(p, vec!["core", "infra", "backend-api"]); // infra not duplicated
        assert_eq!(detect_presets(&repo_with(&["README.md"])), vec!["core"]);
    }

    fn temp_library() -> PathBuf {
        let root = std::env::temp_dir().join(format!("yard-lib-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("presets")).unwrap();
        std::fs::write(
            root.join("presets/core.skills"),
            "session-start planning-gate",
        )
        .unwrap();
        std::fs::write(
            root.join("presets/game.skills"),
            "game-prototype game-assets",
        )
        .unwrap();
        for s in [
            "session-start",
            "planning-gate",
            "game-prototype",
            "game-assets",
        ] {
            std::fs::create_dir_all(root.join("skills").join(s)).unwrap();
            std::fs::write(
                root.join("skills").join(s).join("SKILL.md"),
                format!("---\nname: {s}\ndescription: d\n---\nbody"),
            )
            .unwrap();
        }
        root
    }

    #[test]
    fn skill_score_prefers_verdict_then_done_rate() {
        let s = SkillScore {
            name: "x".into(),
            runs: 4,
            done: 4,
            verdict_pass: 1,
            verdict_total: 4,
        };
        assert!((s.value() - 0.25).abs() < 1e-9); // verdict wins over done rate
        let s = SkillScore {
            name: "x".into(),
            runs: 4,
            done: 3,
            verdict_pass: 0,
            verdict_total: 0,
        };
        assert!((s.value() - 0.75).abs() < 1e-9); // falls back to done rate
        let s = SkillScore {
            name: "x".into(),
            runs: 0,
            done: 0,
            verdict_pass: 0,
            verdict_total: 0,
        };
        assert!((s.value() - 1.0).abs() < 1e-9); // unscored = benefit of the doubt
    }

    #[test]
    fn auto_prune_drops_weak_learned_skills_only() {
        use crate::schemas::HarnessSuggestion;
        use crate::telemetry::RunTelemetry;
        let ws_root = std::env::temp_dir().join(format!("yard-prune-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&ws_root);
        let ws = Workspace::at(&ws_root);
        std::fs::create_dir_all(ws.agents_dir()).unwrap();
        // init a config with auto_prune on
        crate::init::ensure_initialized(&ws_root).unwrap();

        // a learned skill (will score badly) and a library-style equipped skill
        let learned = record_run_suggestions(
            &ws,
            &[HarnessSuggestion {
                kind: "skill".into(),
                title: "Weak One".into(),
                content: "x".into(),
            }],
        );
        assert_eq!(learned, vec!["weak-one"]);
        // a manually-equipped (no source: learned) skill
        let dir = ws.agents_dir().join("skills").join("kept");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            "---\nname: kept\ndescription: d\n---\nb",
        )
        .unwrap();

        // telemetry: weak-one declared in 3 runs, all failed; kept never bad
        let mut tel = |skill: &str, state: &str| RunTelemetry {
            ts: String::new(),
            task_id: "t".into(),
            intent_id: String::new(),
            kind: String::new(),
            risk: String::new(),
            worker: "codex".into(),
            chosen_reason: String::new(),
            result_status: String::new(),
            eval_state: state.into(),
            wall_seconds: 0,
            user_override: None,
            skills: vec![skill.into()],
            verdict_pass: None,
            feedback_cycle: 0,
            max_feedback_cycles: 0,
            feedback_retryable: false,
        };
        for _ in 0..3 {
            crate::telemetry::append_run(&ws, &tel("weak-one", "Failed")).unwrap();
        }
        let _ = &mut tel;

        let pruned = auto_prune(&ws);
        assert_eq!(pruned, vec!["weak-one"]); // learned + below floor + enough runs
        assert!(!installed(&ws).contains(&"weak-one".to_string()));
        assert!(installed(&ws).contains(&"kept".to_string())); // library skill untouched
        let _ = std::fs::remove_dir_all(&ws_root);
    }

    #[test]
    fn record_run_rules_writes_learned_rule_files() {
        use crate::schemas::HarnessSuggestion;
        let ws_root = std::env::temp_dir().join(format!("yard-rules-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&ws_root);
        let ws = Workspace::at(&ws_root);
        crate::init::ensure_initialized(&ws_root).unwrap(); // auto_rule defaults on

        let sugg = vec![
            HarnessSuggestion {
                kind: "rule".into(),
                title: "Always run gdformat before committing".into(),
                content: "Run `gdformat scripts/` and fix diffs before any commit.".into(),
            },
            HarnessSuggestion {
                kind: "skill".into(),
                title: "Not a rule".into(),
                content: "ignored by the rule recorder".into(),
            },
        ];
        let written = record_run_rules(&ws, &sugg);
        assert_eq!(written, vec!["always-run-gdformat-before-committing"]);
        let file = ws
            .agents_dir()
            .join("rules")
            .join("learned-always-run-gdformat-before-committing.md");
        let body = std::fs::read_to_string(&file).unwrap();
        assert!(body.contains("# Always run gdformat before committing"));
        assert!(body.contains("gdformat scripts/"));
        assert_eq!(
            learned_rules(&ws),
            vec!["learned-always-run-gdformat-before-committing"]
        );

        // no clobber on a second proposal of the same title
        assert!(record_run_rules(&ws, &sugg).is_empty());

        // off when auto_rule is disabled
        let mut cfg = ws.load_config().unwrap();
        cfg.auto_rule = false;
        crate::state::save_yaml(&ws.config_path(), &cfg).unwrap();
        let other = vec![HarnessSuggestion {
            kind: "rule".into(),
            title: "Another".into(),
            content: "x".into(),
        }];
        assert!(record_run_rules(&ws, &other).is_empty());

        let _ = std::fs::remove_dir_all(&ws_root);
    }

    #[test]
    fn slug_normalizes_titles() {
        assert_eq!(slug("Godot UI fit to 720p"), "godot-ui-fit-to-720p");
        assert_eq!(
            slug("  Trailing / weird **chars** "),
            "trailing-weird-chars"
        );
        assert_eq!(slug("---"), "");
    }

    #[test]
    fn record_suggested_skill_writes_once_then_no_clobber() {
        use crate::schemas::HarnessSuggestion;
        let ws_root = std::env::temp_dir().join(format!("yard-learn-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&ws_root);
        let ws = Workspace::at(&ws_root);
        std::fs::create_dir_all(ws.agents_dir()).unwrap();

        let name =
            record_suggested_skill(&ws, "Capture Godot screenshots", "1. ...\n2. ...").unwrap();
        assert_eq!(name, "capture-godot-screenshots");
        let md =
            std::fs::read_to_string(ws.agents_dir().join("skills").join(&name).join("SKILL.md"))
                .unwrap();
        assert!(md.contains("name: capture-godot-screenshots"));
        assert!(md.contains("source: learned"));
        assert!(md.contains("description: Capture Godot screenshots"));

        // no clobber on a second proposal of the same title
        assert!(record_suggested_skill(&ws, "Capture Godot screenshots", "different").is_none());

        // empty content / title -> nothing
        assert!(record_suggested_skill(&ws, "x", "   ").is_none());
        assert!(record_suggested_skill(&ws, "---", "body").is_none());

        // record_run_suggestions filters to kind=skill (no config = off -> none)
        let sugg = vec![
            HarnessSuggestion {
                kind: "rule".into(),
                title: "r".into(),
                content: "c".into(),
            },
            HarnessSuggestion {
                kind: "skill".into(),
                title: "New One".into(),
                content: "do it".into(),
            },
        ];
        // no yard.yaml loaded -> auto_skill defaults off via unwrap_or(false)
        assert!(record_run_suggestions(&ws, &sugg).is_empty());
        let _ = std::fs::remove_dir_all(&ws_root);
    }

    #[test]
    fn suggest_and_equip_are_idempotent_and_reversible() {
        let lib_root = temp_library();
        let library = Library::open(lib_root.to_str().unwrap()).unwrap();
        let ws_root = std::env::temp_dir().join(format!("yard-skills-ws-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&ws_root);
        let ws = Workspace::at(&ws_root);
        let repo = repo_with(&["project.godot"]);

        // suggest = core + game skills, none installed yet.
        let mut s = suggest(&ws, &library, &repo);
        s.sort();
        assert_eq!(
            s,
            vec![
                "game-assets",
                "game-prototype",
                "planning-gate",
                "session-start"
            ]
        );

        // equip game preset.
        let r = equip(&ws, &library, &library.resolve("game"));
        assert!(r.iter().all(|(_, o)| matches!(o, EquipResult::Added)));
        let mut inst = installed(&ws);
        inst.sort();
        assert_eq!(inst, vec!["game-assets", "game-prototype"]);

        // idempotent: re-equip is AlreadyEquipped.
        let r = equip(&ws, &library, &["game-prototype".to_string()]);
        assert!(matches!(r[0].1, EquipResult::AlreadyPresent));

        // suggest shrinks by the equipped game skills.
        let mut s = suggest(&ws, &library, &repo);
        s.sort();
        assert_eq!(s, vec!["planning-gate", "session-start"]);

        // unknown skill -> NotInLibrary.
        let r = equip(&ws, &library, &["does-not-exist".to_string()]);
        assert!(matches!(r[0].1, EquipResult::NotInLibrary));

        // reversible.
        assert!(unequip(&ws, "game-prototype").unwrap());
        assert_eq!(installed(&ws), vec!["game-assets"]);
        assert!(!unequip(&ws, "game-prototype").unwrap()); // already gone

        let _ = std::fs::remove_dir_all(&lib_root);
        let _ = std::fs::remove_dir_all(&ws_root);
    }
}
