//! Terminal UI (Ratatui).
//!
//! The TUI is the normal interface, but it is never the canonical state store:
//! it reads and writes through Yardlet's state layer. Long worker runs happen on a
//! background thread so the UI stays responsive; the event loop polls a channel
//! for completion and animates a spinner meanwhile.

pub(crate) mod i18n;
mod ime;
mod planning_review;
mod text_input;
mod view;

use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Result;
use ratatui::crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyEventKind, KeyModifiers,
    KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{self, SetTitle};

use crate::run::{self, RunOptions};
use crate::schemas::TaskState;
use crate::snapshot::Snapshot;
use crate::state::{self, Workspace};

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Screen {
    Home,
    NewWork,
    PlanningReview,
    Answer,
    Handoff,
    Intent,
    Trust,
    Settings,
    Monitor,
    Completion,
    ReportList,
    Approvals,
    /// The full Home key list (`?`). Home's footer can only carry the keys that
    /// have a target right now, so the always-valid globals live here.
    Keys,
}

/// One editable settings row. `key` routes the value back to the right file:
/// "access"/"language" -> yard.yaml; "model:<id>"/"effort:<id>" -> workers.yaml.
/// `options` are the Space-cycle presets ("" = default); typing still works.
pub struct Field {
    pub label: String,
    pub key: String,
    pub value: String,
    pub options: Vec<String>,
}

pub struct SettingsDraft {
    pub fields: Vec<Field>,
    pub sel: usize,
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

/// Cycle options for a field key. Model lists come from the machine itself
/// (CLI aliases; ids seen in recent codex sessions), so they stay current.
fn options_for(key: &str) -> Vec<String> {
    if key == "access" {
        strs(&["sandboxed", "full"])
    } else if key == "parallel" {
        strs(&["1", "2", "3", "4"])
    } else if key == "ime" {
        strs(&["on", "off"])
    } else if key == "language" {
        strs(&["auto", "ko", "en"])
    } else if key == "effort:codex" {
        crate::workers::known_codex_efforts()
    } else if key == "effort:claude-code" {
        crate::workers::known_claude_efforts()
    } else if key.starts_with("effort:") {
        strs(&["", "low", "medium", "high"])
    } else if key == "model:claude-code" {
        crate::workers::known_claude_models()
    } else if key == "model:codex" {
        crate::workers::known_codex_models()
    } else {
        Vec::new()
    }
}

pub struct JobResult {
    pub ok: bool,
    pub summary: String,
}

fn localized_run_outcome(lang: i18n::Lang, report: &crate::run::RunReport) -> String {
    report
        .result_state
        .map(|state| i18n::task_state_label(lang.l(), state).to_string())
        .unwrap_or_else(|| report.lines.last().cloned().unwrap_or_default())
}

#[derive(Clone)]
pub struct ApprovalBatchRow {
    pub id: String,
    pub title: String,
    pub needs_answer: bool,
    pub selected: bool,
}

#[derive(Clone)]
pub enum ReportEntry {
    Current {
        label: String,
    },
    Archived {
        label: String,
        dir: std::path::PathBuf,
    },
    /// One confirmed drain of a replanned intent, nested under its archive
    /// row; opens that drain's own final report.
    ArchivedDrain {
        label: String,
        dir: std::path::PathBuf,
    },
    FollowUp {
        label: String,
        intent_id: String,
        task: Box<crate::schemas::FollowUpTask>,
    },
}

/// Messages a background job streams to the UI loop.
pub enum JobMsg {
    Progress(String),
    Done(JobResult),
    PlanningDone(JobResult),
}

pub enum Job {
    Idle,
    Running {
        label: String,
        started: Instant,
        rx: Receiver<JobMsg>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StartupStage {
    Recovery,
    WorkerProbe,
}

enum StartupMsg {
    Progress(StartupStage),
    Ready {
        snapshot: Box<Snapshot>,
        recovered: Vec<String>,
    },
    Failed(String),
}

#[derive(Debug)]
enum BootstrapState {
    Loading(StartupStage),
    Ready,
    Failed(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BootstrapPhase {
    Loading,
    Ready,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BootstrapKeyAction {
    Dispatch,
    Quit,
    Retry,
    Block,
}

fn bootstrap_key_action(phase: BootstrapPhase, code: KeyCode) -> BootstrapKeyAction {
    use BootstrapKeyAction::*;
    match (phase, code) {
        (BootstrapPhase::Ready, _) => Dispatch,
        (_, KeyCode::Char('q') | KeyCode::Esc) => Quit,
        (BootstrapPhase::Failed, KeyCode::Char('g')) => Retry,
        _ => Block,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScrollViewport {
    pub width: u16,
    pub height: u16,
}

pub struct App {
    pub ws: Workspace,
    pub screen: Screen,
    pub snapshot: Option<Snapshot>,
    bootstrap: BootstrapState,
    startup_rx: Option<Receiver<StartupMsg>>,
    startup_started: Instant,
    startup_just_created: bool,
    pub input: String,
    /// Edit caret as a char index into `input` (text screens). Lets Left/Right/
    /// Home/End move and edit mid-string instead of append-only.
    pub input_caret: usize,
    /// Whether the terminal reports modified Enter keys unambiguously.
    keyboard_enhancement: bool,
    /// Latest surface-neutral planning projection shown on PlanningReview.
    /// The UI never edits this value or canonical files directly; every action
    /// is dispatched back through `planning`.
    pub planning_review: Option<crate::planning::PlanningProjection>,
    pub planning_review_text: String,
    pub planning_review_editing: bool,
    /// Which pending proposal accept/reject acts on, as an index into the
    /// projection's `pending_proposals`. Only user-visible when several are
    /// pending; Tab/Shift+Tab cycle it. Clamped whenever the projection reloads.
    pub planning_review_target: usize,
    pub job: Job,
    pub toast: Option<(bool, String)>,
    pub progress: Option<String>,
    pub handoff_text: String,
    pub intent_text: String,
    pub report_text: String,
    /// Rendered trust + autonomy panel text (v1 table + v2 autonomy block).
    pub trust_text: String,
    /// The `?` key list, generated on entry so it scrolls through the same
    /// clamp every other scrollable screen uses (issue #71 remediation).
    pub keys_text: String,
    /// When true, NewWork input continues (amends) the current intent instead of
    /// starting a fresh one.
    pub amend: bool,
    /// When true, NewWork input asks for a replacement direction and reopens
    /// planning under the same failure-settled intent id.
    pub replan: bool,
    /// The running auto-drain's pause flag, if any. Set it to stop the drain
    /// gracefully after the current task; cleared when the job ends.
    pub pause: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    /// Vertical scroll offset for the handoff/report screens.
    pub scroll: u16,
    /// Monitor scroll-back: index of the first visible log line.
    ///
    /// Held separately from `scroll` because the monitor's content grows under
    /// the viewport. An offset from the TOP stays put as output arrives; an
    /// offset from the bottom would drift a frozen view downward on every write
    /// (issue #54).
    pub monitor_top: usize,
    /// Is the monitor pinned to the newest output? True until the operator
    /// scrolls up, true again the moment they return to the bottom.
    pub monitor_follow: bool,
    /// Log lines the last monitor frame could show, and the largest top index
    /// that still fills it. Recorded by the renderer so paging uses the real
    /// viewport rather than an assumed height.
    pub monitor_visible: usize,
    pub monitor_max_top: usize,
    /// Last rendered inner viewport for the active scrollable text screen.
    pub scroll_viewport: Option<ScrollViewport>,
    /// Selected row in the Home queue (for per-task handoff view).
    pub selected: usize,
    /// Reports/history browser: live report, archived intents, and preserved
    /// follow-ups that can be promoted into fresh work.
    pub reports: Vec<ReportEntry>,
    pub report_sel: usize,
    /// True while viewing an archived report (read-only; no new/continue/redo).
    pub viewing_archived: bool,
    /// Multi-approval picker rows and cursor.
    pub approval_rows: Vec<ApprovalBatchRow>,
    pub approval_sel: usize,
    pub settings: Option<SettingsDraft>,
    pub last_title: Option<String>,
    /// Which running task the Run Monitor is following (Tab cycles when
    /// several tasks run in parallel).
    pub monitor_sel: usize,
    /// Cached Monitor state so rendering never scans the runs directory or
    /// re-parses the whole worker log per frame.
    pub monitor: MonitorCache,
    /// A newer yard binary replaced the one this process was started from
    /// (cargo install while running). `u` re-execs into it.
    pub update_available: bool,
    /// Set by the `u` key; the main loop exits and re-execs the new binary.
    pub want_restart: bool,
    /// What the Answer screen is replying to: (task id, question/context).
    /// Set when the screen opens — a NeedsUser question, or a Partial/Blocked
    /// task's remaining-work context (the answer becomes rerun instructions).
    pub answer_target: Option<(String, String)>,
    /// Read-only context shown above the question on the Answer screen. Built
    /// once from the current intent's latest matching run and conversation.
    pub answer_context: String,
    /// The current Answer submission should grant the selected task's
    /// single-use approval before resuming it. This keeps input+approval work in
    /// one deliberate UI flow without weakening run_next's approval gate.
    pub answer_grants_approval: bool,
    /// The non-ASCII input source we auto-switched away from (restored when a
    /// text-input screen opens, or on quit).
    pub ime_saved: Option<String>,
    /// Throttle for the IME poll (checking the current source every frame
    /// would be wasteful).
    pub ime_checked: Instant,
    pub lang: i18n::Lang,
}

#[derive(Default)]
pub struct MonitorCache {
    /// (task id, latest run dir) for every Running task, in queue order.
    pub runs: Vec<(String, std::path::PathBuf)>,
    /// Newest run dir, used when nothing is running (post-run inspection).
    pub fallback: Option<std::path::PathBuf>,
    /// Header fields of the followed run (from its run.yaml).
    pub header: Option<MonitorHeader>,
    pub log_path: Option<std::path::PathBuf>,
    pub log_len: u64,
    /// Pretty-printed log lines (already filtered through pretty_event_line).
    pub log_lines: Vec<String>,
    /// True when `m` opened the selected Failed/Partial task's exact attempt
    /// streams instead of the live run tail.
    pub diagnostic: bool,
}

pub struct MonitorHeader {
    pub run_name: String,
    pub task_id: String,
    pub worker: String,
    /// run.yaml's state — written once at start; the queue is the live truth.
    pub recorded_state: String,
}

/// Read at most the last `max` bytes of a file, starting at a line boundary.
fn read_tail(path: &std::path::Path, max: u64) -> String {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(path) else {
        return String::new();
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    if len > max {
        let _ = f.seek(SeekFrom::End(-(max as i64)));
    }
    let mut buf = Vec::new();
    let _ = f.read_to_end(&mut buf);
    let mut s = String::from_utf8_lossy(&buf).into_owned();
    if len > max {
        // Drop the partial first line the seek may have cut into.
        if let Some(i) = s.find('\n') {
            s.drain(..=i);
        }
    }
    s
}

/// The most recently modified run dir (no per-dir file reads).
fn newest_run_dir(runs: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut newest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
    for e in std::fs::read_dir(runs).ok()?.flatten() {
        if !e.path().is_dir() {
            continue;
        }
        let t = e
            .metadata()
            .and_then(|m| m.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        if newest.as_ref().map(|(nt, _)| t > *nt).unwrap_or(true) {
            newest = Some((t, e.path()));
        }
    }
    newest.map(|(_, p)| p)
}

fn recover_startup_state(ws: &Workspace) -> Result<Vec<String>> {
    // This must precede both recovery paths: consuming an unhandled planning
    // result can archive and replace intent/queue state, while orphan recovery
    // can rewrite task state. Corrupt activated state is therefore a hard
    // startup error, not a recoverable input.
    crate::planning::validate_active_activation(ws)?;
    let mut recovered = Vec::new();
    if let Some(message) = crate::planner::recover_unconsumed_plan(ws)? {
        recovered.push(message);
    }
    recovered.extend(crate::run::recover_orphans(ws));
    Ok(recovered)
}

fn spawn_startup_job_with<Recover, Load>(
    ws: Workspace,
    recover: Recover,
    load: Load,
) -> Receiver<StartupMsg>
where
    Recover: FnOnce(&Workspace) -> Result<Vec<String>> + Send + 'static,
    Load: FnOnce(&Workspace) -> Result<Snapshot> + Send + 'static,
{
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        if tx
            .send(StartupMsg::Progress(StartupStage::Recovery))
            .is_err()
        {
            return;
        }
        let recovered = match recover(&ws) {
            Ok(recovered) => recovered,
            Err(error) => {
                let _ = tx.send(StartupMsg::Failed(error.to_string()));
                return;
            }
        };
        if tx
            .send(StartupMsg::Progress(StartupStage::WorkerProbe))
            .is_err()
        {
            return;
        }
        match load(&ws) {
            Ok(snapshot) => {
                let _ = tx.send(StartupMsg::Ready {
                    snapshot: Box::new(snapshot),
                    recovered,
                });
            }
            Err(error) => {
                let _ = tx.send(StartupMsg::Failed(error.to_string()));
            }
        }
    });
    rx
}

fn fixture_recovery_delay() {
    #[cfg(debug_assertions)]
    {
        if std::env::var("YARDLET_PROCESS_FIXTURE").as_deref() != Ok("1") {
            return;
        }
        let delay = std::env::var("YARDLET_FIXTURE_RECOVERY_DELAY_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0)
            .min(60_000);
        if delay > 0 {
            thread::sleep(Duration::from_millis(delay));
        }
    }
}

fn spawn_startup_job(ws: Workspace) -> Receiver<StartupMsg> {
    spawn_startup_job_with(
        ws,
        |workspace| {
            fixture_recovery_delay();
            recover_startup_state(workspace)
        },
        Snapshot::load,
    )
}

#[cfg(test)]
fn lang_of(snapshot: &Option<Snapshot>) -> i18n::Lang {
    snapshot
        .as_ref()
        .map(|s| i18n::detect(&s.config.language, s.intent_summary()))
        .unwrap_or(i18n::Lang::En)
}

impl App {
    #[cfg(test)]
    fn new(ws: Workspace) -> App {
        let snapshot = Snapshot::load(&ws).ok();
        let lang = lang_of(&snapshot);
        Self::build(ws, snapshot, BootstrapState::Ready, false, lang)
    }

    fn new_bootstrapping(ws: Workspace, just_created: bool) -> App {
        let lang = ws
            .load_config()
            .ok()
            .map(|config| i18n::detect(&config.language, ""))
            .unwrap_or(i18n::Lang::En);
        Self::build(
            ws,
            None,
            BootstrapState::Loading(StartupStage::Recovery),
            just_created,
            lang,
        )
    }

    fn build(
        ws: Workspace,
        snapshot: Option<Snapshot>,
        bootstrap: BootstrapState,
        startup_just_created: bool,
        lang: i18n::Lang,
    ) -> App {
        App {
            ws,
            screen: Screen::Home,
            snapshot,
            bootstrap,
            startup_rx: None,
            startup_started: Instant::now(),
            startup_just_created,
            input: String::new(),
            input_caret: 0,
            keyboard_enhancement: false,
            planning_review: None,
            planning_review_text: String::new(),
            planning_review_editing: false,
            planning_review_target: 0,
            job: Job::Idle,
            toast: None,
            progress: None,
            handoff_text: String::new(),
            intent_text: String::new(),
            report_text: String::new(),
            trust_text: String::new(),
            keys_text: String::new(),
            amend: false,
            replan: false,
            pause: None,
            scroll: 0,
            monitor_top: 0,
            monitor_follow: true,
            monitor_visible: 0,
            monitor_max_top: 0,
            scroll_viewport: None,
            selected: 0,
            reports: Vec::new(),
            report_sel: 0,
            viewing_archived: false,
            approval_rows: Vec::new(),
            approval_sel: 0,
            settings: None,
            last_title: None,
            monitor_sel: 0,
            monitor: MonitorCache::default(),
            update_available: false,
            want_restart: false,
            answer_target: None,
            answer_context: String::new(),
            answer_grants_approval: false,
            ime_saved: None,
            ime_checked: Instant::now(),
            lang,
        }
    }

    fn bootstrap_phase(&self) -> BootstrapPhase {
        match self.bootstrap {
            BootstrapState::Loading(_) => BootstrapPhase::Loading,
            BootstrapState::Ready => BootstrapPhase::Ready,
            BootstrapState::Failed(_) => BootstrapPhase::Failed,
        }
    }

    fn begin_startup(&mut self, rx: Receiver<StartupMsg>) {
        self.snapshot = None;
        self.bootstrap = BootstrapState::Loading(StartupStage::Recovery);
        self.startup_started = Instant::now();
        self.startup_rx = Some(rx);
        self.toast = None;
    }

    fn apply_startup_msg(&mut self, message: StartupMsg) -> bool {
        match message {
            StartupMsg::Progress(stage) => {
                self.bootstrap = BootstrapState::Loading(stage);
                false
            }
            StartupMsg::Ready {
                snapshot,
                recovered,
            } => {
                self.lang = i18n::detect(&snapshot.config.language, snapshot.intent_summary());
                self.snapshot = Some(*snapshot);
                self.bootstrap = BootstrapState::Ready;
                self.startup_rx = None;
                if self.startup_just_created {
                    self.toast = Some((true, self.lang.l().initialized.to_string()));
                    self.startup_just_created = false;
                } else if !recovered.is_empty() {
                    self.toast = Some((true, recovered.join("; ")));
                }
                self.refresh_monitor_runs();
                true
            }
            StartupMsg::Failed(error) => {
                self.snapshot = None;
                self.bootstrap = BootstrapState::Failed(error);
                self.startup_rx = None;
                false
            }
        }
    }

    fn poll_startup(&mut self) {
        loop {
            let message = match self.startup_rx.as_ref().map(Receiver::try_recv) {
                Some(Ok(message)) => message,
                Some(Err(mpsc::TryRecvError::Empty)) | None => return,
                Some(Err(mpsc::TryRecvError::Disconnected)) => {
                    self.apply_startup_msg(StartupMsg::Failed(
                        "startup job ended without a result".to_string(),
                    ));
                    return;
                }
            };
            if self.apply_startup_msg(message) {
                return;
            }
        }
    }

    /// Keep the OS input source in sync with the screen (macOS, opt-out via
    /// the auto_ime setting): shortcut screens get an ASCII layout so single
    /// keys aren't eaten by IME composition; text screens get the user's IME
    /// back. `force` skips the 1s throttle (used on screen transitions).
    fn sync_ime(&mut self, force: bool) {
        let enabled = self
            .snapshot
            .as_ref()
            .map(|s| s.config.auto_ime)
            .unwrap_or(true);
        if !enabled {
            return;
        }
        if !force && self.ime_checked.elapsed() < Duration::from_secs(1) {
            return;
        }
        self.ime_checked = Instant::now();
        let text_input = matches!(self.screen, Screen::NewWork | Screen::Answer)
            || (self.screen == Screen::PlanningReview && self.planning_review_editing);
        match ime_sync_action(text_input, force) {
            ImeSync::RestoreSaved => {
                // Text input: give the user their IME back.
                if let Some(id) = self.ime_saved.take() {
                    let _ = ime::select_by_id(&id);
                }
            }
            ImeSync::ForceAscii => {
                if let Some((id, ascii)) = ime::current_id_and_ascii() {
                    if !ascii && ime::select_ascii() {
                        self.ime_saved = Some(id);
                    }
                }
            }
            ImeSync::Leave => {}
        }
    }

    /// Cheap state reload: re-reads the yaml files but reuses the last worker
    /// probe (probing spawns `--version` per worker and blocks the event loop
    /// for ~100ms — see `reload_full`). Safe to call once a second mid-run.
    fn reload(&mut self) {
        let cached = self.snapshot.as_ref().map(|s| s.workers.clone());
        let loaded = match cached {
            Some(w) => Snapshot::load_reusing_workers(&self.ws, w),
            None => Snapshot::load(&self.ws),
        };
        if let Ok(s) = loaded {
            self.lang = i18n::detect(&s.config.language, s.intent_summary());
            self.snapshot = Some(s);
        }
        self.refresh_monitor_runs();
    }

    /// Full reload including a fresh worker readiness probe (g / startup).
    fn reload_full(&mut self) {
        if let Ok(s) = Snapshot::load(&self.ws) {
            self.lang = i18n::detect(&s.config.language, s.intent_summary());
            self.snapshot = Some(s);
        }
        self.refresh_monitor_runs();
    }

    /// Rebuild the Monitor's task→run-dir map (a runs-directory scan per
    /// running task — done here, on reload/entry, never per frame).
    fn refresh_monitor_runs(&mut self) {
        if self.monitor.diagnostic {
            return;
        }
        let mut runs = Vec::new();
        if let Some(s) = &self.snapshot {
            for t in &s.queue.tasks {
                if t.state == TaskState::Running {
                    if let Some((_, dir)) = crate::run::latest_run_for(&self.ws, &t.id) {
                        runs.push((t.id.clone(), dir));
                    }
                }
            }
        }
        self.monitor.fallback = if runs.is_empty() {
            newest_run_dir(&self.ws.runs_dir())
        } else {
            None
        };
        if !runs.is_empty() {
            self.monitor_sel %= runs.len();
        } else {
            self.monitor_sel = 0;
        }
        self.monitor.runs = runs;
    }

    /// Refresh the Monitor's log view. Called every frame while the Monitor is
    /// open, but cheap: stat the file and re-read (the tail only) when it grew
    /// or the followed run changed.
    fn refresh_monitor_log(&mut self) {
        if self.monitor.diagnostic {
            return;
        }
        let dir = if self.monitor.runs.is_empty() {
            self.monitor.fallback.clone()
        } else {
            Some(
                self.monitor.runs[self.monitor_sel % self.monitor.runs.len()]
                    .1
                    .clone(),
            )
        };
        let Some(dir) = dir else {
            self.monitor.log_path = None;
            self.monitor.log_lines.clear();
            self.monitor.header = None;
            return;
        };
        let path = dir.join("worker-output.log");
        let len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        if self.monitor.log_path.as_ref() == Some(&path) && self.monitor.log_len == len {
            return;
        }
        // Scroll-back is only as deep as what was read. 128KB was sized for a
        // live tail nobody could move, and it put a wall a few screens above the
        // bottom the moment scrolling existed (issue #54). 4MB is still a
        // bounded read of a local file, done only when the log grows.
        const TAIL: u64 = 4 * 1024 * 1024;
        let raw = read_tail(&path, TAIL);
        self.monitor.log_lines = raw
            .lines()
            .filter_map(view::pretty_event_line)
            .collect::<Vec<_>>();
        // Header fields come from the run dir's small run.yaml, once per change.
        let yaml = std::fs::read_to_string(dir.join("run.yaml")).unwrap_or_default();
        let field = |k: &str| {
            yaml.lines()
                .find_map(|ln| ln.trim().strip_prefix(k))
                .map(|v| v.trim().trim_matches('"').to_string())
                .unwrap_or_default()
        };
        let task_id = field("task_id:");
        if let Some(intent_id) = self
            .snapshot
            .as_ref()
            .map(|snapshot| snapshot.queue.intent_id.as_str())
            .filter(|intent_id| !intent_id.is_empty())
        {
            if let Ok(channel) = self.ws.load_task_channel(intent_id, &task_id) {
                let projected = channel_projection_lines(&channel, self.lang.l());
                let has_public_progress = channel.events.iter().any(|event| {
                    !matches!(
                        event.event_type,
                        crate::schemas::ChannelEventType::AttemptPrepared
                            | crate::schemas::ChannelEventType::WorkerStarted
                    )
                });
                if has_public_progress && !projected.is_empty() {
                    self.monitor.log_lines = projected;
                }
            }
        }
        self.monitor.header = Some(MonitorHeader {
            run_name: dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string(),
            task_id,
            worker: field("worker:"),
            recorded_state: field("state:"),
        });
        self.monitor.log_path = Some(path);
        self.monitor.log_len = len;
    }

    fn is_busy(&self) -> bool {
        matches!(self.job, Job::Running { .. })
    }

    // ---- text input editing (caret-aware) ------------------------------

    /// Byte offset of char index `i` (end of string when past the last char).
    fn input_byte(&self, i: usize) -> usize {
        self.input
            .char_indices()
            .nth(i)
            .map(|(b, _)| b)
            .unwrap_or(self.input.len())
    }

    fn input_len_chars(&self) -> usize {
        self.input.chars().count()
    }

    fn input_clear(&mut self) {
        self.input.clear();
        self.input_caret = 0;
    }

    /// Insert text at the caret and advance past it.
    fn input_insert(&mut self, s: &str) {
        let at = self.input_byte(self.input_caret);
        self.input.insert_str(at, s);
        self.input_caret += s.chars().count();
    }

    /// Delete the char before the caret (Backspace).
    fn input_backspace(&mut self) {
        if self.input_caret == 0 {
            return;
        }
        let start = self.input_byte(self.input_caret - 1);
        let end = self.input_byte(self.input_caret);
        self.input.replace_range(start..end, "");
        self.input_caret -= 1;
    }

    /// Delete the char at the caret (Delete).
    fn input_delete(&mut self) {
        if self.input_caret >= self.input_len_chars() {
            return;
        }
        let start = self.input_byte(self.input_caret);
        let end = self.input_byte(self.input_caret + 1);
        self.input.replace_range(start..end, "");
    }

    fn caret_left(&mut self) {
        self.input_caret = self.input_caret.saturating_sub(1);
    }
    fn caret_right(&mut self) {
        if self.input_caret < self.input_len_chars() {
            self.input_caret += 1;
        }
    }
    fn caret_home(&mut self) {
        let chars: Vec<char> = self.input.chars().collect();
        let caret = self.input_caret.min(chars.len());
        self.input_caret = chars[..caret]
            .iter()
            .rposition(|&c| c == '\n')
            .map(|index| index + 1)
            .unwrap_or(0);
    }
    fn caret_end(&mut self) {
        let chars: Vec<char> = self.input.chars().collect();
        let caret = self.input_caret.min(chars.len());
        self.input_caret = chars[caret..]
            .iter()
            .position(|&c| c == '\n')
            .map(|offset| caret + offset)
            .unwrap_or(chars.len());
    }
    /// Move the caret up one line in the multi-line input, keeping the column
    /// (clamped to the previous line's length). On the first line, jump to the
    /// very start. Char-indexed, so it stays correct with multibyte/CJK text.
    fn caret_up(&mut self) {
        let chars: Vec<char> = self.input.chars().collect();
        let caret = self.input_caret.min(chars.len());
        let line_start = chars[..caret]
            .iter()
            .rposition(|&c| c == '\n')
            .map(|i| i + 1)
            .unwrap_or(0);
        if line_start == 0 {
            self.input_caret = 0;
            return;
        }
        let col = caret - line_start;
        let prev_end = line_start - 1; // the '\n' ending the previous line
        let prev_start = chars[..prev_end]
            .iter()
            .rposition(|&c| c == '\n')
            .map(|i| i + 1)
            .unwrap_or(0);
        self.input_caret = prev_start + col.min(prev_end - prev_start);
    }
    /// Move the caret down one line, keeping the column. On the last line, jump
    /// to the very end.
    fn caret_down(&mut self) {
        let chars: Vec<char> = self.input.chars().collect();
        let caret = self.input_caret.min(chars.len());
        let line_start = chars[..caret]
            .iter()
            .rposition(|&c| c == '\n')
            .map(|i| i + 1)
            .unwrap_or(0);
        let col = caret - line_start;
        let line_end = chars[caret..]
            .iter()
            .position(|&c| c == '\n')
            .map(|i| caret + i)
            .unwrap_or(chars.len());
        if line_end >= chars.len() {
            self.input_caret = chars.len();
            return;
        }
        let next_start = line_end + 1;
        let next_end = chars[next_start..]
            .iter()
            .position(|&c| c == '\n')
            .map(|i| next_start + i)
            .unwrap_or(chars.len());
        self.input_caret = next_start + col.min(next_end - next_start);
    }
}

pub fn run(ws: &Workspace, just_created: bool) -> Result<()> {
    let mut terminal = ratatui::init();
    let mut app = App::new_bootstrapping(ws.clone(), just_created);
    let mut enhanced = false;
    let result = (|| -> Result<bool> {
        // Draw a fail-closed loading frame before recovery, snapshot validation,
        // worker probes, IME inspection, or terminal capability queries.
        terminal.draw(|frame| view::render(frame, &mut app))?;

        let startup = spawn_startup_job(ws.clone());
        app.begin_startup(startup);

        // Enable bracketed paste so pasted text (incl. composed Korean/CJK)
        // arrives as one Event::Paste instead of being dropped.
        let _ = execute!(std::io::stdout(), EnableBracketedPaste);
        // Ask for unambiguous modified-key events so Ctrl+Enter can be an
        // optional submit chord. This query is intentionally after the first
        // frame. Treat enhancement as enabled only when the push succeeds.
        if terminal::supports_keyboard_enhancement().unwrap_or(false) {
            enhanced = execute!(
                std::io::stdout(),
                PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
            )
            .is_ok();
        }
        app.keyboard_enhancement = enhanced;
        main_loop(&mut terminal, app)
    })();
    if enhanced {
        let _ = execute!(std::io::stdout(), PopKeyboardEnhancementFlags);
    }
    let _ = execute!(std::io::stdout(), DisableBracketedPaste, SetTitle(""));
    ratatui::restore();
    // `u` after an in-place upgrade: replace this process with the new binary
    // (same path, same cwd). State lives in .agents/, so nothing is lost; a
    // still-running worker is adopted by the new process on startup.
    if let Ok(true) = &result {
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            if let Ok(exe) = std::env::current_exe() {
                let err = std::process::Command::new(exe).exec();
                eprintln!("yard: restart failed: {err}");
            }
        }
    }
    result.map(|_| ())
}

/// The terminal title for the current state: running task, else current intent,
/// else the app + version.
fn title_for(app: &App) -> String {
    let clip = |s: &str| -> String { s.chars().take(50).collect() };
    if app.is_busy() {
        match &app.progress {
            Some(p) => format!("Yardlet \u{00b7} {}", clip(p)),
            None => format!("Yardlet \u{00b7} {}", app.lang.l().run_word),
        }
    } else {
        match app.snapshot.as_ref().map(|s| s.intent_summary()) {
            Some(intent) if !intent.starts_with('(') => {
                format!("Yardlet \u{00b7} {}", clip(intent))
            }
            _ => format!("Yardlet v{}", env!("CARGO_PKG_VERSION")),
        }
    }
}

/// Modification time of the binary this process was started from.
/// What one input-source sync pass may do. The ASCII force runs only on a
/// real screen transition: the periodic poll must never wrestle a deliberate
/// 한/영 toggle back to ASCII, because tools like Karabiner-Elements switch
/// the source out from under us and the user always wins (issue #130). The
/// poll still restores a saved IME once a text screen is focused (covers the
/// in-screen edit toggle on the plan review, which changes no screen).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ImeSync {
    RestoreSaved,
    ForceAscii,
    Leave,
}

fn ime_sync_action(text_input_screen: bool, force: bool) -> ImeSync {
    if text_input_screen {
        ImeSync::RestoreSaved
    } else if force {
        ImeSync::ForceAscii
    } else {
        ImeSync::Leave
    }
}

fn binary_mtime() -> Option<std::time::SystemTime> {
    std::fs::metadata(std::env::current_exe().ok()?)
        .ok()?
        .modified()
        .ok()
}

/// Returns Ok(true) when the loop ended with a restart request (`u` after an
/// in-place binary upgrade) — the caller re-execs the new binary.
fn main_loop(terminal: &mut ratatui::DefaultTerminal, mut app: App) -> Result<bool> {
    // Force a full repaint when the screen changes so leaving a content-heavy
    // screen (e.g. the Monitor's live worker output) doesn't leave artifacts
    // bleeding onto the next one.
    let mut last_screen: Option<Screen> = None;
    let mut tick: u32 = 0;
    let mut last_idle_recover = Instant::now();
    let launched_mtime = binary_mtime();
    let mut last_update_check = Instant::now();
    loop {
        app.poll_startup();

        // Notice an in-place upgrade (cargo install while running): the file
        // at our own path got a new mtime. Cheap stat, every ~5s.
        if !app.update_available && last_update_check.elapsed() >= Duration::from_secs(5) {
            last_update_check = Instant::now();
            if let (Some(at_launch), Some(now)) = (launched_mtime, binary_mtime()) {
                if now != at_launch {
                    app.update_available = true;
                }
            }
        }
        // While idle with a task still Running — an adopted worker from a
        // previous session — poll for its completion so the finished work is
        // evaluated (and merged) without the user doing anything.
        if matches!(app.job, Job::Idle) && last_idle_recover.elapsed() >= Duration::from_secs(5) {
            last_idle_recover = Instant::now();
            let has_running = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.iter().any(|t| t.state == TaskState::Running))
                .unwrap_or(false);
            if has_running {
                let msgs = crate::run::recover_orphans(&app.ws);
                let changed: Vec<String> = msgs
                    .into_iter()
                    .filter(|m| !m.starts_with("adopted:"))
                    .collect();
                if !changed.is_empty() {
                    app.toast = Some((true, changed.join("; ")));
                    app.reload();
                }
            }
        }
        // Drain background-job messages: progress lines stream in; the final
        // Done message ends the job.
        if let Job::Running { rx, .. } = &app.job {
            let mut latest_progress = None;
            let mut finished = None;
            let mut planning_finished = false;
            loop {
                match rx.try_recv() {
                    Ok(JobMsg::Progress(s)) => latest_progress = Some(s),
                    Ok(JobMsg::Done(r)) => finished = Some(r),
                    Ok(JobMsg::PlanningDone(r)) => {
                        planning_finished = r.ok;
                        finished = Some(r);
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    // The job thread died without reporting (panic): fail the
                    // job instead of spinning busy forever. Any orphaned
                    // worker is picked up by the idle recovery pass.
                    Err(mpsc::TryRecvError::Disconnected) => {
                        if finished.is_none() {
                            finished = Some(JobResult {
                                ok: false,
                                summary: app.lang.l().background_job_failed.to_string(),
                            });
                        }
                        break;
                    }
                }
            }
            let got_progress = latest_progress.is_some();
            if let Some(p) = latest_progress {
                app.progress = Some(p);
            }
            let job_done = finished.is_some();
            let opened_planning_review = finished
                .map(|result| finish_background_job(&mut app, result, planning_finished))
                .unwrap_or(false);
            // Refresh the queue snapshot — but throttled. Snapshot::load probes
            // worker readiness (spawns `--version`), so reloading every ~120ms
            // tick blocks the event loop. Reload on a transition, on finish, and
            // about once a second otherwise.
            tick = tick.wrapping_add(1);
            if got_progress || job_done || tick % 8 == 0 {
                app.reload();
            }
            // When a job finishes and the whole queue is done, surface the
            // intent-level final report and let the user pick what's next.
            if job_done
                && !opened_planning_review
                && app
                    .snapshot
                    .as_ref()
                    .map(|s| queue_ready_for_completion(&s.queue))
                    .unwrap_or(false)
            {
                app.report_text = crate::report::build_final_report(&app.ws).unwrap_or_default();
                app.scroll = 0;
                app.viewing_archived = false;
                app.screen = Screen::Completion;
            }
        }

        if last_screen != Some(app.screen) {
            let _ = terminal.clear();
            if app.screen == Screen::Monitor {
                app.refresh_monitor_runs();
            }
            // Screen changed: sync the input source immediately (ASCII for
            // shortcuts, the user's IME back for text input).
            app.sync_ime(true);
            last_screen = Some(app.screen);
        } else {
            // Poll only restores the IME on text screens (in-screen edit
            // toggles change no screen); it never re-forces ASCII, so a
            // deliberate 한/영 toggle sticks (issue #130).
            app.sync_ime(false);
        }
        // Keep the Monitor's log cache current (stat per frame; read on growth).
        if app.screen == Screen::Monitor {
            app.refresh_monitor_log();
        }
        terminal.draw(|frame| view::render(frame, &mut app))?;

        // Reflect Yardlet's state in the terminal title (OSC sequence), only when
        // it changes.
        let title = title_for(&app);
        if app.last_title.as_deref() != Some(title.as_str()) {
            let _ = execute!(std::io::stdout(), SetTitle(&title));
            app.last_title = Some(title);
        }

        // Poll so the spinner animates and the channel is checked even with no
        // key activity.
        if !event::poll(Duration::from_millis(120))? {
            continue;
        }
        let event = event::read()?;
        // Pasted text (a reliable path for Korean/CJK that raw-mode IME mangles)
        // goes straight into the active input field.
        if let Event::Paste(text) = &event {
            handle_input_paste(&mut app, text);
            continue;
        }
        let Event::Key(key) = event else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }

        // Ctrl-C always quits.
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            break;
        }

        // On shortcut screens, map Korean 2-beolsik jamo to the QWERTY key
        // that produces them, so shortcuts still work with the IME on
        // (pressing m with 한글 active arrives as 'ㅡ'). Text-input screens
        // (and the planning-review edit buffer) keep the raw character.
        let code = dispatch_code(
            app.screen,
            app.planning_review_editing,
            key.code,
            key.modifiers.contains(KeyModifiers::SHIFT),
        );

        match bootstrap_key_action(app.bootstrap_phase(), code) {
            BootstrapKeyAction::Dispatch => {}
            BootstrapKeyAction::Quit => break,
            BootstrapKeyAction::Retry => {
                let startup = spawn_startup_job(app.ws.clone());
                app.begin_startup(startup);
                continue;
            }
            BootstrapKeyAction::Block => continue,
        }

        match app.screen {
            Screen::Home => {
                if handle_home_key(&mut app, code) {
                    break;
                }
            }
            Screen::NewWork => handle_new_work_key(&mut app, key.code, key.modifiers),
            Screen::PlanningReview => handle_planning_review_key(&mut app, code, key.modifiers),
            Screen::Answer => handle_answer_key(&mut app, key.code, key.modifiers),
            Screen::Settings => handle_settings_key(&mut app, key.code),
            Screen::Completion => handle_completion_key(&mut app, code),
            Screen::ReportList => handle_reportlist_key(&mut app, code),
            Screen::Approvals => handle_approvals_key(&mut app, code),
            Screen::Handoff => handle_handoff_key(&mut app, code),
            Screen::Keys => handle_keys_key(&mut app, code),
            Screen::Intent => handle_intent_key(&mut app, code),
            Screen::Trust => handle_trust_key(&mut app, code),
            Screen::Monitor => match code {
                KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::Home,
                // Stop/pause work here too, so the monitor isn't a dead end:
                // `x` stops the running worker, `p` pauses a drain (both also on
                // Home). Esc/q stays "back to Home". The diagnostic Monitor
                // (opened on a Failed/Partial attempt via `m`) is a read-only
                // postmortem with no live worker to stop or drain to pause, so
                // both keys are inert there; the live Monitor keeps them.
                KeyCode::Char('x') | KeyCode::Char('p') => match monitor_control_action(
                    code,
                    app.monitor.diagnostic,
                    app.is_busy() || has_running_task(&app),
                ) {
                    MonitorControl::Stop => stop_running_worker(&mut app),
                    MonitorControl::Pause => request_pause(&mut app),
                    MonitorControl::Ignore => {}
                },
                // Scroll back through what the worker already printed. The
                // operator asked for what a normal streaming session gives them
                // (issue #54).
                KeyCode::Up
                | KeyCode::Down
                | KeyCode::PageUp
                | KeyCode::PageDown
                | KeyCode::Home
                | KeyCode::End => {
                    let (top, follow) = monitor_scroll_to(
                        code,
                        app.monitor_top,
                        app.monitor_max_top,
                        app.monitor_visible,
                    );
                    app.monitor_top = top;
                    app.monitor_follow = follow;
                }
                // Cycle which parallel run is being followed.
                KeyCode::Tab | KeyCode::Right => {
                    let n = app.monitor.runs.len().max(1);
                    app.monitor_sel = (app.monitor_sel + 1) % n;
                }
                KeyCode::Left => {
                    let n = app.monitor.runs.len().max(1);
                    app.monitor_sel = (app.monitor_sel + n - 1) % n;
                }
                _ => {}
            },
        }
    }
    // Leave the input source the way we found it.
    if let Some(id) = app.ime_saved.take() {
        let _ = ime::select_by_id(&id);
    }
    Ok(app.want_restart)
}

/// The effective key code to dispatch on `screen`. Text-input screens (and the
/// planning-review *edit* buffer, `planning_review_editing`) keep the raw
/// character so multi-line Korean input survives verbatim; every other
/// (shortcut) screen gets the [`dekorean`] fallback so a/r/c/e/g/q still fire
/// while the Korean IME is active and `auto_ime` never switched the OS input
/// source to ASCII. Pure so the screen → raw/mapped decision is unit-tested
/// without a live event loop.
fn dispatch_code(
    screen: Screen,
    planning_review_editing: bool,
    code: KeyCode,
    shifted: bool,
) -> KeyCode {
    match screen {
        Screen::NewWork | Screen::Answer | Screen::Settings => code,
        Screen::PlanningReview if planning_review_editing => code,
        _ => dekorean(code, shifted),
    }
}

/// Map a Korean 2-beolsik jamo back to the QWERTY key that produces it, so
/// keyboard shortcuts work while the Korean IME is active. `shifted` upgrades
/// the mapped letter for Shift-chords (Shift+ㅁ → 'A'); the double jamo
/// (ㅃㅉㄸㄲㅆ…) already imply Shift and map straight to uppercase.
fn dekorean(code: KeyCode, shifted: bool) -> KeyCode {
    let KeyCode::Char(c) = code else {
        return code;
    };
    let mapped = match c {
        'ㅂ' => 'q',
        'ㅈ' => 'w',
        'ㄷ' => 'e',
        'ㄱ' => 'r',
        'ㅅ' => 't',
        'ㅛ' => 'y',
        'ㅕ' => 'u',
        'ㅑ' => 'i',
        'ㅐ' => 'o',
        'ㅔ' => 'p',
        'ㅁ' => 'a',
        'ㄴ' => 's',
        'ㅇ' => 'd',
        'ㄹ' => 'f',
        'ㅎ' => 'g',
        'ㅗ' => 'h',
        'ㅓ' => 'j',
        'ㅏ' => 'k',
        'ㅣ' => 'l',
        'ㅋ' => 'z',
        'ㅌ' => 'x',
        'ㅊ' => 'c',
        'ㅍ' => 'v',
        'ㅠ' => 'b',
        'ㅜ' => 'n',
        'ㅡ' => 'm',
        'ㅃ' => 'Q',
        'ㅉ' => 'W',
        'ㄸ' => 'E',
        'ㄲ' => 'R',
        'ㅆ' => 'T',
        'ㅒ' => 'O',
        'ㅖ' => 'P',
        _ => return code,
    };
    if shifted && mapped.is_ascii_lowercase() {
        KeyCode::Char(mapped.to_ascii_uppercase())
    } else {
        KeyCode::Char(mapped)
    }
}

/// Every action Home dispatches.
///
/// The dispatcher acts ONLY on this enum, so the set of working Home keys is
/// enumerable rather than buried in a match on raw key codes. That is what the
/// key list renders from and what its coverage test walks: a key that works but
/// is documented nowhere was invisible to a test suite written only around the
/// footer's own behavior (issue #71).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomeKey {
    Quit,
    Restart,
    New,
    Replan,
    Run,
    Auto,
    Tidy,
    Defer,
    Revive,
    ApproveOrPause,
    Answer,
    Goal,
    Handoff,
    Trust,
    Settings,
    Monitor,
    Refresh,
    Language,
    Access,
    PlanReview,
    Reports,
    Stop,
    Keys,
    Up,
    Down,
    Act,
    ToggleWorker,
}

/// Ordered for the key list: navigation, then work, then always-valid globals.
const HOME_KEYS: &[HomeKey] = &[
    HomeKey::Up,
    HomeKey::Down,
    HomeKey::Act,
    HomeKey::ToggleWorker,
    HomeKey::New,
    HomeKey::Run,
    HomeKey::Auto,
    HomeKey::Answer,
    HomeKey::ApproveOrPause,
    HomeKey::Defer,
    HomeKey::Revive,
    HomeKey::Tidy,
    HomeKey::Replan,
    HomeKey::PlanReview,
    HomeKey::Monitor,
    HomeKey::Stop,
    HomeKey::Goal,
    HomeKey::Handoff,
    HomeKey::Trust,
    HomeKey::Reports,
    HomeKey::Settings,
    HomeKey::Access,
    HomeKey::Language,
    HomeKey::Refresh,
    HomeKey::Restart,
    HomeKey::Keys,
    HomeKey::Quit,
];

/// Which Home key a code means. Pure, so the key list and its coverage test
/// read the same source of truth the event loop does.
fn home_key(code: KeyCode, update_available: bool) -> Option<HomeKey> {
    Some(match code {
        KeyCode::Char('q') => HomeKey::Quit,
        // Restart into the freshly installed binary (notice in the status line).
        KeyCode::Char('u') if update_available => HomeKey::Restart,
        KeyCode::Char('n') => HomeKey::New,
        KeyCode::Char('P') => HomeKey::Replan,
        KeyCode::Char('r') => HomeKey::Run,
        KeyCode::Char('A') => HomeKey::Auto,
        KeyCode::Char('t') => HomeKey::Tidy,
        KeyCode::Char('d') => HomeKey::Defer,
        KeyCode::Char('v') => HomeKey::Revive,
        KeyCode::Char('p') => HomeKey::ApproveOrPause,
        KeyCode::Char('a') => HomeKey::Answer,
        KeyCode::Char('i') => HomeKey::Goal,
        KeyCode::Char('h') => HomeKey::Handoff,
        KeyCode::Char('T') => HomeKey::Trust,
        KeyCode::Char('s') => HomeKey::Settings,
        KeyCode::Char('m') => HomeKey::Monitor,
        KeyCode::Char('g') => HomeKey::Refresh,
        KeyCode::Char('l') => HomeKey::Language,
        KeyCode::Char('f') => HomeKey::Access,
        KeyCode::Char('o') => HomeKey::PlanReview,
        KeyCode::Char('R') => HomeKey::Reports,
        KeyCode::Char('?') => HomeKey::Keys,
        KeyCode::Esc => HomeKey::Stop,
        KeyCode::Up => HomeKey::Up,
        KeyCode::Down => HomeKey::Down,
        KeyCode::Enter => HomeKey::Act,
        KeyCode::Char(' ') => HomeKey::ToggleWorker,
        _ => return None,
    })
}

impl HomeKey {
    /// Keys that start or change work: while a worker runs they explain why
    /// nothing happened instead of acting. The rest stay live mid-run — that is
    /// the whole point of settings, access, monitor and the key list.
    fn needs_idle(self) -> bool {
        matches!(
            self,
            Self::New
                | Self::Run
                | Self::Auto
                | Self::Tidy
                | Self::Defer
                | Self::Revive
                | Self::Language
                | Self::PlanReview
        )
    }

    /// The glyph shown in the key list, matching what the operator presses.
    fn glyph(self) -> &'static str {
        match self {
            Self::Quit => "q",
            Self::Restart => "u",
            Self::New => "n",
            Self::Replan => "P",
            Self::Run => "r",
            Self::Auto => "A",
            Self::Tidy => "t",
            Self::Defer => "d",
            Self::Revive => "v",
            Self::ApproveOrPause => "p",
            Self::Answer => "a",
            Self::Goal => "i",
            Self::Handoff => "h",
            Self::Trust => "T",
            Self::Settings => "s",
            Self::Monitor => "m",
            Self::Refresh => "g",
            Self::Language => "l",
            Self::Access => "f",
            Self::PlanReview => "o",
            Self::Reports => "R",
            Self::Stop => "Esc",
            Self::Keys => "?",
            Self::Up => "\u{2191}",
            Self::Down => "\u{2193}",
            Self::Act => "Enter",
            Self::ToggleWorker => "Space",
        }
    }

    /// What the key does, in the active language. Exhaustive on purpose: a new
    /// Home action cannot compile without documenting itself.
    fn doc(self, l: &i18n::L) -> &'static str {
        match self {
            Self::Quit => l.key_doc_quit,
            Self::Restart => l.key_doc_restart,
            Self::New => l.key_doc_new,
            Self::Replan => l.key_doc_replan,
            Self::Run => l.key_doc_run,
            Self::Auto => l.key_doc_auto,
            Self::Tidy => l.key_doc_tidy,
            Self::Defer => l.key_doc_defer,
            Self::Revive => l.key_doc_revive,
            Self::ApproveOrPause => l.key_doc_approve_or_pause,
            Self::Answer => l.key_doc_answer,
            Self::Goal => l.key_doc_goal,
            Self::Handoff => l.key_doc_handoff,
            Self::Trust => l.key_doc_trust,
            Self::Settings => l.key_doc_settings,
            Self::Monitor => l.key_doc_monitor,
            Self::Refresh => l.key_doc_refresh,
            Self::Language => l.key_doc_language,
            Self::Access => l.key_doc_access,
            Self::PlanReview => l.key_doc_plan_review,
            Self::Reports => l.key_doc_reports,
            Self::Stop => l.key_doc_stop,
            Self::Keys => l.key_doc_keys,
            Self::Up => l.key_doc_up,
            Self::Down => l.key_doc_down,
            Self::Act => l.key_doc_act,
            Self::ToggleWorker => l.key_doc_toggle_worker,
        }
    }
}

/// The full Home key list, one `(glyph, description)` row per action.
pub(crate) fn home_key_rows(l: &i18n::L) -> Vec<(&'static str, &'static str)> {
    HOME_KEYS
        .iter()
        .map(|key| (key.glyph(), key.doc(l)))
        .collect()
}

/// Returns true to quit.
fn handle_home_key(app: &mut App, code: KeyCode) -> bool {
    let busy = app.is_busy();
    // A key Home does not use keeps the old fall-through: while a worker runs,
    // any stray key says why nothing happened.
    let Some(key) = home_key(code, app.update_available) else {
        if busy {
            app.toast = Some((true, app.lang.l().busy.into()));
        }
        return false;
    };
    if busy && key.needs_idle() {
        app.toast = Some((true, app.lang.l().busy.into()));
        return false;
    }
    match key {
        HomeKey::Quit => return true,
        HomeKey::Restart => {
            app.want_restart = true;
            return true;
        }
        HomeKey::New => {
            app.input_clear();
            app.toast = None;
            app.amend = false;
            app.replan = false;
            app.screen = Screen::NewWork;
        }
        HomeKey::Replan => handle_home_replan(app),
        HomeKey::Run => start_run(app),
        HomeKey::Auto => start_auto(app),
        HomeKey::Tidy => tidy_workspace(app),
        HomeKey::Defer => defer_selected_task(app),
        HomeKey::Revive => revive_selected_task(app),
        // `p` is context-aware: a selected approval row wins even while an
        // auto-drain is running; otherwise busy `p` stays graceful pause.
        HomeKey::ApproveOrPause => {
            match home_approve_key_action(selected_awaits_approval(app), busy) {
                HomeApproveKeyAction::Approve => start_approve(app),
                HomeApproveKeyAction::Pause => request_pause(app),
            }
        }
        HomeKey::Answer => handle_home_answer(app),
        HomeKey::Goal => {
            app.intent_text = build_intent_view(app);
            app.scroll = 0;
            app.screen = Screen::Intent;
        }
        HomeKey::Handoff => {
            app.handoff_text = load_latest_handoff(app);
            app.scroll = 0;
            app.screen = Screen::Handoff;
        }
        // Trust + autonomy panel: same numbers as `yardlet trust --json`.
        HomeKey::Trust => {
            app.trust_text = build_trust_view(app);
            app.scroll = 0;
            app.screen = Screen::Trust;
        }
        // Settings can be opened mid-run; saved changes apply to the next task.
        HomeKey::Settings => open_settings(app),
        // Monitor can be opened mid-run. A selected Failed/Partial task opens
        // its exact latest failed attempt; other rows keep the live view.
        HomeKey::Monitor => open_home_monitor(app),
        // Refresh is safe mid-run and lets you re-read the live queue/snapshot.
        // Explicit refresh re-probes worker readiness too (the only reload
        // that does — it spawns each worker CLI, so it is on-demand only).
        HomeKey::Refresh => app.reload_full(),
        HomeKey::Language => toggle_language(app),
        // Access can be toggled even mid-run; it takes effect on the next task.
        HomeKey::Access => toggle_access(app),
        // Esc while a worker runs stops it (kills the worker process). Also
        // covers an adopted worker from a previous session (task Running with
        // no active job): kill it and let the idle recovery pass requeue it.
        HomeKey::Stop => {
            if busy || has_running_task(app) {
                stop_running_worker(app);
            }
        }
        // Browse the queue — and past its end, the workers panel (toggle a
        // worker on/off with Enter/Space). Works while busy too.
        HomeKey::Up => app.selected = app.selected.saturating_sub(1),
        HomeKey::Down => {
            let total = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.len() + s.workers.len())
                .unwrap_or(0);
            if app.selected + 1 < total {
                app.selected += 1;
            }
        }
        // Enter drives the selected row: a queue task's state-appropriate next
        // action (run / answer / approve-guidance / monitor / handoff), or a
        // worker toggle past the queue. Space only toggles workers — queue rows
        // ignore it, so a stray Space never fires a task action.
        HomeKey::Act => {
            let tasks = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.len())
                .unwrap_or(0);
            if app.selected < tasks {
                handle_home_enter(app);
            } else {
                toggle_worker(app, app.selected - tasks);
            }
        }
        HomeKey::ToggleWorker => {
            let tasks = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.len())
                .unwrap_or(0);
            if app.selected >= tasks {
                toggle_worker(app, app.selected - tasks);
            }
        }
        // Re-enter an open planning session. Until today the review screen had
        // exactly one entry point — a planning job finishing in THIS process —
        // so a restart mid-flow left an accepted-but-unconfirmed plan with no
        // TUI path at all (issue #65).
        HomeKey::PlanReview => {
            if app
                .snapshot
                .as_ref()
                .is_some_and(|snap| snap.planning_reentry.is_some())
            {
                let _ = open_planning_review(app);
            } else {
                app.toast = Some((false, app.lang.l().plan_review_nothing.to_string()));
            }
        }
        // Reports/history browser: current final report + past intents.
        HomeKey::Reports => open_reports(app),
        // The always-valid globals (g, s, f, l, i, R) do not fit the footer, so
        // this list is where they stay discoverable (issue #71).
        HomeKey::Keys => {
            app.keys_text = view::key_list_text(app.lang.l());
            app.scroll = 0;
            app.scroll_viewport = None;
            app.screen = Screen::Keys;
        }
    }
    false
}

