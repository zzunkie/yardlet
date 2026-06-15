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

/// A read-only skill library in internal-tool layout: `presets/<name>.skills`
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

/// Record a worker-proposed skill (H4 / docs/skills.md S3): a run's
/// `harness_suggestions` entry of kind "skill" becomes a real
/// `.agents/skills/<slug>/SKILL.md` — the worker proposed the *content*, Yard
/// (the deterministic core) does the writing. Marked `source: learned` so the
/// score loop can later judge and prune it. Returns the slug if newly written.
/// Skips if a skill of that name is already present (no clobber).
pub fn record_suggested_skill(ws: &Workspace, title: &str, content: &str) -> Option<String> {
    let name = slug(title);
    if name.is_empty() || content.trim().is_empty() {
        return None;
    }
    let dst = ws.agents_dir().join("skills").join(&name);
    if dst.exists() {
        return None; // already equipped/learned; don't overwrite
    }
    let body = format!(
        "---\nname: {name}\ndescription: {}\nsource: learned\n---\n{}\n",
        title.trim(),
        content.trim()
    );
    std::fs::create_dir_all(&dst).ok()?;
    crate::state::write_str(&dst.join("SKILL.md"), &body).ok()?;
    Some(name)
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
