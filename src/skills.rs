//! Skill toolbox (docs/skills.md S1): classify a repo and equip skills from a
//! local library. Deterministic — no LLM, no worker. The managed bundle is
//! embedded and placed through the canonical no-clobber writer; an optional
//! external library stays read-only. Everything is reversible (`unequip`, git).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::Deserialize;

use crate::inspect::RepoSummary;
use crate::state::Workspace;

const BUNDLE_MANIFEST: &str = include_str!("../assets/builtin-skills/manifest.yaml");
const SUPERPOWERS_LICENSE: &str =
    include_str!("../assets/builtin-skills/licenses/obra-superpowers-MIT.txt");

macro_rules! builtin_files {
    ($(($name:literal, $file:literal)),* $(,)?) => {
        const BUILTIN_FILES: &[(&str, &str, &str)] = &[
            $(($name, $file, include_str!(concat!("../assets/builtin-skills/skills/", $name, "/", $file)))),*
        ];
    };
}

builtin_files![
    ("test-driven-development", "SKILL.md"),
    ("test-driven-development", "testing-anti-patterns.md"),
    ("systematic-debugging", "SKILL.md"),
    ("systematic-debugging", "root-cause-tracing.md"),
    ("systematic-debugging", "defense-in-depth.md"),
    ("systematic-debugging", "condition-based-waiting.md"),
    ("systematic-debugging", "condition-based-waiting-example.ts"),
    ("systematic-debugging", "find-polluter.sh"),
    ("verification-before-completion", "SKILL.md"),
    ("writing-plans", "SKILL.md"),
    ("writing-plans", "plan-document-reviewer-prompt.md"),
    ("requesting-code-review", "SKILL.md"),
    ("requesting-code-review", "code-reviewer.md"),
    ("receiving-code-review", "SKILL.md"),
    ("finishing-a-development-branch", "SKILL.md"),
    ("writing-skills", "SKILL.md"),
    ("writing-skills", "persuasion-principles.md"),
    ("mcp-builder", "SKILL.md"),
    ("mcp-builder", "LICENSE.txt"),
    ("mcp-builder", "reference/evaluation.md"),
    ("mcp-builder", "reference/mcp_best_practices.md"),
    ("mcp-builder", "reference/node_mcp_server.md"),
    ("mcp-builder", "reference/python_mcp_server.md"),
    ("webapp-testing", "SKILL.md"),
    ("webapp-testing", "LICENSE.txt"),
    ("webapp-testing", "scripts/with_server.py"),
    ("webapp-testing", "examples/console_logging.py"),
    ("webapp-testing", "examples/element_discovery.py"),
    ("webapp-testing", "examples/static_html_automation.py"),
    ("frontend-design", "SKILL.md"),
    ("frontend-design", "LICENSE.txt"),
];

#[derive(Debug, Deserialize)]
struct BundleManifest {
    library: String,
    sources: BTreeMap<String, BundleSource>,
    members: Vec<BundleMember>,
}

#[derive(Debug, Deserialize)]
struct BundleSource {
    commit: String,
    license: String,
}

#[derive(Debug, Deserialize)]
struct BundleMember {
    id: String,
    name: String,
    layer: String,
    slot: String,
    activation: String,
    source: String,
    source_path: String,
    license_blob: String,
}

fn bundle_manifest() -> BundleManifest {
    serde_yaml_ng::from_str(BUNDLE_MANIFEST).expect("embedded built-in manifest must be valid")
}

fn builtin_member(name: &str) -> Option<BundleMember> {
    bundle_manifest()
        .members
        .into_iter()
        .find(|m| m.name == name)
}

pub fn builtin_names() -> Vec<String> {
    let mut names: Vec<_> = bundle_manifest()
        .members
        .into_iter()
        .map(|m| m.name)
        .collect();
    names.sort();
    names
}

pub fn builtin_layer(name: &str) -> Option<String> {
    builtin_member(name).map(|m| m.layer)
}

fn builtin_names_for_slot(slot: &str) -> Vec<String> {
    let mut names: Vec<_> = bundle_manifest()
        .members
        .into_iter()
        .filter(|m| m.layer == "core" && slot == "core" || m.slot == slot)
        .map(|m| m.name)
        .collect();
    names.sort();
    names
}

fn builtin_files_for(name: &str) -> Option<Vec<(String, String)>> {
    let manifest = bundle_manifest();
    let member = manifest.members.iter().find(|m| m.name == name)?;
    let source = &manifest.sources[&member.source];
    let mut files: Vec<(String, String)> = BUILTIN_FILES
        .iter()
        .filter(|(member_name, _, _)| *member_name == name)
        .map(|(_, relative, contents)| ((*relative).to_string(), (*contents).to_string()))
        .collect();
    if member.source == "obra-superpowers" {
        files.push(("LICENSE.txt".into(), SUPERPOWERS_LICENSE.into()));
    }
    files.push((
        ".yardlet-managed.yaml".into(),
        format!(
            "schema_version: 1\nlibrary: {}\nid: {}\nname: {}\nlayer: {}\nslot: {}\nactivation: {:?}\nsource: {}\ncommit: {}\nsource_path: {}\nlicense: {}\nlicense_blob: {}\n",
            manifest.library,
            member.id,
            member.name,
            member.layer,
            member.slot,
            member.activation,
            member.source,
            source.commit,
            member.source_path,
            source.license,
            member.license_blob,
        ),
    ));
    Some(files)
}