/// What Enter does on the selected queue row, decided purely from the task's
/// state, whether it is waiting on an ungranted approval, and whether a worker
/// is already running. Kept pure so the state→action mapping is unit-tested
/// without spawning workers. Approval-pending tasks never go straight to `Run`;
/// a NeedsUser task may open the answer flow, which grants approval only when
/// the user submits the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomeEnterAction {
    /// Run (or retry) this task now.
    Run,
    /// Open the answer screen for a NeedsUser task.
    Answer,
    /// Open the answer screen and grant approval when the answer is submitted.
    AnswerThenApprove,
    /// Approval-required and not granted: point at the approval flow (p), never
    /// run. Approval stays a deliberate, explicit act — Enter cannot grant it.
    ApprovalHint,
    /// Follow the running task's live output in the Monitor.
    Monitor,
    /// View this task's handoff (Done).
    Handoff,
    /// Deferred (set aside by a decision): nothing to run.
    DeferredHint,
    /// A worker is already running; a new run/answer can't start yet.
    Busy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomeMonitorAction {
    SelectedFailure,
    Live,
}

/// `m` is always read-only. Failed and Partial rows select their exact task
/// channel; every other row preserves the existing live/global Monitor.
fn home_monitor_action(
    state: Option<TaskState>,
    _approval_pending: bool,
    _busy: bool,
) -> HomeMonitorAction {
    if matches!(state, Some(TaskState::Failed | TaskState::Partial)) {
        HomeMonitorAction::SelectedFailure
    } else {
        HomeMonitorAction::Live
    }
}

