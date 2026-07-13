use std::fs;
use std::path::{Path, PathBuf};

const FORBIDDEN_FS_CALLS: &[&str] = &[
    "fs::write(",
    "std::fs::write(",
    "fs::remove_file(",
    "std::fs::remove_file(",
];

const CANONICAL_STATE_MARKERS: &[&str] = &[
    "queue_path(",
    "intent_path(",
    "transition_path(",
    "planning_session_path(",
    "draft_revision_path(",
    "activation_path(",
    "runtime_task_receipt_path(",
    "runtime_capability_receipt_path(",
    ".agents/work-queue.yaml",
    ".agents/intent-contract.yaml",
    ".agents/transitions",
    ".agents/planning-sessions",
    ".agents/activations",
    ".agents/runtime-task-receipts",
    ".agents/runtime-capability-receipts",
];

#[test]
fn canonical_agents_state_writes_stay_behind_state_module() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut violations = Vec::new();
    scan_dir(&root, &mut violations);

    assert!(
        violations.is_empty(),
        "canonical .agents state must be written through src/state.rs, not direct file operations:\n{}",
        violations.join("\n")
    );
}

#[test]
fn scanner_rejects_intentional_direct_canonical_state_mutations() {
    let source = r#"
use crate::state::{save_yaml, Workspace};

fn bad_yaml(ws: &Workspace, queue: &crate::schemas::WorkQueue) {
    save_yaml(&ws.queue_path(), queue).unwrap();
}

fn bad_remove(ws: &Workspace) {
    std::fs::remove_file(ws.intent_path()).unwrap();
}

fn bad_literal() {
    std::fs::write(".agents/transitions/YARD-001.yaml", "state").unwrap();
}
"#;

    let violations = scan_source("src/not_state.rs", source);
    assert!(
        violations.len() >= 3,
        "synthetic direct state writes should be rejected, got {violations:?}"
    );
}

fn scan_dir(dir: &Path, violations: &mut Vec<String>) {
    for entry in fs::read_dir(dir).expect("read src directory") {
        let entry = entry.expect("read src entry");
        let path = entry.path();
        if path.is_dir() {
            scan_dir(&path, violations);
            continue;
        }
        if path.extension().and_then(|s| s.to_str()) != Some("rs") {
            continue;
        }
        if path.file_name().and_then(|s| s.to_str()) == Some("state.rs") {
            continue;
        }
        let display_path = path
            .strip_prefix(env!("CARGO_MANIFEST_DIR"))
            .unwrap_or(&path)
            .display()
            .to_string();
        let source = fs::read_to_string(&path).expect("read Rust source");
        violations.extend(scan_source(&display_path, &source));
    }
}

fn scan_source(path: &str, source: &str) -> Vec<String> {
    let production_source = production_source_only(source);
    let mut violations = Vec::new();

    for statement in statements(&production_source) {
        if !touches_canonical_state(&statement.text) {
            continue;
        }
        if has_forbidden_fs_call(&statement.text) || has_unqualified_save_yaml_call(&statement.text)
        {
            violations.push(format!(
                "{path}:{}: {}",
                statement.line,
                statement.text.trim().replace('\n', " ")
            ));
        }
    }

    violations
}

fn production_source_only(source: &str) -> String {
    let mut out = String::new();
    for line in source.lines() {
        if line.trim() == "#[cfg(test)]" {
            break;
        }
        let line = line.split_once("//").map_or(line, |(before, _)| before);
        out.push_str(line);
        out.push('\n');
    }
    out
}

#[derive(Debug)]
struct Statement {
    line: usize,
    text: String,
}

fn statements(source: &str) -> Vec<Statement> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut start_line = 1;

    for (idx, line) in source.lines().enumerate() {
        if buf.trim().is_empty() {
            start_line = idx + 1;
        }
        buf.push_str(line);
        buf.push('\n');
        if line.contains(';') || line.trim_end().ends_with('{') || line.trim_end().ends_with('}') {
            out.push(Statement {
                line: start_line,
                text: std::mem::take(&mut buf),
            });
        }
    }

    if !buf.trim().is_empty() {
        out.push(Statement {
            line: start_line,
            text: buf,
        });
    }

    out
}

fn touches_canonical_state(statement: &str) -> bool {
    CANONICAL_STATE_MARKERS
        .iter()
        .any(|marker| statement.contains(marker))
}

fn has_forbidden_fs_call(statement: &str) -> bool {
    FORBIDDEN_FS_CALLS
        .iter()
        .any(|call| statement.contains(call))
}

fn has_unqualified_save_yaml_call(statement: &str) -> bool {
    let mut rest = statement;
    while let Some(idx) = rest.find("save_yaml(") {
        let before = &rest[..idx];
        let namespaced = before.ends_with("state::") || before.ends_with("crate::state::");
        if !namespaced {
            return true;
        }
        rest = &rest[idx + "save_yaml(".len()..];
    }
    false
}