/// Install selected managed built-ins through the same no-clobber canonical
/// writer as authored skills. Existing user-owned directories always win.
pub fn ensure_builtin_names(ws: &Workspace, names: &[String]) -> Result<Vec<String>> {
    let metadata = vec![
        ("manifest.yaml".into(), BUNDLE_MANIFEST.into()),
        (
            "licenses/obra-superpowers-MIT.txt".into(),
            SUPERPOWERS_LICENSE.into(),
        ),
    ];
    let _ = crate::state::place_skill_files_no_clobber(ws, ".yardlet-managed-bundle", &metadata)?;
    let mut added = Vec::new();
    let wanted: BTreeSet<_> = names.iter().cloned().collect();
    for name in wanted {
        let Some(files) = builtin_files_for(&name) else {
            continue;
        };
        if crate::state::place_skill_files_no_clobber(ws, &name, &files)? {
            added.push(name);
        }
    }
    Ok(added)
}

pub fn ensure_builtin_core(ws: &Workspace) -> Result<Vec<String>> {
    ensure_builtin_names(ws, &builtin_names_for_slot("core"))
}

const PRESETS: &[&str] = &[
    "agent-tooling",
    "backend-api",
    "cli-rust",
    "data-ml",
    "desktop-media",
    "docs-knowledge",
    "fullstack-monorepo",
    "game-godot",
    "gitops-infra",
    "native-mobile",
    "web-ui",
];

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Classification {
    pub presets: Vec<String>,
    pub evidence: Vec<String>,
    pub conflicts: Vec<String>,
    pub no_match: bool,
}

fn read_lower(root: &Path, relative: &str) -> String {
    if !manifest_exists(root, relative) {
        return String::new();
    }
    std::fs::read_to_string(root.join(relative))
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn manifest_exists(root: &Path, relative: &str) -> bool {
    if !root.join(relative).is_file() {
        return false;
    }
    let is_repo = std::process::Command::new("git")
        .args(["rev-parse", "--is-inside-work-tree"])
        .current_dir(root)
        .output()
        .is_ok_and(|output| output.status.success());
    if !is_repo {
        return true;
    }
    std::process::Command::new("git")
        .args(["ls-files", "--error-unmatch", "--", relative])
        .current_dir(root)
        .output()
        .is_ok_and(|output| output.status.success())
}

fn has_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| text.contains(needle))
}

fn has_path(root: &Path, candidates: &[&str]) -> bool {
    candidates
        .iter()
        .any(|candidate| root.join(candidate).exists())
}

const MAX_SIGNAL_DEPTH: usize = 4;
const MAX_SIGNAL_DIRECTORIES: usize = 64;
const MAX_SIGNAL_ENTRIES_PER_DIRECTORY: usize = 400;

fn ignored_signal_directory(name: &str) -> bool {
    name.starts_with('.')
        || matches!(
            name,
            "build" | "coverage" | "dist" | "node_modules" | "out" | "target"
        )
}

fn walk_signals(root: &Path) -> Vec<String> {
    fn walk(
        root: &Path,
        dir: &Path,
        depth: usize,
        directories_visited: &mut usize,
        out: &mut Vec<String>,
    ) {
        if depth > MAX_SIGNAL_DEPTH || *directories_visited >= MAX_SIGNAL_DIRECTORIES {
            return;
        }
        *directories_visited += 1;
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.retain(|entry| {
            let is_directory = entry
                .file_type()
                .map(|kind| kind.is_dir())
                .unwrap_or_else(|_| entry.path().is_dir());
            let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
            !is_directory || !ignored_signal_directory(&name)
        });
        entries.sort_by_key(|entry| entry.file_name());
        entries.truncate(MAX_SIGNAL_ENTRIES_PER_DIRECTORY);
        for entry in entries {
            let path = entry.path();
            let is_directory = path.is_dir();
            let Ok(relative) = path.strip_prefix(root) else {
                continue;
            };
            let relative = relative.to_string_lossy().replace('\\', "/");
            if relative == ".agents"
                || relative.starts_with(".agents/")
                || relative.starts_with(".git/")
                || relative.starts_with("target/")
                || relative.starts_with("node_modules/")
            {
                continue;
            }
            out.push(relative.to_ascii_lowercase());
            if is_directory {
                walk(root, &path, depth + 1, directories_visited, out);
            }
        }
    }
    let mut out = Vec::new();
    let mut directories_visited = 0;
    walk(root, root, 0, &mut directories_visited, &mut out);
    out.sort();
    out
}

fn explicit_signal(text: &str, preset: &str) -> (bool, bool) {
    let lower = text.to_ascii_lowercase();
    let negative = [
        format!("preset:-{preset}"),
        format!("no {preset}"),
        format!("without {preset}"),
        format!("{preset} 사용 금지"),
        format!("{preset} 제외"),
        format!("{preset} 비활성"),
        format!("{preset} 사용하지"),
    ]
    .iter()
    .any(|pattern| lower.contains(pattern));
    let positive = [
        format!("preset:+{preset}"),
        format!("preset:{preset}"),
        format!("use {preset}"),
        format!("enable {preset}"),
        format!("{preset} 사용"),
        format!("{preset} 활성"),
        format!("{preset} 적용"),
    ]
    .iter()
    .any(|pattern| lower.contains(pattern));
    (positive, negative)
}

