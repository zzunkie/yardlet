//! Workspace state layer.
//!
//! Yard owns canonical state under `.agents/` in the target repo. This module
//! is the only place that reads and writes those files. Everything is durable
//! and readable without any previous chat context.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::schemas::{BillingPolicy, IntentContract, WorkQueue, WorkersFile, YardConfig};
use crate::yaml;

pub const STATE_DIR: &str = ".agents";

/// A located Yard workspace: the directory that owns `.agents/`.
#[derive(Debug, Clone)]
pub struct Workspace {
    pub root: PathBuf,
}

impl Workspace {
    /// Walk up from `start` looking for an existing `.agents/yard.yaml`.
    pub fn discover(start: &Path) -> Option<Workspace> {
        let mut dir = Some(start);
        while let Some(d) = dir {
            if d.join(STATE_DIR).join("yard.yaml").is_file() {
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
        self.agents_dir().join("yard.yaml").is_file()
    }

    pub fn config_path(&self) -> PathBuf {
        self.agents_dir().join("yard.yaml")
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
        load_yaml(&self.queue_path())
    }

    pub fn save_queue(&self, queue: &WorkQueue) -> Result<()> {
        save_yaml(&self.queue_path(), queue)
    }

    pub fn load_workers(&self) -> Result<WorkersFile> {
        load_yaml(&self.workers_path())
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

pub fn write_str(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, contents).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}
