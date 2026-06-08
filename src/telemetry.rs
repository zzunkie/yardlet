//! Run telemetry: an append-only projection of each run's outcome, used to
//! suggest (never auto-apply) worker-routing policy updates.

use std::io::Write;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::state::Workspace;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunTelemetry {
    pub ts: String,
    pub task_id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub risk: String,
    pub worker: String,
    #[serde(default)]
    pub chosen_reason: String,
    #[serde(default)]
    pub result_status: String,
    #[serde(default)]
    pub eval_state: String,
    #[serde(default)]
    pub wall_seconds: u64,
    #[serde(default)]
    pub user_override: Option<String>,
}

pub fn log_path(ws: &Workspace) -> std::path::PathBuf {
    ws.agents_dir().join("telemetry").join("runs.jsonl")
}

/// Append one run record. Failures are non-fatal to a run (telemetry is best
/// effort), so callers ignore the error.
pub fn append_run(ws: &Workspace, rec: &RunTelemetry) -> Result<()> {
    let path = log_path(ws);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let line = format!("{}\n", serde_json::to_string(rec)?);
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    f.write_all(line.as_bytes())?;
    Ok(())
}

/// Read all run records (skips malformed lines).
pub fn read_runs(ws: &Workspace) -> Vec<RunTelemetry> {
    let Ok(text) = std::fs::read_to_string(log_path(ws)) else {
        return Vec::new();
    };
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}