/// Why the active queue may or may not be replaced by a same-intent replan.
/// This mirrors the queue-shape portion of planning's final admission gate;
/// activation integrity and open-session checks remain enforced there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReplanAvailability {
    Available,
    LiveQueue,
    WorkerQuestion,
    NothingToReplan,
}

fn same_intent_replan_availability(queue: &crate::schemas::WorkQueue) -> ReplanAvailability {
    if queue.tasks.is_empty() {
        return ReplanAvailability::NothingToReplan;
    }
    if !queue.drained() {
        return ReplanAvailability::LiveQueue;
    }
    if queue.tasks.iter().any(|task| {
        matches!(task.state, TaskState::Failed | TaskState::Partial)
            || (task.state == TaskState::NeedsUser
                && task.needs_user_origin()
                    == Some(crate::schemas::NeedsUserOrigin::GoalFeedbackExhausted))
    }) {
        return ReplanAvailability::Available;
    }
    if queue
        .tasks
        .iter()
        .any(|task| task.state == TaskState::NeedsUser)
    {
        ReplanAvailability::WorkerQuestion
    } else {
        ReplanAvailability::NothingToReplan
    }
}

/// Home/Completion replan key mapping. Kept pure so the queue eligibility,
/// busy gate, and non-replan keys can be tested without starting a planner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomeReplanAction {
    OpenPrompt,
    AnswerWorkerQuestion,
    FinishLiveQueue,
    NothingToReplan,
    Busy,
    Noop,
}

fn home_replan_action(
    code: KeyCode,
    availability: ReplanAvailability,
    busy: bool,
) -> HomeReplanAction {
    if code != KeyCode::Char('P') {
        return HomeReplanAction::Noop;
    }
    if busy {
        return HomeReplanAction::Busy;
    }
    match availability {
        ReplanAvailability::Available => HomeReplanAction::OpenPrompt,
        ReplanAvailability::WorkerQuestion => HomeReplanAction::AnswerWorkerQuestion,
        ReplanAvailability::LiveQueue => HomeReplanAction::FinishLiveQueue,
        ReplanAvailability::NothingToReplan => HomeReplanAction::NothingToReplan,
    }
}

fn current_replan_availability(app: &App) -> ReplanAvailability {
    app.snapshot
        .as_ref()
        .map(|snapshot| same_intent_replan_availability(&snapshot.queue))
        .unwrap_or(ReplanAvailability::NothingToReplan)
}

fn handle_home_replan(app: &mut App) {
    match home_replan_action(
        KeyCode::Char('P'),
        current_replan_availability(app),
        app.is_busy(),
    ) {
        HomeReplanAction::OpenPrompt => {
            app.input_clear();
            app.toast = None;
            app.amend = false;
            app.replan = true;
            app.screen = Screen::NewWork;
        }
        HomeReplanAction::AnswerWorkerQuestion => {
            app.toast = Some((true, app.lang.l().replan_worker_question_hint.into()));
        }
        HomeReplanAction::FinishLiveQueue => {
            app.toast = Some((true, app.lang.l().replan_live_queue_hint.into()));
        }
        HomeReplanAction::NothingToReplan => {
            app.toast = Some((true, app.lang.l().replan_nothing_hint.into()));
        }
        HomeReplanAction::Busy => app.toast = Some((true, app.lang.l().busy.into())),
        HomeReplanAction::Noop => {}
    }
}

fn home_enter_action(state: TaskState, approval_pending: bool, busy: bool) -> HomeEnterAction {
    match state {
        // Read-only views never spawn a worker, so approval/busy don't gate them.
        TaskState::Done => HomeEnterAction::Handoff,
        TaskState::Running => HomeEnterAction::Monitor,
        TaskState::Deferred => HomeEnterAction::DeferredHint,
        // Queued / Partial / Failed / Blocked / NeedsUser: the next action starts
        // or resumes a worker run. An ungranted approval-required task must go
        // through the approval flow first — Enter must never silently run it.
        _ => {
            if approval_pending && state == TaskState::NeedsUser {
                HomeEnterAction::AnswerThenApprove
            } else if approval_pending {
                HomeEnterAction::ApprovalHint
            } else if busy {
                HomeEnterAction::Busy
            } else if state == TaskState::NeedsUser {
                HomeEnterAction::Answer
            } else {
                HomeEnterAction::Run
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomeHoldAction {
    Defer,
    Revive,
    Busy,
    Noop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomeApproveKeyAction {
    Approve,
    Pause,
}

fn home_approve_key_action(selected_approval_pending: bool, busy: bool) -> HomeApproveKeyAction {
    if selected_approval_pending || !busy {
        HomeApproveKeyAction::Approve
    } else {
        HomeApproveKeyAction::Pause
    }
}

fn home_hold_action(state: Option<TaskState>, busy: bool, revive_key: bool) -> HomeHoldAction {
    if busy {
        return HomeHoldAction::Busy;
    }
    match (state, revive_key) {
        (Some(TaskState::Deferred), true) => HomeHoldAction::Revive,
        (Some(TaskState::Done | TaskState::Running), _) => HomeHoldAction::Noop,
        (Some(_), false) => HomeHoldAction::Defer,
        _ => HomeHoldAction::Noop,
    }
}

fn selected_awaits_approval(app: &App) -> bool {
    app.snapshot
        .as_ref()
        .and_then(|s| s.queue.tasks.get(app.selected).map(|t| (&t.id, s)))
        .is_some_and(|(id, s)| s.approvals_needed.iter().any(|approval| approval == id))
}

/// Enter on a selected queue task: run its state-appropriate next action.
fn handle_home_enter(app: &mut App) {
    let Some((id, state, approval_pending)) = app.snapshot.as_ref().and_then(|s| {
        s.queue.tasks.get(app.selected).map(|t| {
            (
                t.id.clone(),
                t.state,
                s.approvals_needed.iter().any(|a| a == &t.id),
            )
        })
    }) else {
        return;
    };
    match home_enter_action(state, approval_pending, app.is_busy()) {
        HomeEnterAction::Run => start_run_target(app, id),
        HomeEnterAction::Answer => open_answer_for_task(app, &id),
        HomeEnterAction::AnswerThenApprove => open_answer_for_task(app, &id),
        HomeEnterAction::ApprovalHint => {
            app.toast = Some((true, format!("{id}: {}", app.lang.l().approval_enter_hint)));
        }
        HomeEnterAction::Monitor => {
            prepare_live_monitor(app);
            focus_monitor_on(app, &id);
            app.screen = Screen::Monitor;
        }
        HomeEnterAction::Handoff => {
            app.handoff_text = load_handoff_for_task(app, &id);
            app.scroll = 0;
            app.screen = Screen::Handoff;
        }
        HomeEnterAction::DeferredHint => {
            app.toast = Some((true, format!("{id}: {}", app.lang.l().deferred_enter_hint)));
        }
        HomeEnterAction::Busy => app.toast = Some((true, app.lang.l().busy.into())),
    }
}

fn prepare_live_monitor(app: &mut App) {
    app.monitor.diagnostic = false;
    app.refresh_monitor_runs();
}

fn open_home_monitor(app: &mut App) {
    let selected = app.snapshot.as_ref().and_then(|snapshot| {
        snapshot.queue.tasks.get(app.selected).map(|task| {
            (
                task.id.clone(),
                task.state,
                snapshot
                    .approvals_needed
                    .iter()
                    .any(|approval| approval == &task.id),
            )
        })
    });
    let action = home_monitor_action(
        selected.as_ref().map(|(_, state, _)| *state),
        selected
            .as_ref()
            .is_some_and(|(_, _, approval_pending)| *approval_pending),
        app.is_busy(),
    );
    match (action, selected) {
        (HomeMonitorAction::SelectedFailure, Some((task_id, _, _))) => {
            load_failed_attempt_monitor(app, &task_id);
        }
        _ => prepare_live_monitor(app),
    }
    app.screen = Screen::Monitor;
}

fn resolve_attempt_ref(ws: &Workspace, reference: &str) -> std::path::PathBuf {
    let path = std::path::Path::new(reference);
    if path.is_absolute() {
        path.to_path_buf()
    } else if let Ok(relative) = path.strip_prefix(".agents") {
        ws.agents_dir().join(relative)
    } else if reference.starts_with("task-channels/") {
        ws.agents_dir().join(path)
    } else {
        ws.root.join(path)
    }
}

fn append_raw_attempt_stream(
    lines: &mut Vec<String>,
    label: &str,
    reference: &str,
    ws: &Workspace,
    l: &i18n::L,
) {
    lines.push(format!("{label}: {reference}"));
    match std::fs::read(resolve_attempt_ref(ws, reference)) {
        Ok(raw) if raw.is_empty() => lines.push(l.monitor_empty_stream.to_string()),
        Ok(raw) => lines.extend(
            String::from_utf8_lossy(&raw)
                .split_terminator('\n')
                .map(str::to_string),
        ),
        Err(error) => lines.push(format!("{}: {error}", l.monitor_read_failed)),
    }
}

fn load_failed_attempt_monitor(app: &mut App, task_id: &str) {
    let l = app.lang.l();
    app.monitor.diagnostic = true;
    app.monitor.runs.clear();
    app.monitor.fallback = None;
    app.monitor_sel = 0;
    app.monitor_top = 0;
    app.monitor_follow = false;
    let Some(intent_id) = app
        .snapshot
        .as_ref()
        .map(|snapshot| snapshot.queue.intent_id.clone())
        .filter(|intent_id| !intent_id.is_empty())
    else {
        set_missing_failed_attempt_monitor(app, l);
        return;
    };
    let Ok(channel) = app.ws.load_task_channel(&intent_id, task_id) else {
        set_missing_failed_attempt_monitor(app, l);
        return;
    };
    let Some(attempt) = channel.attempts.iter().rev().find(|attempt| {
        matches!(
            attempt.state,
            crate::schemas::AttemptState::Failed
                | crate::schemas::AttemptState::TimedOut
                | crate::schemas::AttemptState::Cancelled
                | crate::schemas::AttemptState::Abandoned
        )
    }) else {
        set_missing_failed_attempt_monitor(app, l);
        return;
    };
    let completion = channel.events.iter().rev().find(|event| {
        event.event_type == crate::schemas::ChannelEventType::WorkerCompleted
            && event.attempt_id.as_deref() == Some(attempt.attempt_id.as_str())
    });
    let payload = completion.map(|event| &event.payload);
    let result = payload
        .and_then(|payload| payload.get("result"))
        .and_then(|value| value.as_str())
        .unwrap_or("failed");
    let result = i18n::recorded_state_label(l, result);
    let exit_code = diagnostic_payload_value(payload, "exit_code", l.monitor_none);
    let exit_signal = diagnostic_payload_value(payload, "exit_signal", l.monitor_none);
    let exit_ok = diagnostic_payload_value(payload, "exit_ok", l.monitor_none);
    let timed_out = diagnostic_payload_value(payload, "timed_out", l.monitor_none);
    let mut lines = vec![
        format!("{}: {}", l.monitor_attempt, attempt.attempt_id),
        format!(
            "{}: result={result}, code={exit_code}, signal={exit_signal}, exit_ok={exit_ok}, timed_out={timed_out}",
            l.monitor_exit
        ),
        String::new(),
    ];
    append_raw_attempt_stream(
        &mut lines,
        l.monitor_stdout,
        &attempt.raw_stdout_ref,
        &app.ws,
        l,
    );
    lines.push(String::new());
    append_raw_attempt_stream(
        &mut lines,
        l.monitor_stderr,
        &attempt.raw_stderr_ref,
        &app.ws,
        l,
    );

    let stdout_path = resolve_attempt_ref(&app.ws, &attempt.raw_stdout_ref);
    let run_name = stdout_path
        .ancestors()
        .nth(3)
        .and_then(std::path::Path::file_name)
        .and_then(|name| name.to_str())
        .unwrap_or(&attempt.attempt_id)
        .to_string();
    app.monitor.header = Some(MonitorHeader {
        run_name,
        task_id: task_id.to_string(),
        worker: attempt.worker_id.clone(),
        recorded_state: "failed".to_string(),
    });
    app.monitor.log_len = std::fs::metadata(&stdout_path).map_or(0, |metadata| metadata.len())
        + std::fs::metadata(resolve_attempt_ref(&app.ws, &attempt.raw_stderr_ref))
            .map_or(0, |metadata| metadata.len());
    app.monitor.log_path = Some(stdout_path);
    app.monitor.log_lines = lines;
}

fn diagnostic_payload_value(
    payload: Option<&serde_json::Value>,
    key: &str,
    missing: &str,
) -> String {
    payload
        .and_then(|payload| payload.get(key))
        .filter(|value| !value.is_null())
        .map(|value| value.to_string())
        .unwrap_or_else(|| missing.to_string())
}

fn set_missing_failed_attempt_monitor(app: &mut App, l: &i18n::L) {
    app.monitor.header = None;
    app.monitor.log_path = None;
    app.monitor.log_len = 0;
    app.monitor.log_lines = vec![l.monitor_no_failed_attempt.to_string()];
}

/// Point the Run Monitor at this task's run. Best-effort: the index matches the
/// order refresh_monitor_runs rebuilds (Running tasks in queue order), so the
/// tab lands on the intended task.
fn focus_monitor_on(app: &mut App, id: &str) {
    if let Some(pos) = app.snapshot.as_ref().and_then(|s| {
        s.queue
            .tasks
            .iter()
            .filter(|t| t.state == TaskState::Running)
            .position(|t| t.id == id)
    }) {
        app.monitor_sel = pos;
    }
}

fn selected_task_state(app: &App) -> Option<(String, TaskState)> {
    app.snapshot.as_ref().and_then(|s| {
        s.queue
            .tasks
            .get(app.selected)
            .map(|t| (t.id.clone(), t.state))
    })
}

fn defer_selected_task(app: &mut App) {
    let Some((id, state)) = selected_task_state(app) else {
        app.toast = Some((true, app.lang.l().no_answer_target.into()));
        return;
    };
    match home_hold_action(Some(state), app.is_busy(), false) {
        HomeHoldAction::Defer => {}
        HomeHoldAction::Busy => {
            app.toast = Some((true, app.lang.l().busy.into()));
            return;
        }
        _ => {
            app.toast = Some((true, format!("{id}: {}", app.lang.l().cannot_defer_state)));
            return;
        }
    }
    let lock = match app.ws.acquire_planning_lock() {
        Ok(lock) => lock,
        Err(e) => {
            app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
            return;
        }
    };
    let before = app.ws.load_queue().ok();
    let mut queue = match before.clone() {
        Some(q) => q,
        None => return,
    };
    match queue.defer_task(&id, false, "deferred from the TUI") {
        Ok(outcome) => {
            if let Err(e) = app.ws.save_queue_locked(&lock, &queue) {
                app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
                return;
            }
            if let Some(prev) = before.and_then(|q| q.tasks.into_iter().find(|t| t.id == id)) {
                let _ = crate::state::append_transition(
                    &app.ws,
                    crate::state::transition(
                        &id,
                        prev.state,
                        TaskState::Deferred,
                        crate::schemas::TransitionCause::Defer,
                        "deferred from the TUI",
                        crate::schemas::TransitionActor::User,
                    ),
                );
            }
            app.reload();
            app.toast = Some((
                true,
                format!(
                    "{} {}",
                    app.lang.l().deferred_tasks,
                    outcome.deferred.join(", ")
                ),
            ));
        }
        Err(e) => app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed))),
    }
}

fn revive_selected_task(app: &mut App) {
    let Some((id, state)) = selected_task_state(app) else {
        app.toast = Some((true, app.lang.l().no_answer_target.into()));
        return;
    };
    match home_hold_action(Some(state), app.is_busy(), true) {
        HomeHoldAction::Revive => {}
        HomeHoldAction::Busy => {
            app.toast = Some((true, app.lang.l().busy.into()));
            return;
        }
        _ => {
            app.toast = Some((true, format!("{id}: {}", app.lang.l().cannot_revive_state)));
            return;
        }
    }
    let lock = match app.ws.acquire_planning_lock() {
        Ok(lock) => lock,
        Err(e) => {
            app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
            return;
        }
    };
    let before = app.ws.load_queue().ok();
    let mut queue = match before.clone() {
        Some(q) => q,
        None => return,
    };
    match queue.revive_task(&id, false) {
        Ok(outcome) => {
            if let Err(e) = app.ws.save_queue_locked(&lock, &queue) {
                app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
                return;
            }
            if let Some(prev) = before.and_then(|q| q.tasks.into_iter().find(|t| t.id == id)) {
                let _ = crate::state::append_transition(
                    &app.ws,
                    crate::state::transition(
                        &id,
                        prev.state,
                        TaskState::Queued,
                        crate::schemas::TransitionCause::Revive,
                        "revived from the TUI",
                        crate::schemas::TransitionActor::User,
                    ),
                );
            }
            app.reload();
            app.toast = Some((
                true,
                format!(
                    "{} {}",
                    app.lang.l().revived_tasks,
                    outcome.revived.join(", ")
                ),
            ));
        }
        Err(e) => app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed))),
    }
}

fn tidy_workspace(app: &mut App) {
    match app.ws.tidy() {
        Ok(report) => {
            app.reload_full();
            let l = app.lang.l();
            app.toast = Some((
                true,
                format!(
                    "{}: {} {}, {} {}{}",
                    l.tidy_word,
                    report.migrated_decisions.len(),
                    l.migrated_word,
                    report.deferred.len(),
                    l.s_deferred,
                    report
                        .archived_intent
                        .as_ref()
                        .map(|id| format!(", {} {id}", l.archived_word))
                        .unwrap_or_default()
                ),
            ));
        }
        Err(e) => app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed))),
    }
}

/// Open the answer screen aimed at one specific task (Enter on a NeedsUser row).
fn open_answer_for_task(app: &mut App, id: &str) {
    let target = app
        .snapshot
        .as_ref()
        .and_then(|s| s.queue.tasks.iter().find(|t| t.id == id).cloned())
        .map(|t| task_answer_target(app, &t));
    match target {
        Some(t) => open_answer_target(app, t),
        None => app.toast = Some((true, app.lang.l().no_pending.into())),
    }
}

fn answer_target_will_grant(
    target_id: &str,
    already_marked: bool,
    approvals_needed: &[String],
) -> bool {
    target_id != INTERVIEW_TARGET
        && (already_marked || approvals_needed.iter().any(|id| id == target_id))
}

fn open_answer_target(app: &mut App, target: (String, String)) {
    let approvals_needed = app
        .snapshot
        .as_ref()
        .map(|s| s.approvals_needed.as_slice())
        .unwrap_or(&[]);
    app.answer_grants_approval = answer_target_will_grant(&target.0, false, approvals_needed);
    app.answer_context = build_answer_context(app, &target.0, &target.1);
    app.answer_target = Some(target);
    app.input_clear();
    app.toast = None;
    app.scroll = 0;
    app.scroll_viewport = None;
    app.screen = Screen::Answer;
}

/// Run one specific task by id (Enter on a Queued/Partial/Failed/Blocked row).
/// A named target is an explicit human override, same as `yardlet run --task`;
/// run_next's approval gate still refuses an ungranted approval-required task,
/// so this path cannot bypass approval.
fn start_run_target(app: &mut App, target_id: String) {
    let ws = app.ws.clone();
    let lang = app.lang;
    let lbl = app.lang.l();
    let (via, failed) = (lbl.via_word, lbl.run_failed);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match run::run_next(
            &ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target: Some(target_id),
                answer: None,
                full_access: false,
                accept_ambiguity: false,
                chain: None,
            },
        ) {
            Ok(r) => {
                let outcome = localized_run_outcome(lang, &r);
                JobResult {
                    ok: true,
                    summary: format!("{} {via} {}: {outcome}", r.task_id, r.worker_id),
                }
            }
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(JobMsg::Done(res));
    });
    app.progress = None;
    app.job = Job::Running {
        label: lbl.run_word.into(),
        started: Instant::now(),
        rx,
    };
}

fn short(s: &str, n: usize) -> String {
    let t: String = s.trim().chars().take(n).collect();
    if s.trim().chars().count() > n {
        format!("{t}\u{2026}")
    } else {
        t
    }
}

fn open_reports(app: &mut App) {
    let mut list: Vec<ReportEntry> = Vec::new();
    let cur = app
        .snapshot
        .as_ref()
        .map(|s| s.intent_summary().to_string())
        .unwrap_or_default();
    let l = app.lang.l();
    list.push(ReportEntry::Current {
        label: format!("{} \u{2014} {}", l.current_word, short(&cur, 50)),
    });
    if let Ok(rd) = std::fs::read_dir(app.ws.agents_dir().join("intents")) {
        let mut dirs: Vec<std::path::PathBuf> = rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect();
        dirs.sort();
        dirs.reverse(); // ids are timestamped → newest first
        for d in dirs {
            let id = d
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("?")
                .to_string();
            let summary = std::fs::read_to_string(d.join("intent-contract.yaml"))
                .ok()
                .and_then(|y| {
                    y.lines().find_map(|l| {
                        l.trim()
                            .strip_prefix("summary:")
                            .map(|v| v.trim().trim_matches('"').to_string())
                    })
                })
                .unwrap_or_default();
            list.push(ReportEntry::Archived {
                label: format!("{id} \u{2014} {}", short(&summary, 44)),
                dir: d.clone(),
            });
            for (confirmation_id, drain_dir) in crate::report::archived_drain_snapshots(&d) {
                list.push(ReportEntry::ArchivedDrain {
                    label: format!(
                        "  \u{21b3} {}: {}",
                        l.drain_word,
                        short(&confirmation_id, 44)
                    ),
                    dir: drain_dir,
                });
            }
            if let Some(preserved) = app.ws.load_preserved_follow_ups(&id) {
                for (i, fu) in preserved.tasks.into_iter().enumerate() {
                    let title = if fu.title.trim().is_empty() {
                        format!("{} {}", l.follow_up_word, i + 1)
                    } else {
                        fu.title.trim().to_string()
                    };
                    let reason = if fu.reason.trim().is_empty() {
                        String::new()
                    } else {
                        format!(" \u{00b7} {}", short(&fu.reason, 38))
                    };
                    list.push(ReportEntry::FollowUp {
                        label: format!(
                            "  \u{21b3} {}: {}{}",
                            l.follow_up_word,
                            short(&title, 44),
                            reason
                        ),
                        intent_id: id.clone(),
                        task: Box::new(fu),
                    });
                }
            }
        }
    }
    app.reports = list;
    app.report_sel = 0;
    app.screen = Screen::ReportList;
}

fn handle_reportlist_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::Home,
        KeyCode::Up => app.report_sel = app.report_sel.saturating_sub(1),
        KeyCode::Down => {
            if app.report_sel + 1 < app.reports.len() {
                app.report_sel += 1;
            }
        }
        KeyCode::Enter => {
            let entry = app.reports.get(app.report_sel).cloned();
            match (reportlist_enter_action(entry.as_ref()), entry) {
                (Some(ReportListEnterAction::OpenCurrent), Some(ReportEntry::Current { .. })) => {
                    app.report_text =
                        crate::report::build_final_report(&app.ws).unwrap_or_default();
                    app.viewing_archived = false;
                    app.scroll = 0;
                    app.screen = Screen::Completion;
                }
                (
                    Some(ReportListEnterAction::OpenArchived),
                    Some(
                        ReportEntry::Archived { dir, .. } | ReportEntry::ArchivedDrain { dir, .. },
                    ),
                ) => {
                    app.report_text = std::fs::read_to_string(dir.join("final-report.md"))
                        .unwrap_or_else(|_| app.lang.l().report_empty.into());
                    app.viewing_archived = true;
                    app.scroll = 0;
                    app.screen = Screen::Completion;
                }
                (
                    Some(ReportListEnterAction::PromoteFollowUp),
                    Some(ReportEntry::FollowUp {
                        intent_id, task, ..
                    }),
                ) => {
                    promote_history_follow_up(app, &intent_id, &task);
                }
                _ => {}
            }
        }
        _ => {}
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReportListEnterAction {
    OpenCurrent,
    OpenArchived,
    PromoteFollowUp,
}

fn reportlist_enter_action(entry: Option<&ReportEntry>) -> Option<ReportListEnterAction> {
    match entry {
        Some(ReportEntry::Current { .. }) => Some(ReportListEnterAction::OpenCurrent),
        Some(ReportEntry::Archived { .. } | ReportEntry::ArchivedDrain { .. }) => {
            Some(ReportListEnterAction::OpenArchived)
        }
        Some(ReportEntry::FollowUp { .. }) => Some(ReportListEnterAction::PromoteFollowUp),
        None => None,
    }
}

fn promote_history_follow_up(
    app: &mut App,
    source_intent: &str,
    task: &crate::schemas::FollowUpTask,
) {
    if let Err(e) = crate::report::archive_intent(&app.ws)
        .and_then(|_| app.ws.clear_intent_and_queue())
        .and_then(|_| crate::report::promote_follow_up(&app.ws, task).map(|_| ()))
    {
        app.toast = Some((
            false,
            format!("{} {e}", app.lang.l().history_promote_failed),
        ));
        return;
    }
    app.reload_full();
    app.toast = Some((
        true,
        format!(
            "{}: {} ({source_intent})",
            app.lang.l().history_promoted,
            short(&task.title, 52)
        ),
    ));
    app.screen = Screen::Home;
}

fn handle_new_work_key(app: &mut App, code: KeyCode, mods: KeyModifiers) {
    use text_input::TextInputAction;

    if app.is_busy() {
        if code == KeyCode::Esc {
            app.screen = Screen::Home;
        }
        return;
    }
    match text_input::action_for_key(code, mods, app.keyboard_enhancement) {
        TextInputAction::Noop => {}
        TextInputAction::Cancel => {
            app.input_clear();
            app.amend = false;
            app.replan = false;
            app.screen = Screen::Home;
        }
        TextInputAction::Submit => {
            if !app.input.trim().is_empty() {
                if app.replan {
                    start_replan(app);
                } else if app.amend {
                    start_continue(app);
                } else {
                    start_planning(app);
                }
                app.screen = Screen::Home;
            }
        }
        TextInputAction::InsertNewline => app.input_insert("\n"),
        TextInputAction::Insert(c) => app.input_insert(&c.to_string()),
        TextInputAction::Backspace => app.input_backspace(),
        TextInputAction::Delete => app.input_delete(),
        TextInputAction::CaretLeft => app.caret_left(),
        TextInputAction::CaretRight => app.caret_right(),
        TextInputAction::CaretHome => app.caret_home(),
        TextInputAction::CaretEnd => app.caret_end(),
        TextInputAction::CaretUp => app.caret_up(),
        TextInputAction::CaretDown => app.caret_down(),
    }
}

fn handle_input_paste(app: &mut App, text: &str) {
    if !app.is_busy()
        && (matches!(app.screen, Screen::NewWork | Screen::Answer)
            || (app.screen == Screen::PlanningReview && app.planning_review_editing))
    {
        app.input_insert(text);
    }
}

fn handle_completion_key(app: &mut App, code: KeyCode) {
    // An archived report is read-only — just scroll and go back to the list.
    if app.viewing_archived {
        match code {
            KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::ReportList,
            _ => apply_scroll(app, code),
        }
        return;
    }
    match code {
        KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::Home,
        // New work: archive + clear the finished intent now, then collect the
        // next request against an empty live state.
        KeyCode::Char('n') => {
            if let Err(e) =
                crate::report::archive_intent(&app.ws).and_then(|_| app.ws.clear_intent_and_queue())
            {
                app.toast = Some((false, format!("{} {e}", app.lang.l().archive_failed)));
                return;
            }
            app.reload_full();
            app.input_clear();
            app.toast = None;
            app.amend = false;
            app.replan = false;
            app.screen = Screen::NewWork;
        }
        // Continue: add follow-up tasks to this intent (amend), keep done work.
        KeyCode::Char('c') => {
            app.input_clear();
            app.toast = None;
            app.amend = true;
            app.replan = false;
            app.screen = Screen::NewWork;
        }
        KeyCode::Char('P') => handle_home_replan(app),
        // Redo: requeue every done task so the next drain re-runs them.
        KeyCode::Char('R') => redo_all(app),
        _ => apply_scroll(app, code),
    }
}