/// Deterministic multi-signal repository classifier. Manifest proposals only
/// become presets after their distinguishing path/script signal is present.
/// Explicit negative always wins, including an explicit positive conflict.
pub fn classify_repo(repo: &RepoSummary, explicit: &str) -> Classification {
    let root = Path::new(&repo.root);
    let cargo = read_lower(root, "Cargo.toml");
    let package = read_lower(root, "package.json");
    let pyproject = read_lower(root, "pyproject.toml");
    let go_mod = read_lower(root, "go.mod");
    let paths = walk_signals(root);
    let path_contains = |needles: &[&str]| paths.iter().any(|p| has_any(p, needles));
    let code_manifest = [
        "Cargo.toml",
        "package.json",
        "pyproject.toml",
        "go.mod",
        "project.godot",
        "Chart.yaml",
    ]
    .iter()
    .any(|path| manifest_exists(root, path));

    let mut automatic = BTreeMap::new();
    automatic.insert(
        "cli-rust",
        manifest_exists(root, "Cargo.toml")
            && (root.join("src/main.rs").is_file()
                || cargo.contains("[[bin]]")
                || has_any(&cargo, &["clap", "ratatui"])),
    );
    automatic.insert(
        "web-ui",
        manifest_exists(root, "package.json")
            && has_any(&package, &["react", "next", "vite"])
            && path_contains(&[
                "src/components",
                "src/component",
                "components/",
                ".tsx",
                ".jsx",
            ]),
    );
    let workspace_manifest =
        package.contains("\"workspaces\"") || manifest_exists(root, "pnpm-workspace.yaml");
    let package_dirs = paths
        .iter()
        .filter(|p| {
            (p.starts_with("packages/") || p.starts_with("apps/")) && p.matches('/').count() == 1
        })
        .count();
    automatic.insert(
        "fullstack-monorepo",
        workspace_manifest && package_dirs >= 2,
    );
    let all_manifests = format!("{cargo}\n{package}\n{pyproject}\n{go_mod}");
    automatic.insert(
        "backend-api",
        has_any(
            &all_manifests,
            &[
                "axum",
                "actix-web",
                "rocket",
                "express",
                "fastify",
                "nestjs",
                "django",
                "fastapi",
                "flask",
                "spring-boot",
            ],
        ) && path_contains(&["domain/", "dto/", "entity/", "entities/"])
            && path_contains(&[
                "service_test",
                "service.test",
                "service.spec",
                "test_service",
            ]),
    );
    automatic.insert(
        "data-ml",
        manifest_exists(root, "pyproject.toml")
            && has_any(
                &pyproject,
                &[
                    "pandas",
                    "numpy",
                    "scikit-learn",
                    "torch",
                    "tensorflow",
                    "polars",
                ],
            )
            && path_contains(&["backtest", "test_data", "data_test", "tests/data"]),
    );
    automatic.insert(
        "gitops-infra",
        (manifest_exists(root, "Chart.yaml") || path_contains(&["/chart.yaml"]))
            && path_contains(&["templates/", "argo", "argocd"]),
    );
    automatic.insert(
        "docs-knowledge",
        !code_manifest
            && has_path(root, &["docs", "templates"])
            && path_contains(&["conventions", "docs/", "templates/"]),
    );
    automatic.insert(
        "native-mobile",
        manifest_exists(root, "package.json")
            && package.contains("react-native")
            && root.join("android").is_dir()
            && root.join("ios").is_dir(),
    );
    automatic.insert("game-godot", manifest_exists(root, "project.godot"));
    automatic.insert(
        "desktop-media",
        manifest_exists(root, "go.mod")
            && has_any(&go_mod, &["wails", "fyne", "webview"])
            && root.join("frontend").is_dir()
            && (has_path(root, &["assets", "media"]) || path_contains(&["pipeline"])),
    );
    automatic.insert(
        "agent-tooling",
        code_manifest
            && path_contains(&[
                "mcp",
                "agent",
                "worker",
                "src/workers",
                "src/packet",
                "tool-contract",
            ])
            && has_any(
                &all_manifests,
                &[
                    "serde",
                    "clap",
                    "tokio",
                    "mcp",
                    "agent",
                    "openai",
                    "anthropic",
                ],
            ),
    );

    let mut presets = Vec::new();
    let mut evidence = Vec::new();
    let mut conflicts = Vec::new();
    for preset in PRESETS {
        let (positive, negative) = explicit_signal(explicit, preset);
        if positive && negative {
            conflicts.push(format!(
                "explicit positive/negative conflict for {preset}; negative won"
            ));
        }
        if negative {
            evidence.push(format!("{preset}: explicit negative veto"));
        } else if positive {
            presets.push((*preset).to_string());
            evidence.push(format!("{preset}: explicit positive"));
        } else if automatic.get(preset).copied().unwrap_or(false) {
            presets.push((*preset).to_string());
            evidence.push(format!("{preset}: manifest plus cross-check"));
        }
    }
    Classification {
        no_match: presets.is_empty(),
        presets,
        evidence,
        conflicts,
    }
}

