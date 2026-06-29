//! Workspace state layer.
//!
//! Yardlet owns canonical state under `.agents/` in the target repo. This module
//! is the only place that reads and writes those files. Everything is durable
//! and readable without any previous chat context.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::schemas::{
    BillingPolicy, Conversation, ConversationTurn, IntentContract, TurnRole, WorkQueue,
    WorkersFile, YardConfig,
};
use crate::yaml;

pub const STATE_DIR: &str = ".agents";
/// Canonical config filename. `yard.yaml` is the pre-rename name, still read
/// (and written in place) for back-compat so existing workspaces keep working.
pub const CONFIG_FILE: &str = "yardlet.yaml";
pub const LEGACY_CONFIG_FILE: &str = "yard.yaml";

/// A located Yardlet workspace: the directory that owns `.agents/`.
#[derive(Debug, Clone)]
pub struct Workspace {
    pub root: PathBuf,
}

impl Workspace {
    /// Walk up from `start` looking for an existing config file (the canonical
    /// `.agents/yardlet.yaml` or the legacy `.agents/yard.yaml`).
    pub fn discover(start: &Path) -> Option<Workspace> {
        let mut dir = Some(start);
        while let Some(d) = dir {
            let agents = d.join(STATE_DIR);
            if agents.join(CONFIG_FILE).is_file() || agents.join(LEGACY_CONFIG_FILE).is_file() {
                return Some(Workspace {
                    root: d.to_path_buf(),
                });
            }
            dir = d.parent();
        }
        None
    }

    /// The workspace rooted at `root`, whether or not it is initialized yet.
    pub fn at(root: &Path) -> Workspace {
        Workspace {
            root: root.to_path_buf(),
        }
    }

    pub fn agents_dir(&self) -> PathBuf {
        self.root.join(STATE_DIR)
    }

    pub fn is_initialized(&self) -> bool {
        self.agents_dir().join(CONFIG_FILE).is_file()
            || self.agents_dir().join(LEGACY_CONFIG_FILE).is_file()
    }

    /// The config file path. Prefers the canonical `yardlet.yaml`; falls back to
    /// the legacy `yard.yaml` when that is the file a workspace already has, so
    /// pre-rename workspaces are read and written in place rather than orphaned.
    /// A fresh workspace gets the canonical name.
    pub fn config_path(&self) -> PathBuf {
        let canonical = self.agents_dir().join(CONFIG_FILE);
        let legacy = self.agents_dir().join(LEGACY_CONFIG_FILE);
        if !canonical.is_file() && legacy.is_file() {
            legacy
        } else {
            canonical
        }
    }
    pub fn queue_path(&self) -> PathBuf {
        self.agents_dir().join("work-queue.yaml")
    }
    pub fn intent_path(&self) -> PathBuf {
        self.agents_dir().join("intent-contract.yaml")
    }
    pub fn workers_path(&self) -> PathBuf {
        self.agents_dir().join("workers.yaml")
    }
    pub fn conversations_dir(&self) -> PathBuf {
        self.agents_dir().join("conversations")
    }
    pub fn conversation_path(&self, task_id: &str) -> PathBuf {
        self.conversations_dir().join(format!("{task_id}.yaml"))
    }
    pub fn billing_path(&self) -> PathBuf {
        self.agents_dir().join("billing-policy.yaml")
    }
    pub fn runs_dir(&self) -> PathBuf {
        self.agents_dir().join("runs")
    }
    pub fn checkpoints_dir(&self) -> PathBuf {
        self.agents_dir().join("checkpoints")
    }
    pub fn handoffs_dir(&self) -> PathBuf {
        self.agents_dir().join("handoffs")
    }

    // ---- typed loaders -------------------------------------------------

    pub fn load_config(&self) -> Result<YardConfig> {
        load_yaml(&self.config_path())
    }

    pub fn load_queue(&self) -> Result<WorkQueue> {
        let path = self.queue_path();
        if !path.exists() {
            // The queue is runtime state, not config: a fresh checkout (or one
            // that gitignores the queue) can have none. A missing file is an
            // empty queue, not an error. A present-but-malformed file still fails.
            return Ok(WorkQueue::empty());
        }
        load_yaml(&path)
    }

    pub fn save_queue(&self, queue: &WorkQueue) -> Result<()> {
        save_yaml(&self.queue_path(), queue)
    }

    pub fn load_workers(&self) -> Result<WorkersFile> {
        load_yaml(&self.workers_path())
    }

