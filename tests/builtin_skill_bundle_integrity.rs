use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::Deserialize;

const SUPERPOWERS_COMMIT: &str = "d884ae04edebef577e82ff7c4e143debd0bbec99";
const ANTHROPICS_COMMIT: &str = "9d2f1ae187231d8199c64b5b762e1bdf2244733d";
const SUPERPOWERS_LICENSE_BLOB: &str = "abf0390320aa14406af7a520b9b0739fdda9bf08";
const APACHE_LICENSE_BLOB: &str = "4f881c52d1f72f4cfb720e339e2d35c3058d01a9";
const FRONTEND_LICENSE_BLOB: &str = "f433b1a53f5b830a205fd2df78e2b34974656c7b";

const EXPECTED_LEDGER: &str = "ANT-02|mcp-builder|overlay|mcp-authoring|anthropics-skills|skills/mcp-builder/|LICENSE.txt,SKILL.md,reference/evaluation.md,reference/mcp_best_practices.md,reference/node_mcp_server.md,reference/python_mcp_server.md|scripts/connections.py,scripts/evaluation.py,scripts/example_evaluation.xml,scripts/requirements.txt
ANT-03|webapp-testing|overlay|browser-visual-evidence|anthropics-skills|skills/webapp-testing/|LICENSE.txt,SKILL.md,examples/console_logging.py,examples/element_discovery.py,examples/static_html_automation.py,scripts/with_server.py|
ANT-04|frontend-design|overlay|ui-design|anthropics-skills|skills/frontend-design/|LICENSE.txt,SKILL.md|
SPW-01|test-driven-development|core|C4|obra-superpowers|skills/test-driven-development/|SKILL.md,testing-anti-patterns.md|
SPW-02|systematic-debugging|core|C3|obra-superpowers|skills/systematic-debugging/|SKILL.md,condition-based-waiting-example.ts,condition-based-waiting.md,defense-in-depth.md,find-polluter.sh,root-cause-tracing.md|CREATION-LOG.md,test-academic.md,test-pressure-1.md,test-pressure-2.md,test-pressure-3.md
SPW-03|verification-before-completion|core|C5|obra-superpowers|skills/verification-before-completion/|SKILL.md|
SPW-04|writing-plans|core|C1|obra-superpowers|skills/writing-plans/|SKILL.md,plan-document-reviewer-prompt.md|
SPW-06|requesting-code-review|core|C6|obra-superpowers|skills/requesting-code-review/|SKILL.md,code-reviewer.md|
SPW-07|receiving-code-review|overlay|review-feedback|obra-superpowers|skills/receiving-code-review/|SKILL.md|
SPW-08|finishing-a-development-branch|overlay|branch-finishing|obra-superpowers|skills/finishing-a-development-branch/|SKILL.md|
SPW-13|writing-skills|overlay|skill-authoring|obra-superpowers|skills/writing-skills/|SKILL.md,persuasion-principles.md|anthropic-best-practices.md,examples/CLAUDE_MD_TESTING.md,graphviz-conventions.dot,render-graphs.js,testing-skills-with-subagents.md";

#[derive(Debug, Deserialize)]
struct Manifest {
    schema_version: u32,
    library: String,
    sources: BTreeMap<String, Source>,
    members: Vec<Member>,
}

#[derive(Debug, Deserialize)]
struct Source {
    repository: String,
    commit: String,
    license: String,
    license_source_path: String,
    license_blob: String,
    license_bundle_path: String,
}

#[derive(Debug, Deserialize)]
struct Member {
    id: String,
    name: String,
    layer: String,
    slot: String,
    activation: String,
    source: String,
    source_path: String,
    license_bundle_path: String,
    license_blob: String,
    included: Vec<IncludedFile>,
    excluded: Vec<String>,
    adaptation: Vec<String>,
    residual_requirements: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct IncludedFile {
    source_file: String,
    bundle_file: String,
    upstream_blob: String,
    mode: String,
}

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/builtin-skills")
}

fn load_manifest() -> Manifest {
    let path = root().join("manifest.yaml");
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_yaml_ng::from_str(&raw).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn collect_files(base: &Path) -> BTreeSet<String> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeSet<String>) {
        for entry in std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display())) {
            let entry = entry.unwrap();
            let path = entry.path();
            let file_type = entry.file_type().unwrap();
            if file_type.is_dir() {
                walk(base, &path, out);
            } else if file_type.is_file() {
                out.insert(
                    path.strip_prefix(base)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/"),
                );
            } else {
                panic!("bundle contains a non-file entry: {}", path.display());
            }
        }
    }

    let mut out = BTreeSet::new();
    walk(base, base, &mut out);
    out
}

fn assert_sha(value: &str, label: &str) {
    assert_eq!(value.len(), 40, "{label} must be a full SHA: {value}");
    assert!(
        value.bytes().all(|b| b.is_ascii_hexdigit()),
        "{label} must be hexadecimal: {value}"
    );
}