/// Back-compatible compact view used by the CLI and legacy external library.
/// `core` is an activation layer, not a repo preset, but stays first here for
/// the existing preset-library contract.
pub fn detect_presets(repo: &RepoSummary) -> Vec<String> {
    let mut out = vec!["core".to_string()];
    out.extend(classify_repo(repo, "").presets);
    out
}

const OVERLAYS: &[(&str, &str)] = &[
    ("branch-finishing", "finishing-a-development-branch"),
    ("browser-visual-evidence", "webapp-testing"),
    ("mcp-authoring", "mcp-builder"),
    ("review-feedback", "receiving-code-review"),
    ("skill-authoring", "writing-skills"),
    ("ui-design", "frontend-design"),
];

fn overlay_negative(text: &str, slot: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        format!("overlay:-{slot}"),
        format!("no {slot}"),
        format!("without {slot}"),
        format!("{slot} 사용 금지"),
        format!("{slot} 제외"),
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

/// Return the six approved task-time members whose intent trigger matches.
/// The result is sorted and independent of keyword/input order.
pub fn detect_overlay_skills(text: &str, classification: &Classification) -> Vec<String> {
    let lower = text.to_ascii_lowercase();
    let mut slots = BTreeSet::new();
    if has_any(
        &lower,
        &[
            "browser test",
            "browser verification",
            "visual verification",
            "screenshot",
            "playwright",
            "브라우저 검증",
            "시각 검증",
            "스크린샷",
        ],
    ) {
        slots.insert("browser-visual-evidence");
    }
    if has_any(
        &lower,
        &[
            "mcp server",
            "mcp 서버",
            "mcp builder",
            "mcp 작성",
            "mcp 개선",
        ],
    ) {
        slots.insert("mcp-authoring");
    }
    if has_any(
        &lower,
        &[
            "review feedback",
            "review comment",
            "requested changes",
            "리뷰 피드백",
            "리뷰 코멘트",
            "리뷰 의견 반영",
        ],
    ) {
        slots.insert("review-feedback");
    }
    if has_any(
        &lower,
        &[
            "finish branch",
            "branch finishing",
            "branch integration",
            "merge the branch",
            "브랜치 종결",
            "브랜치 통합",
            "브랜치 마무리",
        ],
    ) {
        slots.insert("branch-finishing");
    }
    if classification.presets.iter().any(|p| p == "web-ui")
        && has_any(
            &lower,
            &[
                "new ui",
                "build ui",
                "redesign",
                "ui design",
                "ui 신규",
                "ui 개편",
                "ui 디자인",
            ],
        )
    {
        slots.insert("ui-design");
    }
    if has_any(
        &lower,
        &[
            "author skill",
            "create skill",
            "improve skill",
            "skill authoring",
            "skill 작성",
            "skill 생성",
            "skill 개선",
            "스킬 작성",
            "스킬 생성",
            "스킬 개선",
        ],
    ) {
        slots.insert("skill-authoring");
    }

    let by_slot: BTreeMap<_, _> = OVERLAYS.iter().copied().collect();
    let mut names: Vec<String> = slots
        .into_iter()
        .filter(|slot| !overlay_negative(&lower, slot))
        .filter_map(|slot| by_slot.get(slot).map(|name| (*name).to_string()))
        .collect();
    names.sort();
    names
}

fn task_intent_text(task: &crate::schemas::Task) -> String {
    let mut parts = vec![task.title.clone(), task.kind.clone()];
    parts.extend(task.allowed_scope.clone());
    parts.extend(
        task.acceptance
            .iter()
            .filter_map(|value| value.as_str().map(str::to_string)),
    );
    if let Some(goal) = &task.goal {
        parts.push(goal.condition.clone());
    }
    parts.join("\n")
}

/// Deterministically project approved task overlays into the existing
/// `task.skills` field and materialize only those managed members. Existing
/// planner-assigned/user skills are preserved and deduplicated.
pub fn project_task_skills_with_context(
    ws: &Workspace,
    repo: &RepoSummary,
    tasks: &mut [crate::schemas::Task],
    explicit_context: &str,
) -> Result<Vec<String>> {
    let classification = classify_repo(repo, explicit_context);
    let mut activated = BTreeSet::new();
    let managed_overlays: BTreeSet<&str> = OVERLAYS.iter().map(|(_, name)| *name).collect();
    for task in tasks {
        let mut skills: BTreeSet<String> = task.skills.iter().cloned().collect();
        skills.retain(|name| !managed_overlays.contains(name.as_str()));
        for name in detect_overlay_skills(&task_intent_text(task), &classification) {
            let vetoed = OVERLAYS
                .iter()
                .find(|(_, member)| *member == name.as_str())
                .is_some_and(|(slot, _)| overlay_negative(explicit_context, slot));
            if vetoed {
                continue;
            }
            activated.insert(name.clone());
            skills.insert(name);
        }
        task.skills = skills.into_iter().collect();
    }
    let activated: Vec<_> = activated.into_iter().collect();
    ensure_builtin_names(ws, &activated)?;
    Ok(activated)
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
    root: Option<PathBuf>,
}

/// Read-only plan-time projection of the two local skill search layers. The
/// vectors are sorted and deduplicated by their underlying catalog readers.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SkillCatalogProjection {
    pub workspace: Vec<String>,
    pub user_library: Vec<String>,
}

