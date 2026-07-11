//! Run telemetry: an append-only projection of each run's outcome, used to
//! suggest (never auto-apply) worker-routing policy updates.

use std::io::Write;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::state::Workspace;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunTelemetry {
    pub ts: String,
    /// Stable idempotency key for finalize/recover projection.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub run_id: String,
    pub task_id: String,
    /// The intent this run served. Lets the trust report scope to one intent so
    /// a task id reused across intents does not fold its attempts together.
    /// Absent on records written before this field existed (default "").
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub intent_id: String,
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
    /// Skills the task declared (for the S4 skill score).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skills: Vec<String>,
    /// Structured review verdict, when this run produced one: (passed, total).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verdict_pass: Option<(usize, usize)>,
    /// Persisted feedback-loop position for this task run. Zero means the run
    /// did not enter deterministic feedback.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub feedback_cycle: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub max_feedback_cycles: u32,
    #[serde(default, skip_serializing_if = "is_false")]
    pub feedback_retryable: bool,
    /// Outcome from the run's canonical `git-finish.json` projection.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub git_finish_status: String,
}

fn is_zero(value: &u32) -> bool {
    *value == 0
}

fn is_false(value: &bool) -> bool {
    !*value
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
    if !rec.run_id.is_empty()
        && read_runs(ws)
            .iter()
            .any(|existing| existing.run_id == rec.run_id)
    {
        return Ok(());
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