fn frontmatter_name(skill_md: &str) -> String {
    let rest = skill_md
        .strip_prefix("---\n")
        .expect("SKILL.md must start with YAML frontmatter");
    let (yaml, _) = rest
        .split_once("\n---\n")
        .expect("SKILL.md frontmatter must have a closing delimiter");
    let value: serde_yaml_ng::Value = serde_yaml_ng::from_str(yaml).unwrap();
    let map = value.as_mapping().expect("frontmatter must be a mapping");
    assert!(
        map.contains_key(serde_yaml_ng::Value::from("description")),
        "frontmatter must contain description"
    );
    map.get(serde_yaml_ng::Value::from("name"))
        .and_then(serde_yaml_ng::Value::as_str)
        .expect("frontmatter must contain string name")
        .to_string()
}

fn joined(items: impl IntoIterator<Item = String>) -> String {
    let mut items: Vec<_> = items.into_iter().collect();
    items.sort();
    items.join(",")
}

fn ledger_line(member: &Member) -> String {
    format!(
        "{}|{}|{}|{}|{}|{}|{}|{}",
        member.id,
        member.name,
        member.layer,
        member.slot,
        member.source,
        member.source_path,
        joined(member.included.iter().map(|f| f.bundle_file.clone())),
        joined(member.excluded.iter().cloned()),
    )
}

#[test]
fn manifest_has_only_the_approved_members_layers_and_pins() {
    let manifest = load_manifest();
    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.library, "yardlet-managed-builtins");
    assert_eq!(manifest.members.len(), 11);
    assert_eq!(manifest.sources.len(), 2);

    let superpowers = &manifest.sources["obra-superpowers"];
    assert_eq!(
        superpowers.repository,
        "https://github.com/obra/superpowers"
    );
    assert_eq!(superpowers.commit, SUPERPOWERS_COMMIT);
    assert_eq!(superpowers.license, "MIT");
    assert_eq!(superpowers.license_source_path, "LICENSE");
    assert_eq!(superpowers.license_blob, SUPERPOWERS_LICENSE_BLOB);
    assert_eq!(
        superpowers.license_bundle_path,
        "licenses/obra-superpowers-MIT.txt"
    );

    let anthropics = &manifest.sources["anthropics-skills"];
    assert_eq!(
        anthropics.repository,
        "https://github.com/anthropics/skills"
    );
    assert_eq!(anthropics.commit, ANTHROPICS_COMMIT);
    assert_eq!(anthropics.license, "Apache-2.0-per-skill");
    assert_eq!(
        anthropics.license_source_path,
        "skills/<member>/LICENSE.txt"
    );
    assert_eq!(anthropics.license_blob, "per-member");
    assert_eq!(
        anthropics.license_bundle_path,
        "skills/<member>/LICENSE.txt"
    );

    let ids: BTreeSet<_> = manifest.members.iter().map(|m| m.id.as_str()).collect();
    let names: BTreeSet<_> = manifest.members.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(ids.len(), 11, "member ids must be unique");
    assert_eq!(names.len(), 11, "member names must be unique");

    let core: BTreeSet<_> = manifest
        .members
        .iter()
        .filter(|m| m.layer == "core")
        .map(|m| m.id.as_str())
        .collect();
    let overlay: BTreeSet<_> = manifest
        .members
        .iter()
        .filter(|m| m.layer == "overlay")
        .map(|m| m.id.as_str())
        .collect();
    assert_eq!(
        core,
        BTreeSet::from(["SPW-01", "SPW-02", "SPW-03", "SPW-04", "SPW-06"])
    );
    assert_eq!(
        overlay,
        BTreeSet::from(["SPW-07", "SPW-08", "SPW-13", "ANT-02", "ANT-03", "ANT-04"])
    );
    assert!(!manifest.members.iter().any(|m| m.layer == "preset"));

    let mut actual: Vec<_> = manifest.members.iter().map(ledger_line).collect();
    actual.sort();
    assert_eq!(actual.join("\n"), EXPECTED_LEDGER);
}