    /// A task's conversation transcript (empty when the task never paused for
    /// the user). A malformed file reads as empty rather than failing the run.
    pub fn load_conversation(&self, task_id: &str) -> Conversation {
        let p = self.conversation_path(task_id);
        if !p.is_file() {
            return Conversation {
                task_id: task_id.to_string(),
                turns: Vec::new(),
            };
        }
        load_yaml(&p).unwrap_or_else(|_| Conversation {
            task_id: task_id.to_string(),
            turns: Vec::new(),
        })
    }

    pub fn load_billing(&self) -> Result<BillingPolicy> {
        load_yaml(&self.billing_path())
    }

    /// The intent contract is optional until a planning gate has run.
    pub fn load_intent(&self) -> Result<Option<IntentContract>> {
        let p = self.intent_path();
        if !p.is_file() {
            return Ok(None);
        }
        Ok(Some(load_yaml(&p)?))
    }
}

pub fn load_yaml<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    yaml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
}

pub fn save_yaml<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let text = yaml::to_string(value)?;
    fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Append a turn to a task's conversation transcript. Yardlet stays the sole
/// writer of `.agents/`: the worker authors its message via `question_for_user`
/// and the user replies through `yardlet answer`; the core records both here.
/// Worker turns dedupe by `run_id`, and an identical consecutive turn is
/// skipped, so a retried run never double-records.
pub fn append_conversation_turn(
    ws: &Workspace,
    task_id: &str,
    turn: ConversationTurn,
) -> Result<()> {
    let mut conv = ws.load_conversation(task_id);
    if conv.task_id.is_empty() {
        conv.task_id = task_id.to_string();
    }
    if turn.role == TurnRole::Worker
        && !turn.run_id.is_empty()
        && conv
            .turns
            .iter()
            .any(|t| t.role == TurnRole::Worker && t.run_id == turn.run_id)
    {
        return Ok(());
    }
    if conv
        .turns
        .last()
        .is_some_and(|t| t.role == turn.role && t.text.trim() == turn.text.trim())
    {
        return Ok(());
    }
    conv.turns.push(turn);
    save_yaml(&ws.conversation_path(task_id), &conv)
}

pub fn write_str(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, contents).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worker(text: &str, run_id: &str) -> ConversationTurn {
        ConversationTurn {
            role: TurnRole::Worker,
            text: text.into(),
            run_id: run_id.into(),
            ts: String::new(),
        }
    }
    fn user(text: &str) -> ConversationTurn {
        ConversationTurn {
            role: TurnRole::User,
            text: text.into(),
            run_id: String::new(),
            ts: String::new(),
        }
    }

    #[test]
    fn conversation_appends_dedupes_and_roundtrips() {
        let dir = std::env::temp_dir().join(format!("yard-conv-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        // First worker question seeds the transcript.
        append_conversation_turn(&ws, "YARD-1", worker("Forward+ or GL?", "run-1")).unwrap();
        // The same run's worker turn is deduped by run_id.
        append_conversation_turn(&ws, "YARD-1", worker("dup of run-1", "run-1")).unwrap();
        // A user reply lands.
        append_conversation_turn(&ws, "YARD-1", user("what is Forward+?")).unwrap();
        // An identical consecutive user turn is skipped.
        append_conversation_turn(&ws, "YARD-1", user("what is Forward+?")).unwrap();
        // A worker turn from a different run lands.
        append_conversation_turn(
            &ws,
            "YARD-1",
            worker("Forward+ is the advanced path", "run-2"),
        )
        .unwrap();

        let conv = ws.load_conversation("YARD-1");
        assert_eq!(conv.task_id, "YARD-1");
        assert_eq!(conv.turns.len(), 3, "the two duplicate turns are dropped");
        assert_eq!(conv.turns[0].role, TurnRole::Worker);
        assert_eq!(conv.turns[0].text, "Forward+ or GL?");
        assert_eq!(conv.turns[1].role, TurnRole::User);
        assert_eq!(conv.turns[2].run_id, "run-2");

        // A task that never paused reads as an empty transcript.
        assert!(ws.load_conversation("YARD-2").turns.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_queue_loads_as_empty() {
        let dir = std::env::temp_dir().join(format!("yard-noqueue-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        // This workspace has no work-queue.yaml at all.
        assert!(!ws.queue_path().exists());

        // Loading must not error; an absent queue reads as empty (runtime state,
        // not config, so a fresh or queue-gitignoring checkout has none).
        let q = ws
            .load_queue()
            .expect("a missing queue must load as empty, not error");
        assert!(q.tasks.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }
}