fn handle_intent_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('i') => app.screen = Screen::Home,
        _ => apply_scroll(app, code),
    }
}

fn handle_keys_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('?') => app.screen = Screen::Home,
        _ => apply_scroll(app, code),
    }
}

/// The full intent contract as scrollable markdown (the header only shows a
/// one-line summary; this is the whole goal, scope, acceptance, and any
/// interview clarifications).
fn build_intent_view(app: &App) -> String {
    let l = app.lang.l();
    let Ok(Some(i)) = app.ws.load_intent() else {
        return l.no_intent.to_string();
    };
    let mut s = String::new();
    s.push_str(&format!("# {}\n\n", l.planning_goal));
    s.push_str(if i.summary.trim().is_empty() {
        l.planning_none
    } else {
        i.summary.trim()
    });
    s.push_str("\n\n");
    if !i.allowed_scope.is_empty() {
        s.push_str(&format!("## {}\n\n", l.planning_allowed_scope));
        for x in &i.allowed_scope {
            s.push_str(&format!("- {x}\n"));
        }
        s.push('\n');
    }
    if !i.out_of_scope.is_empty() {
        s.push_str(&format!("## {}\n\n", l.planning_out_of_scope));
        for x in &i.out_of_scope {
            s.push_str(&format!("- {x}\n"));
        }
        s.push('\n');
    }
    if !i.acceptance.is_empty() {
        s.push_str(&format!("## {}\n\n", l.planning_acceptance));
        for a in &i.acceptance {
            if let Some(t) = a.as_str() {
                s.push_str(&format!("- {t}\n"));
            }
        }
        s.push('\n');
    }
    if !i.clarifications.is_empty() {
        s.push_str(&format!("## {}\n\n", l.conversation_title));
        for c in &i.clarifications {
            s.push_str(c);
            s.push_str("\n\n");
        }
    }
    s
}

fn handle_handoff_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::Home,
        _ => apply_scroll(app, code),
    }
}

fn handle_trust_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('T') => app.screen = Screen::Home,
        _ => apply_scroll(app, code),
    }
}

/// Render the trust + autonomy panel text — the same v1 table + v2 autonomy
/// block `yardlet trust` prints, so the TUI and CLI never diverge.
fn build_trust_view(app: &App) -> String {
    crate::trust::report_text(&app.ws)
        .unwrap_or_else(|e| format!("{} {e}", app.lang.l().trust_report_failed))
}

fn apply_scroll(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Up => app.scroll = app.scroll.saturating_sub(1),
        KeyCode::Down => app.scroll = app.scroll.saturating_add(1),
        KeyCode::PageUp => app.scroll = app.scroll.saturating_sub(10),
        KeyCode::PageDown => app.scroll = app.scroll.saturating_add(10),
        _ => {}
    }
    clamp_scroll(app);
}

/// Where a monitor scroll key lands, and whether it resumes following.
///
/// Split out as a pure function because the branch is the part that can be
/// wrong: the repo's own rule after the key-list defects is that TUI key logic
/// is tested as data, not by driving a terminal.
///
/// Reaching the bottom resumes following rather than leaving the view frozen
/// one line from live — a viewer that stops updating where it looks live is
/// worse than one that never followed.
/// What Monitor's worker-control keys (`x` stop / `p` pause) should do. Pure so
/// the diagnostic gate is unit-tested without a live event loop.
///
/// The diagnostic Monitor is opened on a selected Failed/Partial task's exact
/// attempt streams (`m`): a read-only postmortem with no live worker to stop
/// and no drain to pause, so both keys are inert there. The live Monitor keeps
/// them, matching Home. `can_stop` mirrors the live `x` guard
/// (`is_busy() || has_running_task`); when it is false `x` is a no-op, exactly
/// as it was before this seam existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MonitorControl {
    Stop,
    Pause,
    Ignore,
}

fn monitor_control_action(code: KeyCode, diagnostic: bool, can_stop: bool) -> MonitorControl {
    if diagnostic {
        return MonitorControl::Ignore;
    }
    match code {
        KeyCode::Char('x') if can_stop => MonitorControl::Stop,
        KeyCode::Char('p') => MonitorControl::Pause,
        _ => MonitorControl::Ignore,
    }
}

fn monitor_scroll_to(code: KeyCode, top: usize, max_top: usize, visible: usize) -> (usize, bool) {
    let page = visible.max(1);
    let landed = match code {
        KeyCode::Up => top.saturating_sub(1),
        KeyCode::Down => (top + 1).min(max_top),
        KeyCode::PageUp => top.saturating_sub(page),
        KeyCode::PageDown => (top + page).min(max_top),
        KeyCode::Home => 0,
        KeyCode::End => max_top,
        _ => top,
    };
    // At (or past) the newest line, follow again. `max_top == 0` means the log
    // does not fill the viewport, so there is nothing to freeze.
    (landed, landed >= max_top)
}

fn scroll_text(app: &App) -> Option<&str> {
    match app.screen {
        Screen::Answer => Some(&app.answer_context),
        Screen::PlanningReview => Some(&app.planning_review_text),
        Screen::Handoff => Some(&app.handoff_text),
        Screen::Intent => Some(&app.intent_text),
        Screen::Trust => Some(&app.trust_text),
        Screen::Keys => Some(&app.keys_text),
        Screen::Completion => Some(&app.report_text),
        _ => None,
    }
}

fn max_scroll_for_current_screen(app: &App) -> u16 {
    let Some(viewport) = app.scroll_viewport else {
        return app.scroll;
    };
    let Some(text) = scroll_text(app) else {
        return 0;
    };
    view::max_scroll_offset(text, viewport)
}

fn clamp_scroll(app: &mut App) {
    app.scroll = app.scroll.min(max_scroll_for_current_screen(app));
}

fn redo_all(app: &mut App) {
    if let Ok(lock) = app.ws.acquire_planning_lock() {
        if let Ok(mut q) = app.ws.load_queue() {
            let mut n = 0;
            for t in q.tasks.iter_mut() {
                if t.state == TaskState::Done {
                    t.state = TaskState::Queued;
                    n += 1;
                }
            }
            match app.ws.save_queue_locked(&lock, &q) {
                Ok(()) => app.toast = Some((true, format!("{}: {n}", app.lang.l().redo_done))),
                Err(error) => {
                    app.toast = Some((false, format!("{} {error}", app.lang.l().run_failed)))
                }
            }
        }
    }
    app.reload();
    app.screen = Screen::Home;
}

fn open_settings(app: &mut App) {
    let l = app.lang.l();
    let cfg = app.ws.load_config().ok();
    let wf = app.ws.load_workers().ok();
    let field = |label: String, key: String, value: String| Field {
        options: options_for(&key),
        label,
        key,
        value,
    };
    let mut fields = vec![
        field(
            l.access_word.to_string(),
            "access".into(),
            cfg.as_ref()
                .map(|c| c.default_access.clone())
                .unwrap_or_default(),
        ),
        field(
            l.parallel_word.to_string(),
            "parallel".into(),
            cfg.as_ref()
                .map(|c| c.max_parallel.to_string())
                .unwrap_or_else(|| "1".to_string()),
        ),
        field(
            l.ime_word.to_string(),
            "ime".into(),
            if cfg.as_ref().map(|c| c.auto_ime).unwrap_or(true) {
                "on".to_string()
            } else {
                "off".to_string()
            },
        ),
        field(
            l.language_word.to_string(),
            "language".into(),
            cfg.map(|c| c.language).unwrap_or_default(),
        ),
    ];
    if let Some(wf) = wf {
        for w in wf.workers {
            fields.push(field(
                format!("{} {}", w.id, l.model_word),
                format!("model:{}", w.id),
                w.model,
            ));
            fields.push(field(
                format!("{} {}", w.id, l.effort_word),
                format!("effort:{}", w.id),
                w.effort,
            ));
        }
    }
    app.settings = Some(SettingsDraft { fields, sel: 0 });
    app.screen = Screen::Settings;
}

fn handle_settings_key(app: &mut App, code: KeyCode) {
    let Some(d) = app.settings.as_mut() else {
        app.screen = Screen::Home;
        return;
    };
    match code {
        KeyCode::Esc | KeyCode::Enter => {
            save_settings(app);
            app.screen = Screen::Home;
        }
        KeyCode::Up => d.sel = d.sel.saturating_sub(1),
        KeyCode::Down => {
            if d.sel + 1 < d.fields.len() {
                d.sel += 1;
            }
        }
        KeyCode::Char(' ') => {
            // Cycle through this field's preset options, if any.
            let f = &mut d.fields[d.sel];
            if !f.options.is_empty() {
                let next = f
                    .options
                    .iter()
                    .position(|o| *o == f.value)
                    .map(|i| (i + 1) % f.options.len())
                    .unwrap_or(0);
                f.value = f.options[next].clone();
            }
            // No presets: type the value instead.
        }
        KeyCode::Backspace => {
            d.fields[d.sel].value.pop();
        }
        KeyCode::Char(c) => d.fields[d.sel].value.push(c),
        _ => {}
    }
}

fn save_settings(app: &mut App) {
    let Some(draft) = app.settings.take() else {
        return;
    };
    if let Ok(mut cfg) = app.ws.load_config() {
        for f in &draft.fields {
            match f.key.as_str() {
                "access" if f.value == "full" || f.value == "sandboxed" => {
                    cfg.default_access = f.value.clone()
                }
                "parallel" => {
                    if let Ok(n) = f.value.trim().parse::<usize>() {
                        cfg.max_parallel = n.max(1);
                    }
                }
                "ime" => cfg.auto_ime = f.value != "off",
                "language" if !f.value.is_empty() => cfg.language = f.value.clone(),
                _ => {}
            }
        }
        let _ = crate::state::save_config_preserving_format(&app.ws.config_path(), &cfg);
    }
    if let Ok(mut wf) = app.ws.load_workers() {
        for f in &draft.fields {
            if let Some(id) = f.key.strip_prefix("model:") {
                if let Some(w) = wf.workers.iter_mut().find(|w| w.id == id) {
                    w.model = f.value.clone();
                }
            } else if let Some(id) = f.key.strip_prefix("effort:") {
                if let Some(w) = wf.workers.iter_mut().find(|w| w.id == id) {
                    w.effort = f.value.clone();
                }
            }
        }
        let _ = crate::state::save_workers_preserving_format(&app.ws.workers_path(), &wf);
    }
    app.reload();
    // Settings can be changed mid-run; a running worker keeps the model it was
    // spawned with, but run_next re-reads workers.yaml each task, so the change
    // lands on the next one. Say so — otherwise the save is silent.
    let l = app.lang.l();
    app.toast = Some((
        true,
        if app.is_busy() {
            l.settings_saved_busy.to_string()
        } else {
            l.settings_saved.to_string()
        },
    ));
}

/// Flip the default worker access (sandboxed <-> full) and persist it. Safe to
/// do mid-run; the next task picks it up.
fn toggle_access(app: &mut App) {
    if let Ok(mut cfg) = app.ws.load_config() {
        cfg.default_access = if cfg.default_access.eq_ignore_ascii_case("full") {
            "sandboxed".to_string()
        } else {
            "full".to_string()
        };
        let _ = crate::state::save_config_preserving_format(&app.ws.config_path(), &cfg);
        app.toast = Some((
            true,
            format!("{}: {}", app.lang.l().access_word, cfg.default_access),
        ));
    }
    app.reload();
}

/// Stop the currently running worker by killing the latest run's process
/// (recorded in worker.pid). The worker exiting ends the run; the task is
/// evaluated as failed and the drain halts at the gate, so you can fix or retry.
fn request_pause(app: &mut App) {
    match &app.pause {
        Some(p) => {
            p.store(true, std::sync::atomic::Ordering::Relaxed);
            app.toast = Some((true, app.lang.l().pausing.into()));
        }
        // Planning / single runs have nothing to pause between tasks; tell the
        // user the key that DOES stop them (Esc) instead of a vague "busy".
        None => app.toast = Some((true, app.lang.l().not_pausable.into())),
    }
}

/// Flip a worker's enabled flag (Home workers panel). Routing and planning
/// skip a disabled worker; the change persists to workers.yaml.
fn toggle_worker(app: &mut App, widx: usize) {
    if let Ok(mut wf) = app.ws.load_workers() {
        if let Some(w) = wf.workers.get_mut(widx) {
            w.enabled = !w.enabled;
            let (id, on) = (w.id.clone(), w.enabled);
            let _ = crate::state::save_workers_preserving_format(&app.ws.workers_path(), &wf);
            let l = app.lang.l();
            app.toast = Some((
                true,
                format!("{id}: {}", if on { l.worker_on } else { l.worker_off }),
            ));
        }
    }
    app.reload();
}

fn has_running_task(app: &App) -> bool {
    app.snapshot
        .as_ref()
        .map(|s| s.queue.tasks.iter().any(|t| t.state == TaskState::Running))
        .unwrap_or(false)
}

fn stop_running_worker(app: &mut App) {
    // Prefer the Running task's own latest run (exact, works for adopted
    // workers); fall back to the most recently modified run dir.
    let target = app.snapshot.as_ref().and_then(|s| {
        s.queue
            .tasks
            .iter()
            .find(|t| t.state == TaskState::Running)
            .and_then(|t| crate::run::latest_run_for(&app.ws, &t.id))
            .map(|(_, dir)| dir)
    });
    let runs = app.ws.runs_dir();
    let latest = target.or_else(|| {
        std::fs::read_dir(&runs)
            .ok()
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .max_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok())
    });
    if let Some(dir) = latest {
        // Mark cancelled BEFORE killing so the run loop treats the worker's death
        // as a user stop (requeue) rather than a transient failure to auto-resume.
        let _ = std::fs::write(dir.join("cancelled"), b"1");
        // Verify the pid before signalling, and never signal an unverified one
        // as a GROUP. `worker.pid` is a legacy projection for monitors — an
        // adopted worker is not our child, so once it exits the OS is free to
        // hand its pid to something else while the file still names it and the
        // task still reads Running until the next recovery pass. Killing a
        // recycled pid was already wrong; killing its whole process group would
        // take out a shell job or a daemon. `live_worker_pid` proves process
        // identity from the run-owned provenance record and its start marker,
        // the same evidence the redirect path requires.
        if let Some(pid) = crate::run::live_worker_pid(&dir) {
            // The worker leads its own process group, so signal the whole tree:
            // a launcher-style profile keeps the real agent CLI in a grandchild
            // that a pid-only kill leaves running (issue #52). The direct kill
            // stays as the backstop for a worker adopted from before that
            // change, which is not its own group leader.
            crate::workers::terminate_worker_tree(pid, crate::workers::Signal::Term);
            let _ = std::process::Command::new("kill")
                .arg(pid.to_string())
                .status();
        }
    }
    app.toast = Some((true, app.lang.l().stopping.into()));
}

/// Flip the UI language between English and Korean and persist it to yard.yaml.
fn toggle_language(app: &mut App) {
    if let Ok(mut cfg) = app.ws.load_config() {
        cfg.language = match app.lang {
            i18n::Lang::Ko => "en".to_string(),
            i18n::Lang::En => "ko".to_string(),
        };
        let _ = crate::state::save_config_preserving_format(&app.ws.config_path(), &cfg);
    }
    app.reload();
}

fn refresh_planning_review(app: &mut App) -> Result<()> {
    let projection = crate::planning::projection(&app.ws)?;
    // Keep the accept/reject target inside the pending set. A reload can shrink
    // it (a proposal was accepted/rejected/superseded), so clamp before render.
    app.planning_review_target = match projection.pending_proposals.len() {
        0 => 0,
        len => app.planning_review_target.min(len - 1),
    };
    app.planning_review_text =
        planning_review::format_projection(&projection, app.planning_review_target, app.lang.l());
    app.planning_review = Some(projection);
    Ok(())
}

/// Re-render only the review text from the cached projection (no disk reload),
/// used after the target moves so the on-screen marker follows without racing a
/// concurrent external change into the middle of a selection.
fn rerender_planning_review_text(app: &mut App) {
    let text = app.planning_review.as_ref().map(|projection| {
        planning_review::format_projection(projection, app.planning_review_target, app.lang.l())
    });
    if let Some(text) = text {
        app.planning_review_text = text;
    }
}

fn open_planning_review(app: &mut App) -> bool {
    // Default the accept/reject target to the newest pending proposal (the prior
    // "act on the latest" behavior); refresh clamps usize::MAX down to the last
    // index. This keeps the single-pending flow and CAS behavior unchanged.
    app.planning_review_target = usize::MAX;
    match refresh_planning_review(app) {
        Ok(()) => {
            app.input_clear();
            app.planning_review_editing = false;
            app.scroll = 0;
            app.scroll_viewport = None;
            app.screen = Screen::PlanningReview;
            true
        }
        Err(error) => {
            app.toast = Some((
                false,
                format!("{} {error}", app.lang.l().planning_review_failed),
            ));
            false
        }
    }
}

fn finish_background_job(app: &mut App, result: JobResult, planning_finished: bool) -> bool {
    let open_review = planning_finished && result.ok;
    app.toast = Some((result.ok, result.summary));
    app.job = Job::Idle;
    app.progress = None;
    app.pause = None;
    if open_review {
        // A projection error is itself handled here and must not fall through
        // to the unrelated queue-completion screen, which would hide it.
        let _ = open_planning_review(app);
        true
    } else {
        false
    }
}

fn planning_action_id(action: &str) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    format!(
        "tui-{action}-{}-{}-{}",
        chrono::Utc::now().format("%Y%m%d%H%M%S%6f"),
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

fn review_gate(app: &App) -> planning_review::ReviewGate {
    let projection = app.planning_review.as_ref();
    planning_review::ReviewGate {
        busy: app.is_busy(),
        editing: app.planning_review_editing,
        has_pending_proposal: projection.is_some_and(|p| !p.pending_proposals.is_empty()),
        has_visible_head: projection
            .is_some_and(|p| p.session.current_head.is_some() && p.current_draft.is_some()),
        confirmed: projection.is_some_and(|p| p.activation.is_some()),
        pending_count: projection.map_or(0, |p| p.pending_proposals.len()),
    }
}

/// A successful confirm ends the review screen's job: the queue is active and
/// the drain actions live on Home, so land the operator there and name the
/// next step instead of leaving a dead-end screen (issue #129).
fn finish_planning_confirm(app: &mut App, result: Result<String>) {
    match result {
        Ok(message) => {
            let _ = refresh_planning_review(app);
            app.input_clear();
            app.planning_review_editing = false;
            app.screen = Screen::Home;
            app.reload();
            app.toast = Some((
                true,
                format!("{message} · {}", app.lang.l().planning_confirmed_next),
            ));
        }
        Err(error) => finish_planning_review_action(app, Err(error)),
    }
}

fn finish_planning_review_action(app: &mut App, result: Result<String>) {
    match result {
        Ok(message) => match refresh_planning_review(app) {
            Ok(()) => {
                app.reload();
                app.toast = Some((true, message));
            }
            Err(error) => {
                app.toast = Some((
                    false,
                    format!("{} {error}", app.lang.l().planning_review_failed),
                ));
            }
        },
        Err(error) => {
            // Re-read after stale/duplicate/core errors so the screen does not
            // keep offering an action against a projection known to be old.
            let _ = refresh_planning_review(app);
            app.toast = Some((
                false,
                format!("{} {error}", app.lang.l().planning_review_failed),
            ));
        }
    }
}

fn start_planning_revision(app: &mut App) {
    let request = app.input.trim().to_string();
    if request.is_empty() {
        return;
    }
    let expected_head = app
        .planning_review
        .as_ref()
        .and_then(|projection| projection.session.current_head.clone());
    let ws = app.ws.clone();
    let action_id = planning_action_id("revision");
    let lbl = app.lang.l();
    let (planned_via, tasks_word, failed) = (lbl.planned_via, lbl.tasks_word, lbl.planning_failed);
    let planner_label = lbl.planner.to_string();
    let (tx, rx) = mpsc::channel();
    let worker_request = request.clone();
    thread::spawn(move || {
        let res = planning_review::record_revision_turn(
            &ws,
            &worker_request,
            expected_head.as_deref(),
            &action_id,
        )
        .and_then(|(session, turn)| {
            crate::planner::run_planning_recorded_turn(
                &ws,
                &worker_request,
                None,
                &[],
                session,
                turn,
            )
        });
        let result = match res {
            Ok(report) => JobResult {
                ok: true,
                summary: format!(
                    "{planned_via} {}: {} ({} {tasks_word})",
                    report.worker_id, report.intent_summary, report.task_count
                ),
            },
            Err(error) => JobResult {
                ok: false,
                summary: format!("{failed} {error}"),
            },
        };
        let _ = tx.send(if result.ok {
            JobMsg::PlanningDone(result)
        } else {
            JobMsg::Done(result)
        });
    });
    app.input_clear();
    app.planning_review_editing = false;
    app.job = Job::Running {
        label: planner_label,
        started: Instant::now(),
        rx,
    };
}

fn start_planning_singleton(app: &mut App) {
    let ws = app.ws.clone();
    let lbl = app.lang.l();
    let (failed, fallback, started) = (
        lbl.planning_start_failed,
        lbl.planning_start_fallback,
        lbl.planning_started,
    );
    let run_word = lbl.run_word;
    let auto_word = lbl.auto_word;
    let pause = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let pause_job = pause.clone();
    let (tx, rx) = mpsc::channel();
    let txp = tx.clone();
    thread::spawn(move || {
        let res = crate::planning::start_singleton(&ws).and_then(|outcome| {
            run::run_auto(&ws, false, Some(pause), None, false, |line| {
                let _ = txp.send(JobMsg::Progress(line.to_string()));
            })
            .map(|lines| (outcome, lines))
        });
        let result = match res {
            Ok((outcome, lines)) => JobResult {
                ok: true,
                summary: format!(
                    "{started}: {}{}",
                    outcome.activation.confirmation_id,
                    lines
                        .last()
                        .filter(|line| !line.is_empty())
                        .map(|line| format!(" · {line}"))
                        .unwrap_or_default()
                ),
            },
            Err(error) => JobResult {
                ok: false,
                summary: format!("{failed} {error} {fallback}"),
            },
        };
        let _ = tx.send(JobMsg::Done(result));
    });
    app.input_clear();
    app.planning_review_editing = false;
    app.screen = Screen::Home;
    app.progress = None;
    app.pause = Some(pause_job);
    app.job = Job::Running {
        label: format!("{run_word} ({auto_word})"),
        started: Instant::now(),
        rx,
    };
}

fn handle_planning_review_key(app: &mut App, code: KeyCode, modifiers: KeyModifiers) {
    use planning_review::ReviewAction;

    let action = planning_review::action_for_key_with_enhancement(
        code,
        modifiers,
        app.keyboard_enhancement,
        review_gate(app),
    );
    match action {
        ReviewAction::Noop => {}
        ReviewAction::Back => {
            app.input_clear();
            app.planning_review_editing = false;
            app.screen = Screen::Home;
        }
        ReviewAction::ScrollUp => apply_scroll(app, KeyCode::Up),
        ReviewAction::ScrollDown => apply_scroll(app, KeyCode::Down),
        ReviewAction::PageUp => apply_scroll(app, KeyCode::PageUp),
        ReviewAction::PageDown => apply_scroll(app, KeyCode::PageDown),
        ReviewAction::BeginEdit => {
            app.input_clear();
            app.planning_review_editing = true;
            app.toast = None;
        }
        ReviewAction::CancelEdit => {
            app.input_clear();
            app.planning_review_editing = false;
        }
        ReviewAction::SubmitRevision => start_planning_revision(app),
        ReviewAction::Start => start_planning_singleton(app),
        ReviewAction::InsertNewline => app.input_insert("\n"),
        ReviewAction::Insert(c) => app.input_insert(&c.to_string()),
        ReviewAction::Backspace => app.input_backspace(),
        ReviewAction::Delete => app.input_delete(),
        ReviewAction::CaretLeft => app.caret_left(),
        ReviewAction::CaretRight => app.caret_right(),
        ReviewAction::CaretHome => app.caret_home(),
        ReviewAction::CaretEnd => app.caret_end(),
        ReviewAction::CaretUp => app.caret_up(),
        ReviewAction::CaretDown => app.caret_down(),
        ReviewAction::Refresh => {
            if let Err(error) = refresh_planning_review(app) {
                app.toast = Some((
                    false,
                    format!("{} {error}", app.lang.l().planning_review_failed),
                ));
            }
        }
        ReviewAction::SelectNext | ReviewAction::SelectPrev => {
            if let Some(len) = app
                .planning_review
                .as_ref()
                .map(|projection| projection.pending_proposals.len())
                .filter(|len| *len > 1)
            {
                let step = if action == ReviewAction::SelectNext {
                    1
                } else {
                    len - 1
                };
                app.planning_review_target = (app.planning_review_target + step) % len;
                rerender_planning_review_text(app);
            }
        }
        ReviewAction::Accept => {
            let target = app.planning_review.as_ref().and_then(|projection| {
                projection
                    .pending_proposals
                    .get(app.planning_review_target)
                    .map(|proposal| {
                        (
                            proposal.proposal_id.clone(),
                            projection.session.current_head.clone(),
                        )
                    })
            });
            let Some((proposal_id, expected_head)) = target else {
                return;
            };
            let result = crate::planning::accept_proposal(
                &app.ws,
                &proposal_id,
                expected_head.as_deref(),
                &planning_action_id("accept"),
            )
            .map(|revision| {
                format!(
                    "{}: {}",
                    app.lang.l().planning_accepted,
                    revision.draft_revision_id
                )
            });
            finish_planning_review_action(app, result);
        }
        ReviewAction::Reject => {
            let target = app.planning_review.as_ref().and_then(|projection| {
                projection
                    .pending_proposals
                    .get(app.planning_review_target)
                    .map(|proposal| {
                        (
                            proposal.proposal_id.clone(),
                            projection.session.current_head.clone(),
                        )
                    })
            });
            let Some((proposal_id, expected_head)) = target else {
                return;
            };
            let result = crate::planning::reject_proposal(
                &app.ws,
                &proposal_id,
                expected_head.as_deref(),
                &planning_action_id("reject"),
            )
            .map(|()| format!("{}: {proposal_id}", app.lang.l().planning_rejected));
            finish_planning_review_action(app, result);
        }
        ReviewAction::Confirm => {
            let expected_head = app
                .planning_review
                .as_ref()
                .and_then(|projection| projection.session.current_head.clone());
            let Some(expected_head) = expected_head else {
                return;
            };
            let result =
                crate::planning::confirm(&app.ws, &expected_head, &planning_action_id("confirm"))
                    .map(|activation| {
                        format!(
                            "{}: {}",
                            app.lang.l().planning_confirmed,
                            activation.confirmation_id
                        )
                    });
            finish_planning_confirm(app, result);
        }
    }
}

fn handle_answer_key(app: &mut App, code: KeyCode, mods: KeyModifiers) {
    use text_input::TextInputAction;

    if app.is_busy() {
        if code == KeyCode::Esc {
            app.screen = Screen::Home;
        }
        return;
    }
    // The Answer screen splits into a scrollable read-only context pane above the
    // multi-line draft input. PgUp/PgDn scroll the context and must not reach the
    // shared text-input branch (where they would be no-ops).
    if matches!(code, KeyCode::PageUp | KeyCode::PageDown) {
        apply_scroll(app, code);
        return;
    }
    // Same Enter=newline / Ctrl+S=submit / Ctrl+Enter=submit (when supported)
    // branch as the planner and plan-revision inputs.
    match text_input::action_for_key(code, mods, app.keyboard_enhancement) {
        TextInputAction::Noop => {}
        TextInputAction::Cancel => {
            app.input_clear();
            app.answer_target = None;
            app.answer_grants_approval = false;
            app.screen = Screen::Home;
        }
        TextInputAction::Submit => {
            if !app.input.trim().is_empty() {
                start_answer(app);
                app.screen = Screen::Home;
            }
        }
        TextInputAction::InsertNewline => app.input_insert("\n"),
        TextInputAction::Insert(c) => app.input_insert(&c.to_string()),
        TextInputAction::Backspace => app.input_backspace(),
        TextInputAction::Delete => app.input_delete(),
        TextInputAction::CaretLeft => app.caret_left(),
        TextInputAction::CaretRight => app.caret_right(),
        TextInputAction::CaretHome => app.caret_home(),
        TextInputAction::CaretEnd => app.caret_end(),
        TextInputAction::CaretUp => app.caret_up(),
        TextInputAction::CaretDown => app.caret_down(),
    }
}

fn start_planning(app: &mut App) {
    let ws = app.ws.clone();
    let request = app.input.trim().to_string();
    let planner = app
        .snapshot
        .as_ref()
        .map(|s| s.planner.clone())
        .unwrap_or_else(|| app.lang.l().worker_word.into());
    let lbl = app.lang.l();
    let (planned_via, tasks_word, failed) = (lbl.planned_via, lbl.tasks_word, lbl.planning_failed);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match crate::planner::run_planning(&ws, &request, None, &[]) {
            Ok(r) => JobResult {
                ok: true,
                summary: format!(
                    "{planned_via} {}: {} ({} {tasks_word})",
                    r.worker_id, r.intent_summary, r.task_count
                ),
            },
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(if res.ok {
            JobMsg::PlanningDone(res)
        } else {
            JobMsg::Done(res)
        });
    });
    app.job = Job::Running {
        label: format!("{} {planner}", lbl.run_word),
        started: Instant::now(),
        rx,
    };
    app.input_clear();
}