#[test]
fn inventory_licenses_and_frontmatter_match_the_fixed_ledger() {
    let manifest = load_manifest();
    let actual_dirs: BTreeSet<String> = std::fs::read_dir(root().join("skills"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    let expected_dirs: BTreeSet<String> = manifest.members.iter().map(|m| m.name.clone()).collect();
    assert_eq!(
        actual_dirs, expected_dirs,
        "unapproved or missing skill directory"
    );

    for member in &manifest.members {
        assert!(!member.activation.trim().is_empty());
        assert!(
            !member.adaptation.is_empty(),
            "{} lacks adaptation record",
            member.id
        );
        let _declared_runtime_boundary = &member.residual_requirements;

        let source = &manifest.sources[&member.source];
        assert_sha(&source.commit, &format!("{} source commit", member.id));
        let expected_commit = if member.source == "obra-superpowers" {
            SUPERPOWERS_COMMIT
        } else {
            ANTHROPICS_COMMIT
        };
        assert_eq!(source.commit, expected_commit);

        let included: BTreeSet<String> = member
            .included
            .iter()
            .map(|file| file.bundle_file.clone())
            .collect();
        assert_eq!(
            included.len(),
            member.included.len(),
            "{} has duplicate included inventory",
            member.id
        );
        let excluded: BTreeSet<String> = member.excluded.iter().cloned().collect();
        assert!(
            included.is_disjoint(&excluded),
            "{} includes and excludes the same file",
            member.id
        );

        let skill_dir = root().join("skills").join(&member.name);
        assert_eq!(
            collect_files(&skill_dir),
            included,
            "{} on-disk inventory",
            member.id
        );
        let skill_md = std::fs::read_to_string(skill_dir.join("SKILL.md")).unwrap();
        assert_eq!(frontmatter_name(&skill_md), member.name);

        for file in &member.included {
            assert_eq!(file.source_file, file.bundle_file);
            assert!(!Path::new(&file.bundle_file).is_absolute());
            assert!(!file.bundle_file.split('/').any(|part| part == ".."));
            assert_sha(
                &file.upstream_blob,
                &format!("{} {} upstream blob", member.id, file.source_file),
            );
            assert!(matches!(
                file.mode.as_str(),
                "exact" | "adapted" | "normalized"
            ));
        }

        let license_path = root().join(&member.license_bundle_path);
        let license = std::fs::read_to_string(&license_path)
            .unwrap_or_else(|e| panic!("{}: {e}", license_path.display()));
        if member.source == "obra-superpowers" {
            assert_eq!(member.license_blob, SUPERPOWERS_LICENSE_BLOB);
            assert!(license.contains("MIT License"));
            assert!(license.contains("Permission is hereby granted"));
        } else {
            let expected_blob = if member.id == "ANT-04" {
                FRONTEND_LICENSE_BLOB
            } else {
                APACHE_LICENSE_BLOB
            };
            assert_eq!(member.license_blob, expected_blob);
            assert!(license.contains("Apache License"));
            assert!(license.contains("Version 2.0"));
        }
    }
}

fn assert_absent(member: &str, patterns: &[&str]) {
    let dir = root().join("skills").join(member);
    for relative in collect_files(&dir) {
        if relative == "LICENSE.txt" {
            continue;
        }
        let path = dir.join(&relative);
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let lower = text.to_ascii_lowercase();
        for pattern in patterns {
            assert!(
                !lower.contains(&pattern.to_ascii_lowercase()),
                "forbidden surface {pattern:?} found in {}",
                path.display()
            );
        }
    }
}

#[test]
fn conditional_adaptations_remove_forbidden_files_and_instructions() {
    assert_absent(
        "systematic-debugging",
        &[
            "IDENTITY",
            "security list-keychains",
            "security find-identity",
            "codesign --sign",
        ],
    );
    assert_absent(
        "writing-plans",
        &[
            "required sub-skill",
            "superpowers:",
            "subagent",
            "dispatch a",
        ],
    );
    assert_absent(
        "requesting-code-review",
        &["subagent", "general-purpose agent"],
    );
    assert_absent(
        "finishing-a-development-branch",
        &["git push", "gh pr", "git branch -d", "git worktree remove"],
    );
    assert_absent(
        "writing-skills",
        &[
            "http://", "https://", "raw api", "graphviz", "git push", "gh pr",
        ],
    );
    assert_absent(
        "mcp-builder",
        &[
            "webfetch",
            "raw.githubusercontent.com",
            "/main/readme",
            "anthropic_api_key",
            "subagent",
            "from anthropic import",
        ],
    );

    let all_assets = collect_files(&root());
    for forbidden in [
        "skills/systematic-debugging/CREATION-LOG.md",
        "skills/systematic-debugging/test-academic.md",
        "skills/systematic-debugging/test-pressure-1.md",
        "skills/systematic-debugging/test-pressure-2.md",
        "skills/systematic-debugging/test-pressure-3.md",
        "skills/writing-skills/anthropic-best-practices.md",
        "skills/writing-skills/graphviz-conventions.dot",
        "skills/writing-skills/render-graphs.js",
        "skills/writing-skills/testing-skills-with-subagents.md",
        "skills/writing-skills/examples/CLAUDE_MD_TESTING.md",
        "skills/mcp-builder/scripts/connections.py",
        "skills/mcp-builder/scripts/evaluation.py",
        "skills/mcp-builder/scripts/example_evaluation.xml",
        "skills/mcp-builder/scripts/requirements.txt",
    ] {
        assert!(
            !all_assets.contains(forbidden),
            "excluded file is bundled: {forbidden}"
        );
    }

    for file in &all_assets {
        let path = root().join(file);
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        assert!(
            !text
                .to_ascii_lowercase()
                .contains("local-reference-catalog"),
            "local reference catalog material leaked into {}",
            path.display()
        );
    }
}
