//! Cheap, deterministic local evidence gathering.
//!
//! Yardlet collects this *before* invoking a worker so the worker spends fewer
//! tokens rediscovering the environment. Nothing here calls an AI API.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;

#[derive(Debug, Clone, Default, Serialize)]
pub struct RepoSummary {
    pub root: String,
    pub git: GitInfo,
    pub package_managers: Vec<String>,
    pub test_commands: Vec<String>,
    pub top_level: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct GitInfo {
    pub is_repo: bool,
    pub branch: Option<String>,
    pub dirty_files: usize,
}

impl RepoSummary {
    /// Keep planner evidence focused on the source workspace. `.agents/` is
    /// operational history and canonical state, not repository structure for
    /// a new plan; the packet projects its rules, skills, and memory through
    /// the typed harness sections instead.
    pub fn for_planning(&self) -> Self {
        let mut projected = self.clone();
        projected.top_level.retain(|entry| entry != ".agents");
        projected
    }
}

pub fn summarize(root: &Path) -> RepoSummary {
    RepoSummary {
        root: root.display().to_string(),
        git: git_info(root),
        package_managers: detect_package_managers(root),
        test_commands: detect_test_commands(root),
        top_level: top_level_entries(root),
    }
}

fn git_info(root: &Path) -> GitInfo {
    let inside = Command::new("git")
        .args(["rev-parse", "--is-inside-work-tree"])
        .current_dir(root)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if !inside {
        return GitInfo::default();
    }
    let branch = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(root)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    let dirty_files = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(root)
        .output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.trim().is_empty())
                .count()
        })
        .unwrap_or(0);
    GitInfo {
        is_repo: true,
        branch,
        dirty_files,
    }
}

fn detect_package_managers(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mark = |name: &str, file: &str, out: &mut Vec<String>| {
        if root.join(file).exists() {
            out.push(format!("{name} ({file})"));
        }
    };
    if root.join("pnpm-lock.yaml").exists() {
        out.push("pnpm (pnpm-lock.yaml)".into());
    } else if root.join("yarn.lock").exists() {
        out.push("yarn (yarn.lock)".into());
    } else {
        mark("npm", "package.json", &mut out);
    }
    mark("cargo", "Cargo.toml", &mut out);
    mark("go", "go.mod", &mut out);
    mark("poetry/pip", "pyproject.toml", &mut out);
    mark("pip", "requirements.txt", &mut out);
    mark("bundler", "Gemfile", &mut out);
    mark("gradle", "build.gradle", &mut out);
    mark("maven", "pom.xml", &mut out);
    out
}

fn detect_test_commands(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    if root.join("Cargo.toml").exists() {
        out.push("cargo test".into());
    }
    if root.join("go.mod").exists() {
        out.push("go test ./...".into());
    }
    if root.join("pnpm-lock.yaml").exists() {
        out.push("pnpm test".into());
    } else if root.join("yarn.lock").exists() {
        out.push("yarn test".into());
    } else if root.join("package.json").exists() {
        out.push("npm test".into());
    }
    if root.join("pyproject.toml").exists() || root.join("pytest.ini").exists() {
        out.push("pytest".into());
    }
    out
}

fn top_level_entries(root: &Path) -> Vec<String> {
    let mut entries: Vec<String> = match std::fs::read_dir(root) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n != ".git" && n != "target" && n != "node_modules")
            .collect(),
        Err(_) => Vec::new(),
    };
    entries.sort();
    entries.truncate(40);
    entries
}

/// Render the summary as compact markdown for run evidence.
pub fn to_markdown(s: &RepoSummary) -> String {
    let mut md = String::new();
    md.push_str("# Repo summary\n\n");
    md.push_str(&format!("- root: `{}`\n", s.root));
    if s.git.is_repo {
        md.push_str(&format!(
            "- git: branch `{}`, {} changed file(s)\n",
            s.git.branch.as_deref().unwrap_or("?"),
            s.git.dirty_files
        ));
    } else {
        md.push_str("- git: not a repository\n");
    }
    md.push_str(&format!(
        "- package managers: {}\n",
        if s.package_managers.is_empty() {
            "none detected".to_string()
        } else {
            s.package_managers.join(", ")
        }
    ));
    md.push_str(&format!(
        "- test commands: {}\n",
        if s.test_commands.is_empty() {
            "none detected".to_string()
        } else {
            s.test_commands.join(", ")
        }
    ));
    md.push_str(&format!("- top level: {}\n", s.top_level.join(", ")));
    md
}

pub fn cwd() -> PathBuf {
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn planning_projection_excludes_operational_state_root() {
        let summary = RepoSummary {
            top_level: vec![".agents".into(), "Cargo.toml".into(), "src".into()],
            ..Default::default()
        };

        let planning = summary.for_planning();

        assert_eq!(planning.top_level, vec!["Cargo.toml", "src"]);
        assert_eq!(summary.top_level[0], ".agents");
    }
}