fn start_continue(app: &mut App) {
    let ws = app.ws.clone();
    let request = app.input.trim().to_string();
    let planner = app
        .snapshot
        .as_ref()
        .map(|s| s.planner.clone())
        .unwrap_or_else(|| app.lang.l().worker_word.into());
    let lbl = app.lang.l();
    let (planned_via, tasks_word, failed) = (lbl.planned_via, lbl.tasks_word, lbl.planning_failed);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match crate::planner::run_planning_amend(&ws, &request) {
            Ok(r) => JobResult {
                ok: true,
                summary: format!(
                    "{planned_via} {}: {} ({} {tasks_word})",
                    r.worker_id, r.intent_summary, r.task_count
                ),
            },
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(if res.ok {
            JobMsg::PlanningDone(res)
        } else {
            JobMsg::Done(res)
        });
    });
    app.job = Job::Running {
        label: format!("{} {planner}", lbl.run_word),
        started: Instant::now(),
        rx,
    };
    app.input_clear();
    app.amend = false;
}

fn start_replan(app: &mut App) {
    let ws = app.ws.clone();
    let request = app.input.trim().to_string();
    let planner = app
        .snapshot
        .as_ref()
        .map(|s| s.planner.clone())
        .unwrap_or_else(|| app.lang.l().worker_word.into());
    let lbl = app.lang.l();
    let (planned_via, tasks_word, failed) = (lbl.planned_via, lbl.tasks_word, lbl.planning_failed);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match crate::planner::run_planning_replan(&ws, &request, None) {
            Ok(r) => JobResult {
                ok: true,
                summary: format!(
                    "{planned_via} {}: {} ({} {tasks_word})",
                    r.worker_id, r.intent_summary, r.task_count
                ),
            },
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(if res.ok {
            JobMsg::PlanningDone(res)
        } else {
            JobMsg::Done(res)
        });
    });
    app.job = Job::Running {
        label: format!("{} {planner}", lbl.run_word),
        started: Instant::now(),
        rx,
    };
    app.input_clear();
    app.replan = false;
}

fn start_run(app: &mut App) {
    // A Failed/Partial task can be retried first; Blocked/stale gates are
    // surfaced by tidy or the run-time migration path instead of blindly rerun.
    // it first; otherwise it runs the next queued task. NeedsUser is resolved via a.
    let (stuck, has_queued) = app
        .snapshot
        .as_ref()
        .map(|s| {
            let stuck = s
                .queue
                .tasks
                .iter()
                .find(|t| matches!(t.state, TaskState::Failed | TaskState::Partial))
                .map(|t| t.id.clone());
            let has_queued = s.queue.tasks.iter().any(|t| t.state == TaskState::Queued);
            (stuck, has_queued)
        })
        .unwrap_or((None, false));

    let target = stuck;
    if target.is_none() && !has_queued {
        app.toast = Some((true, app.lang.l().nothing_to_run.into()));
        return;
    }

    let ws = app.ws.clone();
    let lang = app.lang;
    let lbl = app.lang.l();
    let (via, failed) = (lbl.via_word, lbl.run_failed);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match run::run_next(
            &ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target,
                answer: None,
                full_access: false,
                accept_ambiguity: false,
                chain: None,
            },
        ) {
            Ok(r) => {
                let outcome = localized_run_outcome(lang, &r);
                JobResult {
                    ok: true,
                    summary: format!("{} {via} {}: {outcome}", r.task_id, r.worker_id),
                }
            }
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(JobMsg::Done(res));
    });
    app.job = Job::Running {
        label: lbl.run_word.into(),
        started: Instant::now(),
        rx,
    };
}

fn start_approve(app: &mut App) {
    if let Err(e) = crate::planning::validate_active_activation(&app.ws) {
        app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
        return;
    }
    let approvals_needed = app
        .snapshot
        .as_ref()
        .map(|s| s.approvals_needed.clone())
        .unwrap_or_default();
    let selected = app.snapshot.as_ref().and_then(|s| {
        s.queue
            .tasks
            .get(app.selected)
            .map(|t| (t.id.clone(), t.state))
    });
    if app.is_busy() {
        let Some((id, state)) = selected
            .as_ref()
            .filter(|(id, _)| approvals_needed.iter().any(|approval| approval == id))
            .cloned()
        else {
            app.toast = Some((true, app.lang.l().no_approval.into()));
            return;
        };
        if let Err(e) = crate::approvals::grant(&app.ws, &id) {
            app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
            return;
        }
        app.reload();
        let suffix = if state == TaskState::NeedsUser {
            format!("; {}", app.lang.l().key_answer)
        } else {
            String::new()
        };
        app.toast = Some((
            true,
            format!("{}: {id}{suffix}", app.lang.l().approval_batch_approved),
        ));
        return;
    }
    if approvals_needed.len() >= 2 {
        open_approval_batch(app, approvals_needed);
        return;
    }
    let Some(id) = choose_approval_target(
        selected.as_ref().map(|(id, _)| id.as_str()),
        &approvals_needed,
    ) else {
        app.toast = Some((true, app.lang.l().no_approval.into()));
        return;
    };
    if selected
        .as_ref()
        .is_some_and(|(selected_id, state)| selected_id == &id && *state == TaskState::NeedsUser)
    {
        open_answer_for_task(app, &id);
        return;
    }
    if let Err(e) = crate::approvals::grant(&app.ws, &id) {
        app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
        return;
    }
    let ws = app.ws.clone();
    let lang = app.lang;
    let lbl = app.lang.l();
    let (via, failed) = (lbl.via_word, lbl.run_failed);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match run::run_next(
            &ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target: Some(id.clone()),
                answer: None,
                full_access: false,
                accept_ambiguity: false,
                chain: None,
            },
        ) {
            Ok(r) => {
                let outcome = localized_run_outcome(lang, &r);
                JobResult {
                    ok: true,
                    summary: format!("{} {via} {}: {outcome}", r.task_id, r.worker_id),
                }
            }
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(JobMsg::Done(res));
    });
    app.progress = None;
    app.job = Job::Running {
        label: lbl.run_word.into(),
        started: Instant::now(),
        rx,
    };
}

fn choose_approval_target(selected: Option<&str>, approvals_needed: &[String]) -> Option<String> {
    if let Some(id) = selected {
        if approvals_needed.iter().any(|approval| approval == id) {
            return Some(id.to_string());
        }
    }
    approvals_needed.first().cloned()
}

fn queue_ready_for_completion(queue: &crate::schemas::WorkQueue) -> bool {
    state::ready_for_completion(queue)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApprovalBatchAction {
    Back,
    MoveUp,
    MoveDown,
    ToggleSelected,
    ApproveAll,
    ApproveSelected,
    HoldSelected,
    Noop,
}

fn approval_batch_action(
    code: KeyCode,
    selected_count: usize,
    total_count: usize,
) -> ApprovalBatchAction {
    match code {
        KeyCode::Esc | KeyCode::Char('q') => ApprovalBatchAction::Back,
        KeyCode::Up => ApprovalBatchAction::MoveUp,
        KeyCode::Down => ApprovalBatchAction::MoveDown,
        KeyCode::Char(' ') => ApprovalBatchAction::ToggleSelected,
        KeyCode::Char('A') if total_count > 0 => ApprovalBatchAction::ApproveAll,
        KeyCode::Enter | KeyCode::Char('p') if selected_count > 0 => {
            ApprovalBatchAction::ApproveSelected
        }
        KeyCode::Char('d') if selected_count > 0 => ApprovalBatchAction::HoldSelected,
        _ => ApprovalBatchAction::Noop,
    }
}

fn open_approval_batch(app: &mut App, approvals_needed: Vec<String>) {
    let Some(snapshot) = &app.snapshot else {
        return;
    };
    app.approval_rows = approvals_needed
        .into_iter()
        .filter_map(|id| {
            snapshot
                .queue
                .tasks
                .iter()
                .find(|t| t.id == id)
                .map(|t| ApprovalBatchRow {
                    id: t.id.clone(),
                    title: t.title.clone(),
                    needs_answer: t.state == TaskState::NeedsUser,
                    selected: true,
                })
        })
        .collect();
    app.approval_sel = 0;
    app.toast = None;
    app.screen = Screen::Approvals;
}

fn handle_approvals_key(app: &mut App, code: KeyCode) {
    let selected_count = app.approval_rows.iter().filter(|r| r.selected).count();
    match approval_batch_action(code, selected_count, app.approval_rows.len()) {
        ApprovalBatchAction::Back => app.screen = Screen::Home,
        ApprovalBatchAction::MoveUp => app.approval_sel = app.approval_sel.saturating_sub(1),
        ApprovalBatchAction::MoveDown => {
            if app.approval_sel + 1 < app.approval_rows.len() {
                app.approval_sel += 1;
            }
        }
        ApprovalBatchAction::ToggleSelected => {
            if let Some(row) = app.approval_rows.get_mut(app.approval_sel) {
                row.selected = !row.selected;
            }
        }
        ApprovalBatchAction::ApproveAll => {
            let ids: Vec<String> = app.approval_rows.iter().map(|r| r.id.clone()).collect();
            approve_batch_and_run(app, ids);
        }
        ApprovalBatchAction::ApproveSelected => {
            let ids: Vec<String> = app
                .approval_rows
                .iter()
                .filter(|r| r.selected)
                .map(|r| r.id.clone())
                .collect();
            approve_batch_and_run(app, ids);
        }
        ApprovalBatchAction::HoldSelected => {
            let ids: Vec<String> = app
                .approval_rows
                .iter()
                .filter(|r| r.selected)
                .map(|r| r.id.clone())
                .collect();
            hold_batch(app, ids);
        }
        ApprovalBatchAction::Noop => {}
    }
}

fn approve_batch_and_run(app: &mut App, ids: Vec<String>) {
    if let Err(e) = grant_approval_batch(&app.ws, &ids) {
        app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
        app.screen = Screen::Home;
        return;
    }
    app.toast = Some((
        true,
        format!(
            "{}: {}",
            app.lang.l().approval_batch_approved,
            ids.join(", ")
        ),
    ));
    app.approval_rows.clear();
    app.screen = Screen::Home;
    start_auto(app);
}

fn grant_approval_batch(ws: &Workspace, ids: &[String]) -> anyhow::Result<()> {
    crate::planning::validate_active_activation(ws)?;
    for id in ids {
        crate::approvals::grant(ws, id)?;
    }
    Ok(())
}

fn hold_batch(app: &mut App, ids: Vec<String>) {
    let lock = match app.ws.acquire_planning_lock() {
        Ok(lock) => lock,
        Err(e) => {
            app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
            app.screen = Screen::Home;
            return;
        }
    };
    let mut queue = match app.ws.load_queue() {
        Ok(q) => q,
        Err(e) => {
            app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
            app.screen = Screen::Home;
            return;
        }
    };
    let mut held = Vec::new();
    for id in &ids {
        match queue.defer_task(id, false, app.lang.l().approval_batch_hold_reason) {
            Ok(outcome) => held.extend(outcome.deferred),
            Err(e) => app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed))),
        }
    }
    if let Err(e) = app.ws.save_queue_locked(&lock, &queue) {
        app.toast = Some((false, format!("{} {e}", app.lang.l().run_failed)));
        app.screen = Screen::Home;
        return;
    }
    held.sort();
    held.dedup();
    app.reload_full();
    app.toast = Some((
        true,
        format!(
            "{}: {}",
            app.lang.l().approval_batch_deferred,
            held.join(", ")
        ),
    ));
    app.approval_rows.clear();
    if app
        .snapshot
        .as_ref()
        .map(|s| queue_ready_for_completion(&s.queue))
        .unwrap_or(false)
    {
        app.report_text = crate::report::build_final_report(&app.ws).unwrap_or_default();
        app.scroll = 0;
        app.viewing_archived = false;
        app.screen = Screen::Completion;
    } else {
        app.screen = Screen::Home;
    }
}

fn start_auto(app: &mut App) {
    let has_work = app
        .snapshot
        .as_ref()
        .map(|s| s.queue.tasks.iter().any(|t| t.state == TaskState::Queued))
        .unwrap_or(false);
    if !has_work {
        app.toast = Some((true, app.lang.l().nothing_to_run.into()));
        return;
    }
    let ws = app.ws.clone();
    let lbl = app.lang.l();
    let failed = lbl.run_failed;
    let pause = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let pause_job = pause.clone();
    let (tx, rx) = mpsc::channel();
    let txp = tx.clone();
    thread::spawn(move || {
        let res = match run::run_auto(&ws, false, Some(pause), None, false, |s| {
            let _ = txp.send(JobMsg::Progress(s.to_string()));
        }) {
            Ok(lines) => {
                let last = lines.last().cloned().unwrap_or_default();
                let ok = ws
                    .load_queue()
                    .map(|queue| queue_ready_for_completion(&queue))
                    .unwrap_or(false);
                JobResult { ok, summary: last }
            }
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(JobMsg::Done(res));
    });
    app.progress = None;
    app.pause = Some(pause_job);
    app.job = Job::Running {
        label: format!("{} ({})", lbl.run_word, lbl.auto_word),
        started: Instant::now(),
        rx,
    };
}

/// Answer-target sentinel: the reply is an interview answer to the planner,
/// not instructions for a task.
const INTERVIEW_TARGET: &str = "__intent__";

/// What the Home `a` key resolves, independent of terminal or worker state.
/// The global ambiguity gate must be answered before any task can resume. A
/// selected NeedsUser row then wins over the default pending row so multiple
/// open questions remain directly addressable from the cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
enum HomeAnswerAction {
    Task(String),
    Interview,
    Busy,
    None,
}

/// Can `a` instruct this task? Anything not currently running and not done:
/// queued (run with instructions), partial/blocked/failed (continue or retry
/// with instructions), needs-user (answer the question).
fn answerable(state: TaskState) -> bool {
    !matches!(state, TaskState::Running | TaskState::Done)
}

fn home_answer_action(
    ambiguity_gate: bool,
    pending_task: Option<&str>,
    selected_task: Option<(&str, TaskState)>,
    first_answerable_task: Option<&str>,
    busy: bool,
) -> HomeAnswerAction {
    if busy {
        return HomeAnswerAction::Busy;
    }
    if ambiguity_gate {
        return HomeAnswerAction::Interview;
    }
    if let Some((id, TaskState::NeedsUser)) = selected_task {
        return HomeAnswerAction::Task(id.to_string());
    }
    if let Some(id) = pending_task {
        return HomeAnswerAction::Task(id.to_string());
    }
    if let Some((id, _)) = selected_task.filter(|(_, state)| answerable(*state)) {
        return HomeAnswerAction::Task(id.to_string());
    }
    first_answerable_task
        .map(|id| HomeAnswerAction::Task(id.to_string()))
        .unwrap_or(HomeAnswerAction::None)
}

fn current_home_answer_action(app: &App) -> HomeAnswerAction {
    let Some(s) = app.snapshot.as_ref() else {
        return HomeAnswerAction::None;
    };
    let selected = s
        .queue
        .tasks
        .get(app.selected)
        .map(|t| (t.id.as_str(), t.state));
    let first = s
        .queue
        .tasks
        .iter()
        .find(|t| answerable(t.state))
        .map(|t| t.id.as_str());
    home_answer_action(
        s.gate.is_some(),
        s.pending.as_ref().map(|(id, _)| id.as_str()),
        selected,
        first,
        app.is_busy(),
    )
}

fn handle_home_answer(app: &mut App) {
    match current_home_answer_action(app) {
        HomeAnswerAction::Task(id) => open_answer_for_task(app, &id),
        HomeAnswerAction::Interview => {
            let questions = app
                .snapshot
                .as_ref()
                .and_then(|s| s.gate.as_ref())
                .map(|(questions, _)| questions)
                .cloned()
                .unwrap_or_default();
            let text = questions
                .iter()
                .enumerate()
                .map(|(i, q)| format!("{}. {q}", i + 1))
                .collect::<Vec<_>>()
                .join("\n");
            open_answer_target(app, (INTERVIEW_TARGET.to_string(), text));
        }
        HomeAnswerAction::Busy => app.toast = Some((true, app.lang.l().busy.into())),
        HomeAnswerAction::None => {
            app.toast = Some((true, app.lang.l().no_pending.into()));
        }
    }
}

/// The (task id, context) the answer screen replies to: a NeedsUser task's
/// recorded question, else what the previous run reported still missing (so the
/// user can instruct a retry). Empty/never-run tasks fall back to the title.
fn task_answer_target(app: &App, t: &crate::schemas::Task) -> (String, String) {
    if t.state == TaskState::NeedsUser {
        let q = crate::run::latest_question_for(&app.ws, &t.id).unwrap_or_default();
        return (t.id.clone(), q);
    }
    let context = latest_answer_run(app, &t.id)
        .and_then(|dir| std::fs::read_to_string(dir.join("result.json")).ok())
        .and_then(|raw| serde_json::from_str::<crate::schemas::RunResult>(&raw).ok())
        .map(|r| {
            let mut s = r.compact_summary.trim().to_string();
            for f in &r.validation.failures {
                s.push_str("\n- ");
                s.push_str(f);
            }
            s
        })
        .unwrap_or_else(|| t.title.clone());
    (t.id.clone(), context)
}

fn current_intent_id(app: &App) -> Option<&str> {
    app.snapshot
        .as_ref()
        .map(|s| s.queue.intent_id.as_str())
        .filter(|id| !id.is_empty())
}

fn channel_projection_lines(channel: &crate::schemas::TaskChannel, l: &i18n::L) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current_attempt: Option<&str> = None;
    for event in &channel.events {
        if event.attempt_id.as_deref() != current_attempt {
            current_attempt = event.attempt_id.as_deref();
            if let Some(attempt_id) = current_attempt {
                let worker = channel
                    .attempts
                    .iter()
                    .find(|attempt| attempt.attempt_id == attempt_id)
                    .map(|attempt| attempt.worker_id.as_str())
                    .unwrap_or(l.unknown_word);
                lines.push(format!(
                    "--- {} {attempt_id} · {worker} ---",
                    l.planning_attempt
                ));
            }
        }
        let text = match event.event_type {
            crate::schemas::ChannelEventType::WorkerStarted => {
                Some(l.channel_worker_started.to_string())
            }
            crate::schemas::ChannelEventType::WorkerMessage => event
                .payload
                .get("text")
                .and_then(|value| value.as_str())
                .map(str::to_string),
            crate::schemas::ChannelEventType::ToolStarted => Some(format!(
                "{}: {}",
                l.channel_tool_started,
                event
                    .payload
                    .get("name")
                    .or_else(|| event.payload.get("command"))
                    .and_then(|value| value.as_str())
                    .unwrap_or(l.unknown_word)
            )),
            crate::schemas::ChannelEventType::ToolCompleted => Some(format!(
                "{}: {}",
                l.channel_tool_completed,
                event
                    .payload
                    .get("name")
                    .or_else(|| event.payload.get("command"))
                    .and_then(|value| value.as_str())
                    .unwrap_or(l.unknown_word)
            )),
            crate::schemas::ChannelEventType::QuestionAsked => event
                .payload
                .get("text")
                .and_then(|value| value.as_str())
                .map(|text| format!("{}: {text}", l.channel_question)),
            crate::schemas::ChannelEventType::UserAnswered => event
                .payload
                .get("text")
                .and_then(|value| value.as_str())
                .map(|text| format!("{}: {text}", l.channel_user)),
            crate::schemas::ChannelEventType::WorkerCheckpoint => {
                Some(l.channel_checkpoint.to_string())
            }
            crate::schemas::ChannelEventType::WorkerCompleted => Some(format!(
                "{}: {}",
                l.channel_worker_completed,
                event
                    .payload
                    .get("result")
                    .and_then(|value| value.as_str())
                    .unwrap_or(l.unknown_word)
            )),
            crate::schemas::ChannelEventType::CompletionRecorded => {
                let state = event
                    .payload
                    .get("task_state")
                    .and_then(|value| value.as_str())
                    .unwrap_or(l.unknown_word);
                Some(format!(
                    "{}: {}",
                    l.channel_task_completed,
                    i18n::recorded_state_label(l, state)
                ))
            }
            crate::schemas::ChannelEventType::ValidationStarted => {
                Some(l.channel_validation_started.to_string())
            }
            crate::schemas::ChannelEventType::ValidationCompleted => Some(format!(
                "{}: {}",
                l.channel_validation_completed,
                if event
                    .payload
                    .get("passed")
                    .and_then(|value| value.as_bool())
                    .unwrap_or(false)
                {
                    l.passed_word
                } else {
                    l.s_failed
                }
            )),
            _ => None,
        };
        if let Some(text) = text.filter(|text| !text.trim().is_empty()) {
            lines.push(format!("[{}] {text}", event.seq));
        }
    }
    lines
}

/// Latest run for this task that belongs to the live intent. Task ids repeat
/// across plans, so a bare latest-by-task lookup can expose a past intent's
/// worker output on the Answer screen.
fn latest_answer_run(app: &App, task_id: &str) -> Option<std::path::PathBuf> {
    let current_intent = current_intent_id(app);
    let mut best: Option<(String, std::path::PathBuf)> = None;
    for entry in std::fs::read_dir(app.ws.runs_dir()).ok()?.flatten() {
        let dir = entry.path();
        let Some(name) = dir.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.starts_with("run-") {
            continue;
        }
        let Ok(record) = state::load_yaml::<crate::run::RunRecord>(&dir.join("run.yaml")) else {
            continue;
        };
        if record.task_id != task_id {
            continue;
        }
        if current_intent.is_some_and(|intent| record.intent_id != intent) {
            continue;
        }
        if best
            .as_ref()
            .map(|(best_name, _)| name > best_name.as_str())
            .unwrap_or(true)
        {
            best = Some((name.to_string(), dir));
        }
    }
    best.map(|(_, dir)| dir)
}

fn readable_worker_output(run_dir: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(run_dir.join("worker-output.log")).ok()?;
    let text = raw
        .lines()
        .filter_map(view::pretty_event_line)
        .collect::<Vec<_>>()
        .join("\n");
    (!text.trim().is_empty()).then(|| text.trim().to_string())
}

fn compact_run_summary(run_dir: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(run_dir.join("result.json")).ok()?;
    let result = serde_json::from_str::<crate::schemas::RunResult>(&raw).ok()?;
    (!result.compact_summary.trim().is_empty()).then(|| result.compact_summary.trim().to_string())
}

fn run_belongs_to_intent(ws: &Workspace, run_id: &str, intent_id: Option<&str>) -> bool {
    let Ok(record) =
        state::load_yaml::<crate::run::RunRecord>(&ws.runs_dir().join(run_id).join("run.yaml"))
    else {
        return false;
    };
    intent_id
        .map(|intent| record.intent_id == intent)
        .unwrap_or(true)
}

/// Render only the conversation segment attributable to the live intent.
/// User turns inherit the attribution of the worker turn they answer. A
/// run-less seeded decision is included only when it is the current question.
fn answer_conversation(app: &App, task_id: &str, question: &str) -> Option<String> {
    let conversation = app
        .ws
        .load_conversation(current_intent_id(app).unwrap_or(""), task_id);
    let last_worker = conversation
        .turns
        .iter()
        .rposition(|turn| turn.role == crate::schemas::TurnRole::Worker);
    let mut include_segment = false;
    let mut lines = Vec::new();
    for (index, turn) in conversation.turns.iter().enumerate() {
        if turn.role == crate::schemas::TurnRole::Worker {
            include_segment = if turn.run_id.is_empty() {
                Some(index) == last_worker && turn.text.trim() == question.trim()
            } else {
                run_belongs_to_intent(&app.ws, &turn.run_id, current_intent_id(app))
            };
        }
        if !include_segment || turn.text.trim().is_empty() {
            continue;
        }
        let role = match turn.role {
            crate::schemas::TurnRole::Worker => app.lang.l().conversation_worker,
            crate::schemas::TurnRole::User => app.lang.l().conversation_user,
        };
        lines.push(format!("**{role}:** {}", turn.text.trim()));
    }
    (!lines.is_empty()).then(|| lines.join("\n\n"))
}

fn build_answer_context(app: &App, target_id: &str, question: &str) -> String {
    let l = app.lang.l();
    if target_id == INTERVIEW_TARGET {
        let summary = app
            .snapshot
            .as_ref()
            .map(|s| s.intent_summary())
            .unwrap_or(l.no_answer_context);
        return format!("# {}\n\n{}", l.plan_needs, summary);
    }

    let task = app
        .snapshot
        .as_ref()
        .and_then(|s| s.queue.tasks.iter().find(|task| task.id == target_id));
    let mut context = String::new();
    if let Some(task) = task {
        context.push_str(&format!(
            "# {} · {} · [{}]\n\n",
            task.id,
            task.title,
            i18n::task_state_label(l, task.state)
        ));
    } else {
        context.push_str(&format!("# {target_id}\n\n"));
    }

    let run_dir = latest_answer_run(app, target_id);
    let mut has_detail = false;
    if let Some(intent_id) = current_intent_id(app) {
        if let Ok(channel) = app.ws.load_task_channel(intent_id, target_id) {
            let lines = channel_projection_lines(&channel, l);
            if !lines.is_empty() {
                context.push_str(&format!(
                    "## {}\n\n{}\n\n",
                    l.worker_output_title,
                    lines.join("\n")
                ));
                has_detail = true;
            }
        }
    }
    if !has_detail {
        if let Some(output) = run_dir.as_deref().and_then(readable_worker_output) {
            context.push_str(&format!("## {}\n\n{output}\n\n", l.worker_output_title));
            has_detail = true;
        }
    }
    if let Some(conversation) = answer_conversation(app, target_id, question) {
        context.push_str(&format!(
            "## {}\n\n{conversation}\n\n",
            l.conversation_title
        ));
        has_detail = true;
    }
    if !has_detail {
        if let Some(summary) = run_dir.as_deref().and_then(compact_run_summary) {
            context.push_str(&format!("## {}\n\n{summary}\n", l.compact_summary_title));
        } else if !question.trim().is_empty() {
            context.push_str(&format!("## {}\n\n{}\n", l.question_title, question.trim()));
        } else {
            context.push_str(l.no_answer_context);
            context.push('\n');
        }
    }
    context.trim_end().to_string()
}

/// One interview turn: send the user's answer to the planning worker and
/// re-plan in place. The gate re-evaluates from the new ambiguity score.
fn start_interview(app: &mut App) {
    let ws = app.ws.clone();
    let answer = app.input.trim().to_string();
    let lbl = app.lang.l();
    let (planned_via, tasks_word, failed) = (lbl.planned_via, lbl.tasks_word, lbl.planning_failed);
    let planner_label = lbl.planner.to_string();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let res = match crate::planner::run_planning_interview(&ws, &answer) {
            Ok(r) => JobResult {
                ok: true,
                summary: format!(
                    "{planned_via} {}: {} ({} {tasks_word})",
                    r.worker_id, r.intent_summary, r.task_count
                ),
            },
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(if res.ok {
            JobMsg::PlanningDone(res)
        } else {
            JobMsg::Done(res)
        });
    });
    app.job = Job::Running {
        label: planner_label,
        started: Instant::now(),
        rx,
    };
}

