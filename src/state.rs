//! Workspace state layer.
//!
//! Yardlet owns canonical state under `.agents/` in the target repo. This module
//! is the only place that reads and writes those files. Everything is durable
//! and readable without any previous chat context.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::Local;

use serde::Deserialize;

use crate::schemas::{
    BillingPolicy, Conversation, ConversationTurn, FollowUpTask, IntentContract,
    PreservedFollowUps, SelectionPolicy, Task, TaskState, TransitionActor, TransitionCause,
    TransitionLog, TransitionRecord, TurnRole, WorkQueue, WorkersFile, YardConfig,
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

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PlanningWorkerConfig {
    #[serde(default = "default_auto")]
    pub planning_model: String,
    #[serde(default = "default_auto")]
    pub planning_effort: String,
}

impl Default for PlanningWorkerConfig {
    fn default() -> Self {
        Self {
            planning_model: default_auto(),
            planning_effort: default_auto(),
        }
    }
}

fn default_auto() -> String {
    "auto".to_string()
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
    pub fn transitions_dir(&self) -> PathBuf {
        self.agents_dir().join("transitions")
    }
    pub fn transition_path(&self, task_id: &str) -> PathBuf {
        self.transitions_dir().join(format!("{task_id}.yaml"))
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

    pub fn load_planning_worker_config(&self) -> Result<PlanningWorkerConfig> {
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

    /// Append a user-authored task to the latest queue without re-planning or
    /// rewriting existing tasks. This is the `yardlet add` path used while an
    /// auto-drain may already be running; always load the current queue first so
    /// a stale caller cannot clobber runtime state.
    pub fn append_user_task(&self, input: UserTaskInput) -> Result<Task> {
        let mut queue = self.load_queue()?;
        let next_num = queue
            .tasks
            .iter()
            .filter_map(|t| {
                t.id.strip_prefix("YARD-")
                    .and_then(|n| n.parse::<usize>().ok())
            })
            .max()
            .unwrap_or(queue.tasks.len())
            + 1;
        let base_priority = queue.tasks.iter().map(|t| t.priority).max().unwrap_or(0);
        let task = Task {
            id: format!("YARD-{next_num:03}"),
            title: input.title,
            state: TaskState::Queued,
            priority: base_priority + 10,
            risk: input.risk,
            kind: input.kind,
            preferred_worker: input.preferred_worker,
            model: String::new(),
            effort: String::new(),
            depends_on: input.depends_on,
            skills: Vec::new(),
            required_capabilities: Vec::new(),
            allowed_scope: input.allowed_scope,
            acceptance: Vec::new(),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: Some("added directly by user with yardlet add".to_string()),
            provenance: "user-added".to_string(),
        };
        queue.tasks.push(task.clone());
        self.save_queue(&queue)?;
        Ok(task)
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

    pub fn load_transition_log(&self, task_id: &str) -> TransitionLog {
        let p = self.transition_path(task_id);
        if !p.is_file() {
            return TransitionLog {
                task_id: task_id.to_string(),
                records: Vec::new(),
            };
        }
        load_yaml(&p).unwrap_or_else(|_| TransitionLog {
            task_id: task_id.to_string(),
            records: Vec::new(),
        })
    }

    pub fn latest_transition(&self, task_id: &str) -> Option<TransitionRecord> {
        self.load_transition_log(task_id).records.pop()
    }

    /// Read every task's transition log under `.agents/transitions/`. Read-only:
    /// the trust report (`src/trust.rs`) consumes these; nothing here writes.
    /// Malformed or empty logs are skipped, and the result is ordered by task id
    /// so callers fold them deterministically. A missing directory (a fresh or
    /// queue-gitignored workspace) is simply no logs, not an error.
    pub fn load_all_transition_logs(&self) -> Vec<TransitionLog> {
        let Ok(entries) = fs::read_dir(self.transitions_dir()) else {
            return Vec::new();
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "yaml"))
            .collect();
        paths.sort();
        paths
            .iter()
            .filter_map(|p| load_yaml::<TransitionLog>(p).ok())
            .filter(|log| !log.records.is_empty())
            .collect()
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

    /// Wipe the live intent + queue so the workspace starts fresh. Call AFTER
    /// [`crate::report::archive_intent`] has captured the record: this only
    /// removes the live files, so `load_intent` then reads None and `load_queue`
    /// reads an empty queue. Missing files are not an error (already clear).
    pub fn clear_intent_and_queue(&self) -> Result<()> {
        for p in [self.intent_path(), self.queue_path()] {
            if p.is_file() {
                fs::remove_file(&p).with_context(|| format!("removing {}", p.display()))?;
            }
        }
        Ok(())
    }

    /// Load the follow-ups preserved when an intent was archived
    /// (`.agents/intents/<intent_id>/follow-up-tasks.yaml`). None when the intent
    /// left no proposed follow-ups (or the file is absent/unreadable).
    pub fn load_preserved_follow_ups(&self, intent_id: &str) -> Option<PreservedFollowUps> {
        let p = self
            .agents_dir()
            .join("intents")
            .join(intent_id)
            .join("follow-up-tasks.yaml");
        if !p.is_file() {
            return None;
        }
        load_yaml(&p).ok()
    }

    /// Seed a fresh live intent + queue from a single (typically preserved)
    /// follow-up: write a new `intent-contract.yaml` derived from the follow-up
    /// and an empty queue for `seed_fn` to populate. Returns the new intent id.
    /// The caller (the engine promote path) fills the queue's seed task so the
    /// planner's ingest logic (id/approval/decision handling) stays the single
    /// owner of task shaping.
    pub fn seed_intent_from_follow_up(
        &self,
        fu: &FollowUpTask,
        intent_id: &str,
        seed_fn: impl FnOnce(&mut WorkQueue),
    ) -> Result<String> {
        let summary = {
            let title = fu.title.trim();
            let reason = fu.reason.trim();
            if reason.is_empty() {
                title.to_string()
            } else {
                format!("{title} \u{2014} {reason}")
            }
        };
        let intent = IntentContract {
            schema_version: 1,
            id: intent_id.to_string(),
            source: "promoted-follow-up".to_string(),
            raw_request: fu.title.trim().to_string(),
            summary,
            allowed_scope: fu.allowed_scope.clone(),
            out_of_scope: Vec::new(),
            acceptance: fu
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            images: Vec::new(),
            ambiguity: String::new(),
            open_questions: Vec::new(),
            clarifications: Vec::new(),
            interview_turns: 0,
            status: String::new(),
        };
        save_yaml(&self.intent_path(), &intent)?;
        let mut queue = WorkQueue {
            schema_version: 1,
            queue_id: format!("queue-{intent_id}"),
            intent_id: intent_id.to_string(),
            selection_policy: SelectionPolicy::default(),
            tasks: Vec::new(),
        };
        seed_fn(&mut queue);
        self.save_queue(&queue)?;
        Ok(intent_id.to_string())
    }

    pub fn tidy(&self) -> Result<TidyReport> {
        let workers = self.load_workers().ok();
        let vocab = workers
            .as_ref()
            .map(crate::routing::declared_capabilities)
            .unwrap_or_default();
        let mut queue = self.load_queue()?;
        let snapshot = queue.clone();
        let mut report = TidyReport::default();

        for task in &mut queue.tasks {
            let from = task.state;
            if task.state == TaskState::Blocked && !task.required_capabilities.is_empty() {
                let missing =
                    crate::routing::unsatisfiable_capabilities(&task.required_capabilities, &vocab);
                if missing.is_empty() {
                    continue;
                }
                match crate::routing::classify_stale_gate(&missing) {
                    crate::routing::GateShape::Decision => {
                        task.state = TaskState::NeedsUser;
                        task.required_capabilities.clear();
                        let detail = format!(
                            "migrated stale capability gate to a human decision question: {}",
                            missing.join(", ")
                        );
                        append_rationale(task, &detail);
                        let question = format!(
                            "This task needs your decision before Yardlet can run it: {}. Reply with the decision or instructions to proceed.",
                            task.title
                        );
                        append_conversation_turn(
                            self,
                            &task.id,
                            ConversationTurn {
                                role: TurnRole::Worker,
                                text: question,
                                run_id: String::new(),
                                ts: Local::now().to_rfc3339(),
                            },
                        )?;
                        append_transition(
                            self,
                            transition(
                                &task.id,
                                from,
                                task.state,
                                TransitionCause::StaleMigration,
                                &detail,
                                TransitionActor::System,
                            ),
                        )?;
                        report.migrated_decisions.push(task.id.clone());
                    }
                    crate::routing::GateShape::ToolGap => {
                        task.state = TaskState::Deferred;
                        task.set_deferred_by(Some(crate::schemas::DeferredBy::new(&task.id)));
                        let detail = format!(
                            "set aside stale capability gate because no enabled worker declares [{}]",
                            missing.join(", ")
                        );
                        append_rationale(task, &detail);
                        append_transition(
                            self,
                            transition(
                                &task.id,
                                from,
                                task.state,
                                TransitionCause::TidyDefer,
                                &detail,
                                TransitionActor::System,
                            ),
                        )?;
                        report.deferred.push(task.id.clone());
                    }
                }
                continue;
            }

            if task.state == TaskState::Queued {
                let approved =
                    task.approval_required() && crate::approvals::is_granted(self, &task.id);
                let class = snapshot.runnable_class(task, approved, &vocab);
                if matches!(
                    class,
                    crate::schemas::RunnableClass::WaitingDependency
                        | crate::schemas::RunnableClass::WaitingApproval
                        | crate::schemas::RunnableClass::WaitingCapability
                ) {
                    task.state = TaskState::Deferred;
                    task.set_deferred_by(Some(crate::schemas::DeferredBy::new(&task.id)));
                    let detail = format!("tidy set aside non-runnable task: {}", class.label());
                    append_rationale(task, &detail);
                    append_transition(
                        self,
                        transition(
                            &task.id,
                            from,
                            task.state,
                            TransitionCause::TidyDefer,
                            &detail,
                            TransitionActor::System,
                        ),
                    )?;
                    report.deferred.push(task.id.clone());
                }
            }
        }

        self.save_queue(&queue)?;

        let has_open_decision = queue
            .tasks
            .iter()
            .any(|t| t.state == TaskState::NeedsUser || t.state == TaskState::Running);
        let has_runnable = queue.tasks.iter().any(|t| {
            queue.is_runnable_now(
                t,
                t.approval_required() && crate::approvals::is_granted(self, &t.id),
                &vocab,
            )
        });
        if !queue.tasks.is_empty() && queue.drained() && !has_open_decision && !has_runnable {
            if let Some(intent_id) = crate::report::archive_intent(self)? {
                clear_intent_and_queue_with_wrap(self, &queue, &intent_id)?;
                report.archived_intent = Some(intent_id);
            }
        }

        Ok(report)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TidyReport {
    pub archived_intent: Option<String>,
    pub migrated_decisions: Vec<String>,
    pub deferred: Vec<String>,
}

fn append_rationale(task: &mut Task, detail: &str) {
    task.worker_rationale = Some(match task.worker_rationale.take() {
        Some(r) if !r.trim().is_empty() => format!("{r}\n{detail}"),
        _ => detail.to_string(),
    });
}

pub struct UserTaskInput {
    pub title: String,
    pub risk: String,
    pub kind: String,
    pub preferred_worker: String,
    pub depends_on: Vec<String>,
    pub allowed_scope: Vec<String>,
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

pub fn save_config_preserving_format(path: &Path, config: &YardConfig) -> Result<bool> {
    let current: YardConfig = load_yaml(path)?;
    let mut edits = Vec::new();
    if current.language != config.language {
        edits.push(LineEdit::string("language", &config.language));
    }
    if current.default_access != config.default_access {
        edits.push(LineEdit::string("default_access", &config.default_access));
    }
    if current.max_parallel != config.max_parallel {
        edits.push(LineEdit::usize("max_parallel", config.max_parallel));
    }
    if current.auto_ime != config.auto_ime {
        edits.push(LineEdit::bool("auto_ime", config.auto_ime));
    }
    if edits.is_empty() {
        return Ok(false);
    }

    let original =
        fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let updated = apply_top_level_edits(&original, &edits)?;
    if updated == original {
        return Ok(false);
    }
    fs::write(path, updated).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

pub fn save_workers_preserving_format(path: &Path, workers: &WorkersFile) -> Result<bool> {
    let current: WorkersFile = load_yaml(path)?;
    let mut text =
        fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let original = text.clone();

    for desired in &workers.workers {
        let Some(existing) = current.workers.iter().find(|w| w.id == desired.id) else {
            continue;
        };
        if existing.enabled != desired.enabled {
            text = apply_worker_edit(
                &text,
                &desired.id,
                &LineEdit::bool("enabled", desired.enabled),
            )?;
        }
        if existing.model != desired.model {
            text = apply_worker_edit(
                &text,
                &desired.id,
                &LineEdit::string("model", &desired.model),
            )?;
        }
        if existing.effort != desired.effort {
            text = apply_worker_edit(
                &text,
                &desired.id,
                &LineEdit::string("effort", &desired.effort),
            )?;
        }
    }

    if text == original {
        return Ok(false);
    }
    fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

#[derive(Debug)]
struct LineEdit<'a> {
    key: &'static str,
    value: ScalarValue<'a>,
}

impl<'a> LineEdit<'a> {
    fn string(key: &'static str, value: &'a str) -> Self {
        Self {
            key,
            value: ScalarValue::String(value),
        }
    }

    fn bool(key: &'static str, value: bool) -> Self {
        Self {
            key,
            value: ScalarValue::Bool(value),
        }
    }

    fn usize(key: &'static str, value: usize) -> Self {
        Self {
            key,
            value: ScalarValue::Usize(value),
        }
    }
}

#[derive(Debug)]
enum ScalarValue<'a> {
    String(&'a str),
    Bool(bool),
    Usize(usize),
}

fn apply_top_level_edits(input: &str, edits: &[LineEdit<'_>]) -> Result<String> {
    let mut lines = split_preserving_newlines(input);
    for edit in edits {
        let mut found = false;
        for line in &mut lines {
            let (body, eol) = split_line_ending(line);
            let Some((indent, key, _)) = yaml_key_line(body) else {
                continue;
            };
            if indent == 0 && key == edit.key {
                *line = format!("{}{}", replace_line_value(body, &edit.value), eol);
                found = true;
                break;
            }
        }
        if !found {
            lines.push(format!(
                "{}: {}\n",
                edit.key,
                render_scalar("", &edit.value)
            ));
        }
    }
    Ok(lines.concat())
}

fn apply_worker_edit(input: &str, worker_id: &str, edit: &LineEdit<'_>) -> Result<String> {
    let mut lines = split_preserving_newlines(input);
    let Some((start, end, child_indent)) = find_worker_block(&lines, worker_id) else {
        anyhow::bail!("worker '{worker_id}' not found in workers.yaml");
    };

    for line in lines.iter_mut().take(end).skip(start + 1) {
        let (body, eol) = split_line_ending(line);
        let Some((indent, key, _)) = yaml_key_line(body) else {
            continue;
        };
        if indent == child_indent && key == edit.key {
            *line = format!("{}{}", replace_line_value(body, &edit.value), eol);
            return Ok(lines.concat());
        }
    }

    let eol = lines
        .get(start)
        .map(|line| split_line_ending(line).1)
        .filter(|e| !e.is_empty())
        .unwrap_or("\n");
    lines.insert(
        start + 1,
        format!(
            "{}{}: {}{}",
            " ".repeat(child_indent),
            edit.key,
            render_scalar("", &edit.value),
            eol
        ),
    );
    Ok(lines.concat())
}

fn find_worker_block(lines: &[String], worker_id: &str) -> Option<(usize, usize, usize)> {
    for (idx, line) in lines.iter().enumerate() {
        let (body, _) = split_line_ending(line);
        let Some((item_indent, id)) = worker_id_line(body) else {
            continue;
        };
        if id != worker_id {
            continue;
        }
        let mut end = lines.len();
        for (j, next) in lines.iter().enumerate().skip(idx + 1) {
            let (next_body, _) = split_line_ending(next);
            let trimmed = next_body.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let indent = leading_spaces(next_body);
            if indent <= item_indent {
                end = j;
                break;
            }
        }
        return Some((idx, end, item_indent + 2));
    }
    None
}

fn worker_id_line(line: &str) -> Option<(usize, &str)> {
    let item_indent = leading_spaces(line);
    let trimmed = line.trim_start();
    let rest = trimmed.strip_prefix("- ")?;
    let (_, key, value) = yaml_key_line(rest)?;
    if key != "id" {
        return None;
    }
    Some((
        item_indent,
        value_without_comment(value)
            .trim_matches('"')
            .trim_matches('\''),
    ))
}

fn yaml_key_line(line: &str) -> Option<(usize, &str, &str)> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let colon = trimmed.find(':')?;
    let key = trimmed[..colon].trim();
    if key.is_empty()
        || !key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    Some((line.len() - trimmed.len(), key, &trimmed[colon + 1..]))
}

fn replace_line_value(line: &str, value: &ScalarValue<'_>) -> String {
    let Some(colon) = line.find(':') else {
        return line.to_string();
    };
    let (prefix, rest) = line.split_at(colon + 1);
    let rest = rest.strip_prefix(' ').unwrap_or(rest);
    let (old_value, comment) = split_inline_comment(rest);
    let rendered = render_scalar(old_value.trim(), value);
    if comment.is_empty() {
        format!("{prefix} {rendered}")
    } else {
        format!("{prefix} {rendered}{comment}")
    }
}

fn render_scalar(existing: &str, value: &ScalarValue<'_>) -> String {
    match value {
        ScalarValue::Bool(v) => v.to_string(),
        ScalarValue::Usize(v) => v.to_string(),
        ScalarValue::String(v) => render_string_scalar(existing, v),
    }
}

fn render_string_scalar(existing: &str, value: &str) -> String {
    if existing.starts_with('\'') {
        return format!("'{}'", value.replace('\'', "''"));
    }
    if existing.starts_with('"') {
        return serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string());
    }
    if value.is_empty() {
        return "\"\"".to_string();
    }
    if is_plain_scalar(value) {
        value.to_string()
    } else {
        serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
    }
}

fn is_plain_scalar(value: &str) -> bool {
    if value.trim() != value || matches!(value, "true" | "false" | "null" | "~") {
        return false;
    }
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '@'))
}

fn split_inline_comment(rest: &str) -> (&str, &str) {
    let mut quote: Option<char> = None;
    for (idx, ch) in rest.char_indices() {
        match (quote, ch) {
            (Some('\''), '\'') => quote = None,
            (Some('"'), '"') => quote = None,
            (None, '\'' | '"') => quote = Some(ch),
            (None, '#') if idx == 0 || rest[..idx].ends_with(char::is_whitespace) => {
                let mut comment_start = idx;
                while comment_start > 0
                    && rest[..comment_start]
                        .chars()
                        .next_back()
                        .is_some_and(char::is_whitespace)
                {
                    comment_start -= rest[..comment_start]
                        .chars()
                        .next_back()
                        .map(char::len_utf8)
                        .unwrap_or(1);
                }
                return (&rest[..comment_start], &rest[comment_start..]);
            }
            _ => {}
        }
    }
    (rest, "")
}

fn value_without_comment(value: &str) -> &str {
    split_inline_comment(value).0.trim()
}

fn split_preserving_newlines(input: &str) -> Vec<String> {
    if input.is_empty() {
        return Vec::new();
    }
    input.split_inclusive('\n').map(str::to_string).collect()
}

fn split_line_ending(line: &str) -> (&str, &str) {
    if let Some(body) = line.strip_suffix("\r\n") {
        (body, "\r\n")
    } else if let Some(body) = line.strip_suffix('\n') {
        (body, "\n")
    } else {
        (line, "")
    }
}

fn leading_spaces(line: &str) -> usize {
    line.bytes().take_while(|b| *b == b' ').count()
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

pub fn transition(
    task_id: &str,
    from: TaskState,
    to: TaskState,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> TransitionRecord {
    TransitionRecord {
        task_id: task_id.to_string(),
        from,
        to,
        cause,
        detail: detail.to_string(),
        actor,
        ts: Local::now().to_rfc3339(),
    }
}

pub fn append_transition(ws: &Workspace, rec: TransitionRecord) -> Result<()> {
    let mut log = ws.load_transition_log(&rec.task_id);
    if log.task_id.is_empty() {
        log.task_id = rec.task_id.clone();
    }
    if log.records.last().is_some_and(|last| {
        last.from == rec.from
            && last.to == rec.to
            && last.cause == rec.cause
            && last.detail.trim() == rec.detail.trim()
    }) {
        return Ok(());
    }
    log.records.push(rec);
    save_yaml(&ws.transition_path(&log.task_id), &log)
}

fn clear_intent_and_queue_with_wrap(
    ws: &Workspace,
    queue: &WorkQueue,
    intent_id: &str,
) -> Result<()> {
    for task in &queue.tasks {
        append_transition(
            ws,
            transition(
                &task.id,
                task.state,
                task.state,
                TransitionCause::Wrap,
                &format!("archived drained intent {intent_id} and cleared the live queue"),
                TransitionActor::System,
            ),
        )?;
    }
    ws.clear_intent_and_queue()
}

pub fn write_str(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, contents).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

pub fn append_str(path: &Path, contents: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening {}", path.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONFIG_WITH_COMMENTS: &str = r#"schema_version: 1
product: yardlet
workspace_id: test-workspace
created_at: "2026-07-03T00:00:00Z"
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: ""
# language stays user-owned
language: auto
default_access: sandboxed # keep access comment
max_parallel: 1
auto_ime: true
ambiguity_gate: true
harness_discovery: true
skill_library: ""
auto_equip: true
auto_skill: true
auto_rule: false
auto_prune: true
hooks: true
auto_commit: false
"#;

    const WORKERS_WITH_COMMENTS: &str = r#"schema_version: 1
workers:
  - id: codex
    # user note for codex
    enabled: true # keep enabled comment
    model: "" # keep model comment
    effort: ""
    invocation:
      command: codex
  - id: claude-code
    # untouched worker comment
    enabled: true
    model: sonnet
    effort: medium
    invocation:
      command: claude
routing:
  default_worker: codex
  fallback_order: [codex, claude-code]
"#;

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("yard-{name}-{}", std::process::id()))
    }

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
    fn transition_log_appends_and_dedupes_last_reason() {
        let dir = temp_root("transition-log");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        let rec = transition(
            "YARD-1",
            TaskState::Queued,
            TaskState::Deferred,
            TransitionCause::Defer,
            "set aside for later",
            TransitionActor::User,
        );
        append_transition(&ws, rec.clone()).unwrap();
        append_transition(&ws, rec).unwrap();

        let log = ws.load_transition_log("YARD-1");
        assert_eq!(log.records.len(), 1);
        assert_eq!(
            ws.latest_transition("YARD-1").unwrap().detail,
            "set aside for later"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn load_all_transition_logs_reads_every_task_deterministically() {
        let dir = temp_root("all-transitions");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);

        // A missing transitions dir is simply no logs, not an error.
        assert!(ws.load_all_transition_logs().is_empty());

        append_transition(
            &ws,
            transition(
                "YARD-2",
                TaskState::Running,
                TaskState::Done,
                TransitionCause::RunOutcome,
                "worker evaluated task as Done",
                TransitionActor::Worker("run-2".into()),
            ),
        )
        .unwrap();
        append_transition(
            &ws,
            transition(
                "YARD-1",
                TaskState::Queued,
                TaskState::Deferred,
                TransitionCause::Defer,
                "set aside",
                TransitionActor::User,
            ),
        )
        .unwrap();

        let logs = ws.load_all_transition_logs();
        assert_eq!(logs.len(), 2);
        // Ordered by task id (path sort), not by write order.
        assert_eq!(logs[0].task_id, "YARD-1");
        assert_eq!(logs[1].task_id, "YARD-2");
        assert_eq!(logs[1].records[0].cause, TransitionCause::RunOutcome);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tidy_migrates_stale_decision_and_defers_tool_gap_without_deleting_done() {
        let dir = temp_root("tidy-state");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let mut decision: Task =
            crate::yaml::from_str("id: DECIDE\ntitle: pick option\nrequired_capabilities: [user_creative_direction_approval]\n").unwrap();
        decision.state = TaskState::Blocked;
        let mut tool: Task =
            crate::yaml::from_str("id: TOOL\ntitle: import licensed asset\nrequired_capabilities: [licensed_3d_asset_intake]\n").unwrap();
        tool.state = TaskState::Blocked;
        let mut done: Task = crate::yaml::from_str("id: DONE\ntitle: done\n").unwrap();
        done.state = TaskState::Done;
        let mut queue = WorkQueue::empty();
        queue.tasks = vec![decision, tool, done];
        ws.save_queue(&queue).unwrap();

        let report = ws.tidy().unwrap();

        assert_eq!(report.migrated_decisions, vec!["DECIDE".to_string()]);
        assert_eq!(report.deferred, vec!["TOOL".to_string()]);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].state, TaskState::NeedsUser);
        assert!(q.tasks[0].required_capabilities.is_empty());
        assert_eq!(q.tasks[1].state, TaskState::Deferred);
        assert_eq!(q.tasks[2].state, TaskState::Done);
        assert_eq!(
            ws.latest_transition("DECIDE").unwrap().cause,
            TransitionCause::StaleMigration
        );
        assert_eq!(
            ws.latest_transition("TOOL").unwrap().cause,
            TransitionCause::TidyDefer
        );
        assert!(!ws.load_conversation("DECIDE").turns.is_empty());

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

    #[test]
    fn append_user_task_preserves_existing_runtime_queue() {
        let dir = std::env::temp_dir().join(format!("yard-add-task-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ws = Workspace::at(&dir);
        let mut queue = WorkQueue::empty();
        queue.tasks.push(Task {
            id: "YARD-001".to_string(),
            title: "running".to_string(),
            state: TaskState::Running,
            priority: 10,
            risk: "medium".to_string(),
            kind: "implementation".to_string(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            depends_on: Vec::new(),
            skills: Vec::new(),
            required_capabilities: Vec::new(),
            allowed_scope: Vec::new(),
            acceptance: Vec::new(),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
        });
        ws.save_queue(&queue).unwrap();

        let added = ws
            .append_user_task(UserTaskInput {
                title: "새 독립 작업".to_string(),
                risk: "low".to_string(),
                kind: "implementation".to_string(),
                preferred_worker: String::new(),
                depends_on: Vec::new(),
                allowed_scope: vec!["src/run.rs".to_string()],
            })
            .unwrap();

        let q = ws.load_queue().unwrap();
        assert_eq!(added.id, "YARD-002");
        assert_eq!(q.tasks.len(), 2);
        assert_eq!(q.tasks[0].state, TaskState::Running);
        assert_eq!(q.tasks[1].id, "YARD-002");
        assert_eq!(q.tasks[1].state, TaskState::Queued);
        assert!(q.tasks[1].depends_on.is_empty());
        assert_eq!(q.tasks[1].provenance, "user-added");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn serde_yaml_save_reproduces_comment_loss_for_user_config_files() {
        let dir = temp_root("serde-comment-loss");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let cfg: YardConfig = load_yaml(&ws.config_path()).unwrap();
        save_yaml(&ws.config_path(), &cfg).unwrap();
        let rewritten_config = fs::read_to_string(ws.config_path()).unwrap();
        assert!(!rewritten_config.contains("language stays user-owned"));
        assert!(!rewritten_config.contains("keep access comment"));

        let workers: WorkersFile = load_yaml(&ws.workers_path()).unwrap();
        save_yaml(&ws.workers_path(), &workers).unwrap();
        let rewritten_workers = fs::read_to_string(ws.workers_path()).unwrap();
        assert!(!rewritten_workers.contains("user note for codex"));
        assert!(!rewritten_workers.contains("untouched worker comment"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn config_preserving_save_noops_and_keeps_legacy_path() {
        let dir = temp_root("legacy-config-preserve");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        let legacy = ws.agents_dir().join(LEGACY_CONFIG_FILE);
        fs::write(&legacy, CONFIG_WITH_COMMENTS).unwrap();

        assert_eq!(ws.config_path(), legacy);
        let before = fs::read(&legacy).unwrap();
        let cfg = ws.load_config().unwrap();
        assert!(!save_config_preserving_format(&ws.config_path(), &cfg).unwrap());
        assert_eq!(fs::read(&legacy).unwrap(), before);
        assert!(!ws.agents_dir().join(CONFIG_FILE).exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn config_preserving_save_changes_only_target_scalar_lines() {
        let dir = temp_root("config-target-edit");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();

        let mut cfg = ws.load_config().unwrap();
        cfg.default_access = "full".to_string();
        cfg.language = "ko".to_string();
        assert!(save_config_preserving_format(&ws.config_path(), &cfg).unwrap());
        let updated = fs::read_to_string(ws.config_path()).unwrap();
        assert!(updated.contains("# language stays user-owned"));
        assert!(updated.contains("language: ko"));
        assert!(updated.contains("default_access: full # keep access comment"));
        assert!(updated.contains("workspace_id: test-workspace"));
        assert!(updated.contains("auto_commit: false"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn planning_worker_config_defaults_to_auto_when_keys_are_missing() {
        let dir = temp_root("planning-config-default");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();

        let cfg = ws.load_planning_worker_config().unwrap();
        assert_eq!(cfg.planning_model, "auto");
        assert_eq!(cfg.planning_effort, "auto");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn planning_worker_config_reads_explicit_model_and_effort() {
        let dir = temp_root("planning-config-explicit");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        let config =
            format!("{CONFIG_WITH_COMMENTS}planning_model: gpt-5.5\nplanning_effort: high\n");
        fs::write(ws.config_path(), config).unwrap();

        let cfg = ws.load_planning_worker_config().unwrap();
        assert_eq!(cfg.planning_model, "gpt-5.5");
        assert_eq!(cfg.planning_effort, "high");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn workers_preserving_save_changes_only_target_worker_keys() {
        let dir = temp_root("workers-target-edit");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let before = fs::read_to_string(ws.workers_path()).unwrap();
        let mut workers = ws.load_workers().unwrap();
        let codex = workers
            .workers
            .iter_mut()
            .find(|w| w.id == "codex")
            .unwrap();
        codex.enabled = false;
        codex.model = "gpt-5".to_string();
        codex.effort = "high".to_string();
        assert!(save_workers_preserving_format(&ws.workers_path(), &workers).unwrap());
        let updated = fs::read_to_string(ws.workers_path()).unwrap();
        assert_ne!(updated, before);
        assert!(updated.contains("# user note for codex"));
        assert!(updated.contains("enabled: false # keep enabled comment"));
        assert!(updated.contains("model: \"gpt-5\" # keep model comment"));
        assert!(updated.contains("effort: \"high\""));
        assert!(updated.contains("# untouched worker comment"));
        assert!(updated.contains("model: sonnet"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn workers_preserving_save_noops_when_values_are_unchanged() {
        let dir = temp_root("workers-noop");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(STATE_DIR)).unwrap();
        let ws = Workspace::at(&dir);
        fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();

        let before = fs::read(ws.workers_path()).unwrap();
        let workers = ws.load_workers().unwrap();
        assert!(!save_workers_preserving_format(&ws.workers_path(), &workers).unwrap());
        assert_eq!(fs::read(ws.workers_path()).unwrap(), before);

        let _ = fs::remove_dir_all(&dir);
    }
}
