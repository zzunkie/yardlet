//! Single-use approvals for gated tasks (the plan's `approved_once` state).
//!
//! A task whose `approval.required` is true does not run until a human grants
//! it with `yard approve <id>`. The grant is consumed on the next run, so the
//! task asks again next time — approval never persists silently.

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::state::Workspace;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Approvals {
    #[serde(default)]
    pub granted_once: Vec<String>,
}

fn path(ws: &Workspace) -> std::path::PathBuf {
    ws.agents_dir().join("approvals.yaml")
}

pub fn load(ws: &Workspace) -> Approvals {
    std::fs::read_to_string(path(ws))
        .ok()
        .and_then(|t| crate::yaml::from_str(&t).ok())
        .unwrap_or_default()
}

fn save(ws: &Workspace, a: &Approvals) -> Result<()> {
    crate::state::save_yaml(&path(ws), a)
}

pub fn grant(ws: &Workspace, task_id: &str) -> Result<()> {
    let mut a = load(ws);
    if !a.granted_once.iter().any(|t| t == task_id) {
        a.granted_once.push(task_id.to_string());
    }
    save(ws, &a)
}

pub fn is_granted(ws: &Workspace, task_id: &str) -> bool {
    load(ws).granted_once.iter().any(|t| t == task_id)
}

pub fn consume(ws: &Workspace, task_id: &str) -> Result<()> {
    let mut a = load(ws);
    a.granted_once.retain(|t| t != task_id);
    save(ws, &a)
}