fn start_answer(app: &mut App) {
    let grant_after_answer = app.answer_grants_approval;
    app.answer_grants_approval = false;
    let target = app
        .answer_target
        .take()
        .or_else(|| app.snapshot.as_ref().and_then(|s| s.pending.clone()));
    let Some((task_id, _)) = target else {
        app.toast = Some((false, app.lang.l().no_answer_target.into()));
        return;
    };
    if task_id == INTERVIEW_TARGET {
        start_interview(app);
        return;
    }
    let approvals_needed = app
        .snapshot
        .as_ref()
        .map(|s| s.approvals_needed.as_slice())
        .unwrap_or(&[]);
    if answer_target_will_grant(&task_id, grant_after_answer, approvals_needed) {
        if let Err(e) = crate::planning::validate_active_activation(&app.ws) {
            app.toast = Some((false, format!("{} {e}", app.lang.l().answer_failed)));
            return;
        }
        if let Err(e) = crate::approvals::grant(&app.ws, &task_id) {
            app.toast = Some((false, format!("{} {e}", app.lang.l().answer_failed)));
            return;
        }
    }
    let ws = app.ws.clone();
    let lang = app.lang;
    let answer = app.input.trim().to_string();
    if let Err(e) = run::prepare_answer_action(&app.ws, &task_id, &answer, None) {
        app.toast = Some((false, format!("{} {e}", app.lang.l().answer_failed)));
        return;
    }
    let lbl = app.lang.l();
    let (resumed_via, failed) = (lbl.resumed_via, lbl.answer_failed);
    let (tx, rx) = mpsc::channel();
    let label_task = task_id.clone();
    thread::spawn(move || {
        let res = match run::run_next(
            &ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target: Some(task_id.clone()),
                answer: Some(answer),
                full_access: false,
                accept_ambiguity: false,
                chain: None,
            },
        ) {
            Ok(r) => {
                let outcome = localized_run_outcome(lang, &r);
                JobResult {
                    ok: true,
                    summary: format!("{} {resumed_via} {}: {outcome}", r.task_id, r.worker_id),
                }
            }
            Err(e) => JobResult {
                ok: false,
                summary: format!("{failed} {e}"),
            },
        };
        let _ = tx.send(JobMsg::Done(res));
    });
    app.job = Job::Running {
        label: format!("{} {label_task}", lbl.run_word),
        started: Instant::now(),
        rx,
    };
    app.input_clear();
}

fn load_handoff_for_task(app: &App, task_id: &str) -> String {
    if let Some((_, dir)) = crate::run::latest_run_for(&app.ws, task_id) {
        if let Ok(txt) = std::fs::read_to_string(dir.join("handoff.md")) {
            if !txt.trim().is_empty() {
                return txt;
            }
        }
    }
    format!("{task_id}: {}", app.lang.l().no_task_handoff)
}