impl Library {
    /// Open the always-available managed library plus an optional valid
    /// external library path.
    pub fn open(config_path: &str) -> Option<Library> {
        let p = config_path.trim();
        let root = (!p.is_empty() && p != "builtin")
            .then(|| expand_home(p))
            .filter(|path| path.is_dir());
        Some(Library { root })
    }

    /// Skill names listed in `presets/<preset>.skills` (whitespace-separated).
    pub fn preset_skills(&self, preset: &str) -> Vec<String> {
        let mut out: BTreeSet<String> = builtin_names_for_slot(preset).into_iter().collect();
        if let Some(root) = &self.root {
            if let Ok(text) =
                std::fs::read_to_string(root.join("presets").join(format!("{preset}.skills")))
            {
                out.extend(text.split_whitespace().map(str::to_string));
            }
        }
        out.into_iter().collect()
    }

    /// Does the library hold this skill (a `skills/<name>/SKILL.md`)?
    pub fn has(&self, name: &str) -> bool {
        builtin_member(name).is_some()
            || self
                .root
                .as_ref()
                .is_some_and(|root| root.join("skills").join(name).join("SKILL.md").is_file())
    }

    fn skill_dir(&self, name: &str) -> Option<PathBuf> {
        self.root
            .as_ref()
            .map(|root| root.join("skills").join(name))
            .filter(|path| path.join("SKILL.md").is_file())
    }