fn load_latest_handoff(app: &App) -> String {
    let runs = app.ws.runs_dir();
    let mut newest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
    if let Ok(rd) = std::fs::read_dir(&runs) {
        for e in rd.flatten() {
            // Only runs that actually wrote a handoff — skip plan-* and
            // unfinished runs — so `h` shows the most recent real handoff,
            // including after a restart. Handoffs persist on disk.
            let hf = e.path().join("handoff.md");
            if !hf.is_file() {
                continue;
            }
            let t = hf
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            if newest.as_ref().map(|(nt, _)| t > *nt).unwrap_or(true) {
                newest = Some((t, e.path()));
            }
        }
    }
    match newest {
        Some((_, dir)) => std::fs::read_to_string(dir.join("handoff.md"))
            .unwrap_or_else(|_| app.lang.l().latest_handoff_failed.into()),
        None => app.lang.l().no_latest_handoff.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every key that WORKS on Home must be documented somewhere the operator
    /// can find it. The footer change that curated content keys shipped with
    /// tests asserting keys are hidden when they have no target, but nothing
    /// asserted the opposite direction — so `g`, `s`, `f`, `l`, `i` and `R`
    /// worked while appearing on no idle surface (issue #71).
    ///
    /// This walks the dispatcher's own classifier rather than a hand-written
    /// list, so a new binding cannot be added without documenting it.
    #[test]
    fn every_dispatched_home_key_appears_in_the_key_list() {
        let mut dispatched = Vec::new();
        let mut codes: Vec<KeyCode> = (0x20_u8..=0x7e).map(|b| KeyCode::Char(b as char)).collect();
        codes.extend([
            KeyCode::Up,
            KeyCode::Down,
            KeyCode::Left,
            KeyCode::Right,
            KeyCode::Enter,
            KeyCode::Esc,
            KeyCode::Tab,
            KeyCode::Backspace,
            KeyCode::PageUp,
            KeyCode::PageDown,
            KeyCode::Home,
            KeyCode::End,
        ]);
        for code in codes {
            // `update_available` on, so the restart key is classified too.
            if let Some(key) = home_key(code, true) {
                if !dispatched.contains(&key) {
                    dispatched.push(key);
                }
            }
        }
        assert!(
            dispatched.len() >= 20,
            "the classifier scan found almost nothing; the walk is broken, not the UI"
        );
        for key in dispatched {
            assert!(
                HOME_KEYS.contains(&key),
                "{key:?} works on Home but is missing from the key list"
            );
            for lang in [i18n::Lang::En, i18n::Lang::Ko] {
                assert!(
                    !key.doc(lang.l()).trim().is_empty(),
                    "{key:?} has no {lang:?} description"
                );
            }
        }
        // The list must not advertise a key the dispatcher does not have.
        for key in HOME_KEYS {
            assert!(
                (0x20_u8..=0x7e)
                    .map(|b| KeyCode::Char(b as char))
                    .chain([KeyCode::Up, KeyCode::Down, KeyCode::Enter, KeyCode::Esc])
                    .any(|code| home_key(code, true) == Some(*key)),
                "the key list advertises {key:?}, which Home does not dispatch"
            );
        }
    }

    /// Busy-gating moved from eight inline `if !app.is_busy()` guards into one
    /// predicate. Nothing tested it, so dropping `Run` from the set — starting a
    /// second run while one is in flight — would have failed no test at all.
    #[test]
    fn busy_gating_covers_exactly_the_keys_that_start_or_change_work() {
        let gated: Vec<HomeKey> = HOME_KEYS
            .iter()
            .copied()
            .filter(|key| key.needs_idle())
            .collect();
        assert_eq!(
            gated,
            vec![
                HomeKey::New,
                HomeKey::Run,
                HomeKey::Auto,
                HomeKey::Defer,
                HomeKey::Revive,
                HomeKey::Tidy,
                HomeKey::PlanReview,
                HomeKey::Language,
            ],
            "the busy gate changed; every entry here starts or changes work, and \
             every key NOT here has to stay usable while a worker runs"
        );
        // The inverse is the part that actually bit operators: settings, access,
        // the monitor, the handoff and the key list exist to be reachable
        // mid-run, and quitting must never be gated.
        for key in [
            HomeKey::Settings,
            HomeKey::Access,
            HomeKey::Monitor,
            HomeKey::Handoff,
            HomeKey::Goal,
            HomeKey::Trust,
            HomeKey::Reports,
            HomeKey::Refresh,
            HomeKey::Keys,
            HomeKey::Quit,
            HomeKey::Stop,
            HomeKey::ApproveOrPause,
            HomeKey::Up,
            HomeKey::Down,
            HomeKey::Act,
            HomeKey::ToggleWorker,
        ] {
            assert!(!key.needs_idle(), "{key:?} must stay usable while busy");
        }
    }

    /// The key list is reachable from both Home footers, idle and busy: the
    /// inversion the issue called out (globals discoverable only mid-run) must
    /// not come back in either direction.
    #[test]
    fn the_key_list_key_is_advertised_in_every_home_footer() {
        for lang in [i18n::Lang::En, i18n::Lang::Ko] {
            let l = lang.l();
            for footer in [l.footer_home_busy, l.footer_home_busy_nodrain] {
                assert!(
                    footer.contains(l.key_keys),
                    "{lang:?} busy footer does not advertise the key list: {footer}"
                );
            }
        }
    }

    /// Every always-valid global the issue named is in the list with a
    /// description, in both languages.
    #[test]
    fn always_valid_globals_are_documented_in_both_languages() {
        for glyph in ["g", "s", "f", "l", "i", "R", "q", "?"] {
            for lang in [i18n::Lang::En, i18n::Lang::Ko] {
                let rows = home_key_rows(lang.l());
                let row = rows.iter().find(|(key, _)| *key == glyph);
                let (_, doc) = row.unwrap_or_else(|| {
                    panic!("{glyph} is not in the {lang:?} key list: {rows:?}");
                });
                assert!(!doc.trim().is_empty(), "{glyph} has an empty {lang:?} doc");
            }
        }
    }

    const CONFIG_WITH_COMMENTS: &str = r#"schema_version: 1
product: yardlet
workspace_id: ui-test
created_at: "2026-07-03T00:00:00Z"
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: ""
# keep language comment
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
    # keep codex comment
    enabled: true # keep enabled comment
    model: "" # keep model comment
    effort: ""
    invocation:
      command: codex
  - id: claude-code
    # keep claude comment
    enabled: true
    model: sonnet
    effort: medium
    invocation:
      command: claude
routing:
  default_worker: codex
  fallback_order: [codex, claude-code]
"#;

    fn workspace_with_user_config(name: &str) -> Workspace {
        let root = std::env::temp_dir().join(format!("yard-ui-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        std::fs::create_dir_all(ws.agents_dir()).unwrap();
        std::fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();
        std::fs::write(ws.workers_path(), WORKERS_WITH_COMMENTS).unwrap();
        std::fs::write(ws.billing_path(), crate::templates::BILLING_POLICY).unwrap();
        ws
    }

    fn cached_snapshot(ws: &Workspace) -> Snapshot {
        let billing = ws.load_billing().unwrap();
        let workers = ws
            .load_workers()
            .unwrap()
            .workers
            .into_iter()
            .map(|worker| crate::snapshot::WorkerLine {
                readiness_cache_key: crate::guard::readiness_cache_key(
                    &worker,
                    &billing,
                    "sandboxed",
                ),
                id: worker.id,
                readiness: "invocable".into(),
                version: Some("fixture 1.0".into()),
                billing_env_present: 0,
                billing_blocked: false,
                model: worker.model,
                detail: "injected".into(),
                enabled: true,
            })
            .collect();
        Snapshot::load_reusing_workers(ws, workers).unwrap()
    }

    fn record_monitor_attempt(
        ws: &Workspace,
        intent_id: &str,
        attempt_id: &str,
        stdout_ref: &std::path::Path,
        stderr_ref: &std::path::Path,
        result: &str,
        exit: (Option<i32>, Option<i32>),
    ) {
        let task_id = "TARGET";
        let session_id = format!("session-{intent_id}");
        let (exit_code, exit_signal) = exit;
        let attempt = crate::schemas::WorkerAttempt {
            schema_version: 1,
            attempt_id: attempt_id.into(),
            session_id: session_id.clone(),
            intent_id: intent_id.into(),
            task_id: task_id.into(),
            worker_id: "fixture".into(),
            worker_session_ref: None,
            state: crate::schemas::AttemptState::Prepared,
            continuation: crate::schemas::ContinuationMode::Fresh,
            caused_by_event_id: None,
            caused_by_action_id: None,
            raw_stdout_ref: stdout_ref.display().to_string(),
            raw_stderr_ref: stderr_ref.display().to_string(),
        };
        ws.record_worker_attempt(&attempt).unwrap();
        for (event_type, payload) in [
            (
                crate::schemas::ChannelEventType::AttemptPrepared,
                serde_json::json!({"worker_id": "fixture"}),
            ),
            (
                crate::schemas::ChannelEventType::WorkerStarted,
                serde_json::json!({"worker_id": "fixture"}),
            ),
            (
                crate::schemas::ChannelEventType::WorkerCompleted,
                serde_json::json!({
                    "result": result,
                    "exit_ok": exit_code == Some(0) && exit_signal.is_none(),
                    "exit_code": exit_code,
                    "exit_signal": exit_signal,
                    "timed_out": false,
                    "raw_stdout_ref": attempt.raw_stdout_ref,
                    "raw_stderr_ref": attempt.raw_stderr_ref
                }),
            ),
        ] {
            ws.record_task_event(
                intent_id,
                crate::schemas::ChannelEvent {
                    schema_version: 1,
                    event_id: String::new(),
                    session_id: session_id.clone(),
                    seq: 0,
                    event_type,
                    recorded_at: "2026-08-03T00:00:00Z".into(),
                    actor: crate::schemas::EventActor {
                        kind: crate::schemas::EventActorKind::System,
                        id: String::new(),
                    },
                    action_id: None,
                    causation_id: None,
                    correlation_id: format!("cor-{session_id}"),
                    task_id: task_id.into(),
                    attempt_id: Some(attempt_id.into()),
                    payload,
                    raw_ref: None,
                },
            )
            .unwrap();
        }
    }

    #[cfg(unix)]
    fn write_version_probe(path: &std::path::Path, version: &str) {
        use std::os::unix::fs::PermissionsExt;

        std::fs::write(
            path,
            format!(
                "#!/bin/sh\nif [ \"${{1:-}}\" = \"--version\" ]; then\n  printf '%s\\n' '{}'\n  exit 0\nfi\nexit 1\n",
                version
            ),
        )
        .unwrap();
        let mut permissions = std::fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn explicit_refresh_reprobes_worker_readiness_after_cached_reload() {
        let ws = workspace_with_user_config("explicit-refresh-probe");
        let probe = ws.root.join("fixture-worker");
        write_version_probe(&probe, "fixture 1.0");
        std::fs::write(
            ws.workers_path(),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    enabled: true\n    invocation:\n      command: {}\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\nrouting: {{}}\n",
                probe.display()
            ),
        )
        .unwrap();

        let mut app = App::new(ws.clone());
        assert_eq!(
            app.snapshot.as_ref().unwrap().workers[0].version.as_deref(),
            Some("fixture 1.0")
        );

        write_version_probe(&probe, "fixture 2.0");
        app.reload();
        assert_eq!(
            app.snapshot.as_ref().unwrap().workers[0].version.as_deref(),
            Some("fixture 1.0"),
            "cheap reload must keep the cached readiness result"
        );

        app.reload_full();
        assert_eq!(
            app.snapshot.as_ref().unwrap().workers[0].version.as_deref(),
            Some("fixture 2.0"),
            "explicit refresh must run a fresh readiness probe"
        );
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[cfg(unix)]
    #[test]
    fn cheap_reload_invalidates_readiness_when_the_invocation_contract_changes() {
        let ws = workspace_with_user_config("invocation-contract-cache");
        let probe = ws.root.join("fixture-worker");
        write_version_probe(&probe, "fixture 1.0");
        let workers = |supports_noninteractive: bool| {
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    enabled: true\n    invocation:\n      command: {}\n      supports_noninteractive: {}\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\nrouting: {{}}\n",
                probe.display(), supports_noninteractive
            )
        };
        std::fs::write(ws.workers_path(), workers(true)).unwrap();

        let mut app = App::new(ws.clone());
        assert_eq!(
            app.snapshot.as_ref().unwrap().workers[0].readiness,
            "invocable"
        );

        std::fs::write(ws.workers_path(), workers(false)).unwrap();
        app.reload();
        assert_eq!(
            app.snapshot.as_ref().unwrap().workers[0].readiness,
            "not ready",
            "a changed static invocation contract must not inherit cached ready state"
        );
        assert!(app.snapshot.as_ref().unwrap().workers[0]
            .detail
            .contains("supports_noninteractive"));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn bootstrap_key_gate_blocks_all_canonical_actions_until_ready() {
        use BootstrapKeyAction::*;

        for code in [
            KeyCode::Char('n'),
            KeyCode::Char('r'),
            KeyCode::Char('A'),
            KeyCode::Char('t'),
            KeyCode::Char('d'),
            KeyCode::Char('v'),
            KeyCode::Char('p'),
            KeyCode::Char('a'),
            KeyCode::Char('s'),
            KeyCode::Char('l'),
            KeyCode::Char('f'),
            KeyCode::Enter,
            KeyCode::Char(' '),
        ] {
            assert_eq!(
                bootstrap_key_action(BootstrapPhase::Loading, code),
                Block,
                "{code:?} must not reach a handler while startup is loading"
            );
            assert_eq!(
                bootstrap_key_action(BootstrapPhase::Failed, code),
                Block,
                "{code:?} must not reach a handler after startup failed"
            );
            assert_eq!(
                bootstrap_key_action(BootstrapPhase::Ready, code),
                Dispatch,
                "{code:?} should preserve normal behavior after startup"
            );
        }
        assert_eq!(
            bootstrap_key_action(BootstrapPhase::Loading, KeyCode::Char('q')),
            Quit
        );
        assert_eq!(
            bootstrap_key_action(BootstrapPhase::Failed, KeyCode::Char('g')),
            Retry
        );
        assert_eq!(
            bootstrap_key_action(BootstrapPhase::Loading, KeyCode::Char('g')),
            Block
        );
    }

    #[test]
    fn startup_job_orders_recovery_before_worker_probe_and_returns_latest_snapshot() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let ws = workspace_with_user_config("startup-job-order");
        let recovered = Arc::new(AtomicBool::new(false));
        let observed = recovered.clone();
        let rx = spawn_startup_job_with(
            ws.clone(),
            move |_workspace| {
                recovered.store(true, Ordering::SeqCst);
                Ok(vec!["recovered fixture".into()])
            },
            move |workspace| {
                assert!(
                    observed.load(Ordering::SeqCst),
                    "snapshot probe started before recovery completed"
                );
                Ok(cached_snapshot(workspace))
            },
        );

        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            StartupMsg::Progress(StartupStage::Recovery)
        ));
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            StartupMsg::Progress(StartupStage::WorkerProbe)
        ));
        match rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StartupMsg::Ready {
                snapshot,
                recovered,
            } => {
                assert_eq!(snapshot.workers.len(), 2);
                assert_eq!(recovered, vec!["recovered fixture"]);
            }
            _ => panic!("startup did not return a ready snapshot"),
        }
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn startup_failure_stays_fail_closed_and_a_retry_can_become_ready() {
        let ws = workspace_with_user_config("startup-retry");
        let mut app = App::new_bootstrapping(ws.clone(), false);
        let failed = spawn_startup_job_with(
            ws.clone(),
            |_workspace| anyhow::bail!("fixture validation rejected"),
            |_workspace| unreachable!("probe must not run after recovery failure"),
        );
        app.begin_startup(failed);
        let deadline = Instant::now() + Duration::from_secs(1);
        while app.bootstrap_phase() == BootstrapPhase::Loading && Instant::now() < deadline {
            app.poll_startup();
            std::thread::yield_now();
        }
        assert_eq!(app.bootstrap_phase(), BootstrapPhase::Failed);
        assert!(app.snapshot.is_none());
        assert!(matches!(
            &app.bootstrap,
            BootstrapState::Failed(message) if message.contains("fixture validation rejected")
        ));

        let ready = spawn_startup_job_with(
            ws.clone(),
            |_workspace| Ok(Vec::new()),
            |workspace| Ok(cached_snapshot(workspace)),
        );
        app.begin_startup(ready);
        let deadline = Instant::now() + Duration::from_secs(1);
        while app.bootstrap_phase() == BootstrapPhase::Loading && Instant::now() < deadline {
            app.poll_startup();
            std::thread::yield_now();
        }
        assert_eq!(app.bootstrap_phase(), BootstrapPhase::Ready);
        assert!(app.snapshot.is_some());
        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn write_answer_run(
        ws: &Workspace,
        run_id: &str,
        task_id: &str,
        intent_id: &str,
        output: Option<&[u8]>,
        summary: &str,
    ) {
        let dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&dir).unwrap();
        state::save_yaml(
            &dir.join("run.yaml"),
            &crate::run::RunRecord {
                run_id: run_id.to_string(),
                task_id: task_id.to_string(),
                intent_id: intent_id.to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        if let Some(bytes) = output {
            std::fs::write(dir.join("worker-output.log"), bytes).unwrap();
        }
        std::fs::write(
            dir.join("result.json"),
            serde_json::json!({
                "schema_version": 1,
                "run_id": run_id,
                "task_id": task_id,
                "status": "needs_user",
                "compact_summary": summary
            })
            .to_string(),
        )
        .unwrap();
    }

    #[test]
    fn input_caret_edits_midstring_with_hangul() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-caret-test"));
        let mut app = App::new(ws);
        app.input_insert("가나");
        app.input_insert("다"); // "가나다", caret=3
        assert_eq!(app.input, "가나다");
        assert_eq!(app.input_caret, 3);
        app.caret_left(); // between 나 and 다
        app.caret_left(); // between 가 and 나
        app.input_insert("X"); // "가X나다"
        assert_eq!(app.input, "가X나다");
        assert_eq!(app.input_caret, 2);
        app.input_backspace(); // delete X -> "가나다"
        assert_eq!(app.input, "가나다");
        assert_eq!(app.input_caret, 1);
        app.caret_end();
        app.input_delete(); // at end, no-op
        assert_eq!(app.input, "가나다");
        app.caret_home();
        app.input_delete(); // delete 가 -> "나다"
        assert_eq!(app.input, "나다");
        assert_eq!(app.input_caret, 0);
    }

    #[test]
    fn caret_up_down_moves_between_lines_keeping_column() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-caret-vert-test"));
        let mut app = App::new(ws);
        // Lines: "ab" / "cde" / "fg" (chars a b \n c d e \n f g, caret at end).
        app.input_insert("ab\ncde\nfg");
        assert_eq!(app.input_caret, 9);
        app.caret_up(); // last line col 2 -> "cde" col 2
        assert_eq!(app.input_caret, 5);
        app.caret_up(); // -> "ab" clamped to its length
        assert_eq!(app.input_caret, 2);
        app.caret_up(); // first line -> jump to the very start
        assert_eq!(app.input_caret, 0);
        app.caret_down(); // -> "cde" col 0
        assert_eq!(app.input_caret, 3);
        app.caret_down(); // -> "fg" col 0
        assert_eq!(app.input_caret, 7);
        app.caret_down(); // last line -> jump to the very end
        assert_eq!(app.input_caret, 9);

        // Column is kept across a multibyte source line (가나다 -> xy).
        app.input_clear();
        app.input_insert("가나다\nxy");
        app.input_caret = 2; // col 2 on "가나다"
        app.caret_down(); // -> "xy", clamped to its length 2
        assert_eq!(app.input_caret, 6);
    }

    #[test]
    fn home_end_move_to_current_line_boundaries() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-caret-line-boundary-test"));
        let mut app = App::new(ws);
        app.input_insert("첫줄\n가나다\n끝");
        app.input_caret = 5;

        app.caret_home();
        assert_eq!(app.input_caret, 3, "Home must stay on the middle line");
        app.caret_end();
        assert_eq!(app.input_caret, 6, "End must stay on the middle line");
    }

    #[test]
    fn new_work_enter_is_newline_and_control_s_does_not_insert_text() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-new-work-key-test"));
        let mut app = App::new(ws);
        app.screen = Screen::NewWork;

        handle_new_work_key(&mut app, KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(app.input, "\n");
        assert_eq!(app.screen, Screen::NewWork);

        app.input_clear();
        handle_new_work_key(&mut app, KeyCode::Char('s'), KeyModifiers::CONTROL);
        assert!(app.input.is_empty(), "Ctrl+S must never insert a literal s");
        assert_eq!(app.screen, Screen::NewWork);
        assert!(matches!(app.job, Job::Idle));

        handle_new_work_key(&mut app, KeyCode::Enter, KeyModifiers::CONTROL);
        assert_eq!(
            app.input, "\n",
            "without enhancement, modified Enter remains a newline"
        );
        app.input_clear();
        app.keyboard_enhancement = true;
        handle_new_work_key(&mut app, KeyCode::Enter, KeyModifiers::CONTROL);
        assert!(
            app.input.is_empty(),
            "enhanced Ctrl+Enter must reach empty-submit rejection"
        );
        assert!(matches!(app.job, Job::Idle));
    }

    #[test]
    fn new_work_escape_discards_the_draft_without_touching_other_state() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-new-work-cancel-test"));
        let mut app = App::new(ws);
        app.screen = Screen::NewWork;
        app.replan = true;
        app.input_insert("취소할\n요청");

        handle_new_work_key(&mut app, KeyCode::Esc, KeyModifiers::NONE);

        assert_eq!(app.screen, Screen::Home);
        assert!(app.input.is_empty());
        assert_eq!(app.input_caret, 0);
        assert!(!app.amend);
        assert!(!app.replan);
    }

    #[test]
    fn bracketed_paste_preserves_hangul_lines_for_mid_buffer_editing() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-multiline-paste-test"));
        let mut app = App::new(ws);
        app.screen = Screen::PlanningReview;
        handle_input_paste(&mut app, "무시");
        assert!(app.input.is_empty(), "review mode is read-only before e");

        app.planning_review_editing = true;
        handle_input_paste(&mut app, "첫째\n둘째\n셋");
        assert_eq!(app.input, "첫째\n둘째\n셋");
        assert_eq!(app.input_caret, 7);

        app.caret_up();
        assert_eq!(app.input_caret, 4);
        app.input_insert("가");
        app.input_delete();
        assert_eq!(app.input, "첫째\n둘가\n셋");
        assert_eq!(app.input_caret, 5);

        app.caret_down();
        app.input_backspace();
        assert_eq!(app.input, "첫째\n둘가\n");
        assert_eq!(app.input_caret, 6);
    }

    #[test]
    fn planning_revision_escape_clears_only_the_editing_draft() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-revision-cancel-test"));
        let mut app = App::new(ws);
        app.screen = Screen::PlanningReview;
        app.planning_review_editing = true;
        app.input_insert(" \n ");

        handle_planning_review_key(&mut app, KeyCode::Char('s'), KeyModifiers::CONTROL);
        assert!(app.planning_review_editing);
        assert_eq!(app.input, " \n ");
        assert!(matches!(app.job, Job::Idle));

        app.input_clear();
        app.input_insert("버릴\n수정 요청");

        handle_planning_review_key(&mut app, KeyCode::Esc, KeyModifiers::NONE);

        assert_eq!(app.screen, Screen::PlanningReview);
        assert!(!app.planning_review_editing);
        assert!(app.input.is_empty());
        assert_eq!(app.input_caret, 0);
    }

    #[test]
    fn trust_panel_opens_from_home_and_closes_back() {
        let ws = workspace_with_user_config("trust-nav");
        let mut app = App::new(ws);
        assert_eq!(app.screen, Screen::Home);
        // T opens the trust/autonomy panel (read-only; viewable any time).
        assert!(!handle_home_key(&mut app, KeyCode::Char('T')));
        assert_eq!(app.screen, Screen::Trust);
        // The panel text is populated (empty-telemetry case renders, not panics).
        assert!(!app.trust_text.is_empty());
        // Each of T / q / Esc returns to Home.
        for close in [KeyCode::Char('T'), KeyCode::Char('q'), KeyCode::Esc] {
            app.screen = Screen::Trust;
            handle_trust_key(&mut app, close);
            assert_eq!(app.screen, Screen::Home, "{close:?} should close the panel");
        }
    }

    #[test]
    fn home_enter_action_maps_state_to_next_action() {
        use HomeEnterAction::*;
        // Approval invariant: an ungranted approval-required task is NEVER Run by
        // Enter — it points at the approval flow, whatever the underlying state
        // and even when a worker is busy (approval is checked before busy).
        assert_eq!(
            home_enter_action(TaskState::Queued, true, false),
            ApprovalHint
        );
        assert_eq!(
            home_enter_action(TaskState::Queued, true, true),
            ApprovalHint
        );
        assert_eq!(
            home_enter_action(TaskState::NeedsUser, true, false),
            AnswerThenApprove
        );
        assert_eq!(
            home_enter_action(TaskState::NeedsUser, true, true),
            AnswerThenApprove
        );
        // State dispatch (no approval pending, idle).
        assert_eq!(home_enter_action(TaskState::Queued, false, false), Run);
        assert_eq!(home_enter_action(TaskState::Partial, false, false), Run);
        assert_eq!(home_enter_action(TaskState::Failed, false, false), Run);
        assert_eq!(home_enter_action(TaskState::Blocked, false, false), Run);
        assert_eq!(
            home_enter_action(TaskState::NeedsUser, false, false),
            Answer
        );
        assert_eq!(home_enter_action(TaskState::Done, false, false), Handoff);
        assert_eq!(home_enter_action(TaskState::Running, false, false), Monitor);
        assert_eq!(
            home_enter_action(TaskState::Deferred, false, false),
            DeferredHint
        );
        // Busy blocks a new run/answer, but read-only views still work and a
        // deferred row is still just informational.
        assert_eq!(home_enter_action(TaskState::Queued, false, true), Busy);
        assert_eq!(home_enter_action(TaskState::NeedsUser, false, true), Busy);
        assert_eq!(home_enter_action(TaskState::Done, false, true), Handoff);
        assert_eq!(home_enter_action(TaskState::Running, false, true), Monitor);
        assert_eq!(
            home_enter_action(TaskState::Deferred, false, true),
            DeferredHint
        );
    }

    #[test]
    fn home_monitor_action_is_read_only_across_busy_and_approval_gates() {
        use HomeMonitorAction::*;
        for state in [TaskState::Failed, TaskState::Partial] {
            for approval_pending in [false, true] {
                for busy in [false, true] {
                    assert_eq!(
                        home_monitor_action(Some(state), approval_pending, busy),
                        SelectedFailure
                    );
                }
            }
        }
        for state in [
            None,
            Some(TaskState::Queued),
            Some(TaskState::Running),
            Some(TaskState::Done),
            Some(TaskState::NeedsUser),
        ] {
            assert_eq!(home_monitor_action(state, false, false), Live);
        }
    }

    #[test]
    fn home_replan_availability_and_key_action_cover_the_settled_queue_matrix() {
        use HomeReplanAction::*;
        use ReplanAvailability::*;

        let mut cap_exhausted: crate::schemas::Task = crate::yaml::from_str(
            "id: CAP\ntitle: exhausted approach\nstate: needs_user\ninteraction:\n  needs_user_origin: goal_feedback_exhausted\n",
        )
        .unwrap();
        cap_exhausted
            .set_needs_user_origin(Some(crate::schemas::NeedsUserOrigin::GoalFeedbackExhausted));
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.tasks = vec![cap_exhausted];
        assert_eq!(same_intent_replan_availability(&queue), Available);
        assert_eq!(
            home_replan_action(KeyCode::Char('P'), Available, false),
            OpenPrompt
        );
        assert_eq!(
            home_replan_action(KeyCode::Char('P'), Available, true),
            Busy
        );
        assert_eq!(
            home_replan_action(KeyCode::Char('x'), Available, false),
            Noop
        );

        let worker_question: crate::schemas::Task = crate::yaml::from_str(
            "id: ASK\ntitle: open worker question\nstate: needs_user\ninteraction:\n  needs_user_origin: worker_question\n",
        )
        .unwrap();
        queue.tasks = vec![worker_question];
        assert_eq!(same_intent_replan_availability(&queue), WorkerQuestion);
        assert_eq!(
            home_replan_action(KeyCode::Char('P'), WorkerQuestion, false),
            AnswerWorkerQuestion
        );

        let live: crate::schemas::Task =
            crate::yaml::from_str("id: LIVE\ntitle: live work\nstate: queued\n").unwrap();
        queue.tasks = vec![live];
        assert_eq!(same_intent_replan_availability(&queue), LiveQueue);
        assert_eq!(
            home_replan_action(KeyCode::Char('P'), LiveQueue, false),
            FinishLiveQueue
        );
    }

    #[test]
    fn home_replan_key_opens_a_same_intent_direction_prompt() {
        let ws = workspace_with_user_config("replan-key");
        let task: crate::schemas::Task = crate::yaml::from_str(
            "id: CAP\ntitle: exhausted approach\nstate: needs_user\ninteraction:\n  needs_user_origin: goal_feedback_exhausted\n",
        )
        .unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-replan-key".into();
        queue.tasks = vec![task];
        ws.save_queue(&queue).unwrap();

        let mut app = App::new(ws.clone());
        assert!(!handle_home_key(&mut app, KeyCode::Char('P')));
        assert_eq!(app.screen, Screen::NewWork);
        assert!(app.replan);
        assert!(!app.amend);

        let _ = std::fs::remove_dir_all(&ws.root);
    }

    #[test]
    fn home_answer_action_maps_every_gate_and_task_state_to_one_target() {
        assert_eq!(
            home_answer_action(
                true,
                Some("PENDING"),
                Some(("SELECTED", TaskState::NeedsUser)),
                Some("FIRST"),
                false
            ),
            HomeAnswerAction::Interview,
            "the global ambiguity gate must resolve before a task can resume"
        );
        assert_eq!(
            home_answer_action(
                false,
                Some("PENDING"),
                Some(("SELECTED", TaskState::NeedsUser)),
                Some("FIRST"),
                false
            ),
            HomeAnswerAction::Task("SELECTED".into()),
            "the cursor chooses among multiple open task questions"
        );
        assert_eq!(
            home_answer_action(
                false,
                Some("PENDING"),
                Some(("DONE", TaskState::Done)),
                Some("FIRST"),
                false
            ),
            HomeAnswerAction::Task("PENDING".into())
        );

        for state in [
            TaskState::Queued,
            TaskState::Blocked,
            TaskState::Failed,
            TaskState::Partial,
            TaskState::Deferred,
        ] {
            assert_eq!(
                home_answer_action(false, None, Some(("SELECTED", state)), Some("FIRST"), false),
                HomeAnswerAction::Task("SELECTED".into()),
                "an answerable selected state should target the selected task"
            );
        }
        for state in [TaskState::Running, TaskState::Done] {
            assert_eq!(
                home_answer_action(false, None, Some(("SELECTED", state)), Some("FIRST"), false),
                HomeAnswerAction::Task("FIRST".into()),
                "a non-answerable selected state should fall back to the first answerable task"
            );
        }
        assert_eq!(
            home_answer_action(false, None, None, None, false),
            HomeAnswerAction::None
        );
        assert_eq!(
            home_answer_action(
                true,
                Some("PENDING"),
                Some(("SELECTED", TaskState::NeedsUser)),
                Some("FIRST"),
                true
            ),
            HomeAnswerAction::Busy
        );
    }

    #[test]
    fn localized_run_outcome_never_uses_internal_english_state_tail_in_korean() {
        for state in [
            TaskState::Queued,
            TaskState::Running,
            TaskState::Done,
            TaskState::Failed,
            TaskState::Blocked,
            TaskState::NeedsUser,
            TaskState::Partial,
            TaskState::Deferred,
        ] {
            let report = crate::run::RunReport {
                run_id: "run-test".into(),
                task_id: "TASK".into(),
                worker_id: "worker".into(),
                run_dir: std::path::PathBuf::new(),
                prepared: true,
                executed: true,
                lines: vec!["next task state: internal english tail".into()],
                result_state: Some(state),
                session: None,
                chained: false,
            };
            let outcome = localized_run_outcome(i18n::Lang::Ko, &report);
            assert_eq!(outcome, i18n::task_state_label(i18n::Lang::Ko.l(), state));
            assert!(!outcome.contains("internal english tail"));
        }
    }

    #[test]
    fn channel_projection_localizes_chrome_and_preserves_payloads_and_identifiers() {
        let event = |seq, event_type, payload| crate::schemas::ChannelEvent {
            schema_version: 1,
            event_id: format!("evt-{seq}"),
            session_id: "ses-keep".into(),
            seq,
            event_type,
            recorded_at: "2026-07-24T00:00:00Z".into(),
            actor: crate::schemas::EventActor {
                kind: crate::schemas::EventActorKind::Worker,
                id: "worker-keep".into(),
            },
            action_id: None,
            causation_id: None,
            correlation_id: "cor-keep".into(),
            task_id: "YARD-KEEP".into(),
            attempt_id: None,
            payload,
            raw_ref: None,
        };
        let channel = crate::schemas::TaskChannel {
            schema_version: 1,
            channel_id: "chn-keep".into(),
            session_id: "ses-keep".into(),
            intent_id: "intent-keep".into(),
            task_id: "YARD-KEEP".into(),
            highest_seq: 5,
            attempts: Vec::new(),
            questions: Vec::new(),
            answers: Vec::new(),
            events: vec![
                event(
                    1,
                    crate::schemas::ChannelEventType::WorkerMessage,
                    serde_json::json!({"text": "WORKER CONTENT KEEP"}),
                ),
                event(
                    2,
                    crate::schemas::ChannelEventType::ToolStarted,
                    serde_json::json!({"command": "/tmp/KEEP --model MODEL-KEEP"}),
                ),
                event(
                    3,
                    crate::schemas::ChannelEventType::QuestionAsked,
                    serde_json::json!({"text": "USER QUESTION KEEP"}),
                ),
                event(
                    4,
                    crate::schemas::ChannelEventType::UserAnswered,
                    serde_json::json!({"text": "USER ANSWER KEEP"}),
                ),
                event(
                    5,
                    crate::schemas::ChannelEventType::CompletionRecorded,
                    serde_json::json!({"task_state": "done"}),
                ),
            ],
            replay_errors: Vec::new(),
        };

        let en = channel_projection_lines(&channel, i18n::Lang::En.l()).join("\n");
        let ko = channel_projection_lines(&channel, i18n::Lang::Ko.l()).join("\n");
        for original in [
            "WORKER CONTENT KEEP",
            "/tmp/KEEP --model MODEL-KEEP",
            "USER QUESTION KEEP",
            "USER ANSWER KEEP",
        ] {
            assert!(en.contains(original), "{en}");
            assert!(ko.contains(original), "{ko}");
        }
        assert!(en.contains("tool started: /tmp/KEEP --model MODEL-KEEP"));
        assert!(en.contains("question: USER QUESTION KEEP"));
        assert!(en.contains("user: USER ANSWER KEEP"));
        assert!(en.contains("task completed: done"));
        assert!(ko.contains("도구 시작: /tmp/KEEP --model MODEL-KEEP"));
        assert!(ko.contains("질문: USER QUESTION KEEP"));
        assert!(ko.contains("사용자: USER ANSWER KEEP"));
        assert!(ko.contains("태스크 완료: 완료"));
        for leak in [
            "tool started:",
            "question:",
            "user:",
            "task completed:",
            "done",
        ] {
            assert!(!ko.contains(leak), "Korean projection leaked {leak}: {ko}");
        }
    }

    #[test]
    fn report_current_label_follows_selected_language() {
        let ws = workspace_with_user_config("report-label-language");
        let mut app = App::new(ws.clone());
        app.lang = i18n::Lang::Ko;
        open_reports(&mut app);
        assert!(matches!(
            app.reports.first(),
            Some(ReportEntry::Current { label }) if label.starts_with("현재 ")
        ));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn home_hold_action_maps_defer_and_revive_keys() {
        use HomeHoldAction::*;
        assert_eq!(
            home_hold_action(Some(TaskState::Queued), false, false),
            Defer
        );
        assert_eq!(
            home_hold_action(Some(TaskState::Partial), false, false),
            Defer
        );
        assert_eq!(
            home_hold_action(Some(TaskState::Deferred), false, true),
            Revive
        );
        assert_eq!(
            home_hold_action(Some(TaskState::Deferred), false, false),
            Defer
        );
        assert_eq!(home_hold_action(Some(TaskState::Done), false, false), Noop);
        assert_eq!(
            home_hold_action(Some(TaskState::Running), false, false),
            Noop
        );
        assert_eq!(home_hold_action(Some(TaskState::Queued), true, false), Busy);
        assert_eq!(home_hold_action(None, false, false), Noop);
    }

    #[test]
    fn home_approve_key_action_prefers_selected_approval_over_busy_pause() {
        use HomeApproveKeyAction::*;
        assert_eq!(home_approve_key_action(true, true), Approve);
        assert_eq!(home_approve_key_action(true, false), Approve);
        assert_eq!(home_approve_key_action(false, false), Approve);
        assert_eq!(home_approve_key_action(false, true), Pause);
    }

    #[test]
    fn busy_home_p_grants_selected_approval_without_replacing_running_job() {
        let ws = workspace_with_user_config("busy-approval");
        let mut task: crate::schemas::Task =
            crate::yaml::from_str("id: APV\ntitle: approve me\napproval:\n  required: true\n")
                .unwrap();
        task.state = TaskState::Queued;
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.tasks = vec![task];
        ws.save_queue(&queue).unwrap();

        let mut app = App::new(ws.clone());
        let (_tx, rx) = mpsc::channel();
        app.job = Job::Running {
            label: "auto".to_string(),
            started: Instant::now(),
            rx,
        };

        assert!(!crate::approvals::is_granted(&ws, "APV"));
        assert!(!handle_home_key(&mut app, KeyCode::Char('p')));

        assert!(crate::approvals::is_granted(&ws, "APV"));
        assert!(matches!(&app.job, Job::Running { label, .. } if label == "auto"));
    }

    #[test]
    fn corrupt_state_blocks_tui_startup_recovery_and_approval_side_effects() {
        let ws = crate::snapshot::corrupt_activated_state_fixture("tui-entrypoints");
        // Reproduce the dangerous startup path: without a preflight gate this
        // newer, unconsumed result archives and replaces the live intent/queue.
        std::thread::sleep(Duration::from_millis(10));
        let plan_run = ws.runs_dir().join("plan-20990714-000000");
        std::fs::create_dir_all(&plan_run).unwrap();
        std::fs::write(
            plan_run.join("plan-meta.yaml"),
            "mode: new\nrequest: replacement plan\n",
        )
        .unwrap();
        std::fs::write(
            plan_run.join("planning-result.json"),
            r#"{"summary":"replacement","tasks":[{"id":"YARD-999","title":"replace live state"}]}"#,
        )
        .unwrap();
        let intent_before = std::fs::read(ws.intent_path()).unwrap();
        let queue_before = std::fs::read(ws.queue_path()).unwrap();
        let approval_path = ws.agents_dir().join("approvals.yaml");
        let archive_path = ws.agents_dir().join("intents");

        let recovery_error = recover_startup_state(&ws).unwrap_err().to_string();
        assert!(
            recovery_error.contains("unconfirmed_or_inconsistent"),
            "{recovery_error}"
        );
        let approval_error = grant_approval_batch(&ws, &["YARD-001".to_string()])
            .unwrap_err()
            .to_string();
        assert!(
            approval_error.contains("unconfirmed_or_inconsistent"),
            "{approval_error}"
        );

        assert_eq!(std::fs::read(ws.intent_path()).unwrap(), intent_before);
        assert_eq!(std::fs::read(ws.queue_path()).unwrap(), queue_before);
        assert!(!approval_path.exists());
        assert!(!archive_path.exists());
        assert!(!plan_run.join("consumed").exists());
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn selected_task_defer_and_revive_change_queue_state() {
        let ws = workspace_with_user_config("defer-revive");
        let mut task: crate::schemas::Task =
            crate::yaml::from_str("id: HOLD\ntitle: hold me\n").unwrap();
        task.state = TaskState::Queued;
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.tasks = vec![task];
        ws.save_queue(&queue).unwrap();

        let mut app = App::new(ws.clone());
        defer_selected_task(&mut app);
        let queue = ws.load_queue().unwrap();
        assert_eq!(queue.tasks[0].state, TaskState::Deferred);
        assert_eq!(
            ws.latest_transition("HOLD").unwrap().cause,
            crate::schemas::TransitionCause::Defer
        );

        revive_selected_task(&mut app);
        let queue = ws.load_queue().unwrap();
        assert_eq!(queue.tasks[0].state, TaskState::Queued);
        assert_eq!(
            ws.latest_transition("HOLD").unwrap().cause,
            crate::schemas::TransitionCause::Revive
        );
    }

    #[test]
    fn selected_approval_target_wins_over_first_global_approval() {
        let approvals = vec!["A".to_string(), "B".to_string()];
        assert_eq!(
            choose_approval_target(Some("B"), &approvals),
            Some("B".to_string())
        );
        assert_eq!(
            choose_approval_target(Some("C"), &approvals),
            Some("A".to_string())
        );
        assert_eq!(choose_approval_target(None, &[]), None);
    }

    #[test]
    fn approval_batch_action_keeps_approval_explicit() {
        use ApprovalBatchAction::*;
        assert_eq!(approval_batch_action(KeyCode::Char('A'), 0, 2), ApproveAll);
        assert_eq!(approval_batch_action(KeyCode::Enter, 1, 2), ApproveSelected);
        assert_eq!(
            approval_batch_action(KeyCode::Char('p'), 1, 2),
            ApproveSelected
        );
        assert_eq!(
            approval_batch_action(KeyCode::Char('d'), 1, 2),
            HoldSelected
        );
        assert_eq!(
            approval_batch_action(KeyCode::Char(' '), 0, 2),
            ToggleSelected
        );
        assert_eq!(approval_batch_action(KeyCode::Enter, 0, 2), Noop);
        assert_eq!(approval_batch_action(KeyCode::Char('A'), 0, 0), Noop);
        assert_eq!(approval_batch_action(KeyCode::Esc, 1, 2), Back);
    }

    #[test]
    fn approval_batch_grants_each_task_once() {
        let ws = workspace_with_user_config("approval-batch-grants");
        let ids = vec!["YARD-A".to_string(), "YARD-B".to_string()];

        grant_approval_batch(&ws, &ids).unwrap();

        assert!(crate::approvals::is_granted(&ws, "YARD-A"));
        assert!(crate::approvals::is_granted(&ws, "YARD-B"));

        crate::approvals::consume(&ws, "YARD-A").unwrap();
        assert!(!crate::approvals::is_granted(&ws, "YARD-A"));
        assert!(
            crate::approvals::is_granted(&ws, "YARD-B"),
            "each approval must be an independent single-use grant"
        );
    }

    #[test]
    fn completion_ready_uses_drained_not_all_done() {
        let mut queue = crate::schemas::WorkQueue::empty();
        assert!(!queue_ready_for_completion(&queue));

        let mut done: crate::schemas::Task =
            crate::yaml::from_str("id: DONE\ntitle: done").unwrap();
        done.state = TaskState::Done;
        let mut deferred: crate::schemas::Task =
            crate::yaml::from_str("id: DEF\ntitle: deferred").unwrap();
        deferred.state = TaskState::Deferred;
        queue.tasks = vec![done.clone(), deferred];
        assert!(queue_ready_for_completion(&queue));

        let mut queued: crate::schemas::Task =
            crate::yaml::from_str("id: TODO\ntitle: todo").unwrap();
        queued.state = TaskState::Queued;
        queue.tasks = vec![done, queued];
        assert!(!queue_ready_for_completion(&queue));
    }

    #[test]
    fn completion_ready_gates_needs_user_independent_of_language() {
        let mut done: crate::schemas::Task =
            crate::yaml::from_str("id: DONE\ntitle: done").unwrap();
        done.state = TaskState::Done;
        let mut needs_user: crate::schemas::Task =
            crate::yaml::from_str("id: ASK\ntitle: ask").unwrap();
        needs_user.state = TaskState::NeedsUser;

        let mut queue = crate::schemas::WorkQueue::empty();
        queue.tasks = vec![done, needs_user];
        assert!(queue.drained());

        for lang in [i18n::Lang::En, i18n::Lang::Ko] {
            let label = match lang {
                i18n::Lang::En => "en",
                i18n::Lang::Ko => "ko",
            };
            assert!(
                !queue_ready_for_completion(&queue),
                "{label}: completion must not auto-open while a NeedsUser question is open"
            );
        }
    }

    #[test]
    fn report_list_enter_action_maps_history_rows() {
        let follow_up = crate::schemas::FollowUpTask {
            title: "Promote me".to_string(),
            reason: "preserved from archive".to_string(),
            ..Default::default()
        };
        let archived = ReportEntry::Archived {
            label: "intent-arch".to_string(),
            dir: std::path::PathBuf::from("/tmp/intent-arch"),
        };
        let current = ReportEntry::Current {
            label: "current".to_string(),
        };
        let follow = ReportEntry::FollowUp {
            label: "follow-up".to_string(),
            intent_id: "intent-arch".to_string(),
            task: Box::new(follow_up),
        };

        assert_eq!(
            reportlist_enter_action(Some(&current)),
            Some(ReportListEnterAction::OpenCurrent)
        );
        assert_eq!(
            reportlist_enter_action(Some(&archived)),
            Some(ReportListEnterAction::OpenArchived)
        );
        let drain = ReportEntry::ArchivedDrain {
            label: "drain".to_string(),
            dir: std::path::PathBuf::from("/tmp/intent-arch/drains/cnf_one"),
        };
        assert_eq!(
            reportlist_enter_action(Some(&drain)),
            Some(ReportListEnterAction::OpenArchived)
        );
        assert_eq!(
            reportlist_enter_action(Some(&follow)),
            Some(ReportListEnterAction::PromoteFollowUp)
        );
        assert_eq!(reportlist_enter_action(None), None);
    }

    #[test]
    fn reports_list_shows_archived_follow_ups_and_promotes_selected_one() {
        let root =
            std::env::temp_dir().join(format!("yard-history-promote-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let archive_dir = ws.agents_dir().join("intents").join("intent-arch");
        std::fs::create_dir_all(&archive_dir).unwrap();
        std::fs::write(
            archive_dir.join("intent-contract.yaml"),
            "schema_version: 1\nid: intent-arch\nsummary: Archived goal\n",
        )
        .unwrap();
        std::fs::write(archive_dir.join("final-report.md"), "# Final report\n").unwrap();
        std::fs::write(
            archive_dir.join("follow-up-tasks.yaml"),
            "\
schema_version: 1
intent_id: intent-arch
tasks:
  - title: Promote me
    reason: preserved from archive
    acceptance:
      - promoted task exists
",
        )
        .unwrap();

        let mut app = App::new(ws);
        open_reports(&mut app);

        assert!(app
            .reports
            .iter()
            .any(|entry| matches!(entry, ReportEntry::Archived { label, .. } if label.contains("Archived goal"))));
        let follow_idx = app
            .reports
            .iter()
            .position(|entry| {
                matches!(
                    entry,
                    ReportEntry::FollowUp { label, .. } if label.contains("Promote me")
                )
            })
            .expect("preserved follow-up row");
        assert_eq!(
            reportlist_enter_action(app.reports.get(follow_idx)),
            Some(ReportListEnterAction::PromoteFollowUp)
        );

        app.report_sel = follow_idx;
        handle_reportlist_key(&mut app, KeyCode::Enter);

        let intent = app.ws.load_intent().unwrap().unwrap();
        assert_eq!(intent.source, "promoted-follow-up");
        assert_eq!(intent.raw_request, "Promote me");
        let queue = app.ws.load_queue().unwrap();
        assert_eq!(queue.tasks.len(), 1);
        assert_eq!(queue.tasks[0].title, "Promote me");
        assert!(matches!(app.screen, Screen::Home));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reports_list_nests_replan_drain_snapshots_and_opens_each_final_report() {
        let root = std::env::temp_dir().join(format!("yard-history-drains-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let archive_dir = ws.agents_dir().join("intents").join("intent-replan");
        std::fs::create_dir_all(&archive_dir).unwrap();
        std::fs::write(
            archive_dir.join("intent-contract.yaml"),
            "schema_version: 1\nid: intent-replan\nsummary: Replanned goal\n",
        )
        .unwrap();
        std::fs::write(archive_dir.join("final-report.md"), "# latest drain\n").unwrap();
        for (cnf, body) in [
            ("cnf_first", "# first drain\n"),
            ("cnf_second", "# latest drain\n"),
        ] {
            let drain_dir = archive_dir.join("drains").join(cnf);
            std::fs::create_dir_all(&drain_dir).unwrap();
            std::fs::write(drain_dir.join("final-report.md"), body).unwrap();
        }

        let mut app = App::new(ws);
        open_reports(&mut app);

        let parent_idx = app
            .reports
            .iter()
            .position(|entry| {
                matches!(entry, ReportEntry::Archived { label, .. } if label.contains("Replanned goal"))
            })
            .expect("archived intent row");
        // Drain snapshots nest directly under their intent's archive row,
        // newest first.
        let drain_labels: Vec<&str> = app.reports[parent_idx + 1..]
            .iter()
            .map_while(|entry| match entry {
                ReportEntry::ArchivedDrain { label, .. } => Some(label.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(drain_labels.len(), 2, "one row per confirmed drain");
        assert!(drain_labels[0].contains("cnf_second"), "{drain_labels:?}");
        assert!(drain_labels[1].contains("cnf_first"), "{drain_labels:?}");

        app.report_sel = parent_idx + 2;
        handle_reportlist_key(&mut app, KeyCode::Enter);
        assert_eq!(app.report_text, "# first drain\n");
        assert!(app.viewing_archived);
        assert!(matches!(app.screen, Screen::Completion));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reports_list_keeps_single_drain_intents_unchanged() {
        let root =
            std::env::temp_dir().join(format!("yard-history-one-drain-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let archive_dir = ws.agents_dir().join("intents").join("intent-single");
        std::fs::create_dir_all(&archive_dir).unwrap();
        std::fs::write(
            archive_dir.join("intent-contract.yaml"),
            "schema_version: 1\nid: intent-single\nsummary: Single drain goal\n",
        )
        .unwrap();
        std::fs::write(archive_dir.join("final-report.md"), "# only drain\n").unwrap();
        let drain_dir = archive_dir.join("drains").join("cnf_only");
        std::fs::create_dir_all(&drain_dir).unwrap();
        std::fs::write(drain_dir.join("final-report.md"), "# only drain\n").unwrap();

        let mut app = App::new(ws);
        open_reports(&mut app);

        assert!(app
            .reports
            .iter()
            .any(|entry| matches!(entry, ReportEntry::Archived { label, .. } if label.contains("Single drain goal"))));
        assert!(
            !app.reports
                .iter()
                .any(|entry| matches!(entry, ReportEntry::ArchivedDrain { .. })),
            "a single-drain intent must list exactly as before"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn ime_poll_never_forces_ascii_over_a_deliberate_toggle() {
        // Screen transition may force ASCII on shortcut screens.
        assert_eq!(ime_sync_action(false, true), ImeSync::ForceAscii);
        // The periodic poll must not wrestle a manual/Karabiner 한/영 toggle.
        assert_eq!(ime_sync_action(false, false), ImeSync::Leave);
        // Text screens always get the saved IME back, poll or transition.
        assert_eq!(ime_sync_action(true, false), ImeSync::RestoreSaved);
        assert_eq!(ime_sync_action(true, true), ImeSync::RestoreSaved);
    }

    #[test]
    fn confirm_success_lands_on_home_and_names_the_drain_actions() {
        let ws = workspace_with_user_config("confirm-next-step");
        let mut app = App::new(ws.clone());
        app.screen = Screen::PlanningReview;
        app.planning_review_editing = true;

        finish_planning_confirm(&mut app, Ok("confirmed: cnf_x".to_string()));

        assert_eq!(
            app.screen,
            Screen::Home,
            "confirm must not dead-end on the review screen"
        );
        assert!(!app.planning_review_editing);
        let (ok, toast) = app.toast.clone().expect("confirm sets a toast");
        assert!(ok);
        assert!(toast.contains("confirmed: cnf_x"), "{toast}");
        assert!(
            toast.contains(app.lang.l().planning_confirmed_next),
            "the toast must name the next step: {toast}"
        );

        // A failed confirm keeps today's behavior: stay on the screen and
        // surface the error.
        app.screen = Screen::PlanningReview;
        finish_planning_confirm(&mut app, Err(anyhow::anyhow!("stale head")));
        assert_eq!(app.screen, Screen::PlanningReview);
        let (ok, toast) = app.toast.clone().expect("error sets a toast");
        assert!(!ok);
        assert!(toast.contains("stale head"), "{toast}");
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn answer_submission_grants_only_task_approval_targets() {
        let approvals = vec!["YARD-003".to_string()];
        assert!(answer_target_will_grant("YARD-003", false, &approvals));
        assert!(answer_target_will_grant("YARD-004", true, &approvals));
        assert!(!answer_target_will_grant(
            INTERVIEW_TARGET,
            true,
            &approvals
        ));
        assert!(!answer_target_will_grant("YARD-005", false, &approvals));
    }

    #[test]
    fn answer_context_uses_full_current_intent_output_and_scoped_conversation() {
        let ws = workspace_with_user_config("answer-current-intent");
        let mut task: crate::schemas::Task =
            crate::yaml::from_str("id: ASK\ntitle: Pick the launch lane\n").unwrap();
        task.state = TaskState::NeedsUser;
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-current".into();
        queue.tasks.push(task);
        ws.save_queue(&queue).unwrap();

        write_answer_run(
            &ws,
            "run-20260711-010000",
            "ASK",
            "intent-current",
            Some(b"{\"type\":\"text\",\"text\":\"CURRENT OUTPUT ONE\"}\n{\"type\":\"text\",\"text\":\"CURRENT OUTPUT TWO\"}\n"),
            "current summary",
        );
        // Newer by directory name, but from a past intent with the same task id.
        write_answer_run(
            &ws,
            "run-20260711-020000",
            "ASK",
            "intent-old",
            Some(b"STALE OUTPUT\n"),
            "stale summary",
        );
        state::append_conversation_turn(
            &ws,
            "intent-old",
            "ASK",
            crate::schemas::ConversationTurn {
                role: crate::schemas::TurnRole::Worker,
                text: "stale question".into(),
                run_id: "run-20260711-020000".into(),
                ts: String::new(),
            },
        )
        .unwrap();
        state::append_conversation_turn(
            &ws,
            "intent-old",
            "ASK",
            crate::schemas::ConversationTurn {
                role: crate::schemas::TurnRole::User,
                text: "stale answer".into(),
                run_id: String::new(),
                ts: String::new(),
            },
        )
        .unwrap();
        state::append_conversation_turn(
            &ws,
            "intent-current",
            "ASK",
            crate::schemas::ConversationTurn {
                role: crate::schemas::TurnRole::Worker,
                text: "current question".into(),
                run_id: "run-20260711-010000".into(),
                ts: String::new(),
            },
        )
        .unwrap();
        state::append_conversation_turn(
            &ws,
            "intent-current",
            "ASK",
            crate::schemas::ConversationTurn {
                role: crate::schemas::TurnRole::User,
                text: "current answer".into(),
                run_id: String::new(),
                ts: String::new(),
            },
        )
        .unwrap();

        let app = App::new(ws.clone());
        let context = build_answer_context(&app, "ASK", "current question");
        assert!(context.contains("Pick the launch lane"));
        assert!(context.contains("CURRENT OUTPUT ONE"));
        assert!(context.contains("CURRENT OUTPUT TWO"));
        assert!(context.contains("current question"));
        assert!(context.contains("current answer"));
        assert!(!context.contains("STALE OUTPUT"));
        assert!(!context.contains("stale question"));
        assert!(!context.contains("stale answer"));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn answer_context_falls_back_from_corrupt_log_to_summary_then_question() {
        let ws = workspace_with_user_config("answer-fallback");
        let mut task: crate::schemas::Task =
            crate::yaml::from_str("id: ASK\ntitle: 결정 필요\n").unwrap();
        task.state = TaskState::NeedsUser;
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-current".into();
        queue.tasks.push(task);
        ws.save_queue(&queue).unwrap();
        write_answer_run(
            &ws,
            "run-20260711-030000",
            "ASK",
            "intent-current",
            Some(&[0xff, 0xfe, 0xfd]),
            "안전한 요약",
        );

        let mut app = App::new(ws.clone());
        app.lang = i18n::Lang::Ko;
        let summary_context = build_answer_context(&app, "ASK", "어느 안으로 진행할까요?");
        assert!(summary_context.contains("안전한 요약"));
        assert!(summary_context.contains("[응답대기]"));
        for leaked in [
            "NeedsUser",
            "running",
            "done",
            "failed",
            "blocked",
            "needs-you",
            "partial",
            "deferred",
            "queued",
        ] {
            assert!(!summary_context.contains(leaked), "leaked {leaked}");
        }

        std::fs::remove_file(
            ws.runs_dir()
                .join("run-20260711-030000")
                .join("result.json"),
        )
        .unwrap();
        let question_context = build_answer_context(&app, "ASK", "어느 안으로 진행할까요?");
        assert!(question_context.contains("어느 안으로 진행할까요?"));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn answer_page_keys_scroll_only_the_read_only_context() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-answer-scroll-test"));
        let mut app = App::new(ws);
        app.screen = Screen::Answer;
        app.answer_context = (0..30)
            .map(|index| format!("context line {index}"))
            .collect::<Vec<_>>()
            .join("\n");
        app.scroll_viewport = Some(ScrollViewport {
            width: 40,
            height: 5,
        });
        app.input = "draft answer".into();
        app.input_caret = app.input.chars().count();

        handle_answer_key(&mut app, KeyCode::PageDown, KeyModifiers::NONE);
        assert_eq!(app.scroll, 10);
        assert_eq!(app.input, "draft answer");
        handle_answer_key(&mut app, KeyCode::PageUp, KeyModifiers::NONE);
        assert_eq!(app.scroll, 0);
        assert_eq!(app.input, "draft answer");
    }

    #[test]
    fn answer_enter_is_newline_and_control_s_does_not_insert_text() {
        // Answer input shares the planner/plan-revision multi-line submit branch:
        // default Enter is a newline, Ctrl+S submits, and (with enhancement)
        // Ctrl+Enter submits. Ctrl+S must never leak a literal 's'.
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-answer-key-test"));
        let mut app = App::new(ws);
        app.screen = Screen::Answer;

        handle_answer_key(&mut app, KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(app.input, "\n", "default Enter inserts a newline");
        assert_eq!(app.screen, Screen::Answer);

        app.input_clear();
        handle_answer_key(&mut app, KeyCode::Char('s'), KeyModifiers::CONTROL);
        assert!(app.input.is_empty(), "Ctrl+S must never insert a literal s");
        assert_eq!(
            app.screen,
            Screen::Answer,
            "empty Ctrl+S submit is rejected"
        );
        assert!(matches!(app.job, Job::Idle));

        handle_answer_key(&mut app, KeyCode::Enter, KeyModifiers::CONTROL);
        assert_eq!(
            app.input, "\n",
            "without enhancement, modified Enter stays a newline"
        );
        app.input_clear();
        app.keyboard_enhancement = true;
        handle_answer_key(&mut app, KeyCode::Enter, KeyModifiers::CONTROL);
        assert!(
            app.input.is_empty(),
            "enhanced Ctrl+Enter reaches empty-submit rejection, not a newline"
        );
        assert_eq!(app.screen, Screen::Answer);
        assert!(matches!(app.job, Job::Idle));
    }

    #[test]
    fn answer_escape_cancels_target_and_discards_the_draft() {
        // Esc must leave no lingering answer state: the draft, the answer target,
        // and the approval-grant flag all reset before returning Home.
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-answer-cancel-test"));
        let mut app = App::new(ws);
        app.screen = Screen::Answer;
        app.answer_target = Some(("YARD-003".to_string(), "질문?".to_string()));
        app.answer_grants_approval = true;
        app.input_insert("취소할\n초안");

        handle_answer_key(&mut app, KeyCode::Esc, KeyModifiers::NONE);

        assert_eq!(app.screen, Screen::Home);
        assert!(app.input.is_empty());
        assert_eq!(app.input_caret, 0);
        assert!(app.answer_target.is_none());
        assert!(!app.answer_grants_approval);
    }

    #[test]
    fn jamo_maps_to_qwerty_shortcuts() {
        // 한글 IME on: pressing m arrives as ㅡ, h as ㅗ, q as ㅂ.
        assert_eq!(dekorean(KeyCode::Char('ㅡ'), false), KeyCode::Char('m'));
        assert_eq!(dekorean(KeyCode::Char('ㅗ'), false), KeyCode::Char('h'));
        assert_eq!(dekorean(KeyCode::Char('ㅂ'), false), KeyCode::Char('q'));
        // Shift chords: Shift+ㅁ → A (auto-drain), double jamo imply shift.
        assert_eq!(dekorean(KeyCode::Char('ㅁ'), true), KeyCode::Char('A'));
        assert_eq!(dekorean(KeyCode::Char('ㄲ'), false), KeyCode::Char('R'));
        // Non-jamo input passes through untouched.
        assert_eq!(dekorean(KeyCode::Char('m'), false), KeyCode::Char('m'));
        assert_eq!(dekorean(KeyCode::Enter, false), KeyCode::Enter);
    }

    #[test]
    fn dispatch_code_dekoreans_review_shortcuts_but_keeps_edit_buffer_raw() {
        // Review (non-editing) is a shortcut screen: with the Korean IME active
        // and auto_ime=false (the OS input source was never switched to ASCII),
        // 'a' arrives as 'ㅁ', 'r' as 'ㄱ', 'c' as 'ㅊ', 'e' as 'ㄷ', 'g' as
        // 'ㅎ', 'q' as 'ㅂ'. All six must fall back to their QWERTY keys.
        for (jamo, qwerty) in [
            ('ㅁ', 'a'),
            ('ㄱ', 'r'),
            ('ㅊ', 'c'),
            ('ㄷ', 'e'),
            ('ㅎ', 'g'),
            ('ㅂ', 'q'),
        ] {
            assert_eq!(
                dispatch_code(Screen::PlanningReview, false, KeyCode::Char(jamo), false),
                KeyCode::Char(qwerty),
            );
        }
        // The edit buffer keeps the raw jamo so multi-line Korean input survives.
        assert_eq!(
            dispatch_code(Screen::PlanningReview, true, KeyCode::Char('ㅁ'), false),
            KeyCode::Char('ㅁ'),
        );
        // Text-input screens always keep the raw character.
        assert_eq!(
            dispatch_code(Screen::NewWork, false, KeyCode::Char('ㅁ'), false),
            KeyCode::Char('ㅁ'),
        );
        assert_eq!(
            dispatch_code(Screen::Answer, false, KeyCode::Char('ㅁ'), false),
            KeyCode::Char('ㅁ'),
        );
        // Other shortcut screens (e.g. Home) get the fallback too.
        assert_eq!(
            dispatch_code(Screen::Home, false, KeyCode::Char('ㅂ'), false),
            KeyCode::Char('q'),
        );
    }

    #[test]
    fn planning_review_nonediting_hangul_shortcut_reaches_qwerty_action() {
        use planning_review::{action_for_key_with_enhancement, ReviewAction, ReviewGate};
        let gate = ReviewGate {
            busy: false,
            editing: false,
            has_pending_proposal: true,
            has_visible_head: false,
            confirmed: false,
            pending_count: 1,
        };
        // Raw jamo miss the a/r shortcuts — this is the bug the fallback fixes.
        assert_eq!(
            action_for_key_with_enhancement(KeyCode::Char('ㅁ'), KeyModifiers::NONE, false, gate),
            ReviewAction::Noop,
        );
        // Routed through the screen dispatch, 'ㅁ'/'ㄱ' fall back to a/r →
        // Accept/Reject; 'ㄷ' → e (BeginEdit), 'ㅎ' → g (Refresh), 'ㅂ' → q (Back).
        let accept = dispatch_code(Screen::PlanningReview, false, KeyCode::Char('ㅁ'), false);
        assert_eq!(
            action_for_key_with_enhancement(accept, KeyModifiers::NONE, false, gate),
            ReviewAction::Accept,
        );
        let reject = dispatch_code(Screen::PlanningReview, false, KeyCode::Char('ㄱ'), false);
        assert_eq!(
            action_for_key_with_enhancement(reject, KeyModifiers::NONE, false, gate),
            ReviewAction::Reject,
        );
        let edit = dispatch_code(Screen::PlanningReview, false, KeyCode::Char('ㄷ'), false);
        assert_eq!(
            action_for_key_with_enhancement(edit, KeyModifiers::NONE, false, gate),
            ReviewAction::BeginEdit,
        );
        let refresh = dispatch_code(Screen::PlanningReview, false, KeyCode::Char('ㅎ'), false);
        assert_eq!(
            action_for_key_with_enhancement(refresh, KeyModifiers::NONE, false, gate),
            ReviewAction::Refresh,
        );
        let back = dispatch_code(Screen::PlanningReview, false, KeyCode::Char('ㅂ'), false);
        assert_eq!(
            action_for_key_with_enhancement(back, KeyModifiers::NONE, false, gate),
            ReviewAction::Back,
        );
        // Confirm (c) is available once the pending proposal is resolved.
        let confirmed_gate = ReviewGate {
            has_pending_proposal: false,
            has_visible_head: true,
            ..gate
        };
        let confirm = dispatch_code(Screen::PlanningReview, false, KeyCode::Char('ㅊ'), false);
        assert_eq!(
            action_for_key_with_enhancement(confirm, KeyModifiers::NONE, false, confirmed_gate),
            ReviewAction::Confirm,
        );
    }

    #[test]
    fn planning_review_editing_keeps_raw_hangul_insert() {
        use planning_review::{action_for_key_with_enhancement, ReviewAction, ReviewGate};
        let editing = ReviewGate {
            busy: false,
            editing: true,
            has_pending_proposal: false,
            has_visible_head: true,
            confirmed: false,
            pending_count: 0,
        };
        // In the edit buffer a jamo is NOT de-koreaned: it is inserted as the raw
        // character so multi-line Korean input is preserved verbatim.
        let raw = dispatch_code(Screen::PlanningReview, true, KeyCode::Char('ㅁ'), false);
        assert_eq!(
            action_for_key_with_enhancement(raw, KeyModifiers::NONE, false, editing),
            ReviewAction::Insert('ㅁ'),
        );
        let syllable = dispatch_code(Screen::PlanningReview, true, KeyCode::Char('한'), false);
        assert_eq!(
            action_for_key_with_enhancement(syllable, KeyModifiers::NONE, false, editing),
            ReviewAction::Insert('한'),
        );
        // Enter still inserts a newline for multi-line input in the edit buffer.
        let newline = dispatch_code(Screen::PlanningReview, true, KeyCode::Enter, false);
        assert_eq!(
            action_for_key_with_enhancement(newline, KeyModifiers::NONE, false, editing),
            ReviewAction::InsertNewline,
        );
    }

    /// Issue #54: the operator asked to scroll back through a worker's output
    /// the way a normal streaming session lets them.
    #[test]
    fn monitor_scroll_freezes_on_the_way_up_and_resumes_following_at_the_bottom() {
        // 100 lines, 10 visible: the newest screen starts at line 90.
        let (max_top, visible) = (90_usize, 10_usize);

        // Up from the bottom freezes: following stops the moment they move.
        assert_eq!(
            monitor_scroll_to(KeyCode::Up, max_top, max_top, visible),
            (89, false)
        );
        assert_eq!(
            monitor_scroll_to(KeyCode::PageUp, max_top, max_top, visible),
            (80, false)
        );
        // Home reaches the oldest line that was read.
        assert_eq!(
            monitor_scroll_to(KeyCode::Home, 42, max_top, visible),
            (0, false)
        );

        // Coming back down resumes following, so a view that looks live IS live.
        assert_eq!(
            monitor_scroll_to(KeyCode::End, 0, max_top, visible),
            (max_top, true)
        );
        assert_eq!(
            monitor_scroll_to(KeyCode::Down, 89, max_top, visible),
            (max_top, true)
        );
        assert_eq!(
            monitor_scroll_to(KeyCode::PageDown, 85, max_top, visible),
            (max_top, true)
        );

        // Neither end runs off: up from the top and down from the bottom stay.
        assert_eq!(
            monitor_scroll_to(KeyCode::Up, 0, max_top, visible),
            (0, false)
        );
        assert_eq!(
            monitor_scroll_to(KeyCode::PageUp, 3, max_top, visible),
            (0, false)
        );
        assert_eq!(
            monitor_scroll_to(KeyCode::Down, max_top, max_top, visible),
            (max_top, true)
        );

        // A log shorter than the viewport has nothing to freeze: every key
        // leaves it following.
        for code in [KeyCode::Up, KeyCode::PageUp, KeyCode::Home] {
            assert_eq!(monitor_scroll_to(code, 0, 0, visible), (0, true));
        }
    }

    /// The live Monitor's `x`/`p` still stop the worker and pause the drain; the
    /// diagnostic Monitor (a read-only postmortem opened on a Failed/Partial
    /// attempt) has no live worker, so both keys are inert there.
    #[test]
    fn monitor_control_gates_stop_and_pause_off_in_the_diagnostic_view() {
        // Live Monitor, worker running: x stops, p pauses.
        assert_eq!(
            monitor_control_action(KeyCode::Char('x'), false, true),
            MonitorControl::Stop,
        );
        assert_eq!(
            monitor_control_action(KeyCode::Char('p'), false, true),
            MonitorControl::Pause,
        );
        // Live Monitor, nothing running: x is a no-op (mirrors the live guard),
        // but p still fires (request_pause reports "nothing to pause" itself).
        assert_eq!(
            monitor_control_action(KeyCode::Char('x'), false, false),
            MonitorControl::Ignore,
        );
        assert_eq!(
            monitor_control_action(KeyCode::Char('p'), false, false),
            MonitorControl::Pause,
        );

        // Diagnostic Monitor: both keys are inert regardless of `can_stop`.
        for can_stop in [true, false] {
            assert_eq!(
                monitor_control_action(KeyCode::Char('x'), true, can_stop),
                MonitorControl::Ignore,
                "diagnostic x must be a no-op (can_stop={can_stop})",
            );
            assert_eq!(
                monitor_control_action(KeyCode::Char('p'), true, can_stop),
                MonitorControl::Ignore,
                "diagnostic p must be a no-op (can_stop={can_stop})",
            );
        }
    }

    #[test]
    fn home_monitor_uses_selected_failed_task_latest_failure_in_current_intent() {
        let ws = workspace_with_user_config("selected-failed-monitor");
        let mut task: crate::schemas::Task =
            crate::yaml::from_str("id: TARGET\ntitle: selected failure\nstate: failed\n").unwrap();
        task.state = TaskState::Failed;
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-current".into();
        queue.tasks.push(task);
        ws.save_queue(&queue).unwrap();

        let current_old = ws.runs_dir().join("run-current-old");
        let current_new = ws.runs_dir().join("run-current-new");
        let wrong_newest = ws.runs_dir().join("run-wrong-newest");
        for dir in [&current_old, &current_new, &wrong_newest] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let old_stdout = current_old.join("attempts/att-current-old/stdout.log");
        let old_stderr = current_old.join("attempts/att-current-old/stderr.log");
        std::fs::create_dir_all(old_stdout.parent().unwrap()).unwrap();
        std::fs::write(&old_stdout, "current old stdout\n").unwrap();
        std::fs::write(&old_stderr, "current old stderr\n").unwrap();
        record_monitor_attempt(
            &ws,
            "intent-current",
            "att-current-old",
            &old_stdout,
            &old_stderr,
            "failed",
            (Some(12), None),
        );

        let current_stdout = current_new.join("attempts/att-current-new/stdout.log");
        let current_stderr = current_new.join("attempts/att-current-new/stderr.log");
        std::fs::create_dir_all(current_stdout.parent().unwrap()).unwrap();
        std::fs::write(&current_stdout, "current newest stdout\n").unwrap();
        std::fs::write(&current_stderr, "current newest stderr\n").unwrap();
        record_monitor_attempt(
            &ws,
            "intent-current",
            "att-current-new",
            &current_stdout,
            &current_stderr,
            "failed",
            (None, Some(15)),
        );

        let wrong_stdout = wrong_newest.join("attempts/att-wrong/stdout.log");
        let wrong_stderr = wrong_newest.join("attempts/att-wrong/stderr.log");
        std::fs::create_dir_all(wrong_stdout.parent().unwrap()).unwrap();
        std::fs::write(&wrong_stdout, "wrong intent stdout\n").unwrap();
        std::fs::write(&wrong_stderr, "wrong intent stderr\n").unwrap();
        std::fs::write(wrong_newest.join("worker-output.log"), "wrong newest run\n").unwrap();
        record_monitor_attempt(
            &ws,
            "intent-old",
            "att-wrong",
            &wrong_stdout,
            &wrong_stderr,
            "failed",
            (Some(99), None),
        );

        let mut app = App::new(ws.clone());
        app.snapshot = Some(cached_snapshot(&ws));
        app.selected = 0;
        app.lang = i18n::Lang::Ko;
        assert!(!handle_home_key(&mut app, KeyCode::Char('m')));
        assert_eq!(app.screen, Screen::Monitor);
        assert!(
            matches!(app.job, Job::Idle),
            "Monitor must not rerun the task"
        );
        app.refresh_monitor_log();
        let diagnostic = app.monitor.log_lines.join("\n");
        assert!(diagnostic.contains("att-current-new"), "{diagnostic}");
        assert!(diagnostic.contains("current newest stdout"), "{diagnostic}");
        assert!(diagnostic.contains("current newest stderr"), "{diagnostic}");
        assert!(diagnostic.contains("signal=15"), "{diagnostic}");
        assert!(diagnostic.contains("result=실패"), "{diagnostic}");
        assert!(!diagnostic.contains("result=failed"), "{diagnostic}");
        assert!(!diagnostic.contains("current old stdout"), "{diagnostic}");
        assert!(!diagnostic.contains("wrong intent stdout"), "{diagnostic}");
        assert!(!diagnostic.contains("wrong newest run"), "{diagnostic}");

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn failed_attempt_monitor_shows_empty_stream_and_exact_read_error_path() {
        let ws = workspace_with_user_config("failed-monitor-stream-errors");
        let task: crate::schemas::Task =
            crate::yaml::from_str("id: TARGET\ntitle: partial task\nstate: partial\n").unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-current".into();
        queue.tasks.push(task);
        ws.save_queue(&queue).unwrap();

        let run_dir = ws.runs_dir().join("run-partial");
        let stdout_ref = run_dir.join("attempts/att-partial/stdout.log");
        let stderr_ref = run_dir.join("attempts/att-partial/stderr.log");
        std::fs::create_dir_all(stdout_ref.parent().unwrap()).unwrap();
        std::fs::write(&stdout_ref, []).unwrap();
        record_monitor_attempt(
            &ws,
            "intent-current",
            "att-partial",
            &stdout_ref,
            &stderr_ref,
            "failed",
            (Some(7), None),
        );

        let mut app = App::new(ws.clone());
        app.snapshot = Some(cached_snapshot(&ws));
        assert!(!handle_home_key(&mut app, KeyCode::Char('m')));
        app.refresh_monitor_log();
        let diagnostic = app.monitor.log_lines.join("\n");
        assert!(
            diagnostic.contains(&stdout_ref.display().to_string()),
            "{diagnostic}"
        );
        assert!(diagnostic.contains("(empty stream)"), "{diagnostic}");
        assert!(
            diagnostic.contains(&stderr_ref.display().to_string()),
            "{diagnostic}"
        );
        assert!(diagnostic.contains("read failed"), "{diagnostic}");

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn scroll_down_and_page_down_stop_at_rendered_content_end() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-scroll-clamp-test"));
        let mut app = App::new(ws);
        app.screen = Screen::Handoff;
        app.handoff_text = "hello world\nlast".to_string();
        app.scroll_viewport = Some(ScrollViewport {
            width: 5,
            height: 3,
        });

        apply_scroll(&mut app, KeyCode::Down);
        assert_eq!(app.scroll, 1);
        apply_scroll(&mut app, KeyCode::Down);
        assert_eq!(app.scroll, 1);
        apply_scroll(&mut app, KeyCode::PageDown);
        assert_eq!(app.scroll, 1);
    }

    #[test]
    fn scroll_stays_zero_when_content_is_shorter_than_viewport() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-scroll-short-test"));
        let mut app = App::new(ws);
        app.screen = Screen::Completion;
        app.report_text = "one\ntwo".to_string();
        app.scroll_viewport = Some(ScrollViewport {
            width: 20,
            height: 5,
        });

        apply_scroll(&mut app, KeyCode::PageDown);
        assert_eq!(app.scroll, 0);
        apply_scroll(&mut app, KeyCode::Down);
        assert_eq!(app.scroll, 0);
    }

    #[test]
    fn scroll_up_and_page_up_keep_existing_saturating_behavior() {
        let ws = Workspace::at(std::path::Path::new("/tmp/yard-scroll-up-test"));
        let mut app = App::new(ws);
        app.screen = Screen::Intent;
        app.intent_text = "hello world\nlast".to_string();
        app.scroll_viewport = Some(ScrollViewport {
            width: 5,
            height: 3,
        });
        app.scroll = 1;

        apply_scroll(&mut app, KeyCode::Up);
        assert_eq!(app.scroll, 0);
        apply_scroll(&mut app, KeyCode::PageUp);
        assert_eq!(app.scroll, 0);
    }

    #[test]
    fn tail_read_starts_at_a_line_boundary() {
        let p = std::env::temp_dir().join(format!("yard-tail-{}", std::process::id()));
        let body = "first line\nsecond line\nthird line\n";
        std::fs::write(&p, body).unwrap();
        // Big enough cap: whole file comes back.
        assert_eq!(read_tail(&p, 1024), body);
        // Small cap: partial first line is dropped, rest intact.
        let tail = read_tail(&p, 15);
        assert_eq!(tail, "third line\n");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn settings_save_noop_keeps_config_and_workers_bytes() {
        let ws = workspace_with_user_config("settings-noop");
        let mut app = App::new(ws.clone());
        open_settings(&mut app);
        let before_config = std::fs::read(ws.config_path()).unwrap();
        let before_workers = std::fs::read(ws.workers_path()).unwrap();

        save_settings(&mut app);

        assert_eq!(std::fs::read(ws.config_path()).unwrap(), before_config);
        assert_eq!(std::fs::read(ws.workers_path()).unwrap(), before_workers);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn settings_save_changes_only_target_config_and_worker_keys() {
        let ws = workspace_with_user_config("settings-edit");
        let mut app = App::new(ws.clone());
        open_settings(&mut app);
        let draft = app.settings.as_mut().unwrap();
        for field in &mut draft.fields {
            match field.key.as_str() {
                "access" => field.value = "full".to_string(),
                "parallel" => field.value = "3".to_string(),
                "ime" => field.value = "off".to_string(),
                "language" => field.value = "ko".to_string(),
                "model:codex" => field.value = "gpt-5".to_string(),
                "effort:codex" => field.value = "high".to_string(),
                _ => {}
            }
        }

        save_settings(&mut app);

        let config = std::fs::read_to_string(ws.config_path()).unwrap();
        assert!(config.contains("# keep language comment"));
        assert!(config.contains("language: ko"));
        assert!(config.contains("default_access: full # keep access comment"));
        assert!(config.contains("max_parallel: 3"));
        assert!(config.contains("auto_ime: false"));
        assert!(config.contains("auto_commit: false"));

        let workers = std::fs::read_to_string(ws.workers_path()).unwrap();
        assert!(workers.contains("# keep codex comment"));
        assert!(workers.contains("model: \"gpt-5\" # keep model comment"));
        assert!(workers.contains("effort: \"high\""));
        assert!(workers.contains("# keep claude comment"));
        assert!(workers.contains("model: sonnet"));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn access_language_and_worker_toggles_preserve_comments() {
        let ws = workspace_with_user_config("toggles");
        let mut app = App::new(ws.clone());

        toggle_access(&mut app);
        toggle_language(&mut app);
        toggle_worker(&mut app, 0);

        let config = std::fs::read_to_string(ws.config_path()).unwrap();
        assert!(config.contains("# keep language comment"));
        assert!(config.contains("language: ko"));
        assert!(config.contains("default_access: full # keep access comment"));

        let workers = std::fs::read_to_string(ws.workers_path()).unwrap();
        assert!(workers.contains("# keep codex comment"));
        assert!(workers.contains("enabled: false # keep enabled comment"));
        assert!(workers.contains("model: \"\" # keep model comment"));
        assert!(workers.contains("# keep claude comment"));
        let _ = std::fs::remove_dir_all(ws.root);
    }
}