    /// Every skill name the library can provide (for `list`).
    pub fn all_skills(&self) -> Vec<String> {
        let mut out: BTreeSet<String> = builtin_names().into_iter().collect();
        if let Some(root) = &self.root {
            out.extend(
                std::fs::read_dir(root.join("skills"))
                    .into_iter()
                    .flatten()
                    .flatten()
                    .filter(|e| e.path().join("SKILL.md").is_file())
                    .filter_map(|e| e.file_name().to_str().map(str::to_string)),
            );
        }
        out.into_iter().collect()
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

/// Snapshot capability-discovery inputs without equipping or writing a skill.
pub fn capability_catalog_projection(ws: &Workspace, library: &Library) -> SkillCatalogProjection {
    SkillCatalogProjection {
        workspace: installed(ws),
        user_library: library.all_skills(),
    }
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
                if std::fs::symlink_metadata(&dst).is_ok() {
                    EquipResult::AlreadyPresent
                } else if let Some(src) = library.skill_dir(name) {
                    match link_or_copy(&src, &dst) {
                        Ok(()) => EquipResult::Added,
                        Err(e) => EquipResult::Failed(e),
                    }
                } else if builtin_member(name).is_some() {
                    match builtin_files_for(name).and_then(|files| {
                        crate::state::place_skill_files_no_clobber(ws, name, &files).ok()
                    }) {
                        Some(true) => EquipResult::Added,
                        Some(false) => EquipResult::AlreadyPresent,
                        None => EquipResult::Failed("managed built-in placement failed".into()),
                    }
                } else {
                    EquipResult::NotInLibrary
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
/// one-line report). No-op when `auto_equip` is off.
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
    let files = vec![("SKILL.md".to_string(), md)];
    crate::state::place_skill_files_no_clobber(ws, &name, &files)
        .ok()
        .filter(|written| *written)
        .map(|_| name)
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
    if std::fs::symlink_metadata(ws.agents_dir().join("skills").join(&name_slug)).is_ok() {
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
    use std::sync::atomic::{AtomicUsize, Ordering};

    static FIXTURE_ID: AtomicUsize = AtomicUsize::new(0);

    fn fixture(name: &str, files: &[(&str, &str)], dirs: &[&str]) -> RepoSummary {
        let root = std::env::temp_dir().join(format!(
            "yard-builtin-{name}-{}-{}",
            std::process::id(),
            FIXTURE_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for dir in dirs {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        for (relative, contents) in files {
            let path = root.join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, contents).unwrap();
        }
        crate::inspect::summarize(&root)
    }

    #[test]
    fn classifier_matrix_requires_manifest_cross_checks_and_covers_all_presets() {
        let cases = vec![
            (
                "cli",
                fixture(
                    "cli",
                    &[("Cargo.toml", "[dependencies]\nclap = \"4\"")],
                    &["src"],
                ),
                "cli-rust",
            ),
            (
                "web",
                fixture(
                    "web",
                    &[
                        ("package.json", r#"{"dependencies":{"react":"1"}}"#),
                        ("src/components/App.tsx", "export default 1"),
                    ],
                    &[],
                ),
                "web-ui",
            ),
            (
                "mono",
                fixture(
                    "mono",
                    &[("package.json", r#"{"workspaces":["packages/*"]}"#)],
                    &["packages/a", "packages/b"],
                ),
                "fullstack-monorepo",
            ),
            (
                "backend",
                fixture(
                    "backend",
                    &[
                        ("Cargo.toml", "[dependencies]\naxum = \"1\""),
                        ("src/domain/user.rs", ""),
                        ("tests/user_service_test.rs", ""),
                    ],
                    &[],
                ),
                "backend-api",
            ),
            (
                "data",
                fixture(
                    "data",
                    &[
                        ("pyproject.toml", "dependencies = ['pandas']"),
                        ("tests/data/test_data.py", ""),
                    ],
                    &[],
                ),
                "data-ml",
            ),
            (
                "gitops",
                fixture(
                    "gitops",
                    &[("Chart.yaml", "name: app"), ("templates/deploy.yaml", "")],
                    &[],
                ),
                "gitops-infra",
            ),
            (
                "docs",
                fixture("docs", &[("docs/CONVENTIONS.md", "# Rules")], &[]),
                "docs-knowledge",
            ),
            (
                "mobile",
                fixture(
                    "mobile",
                    &[("package.json", r#"{"dependencies":{"react-native":"1"}}"#)],
                    &["android", "ios"],
                ),
                "native-mobile",
            ),
            (
                "godot",
                fixture("godot", &[("project.godot", "[application]")], &[]),
                "game-godot",
            ),
            (
                "desktop",
                fixture(
                    "desktop",
                    &[("go.mod", "require github.com/wailsapp/wails/v2 v2.0.0")],
                    &["frontend", "assets"],
                ),
                "desktop-media",
            ),
            (
                "agent",
                fixture(
                    "agent",
                    &[
                        ("Cargo.toml", "[dependencies]\nserde = \"1\""),
                        ("src/workers.rs", ""),
                    ],
                    &[],
                ),
                "agent-tooling",
            ),
        ];
        for (label, repo, expected) in cases {
            let classified = classify_repo(&repo, "");
            assert!(
                classified.presets.iter().any(|preset| preset == expected),
                "{label}: {:?}",
                classified
            );
        }

        let proposal_only = fixture(
            "proposal-only",
            &[("package.json", r#"{"dependencies":{"react":"1"}}"#)],
            &[],
        );
        assert!(classify_repo(&proposal_only, "").no_match);

        let multi = fixture(
            "multi",
            &[
                ("Cargo.toml", "[dependencies]\nclap = \"4\""),
                ("src/main.rs", "fn main() {}"),
                ("package.json", r#"{"dependencies":{"react":"1"}}"#),
                ("src/components/App.tsx", ""),
            ],
            &[],
        );
        assert_eq!(
            classify_repo(&multi, "").presets,
            vec!["cli-rust", "web-ui"]
        );
    }

    fn wide_web_fixture(name: &str, reverse_creation_order: bool) -> RepoSummary {
        let repo = fixture(
            name,
            &[
                ("package.json", r#"{"dependencies":{"react":"^19.2.0"}}"#),
                ("src/components/App.tsx", "export default function App() {}"),
            ],
            &["000-generated"],
        );
        let root = PathBuf::from(&repo.root);
        let indices: Box<dyn Iterator<Item = usize>> = if reverse_creation_order {
            Box::new((0..401).rev())
        } else {
            Box::new(0..401)
        };
        for index in indices {
            std::fs::write(root.join(format!("000-generated/{index:03}.txt")), "filler").unwrap();
        }
        crate::inspect::summarize(&root)
    }

    #[test]
    fn classifier_observes_later_sibling_after_wide_earlier_directory() {
        let forward = wide_web_fixture("wide-web-forward", false);
        let reverse = wide_web_fixture("wide-web-reverse", true);

        let forward_paths = walk_signals(Path::new(&forward.root));
        let reverse_paths = walk_signals(Path::new(&reverse.root));
        assert_eq!(forward_paths, reverse_paths);
        assert!(forward_paths.len() <= MAX_SIGNAL_DIRECTORIES * MAX_SIGNAL_ENTRIES_PER_DIRECTORY);
        assert!(forward_paths
            .iter()
            .any(|path| path == "src/components/app.tsx"));

        let expected = vec!["web-ui".to_string()];
        assert_eq!(classify_repo(&forward, "").presets, expected);
        assert_eq!(classify_repo(&reverse, "").presets, expected);
    }

    fn artifact_heavy_web_fixture(name: &str, include_artifacts: bool) -> RepoSummary {
        let repo = fixture(
            name,
            &[
                ("package.json", r#"{"dependencies":{"react":"^19.2.0"}}"#),
                ("src/components/App.tsx", "export default function App() {}"),
                ("public/icons/app.svg", "<svg />"),
            ],
            &[],
        );
        let root = PathBuf::from(&repo.root);
        if include_artifacts {
            for index in 0..31 {
                std::fs::create_dir_all(root.join(format!(".output/chunk-{index:02}/nested")))
                    .unwrap();
            }
            for index in 0..12 {
                std::fs::create_dir_all(root.join(format!("public/assets/group-{index:02}")))
                    .unwrap();
            }
            for generated in ["build", "coverage", "dist", "out"] {
                std::fs::create_dir_all(root.join(generated).join("nested")).unwrap();
            }
        }
        crate::inspect::summarize(&root)
    }

    #[test]
    fn classifier_ignores_dot_build_artifacts_before_source_directory_budget() {
        let clean = artifact_heavy_web_fixture("artifact-web-clean", false);
        let with_artifacts = artifact_heavy_web_fixture("artifact-web-output", true);

        assert_eq!(
            classify_repo(&clean, "").presets,
            vec!["web-ui".to_string()]
        );
        assert_eq!(
            classify_repo(&with_artifacts, "").presets,
            vec!["web-ui".to_string()]
        );
        let paths = walk_signals(Path::new(&with_artifacts.root));
        assert!(paths.iter().any(|path| path == "src/components/app.tsx"));
        assert!(paths.iter().all(|path| {
            ![".output", "build", "coverage", "dist", "out"]
                .iter()
                .any(|ignored| path == ignored || path.starts_with(&format!("{ignored}/")))
        }));
    }

    #[test]
    fn explicit_signal_priority_is_order_independent_and_negative_wins() {
        let repo = fixture("explicit", &[("README.md", "starter")], &[]);
        assert_eq!(
            classify_repo(&repo, "preset:+web-ui").presets,
            vec!["web-ui"]
        );
        let a = classify_repo(&repo, "preset:+web-ui then preset:-web-ui");
        let b = classify_repo(&repo, "preset:-web-ui then preset:+web-ui");
        assert!(a.presets.is_empty() && b.presets.is_empty());
        assert_eq!(a.conflicts, b.conflicts);
        assert_eq!(a.conflicts.len(), 1);
    }

    #[test]
    fn all_six_overlay_triggers_are_sorted_and_negative_can_veto_one() {
        let classification = Classification {
            presets: vec!["web-ui".into()],
            ..Default::default()
        };
        let text = "MCP server 작성, review feedback 반영, 브라우저 검증 screenshot, \
                    브랜치 종결, new UI redesign, skill 작성";
        let expected = vec![
            "finishing-a-development-branch",
            "frontend-design",
            "mcp-builder",
            "receiving-code-review",
            "webapp-testing",
            "writing-skills",
        ];
        assert_eq!(detect_overlay_skills(text, &classification), expected);
        let reversed = "skill 작성, new UI redesign, 브랜치 종결, screenshot 브라우저 검증, \
                        review feedback 반영, MCP server 작성";
        assert_eq!(detect_overlay_skills(reversed, &classification), expected);
        let vetoed = detect_overlay_skills(
            &format!("{text}\noverlay:-browser-visual-evidence"),
            &classification,
        );
        assert!(!vetoed.contains(&"webapp-testing".to_string()));
    }

    #[test]
    fn fresh_and_existing_workspaces_get_managed_availability_without_clobber() {
        let fresh = fixture("fresh", &[("README.md", "")], &[]);
        let fresh_root = PathBuf::from(&fresh.root);
        crate::init::init(&fresh_root, false).unwrap();
        let fresh_ws = Workspace::at(&fresh_root);
        assert_eq!(Library::open("").unwrap().all_skills().len(), 11);
        let installed_set: BTreeSet<_> = installed(&fresh_ws).into_iter().collect();
        for core in builtin_names_for_slot("core") {
            assert!(installed_set.contains(&core), "missing fresh core {core}");
            assert!(fresh_ws
                .agents_dir()
                .join("skills")
                .join(&core)
                .join(".yardlet-managed.yaml")
                .is_file());
        }
        assert!(!installed_set.contains("webapp-testing"));
        assert!(fresh_ws
            .agents_dir()
            .join("skills/.yardlet-managed-bundle/manifest.yaml")
            .is_file());
        assert!(ensure_builtin_core(&fresh_ws).unwrap().is_empty());

        let existing = fixture("existing", &[("README.md", "")], &[]);
        let existing_root = PathBuf::from(&existing.root);
        let collision = existing_root.join(".agents/skills/writing-plans/SKILL.md");
        std::fs::create_dir_all(collision.parent().unwrap()).unwrap();
        std::fs::write(&collision, "USER OWNED\n").unwrap();
        crate::init::init(&existing_root, false).unwrap();
        let existing_ws = Workspace::at(&existing_root);
        assert_eq!(std::fs::read_to_string(&collision).unwrap(), "USER OWNED\n");
        assert!(!collision
            .parent()
            .unwrap()
            .join(".yardlet-managed.yaml")
            .exists());
        crate::init::ensure_initialized(&existing_root).unwrap();
        assert_eq!(std::fs::read_to_string(&collision).unwrap(), "USER OWNED\n");

        let overlay_collision = existing_root.join(".agents/skills/frontend-design/SKILL.md");
        std::fs::create_dir_all(overlay_collision.parent().unwrap()).unwrap();
        std::fs::write(&overlay_collision, "CUSTOM UI SKILL\n").unwrap();
        ensure_builtin_names(&existing_ws, &["frontend-design".into()]).unwrap();
        assert_eq!(
            std::fs::read_to_string(&overlay_collision).unwrap(),
            "CUSTOM UI SKILL\n"
        );
    }

    #[test]
    fn capability_catalog_projection_is_sorted_deduplicated_and_read_only() {
        let repo = fixture("capability-catalog", &[("README.md", "")], &[]);
        let root = PathBuf::from(&repo.root);
        let workspace_skill = root.join(".agents/skills/local-only/SKILL.md");
        std::fs::create_dir_all(workspace_skill.parent().unwrap()).unwrap();
        std::fs::write(&workspace_skill, "local").unwrap();
        let library_root = root.join("user-library");
        let user_skill = library_root.join("skills/user-only/SKILL.md");
        std::fs::create_dir_all(user_skill.parent().unwrap()).unwrap();
        std::fs::write(&user_skill, "user").unwrap();

        let ws = Workspace::at(&root);
        let library = Library::open(library_root.to_str().unwrap()).unwrap();
        let projection = capability_catalog_projection(&ws, &library);

        assert_eq!(projection.workspace, vec!["local-only"]);
        assert!(projection.user_library.contains(&"user-only".to_string()));
        assert_eq!(projection.workspace.len(), installed(&ws).len());
        assert!(!root.join(".agents/skills/user-only").exists());
    }

    fn task(title: &str) -> crate::schemas::Task {
        crate::schemas::Task {
            id: "YARD-001".into(),
            title: title.into(),
            state: crate::schemas::TaskState::Queued,
            priority: 10,
            risk: "low".into(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
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
            routing_provenance: None,
        }
    }

    #[test]
    fn overlay_projects_through_task_skills_and_packet_catalog_only_for_task_lifetime() {
        let repo = fixture(
            "packet-projection",
            &[
                ("package.json", r#"{"dependencies":{"react":"1"}}"#),
                ("src/components/App.tsx", ""),
            ],
            &[],
        );
        let root = PathBuf::from(&repo.root);
        crate::init::init(&root, false).unwrap();
        let ws = Workspace::at(&root);
        let mut selected = task("Build a new UI and redesign the dashboard");
        project_task_skills_with_context(&ws, &repo, std::slice::from_mut(&mut selected), "")
            .unwrap();
        assert_eq!(selected.skills, vec!["frontend-design"]);
        assert!(selected.required_capabilities.is_empty());
        assert!(selected.approval.is_none());

        let harness = crate::packet::discover_harness(&root, false);
        let selected_packet = crate::packet::compile(&crate::packet::PacketInputs {
            worker_id: "codex",
            task: &selected,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/test",
            conversation: &[],
            continuation: None,
            chained_from: None,
            language: "en",
            images: &[],
            role_notes: "",
            harness: &harness,
            approved: false,
        });
        assert!(selected_packet.contains("frontend-design"));
        assert!(selected_packet.contains(".agents/skills/frontend-design/SKILL.md"));
        assert!(selected_packet.contains("writing-plans"));
        assert!(!selected_packet.contains("webapp-testing"));

        let unrelated = task("Update a plain text note");
        let unrelated_packet = crate::packet::compile(&crate::packet::PacketInputs {
            worker_id: "codex",
            task: &unrelated,
            intent: None,
            repo: &repo,
            run_dir_rel: ".agents/runs/test-2",
            conversation: &[],
            continuation: None,
            chained_from: None,
            language: "en",
            images: &[],
            role_notes: "",
            harness: &harness,
            approved: false,
        });
        assert!(!unrelated_packet.contains("frontend-design"));
        assert!(unrelated_packet.contains("verification-before-completion"));

        ensure_builtin_names(&ws, &["mcp-builder".into()]).unwrap();
        let planning_harness = crate::packet::discover_harness(&root, false);
        let planning_packet = crate::packet::compile_planning(
            "MCP server 작성. preset:+web-ui preset:-web-ui",
            None,
            &repo,
            ".agents/runs/plan-test",
            "en",
            "",
            &[],
            &planning_harness,
            "codex",
            crate::packet::PlanningGitPolicy::default(),
        );
        assert!(planning_packet.contains("mcp-builder"));
        assert!(!planning_packet.contains("frontend-design"));
        assert!(planning_packet
            .contains("explicit positive/negative conflict for web-ui; negative won"));
        assert!(planning_packet.contains("classification grants no network"));

        let mut vetoed_task = task("Build a new UI with browser verification screenshots");
        project_task_skills_with_context(
            &ws,
            &repo,
            std::slice::from_mut(&mut vetoed_task),
            "preset:-web-ui overlay:-browser-visual-evidence",
        )
        .unwrap();
        assert!(vetoed_task.skills.is_empty());
        assert!(vetoed_task.required_capabilities.is_empty());
        assert!(vetoed_task.approval.is_none());
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
            run_id: String::new(),
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
            git_finish_status: String::new(),
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
        let repo = fixture("external-library", &[("README.md", "")], &[]);

        // Built-in core joins an existing external library deterministically.
        let mut s = suggest(&ws, &library, &repo);
        s.sort();
        assert_eq!(
            s,
            vec![
                "planning-gate",
                "requesting-code-review",
                "session-start",
                "systematic-debugging",
                "test-driven-development",
                "verification-before-completion",
                "writing-plans",
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

        // Repo classification does not silently activate legacy preset names.
        let mut s = suggest(&ws, &library, &repo);
        s.sort();
        assert_eq!(
            s,
            vec![
                "planning-gate",
                "requesting-code-review",
                "session-start",
                "systematic-debugging",
                "test-driven-development",
                "verification-before-completion",
                "writing-plans",
            ]
        );

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
