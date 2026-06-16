//! Terminal UI (Ratatui).
//!
//! The TUI is the normal interface, but it is never the canonical state store:
//! it reads and writes through Yard's state layer. Long worker runs happen on a
//! background thread so the UI stays responsive; the event loop polls a channel
//! for completion and animates a spinner meanwhile.

mod i18n;
mod ime;
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
use crate::state::Workspace;

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Screen {
    Home,
    NewWork,
    Answer,
    Handoff,
    Intent,
    Settings,
    Monitor,
    Completion,
    ReportList,
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

/// Messages a background job streams to the UI loop.
pub enum JobMsg {
    Progress(String),
    Done(JobResult),
}

pub enum Job {
    Idle,
    Running {
        label: String,
        started: Instant,
        rx: Receiver<JobMsg>,
    },
}

pub struct App {
    pub ws: Workspace,
    pub screen: Screen,
    pub snapshot: Option<Snapshot>,
    pub input: String,
    /// Edit caret as a char index into `input` (text screens). Lets Left/Right/
    /// Home/End move and edit mid-string instead of append-only.
    pub input_caret: usize,
    pub job: Job,
    pub toast: Option<(bool, String)>,
    pub progress: Option<String>,
    pub handoff_text: String,
    pub intent_text: String,
    pub report_text: String,
    /// When true, NewWork input continues (amends) the current intent instead of
    /// starting a fresh one.
    pub amend: bool,
    /// The running auto-drain's pause flag, if any. Set it to stop the drain
    /// gracefully after the current task; cleared when the job ends.
    pub pause: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    /// Vertical scroll offset for the handoff/report screens.
    pub scroll: u16,
    /// Selected row in the Home queue (for per-task handoff view).
    pub selected: usize,
    /// Reports browser: (label, source) — None source = current (live) report,
    /// Some(dir) = an archived intent under .agents/intents/.
    pub reports: Vec<(String, Option<std::path::PathBuf>)>,
    pub report_sel: usize,
    /// True while viewing an archived report (read-only; no new/continue/redo).
    pub viewing_archived: bool,
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

fn lang_of(snapshot: &Option<Snapshot>) -> i18n::Lang {
    snapshot
        .as_ref()
        .map(|s| i18n::detect(&s.config.language, s.intent_summary()))
        .unwrap_or(i18n::Lang::En)
}

impl App {
    fn new(ws: Workspace) -> App {
        let snapshot = Snapshot::load(&ws).ok();
        let lang = lang_of(&snapshot);
        App {
            ws,
            screen: Screen::Home,
            snapshot,
            input: String::new(),
            input_caret: 0,
            job: Job::Idle,
            toast: None,
            progress: None,
            handoff_text: String::new(),
            intent_text: String::new(),
            report_text: String::new(),
            amend: false,
            pause: None,
            scroll: 0,
            selected: 0,
            reports: Vec::new(),
            report_sel: 0,
            viewing_archived: false,
            settings: None,
            last_title: None,
            monitor_sel: 0,
            monitor: MonitorCache::default(),
            update_available: false,
            want_restart: false,
            answer_target: None,
            ime_saved: None,
            ime_checked: Instant::now(),
            lang,
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
        if matches!(self.screen, Screen::NewWork | Screen::Answer) {
            // Text input: give the user their IME back.
            if let Some(id) = self.ime_saved.take() {
                let _ = ime::select_by_id(&id);
            }
        } else if let Some((id, ascii)) = ime::current_id_and_ascii() {
            if !ascii && ime::select_ascii() {
                self.ime_saved = Some(id);
            }
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
        const TAIL: u64 = 128 * 1024;
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
        self.monitor.header = Some(MonitorHeader {
            run_name: dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string(),
            task_id: field("task_id:"),
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
        self.input_caret = 0;
    }
    fn caret_end(&mut self) {
        self.input_caret = self.input_len_chars();
    }
}

pub fn run(ws: &Workspace, just_created: bool) -> Result<()> {
    let mut terminal = ratatui::init();
    let mut app = App::new(ws.clone());
    // On startup, recover any tasks left "running" by an interrupted/quit session
    // (evaluate finished runs, requeue the rest) so a restart isn't left stale.
    // Also consume a planning result the previous session paid for but never read.
    let mut recovered = Vec::new();
    if let Some(m) = crate::planner::recover_unconsumed_plan(ws) {
        recovered.push(m);
    }
    recovered.extend(crate::run::recover_orphans(ws));
    if !recovered.is_empty() {
        app.reload();
        app.toast = Some((true, recovered.join("; ")));
    }
    if just_created {
        app.toast = Some((true, app.lang.l().initialized.to_string()));
    }
    // Enable bracketed paste so pasted text (incl. composed Korean/CJK) arrives
    // as one Event::Paste instead of being dropped.
    let _ = execute!(std::io::stdout(), EnableBracketedPaste);
    // Ask for keyboard disambiguation so Shift/Alt+Enter are reported distinctly
    // (needed for newline-in-input). Only on terminals that support it.
    let enhanced = terminal::supports_keyboard_enhancement().unwrap_or(false);
    if enhanced {
        let _ = execute!(
            std::io::stdout(),
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        );
    }
    let result = main_loop(&mut terminal, app);
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
            Some(p) => format!("Yard \u{00b7} {}", clip(p)),
            None => "Yard \u{00b7} running".to_string(),
        }
    } else {
        match app.snapshot.as_ref().map(|s| s.intent_summary()) {
            Some(intent) if !intent.starts_with('(') => format!("Yard \u{00b7} {}", clip(intent)),
            _ => format!("Yard v{}", env!("CARGO_PKG_VERSION")),
        }
    }
}

/// Modification time of the binary this process was started from.
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
            loop {
                match rx.try_recv() {
                    Ok(JobMsg::Progress(s)) => latest_progress = Some(s),
                    Ok(JobMsg::Done(r)) => finished = Some(r),
                    Err(mpsc::TryRecvError::Empty) => break,
                    // The job thread died without reporting (panic): fail the
                    // job instead of spinning busy forever. Any orphaned
                    // worker is picked up by the idle recovery pass.
                    Err(mpsc::TryRecvError::Disconnected) => {
                        if finished.is_none() {
                            finished = Some(JobResult {
                                ok: false,
                                summary: "background job died unexpectedly; \
                                          state will be recovered"
                                    .to_string(),
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
            if let Some(r) = finished {
                app.toast = Some((r.ok, r.summary));
                app.job = Job::Idle;
                app.progress = None;
                app.pause = None;
            }
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
            if job_done {
                let all_done = app
                    .snapshot
                    .as_ref()
                    .map(|s| {
                        !s.queue.tasks.is_empty()
                            && s.queue.tasks.iter().all(|t| t.state == TaskState::Done)
                    })
                    .unwrap_or(false);
                if all_done {
                    app.report_text =
                        crate::report::build_final_report(&app.ws).unwrap_or_default();
                    app.scroll = 0;
                    app.viewing_archived = false;
                    app.screen = Screen::Completion;
                }
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
            // Catch a manual 한/영 toggle while on a shortcut screen.
            app.sync_ime(false);
        }
        // Keep the Monitor's log cache current (stat per frame; read on growth).
        if app.screen == Screen::Monitor {
            app.refresh_monitor_log();
        }
        terminal.draw(|frame| view::render(frame, &app))?;

        // Reflect Yard's state in the terminal title (OSC sequence), only when
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
            if !app.is_busy() && matches!(app.screen, Screen::NewWork | Screen::Answer) {
                app.input_insert(text);
            }
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
        // keep the raw character.
        let code = match app.screen {
            Screen::NewWork | Screen::Answer | Screen::Settings => key.code,
            _ => dekorean(key.code, key.modifiers.contains(KeyModifiers::SHIFT)),
        };

        match app.screen {
            Screen::Home => {
                if handle_home_key(&mut app, code) {
                    break;
                }
            }
            Screen::NewWork => handle_new_work_key(&mut app, key.code, key.modifiers),
            Screen::Answer => handle_answer_key(&mut app, key.code, key.modifiers),
            Screen::Settings => handle_settings_key(&mut app, key.code),
            Screen::Completion => handle_completion_key(&mut app, code),
            Screen::ReportList => handle_reportlist_key(&mut app, code),
            Screen::Handoff => handle_handoff_key(&mut app, code),
            Screen::Intent => handle_intent_key(&mut app, code),
            Screen::Monitor => match code {
                KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::Home,
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

/// Returns true to quit.
fn handle_home_key(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Char('q') => return true,
        // Restart into the freshly installed binary (notice in the status line).
        KeyCode::Char('u') if app.update_available => {
            app.want_restart = true;
            return true;
        }
        KeyCode::Char('n') if !app.is_busy() => {
            app.input_clear();
            app.toast = None;
            app.amend = false;
            app.screen = Screen::NewWork;
        }
        KeyCode::Char('r') if !app.is_busy() => start_run(app),
        KeyCode::Char('A') if !app.is_busy() => start_auto(app),
        KeyCode::Char('p') if !app.is_busy() => start_approve(app),
        // While an auto-drain runs, p requests a graceful pause (finish current
        // task, then stop). Esc stops immediately; A resumes.
        KeyCode::Char('p') => request_pause(app),
        KeyCode::Char('a') if !app.is_busy() => {
            // Answer a NeedsUser question — or give rerun instructions to a
            // Partial/Blocked task (threaded into its continuation packet).
            match compute_answer_target(app) {
                Some(t) => {
                    app.answer_target = Some(t);
                    app.input_clear();
                    app.toast = None;
                    app.screen = Screen::Answer;
                }
                None => app.toast = Some((true, app.lang.l().no_pending.into())),
            }
        }
        KeyCode::Char('i') => {
            app.intent_text = build_intent_view(app);
            app.scroll = 0;
            app.screen = Screen::Intent;
        }
        KeyCode::Char('h') => {
            app.handoff_text = load_latest_handoff(app);
            app.scroll = 0;
            app.screen = Screen::Handoff;
        }
        // Settings can be opened mid-run; saved changes apply to the next task.
        KeyCode::Char('s') => open_settings(app),
        // Monitor can be opened mid-run to watch the worker's live output.
        KeyCode::Char('m') => app.screen = Screen::Monitor,
        // Refresh is safe mid-run and lets you re-read the live queue/snapshot.
        // Explicit refresh re-probes worker readiness too (the only reload
        // that does — it spawns each worker CLI, so it is on-demand only).
        KeyCode::Char('g') => app.reload_full(),
        KeyCode::Char('l') if !app.is_busy() => toggle_language(app),
        // Access can be toggled even mid-run; it takes effect on the next task.
        KeyCode::Char('f') => toggle_access(app),
        // Esc while a worker runs stops it (kills the worker process). Also
        // covers an adopted worker from a previous session (task Running with
        // no active job): kill it and let the idle recovery pass requeue it.
        KeyCode::Esc if app.is_busy() || has_running_task(app) => stop_running_worker(app),
        // Browse the queue — and past its end, the workers panel (toggle a
        // worker on/off with Enter/Space). Works while busy too.
        KeyCode::Up => app.selected = app.selected.saturating_sub(1),
        KeyCode::Down => {
            let total = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.len() + s.workers.len())
                .unwrap_or(0);
            if app.selected + 1 < total {
                app.selected += 1;
            }
        }
        KeyCode::Enter | KeyCode::Char(' ') => {
            let tasks = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.len())
                .unwrap_or(0);
            if app.selected < tasks {
                if code == KeyCode::Enter {
                    let id = app
                        .snapshot
                        .as_ref()
                        .and_then(|s| s.queue.tasks.get(app.selected))
                        .map(|t| t.id.clone());
                    if let Some(id) = id {
                        app.handoff_text = load_handoff_for_task(app, &id);
                        app.scroll = 0;
                        app.screen = Screen::Handoff;
                    }
                }
            } else {
                toggle_worker(app, app.selected - tasks);
            }
        }
        // Reports/history browser: current final report + past intents.
        KeyCode::Char('R') => open_reports(app),
        _ if app.is_busy() => app.toast = Some((true, app.lang.l().busy.into())),
        _ => {}
    }
    false
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
    let mut list: Vec<(String, Option<std::path::PathBuf>)> = Vec::new();
    let cur = app
        .snapshot
        .as_ref()
        .map(|s| s.intent_summary().to_string())
        .unwrap_or_default();
    list.push((format!("current \u{2014} {}", short(&cur, 50)), None));
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
            list.push((format!("{id} \u{2014} {}", short(&summary, 44)), Some(d)));
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
            let src = app.reports.get(app.report_sel).map(|(_, s)| s.clone());
            if let Some(src) = src {
                let (body, archived) = match src {
                    None => (
                        crate::report::build_final_report(&app.ws).unwrap_or_default(),
                        false,
                    ),
                    Some(d) => (
                        std::fs::read_to_string(d.join("final-report.md"))
                            .unwrap_or_else(|_| "(no report)".into()),
                        true,
                    ),
                };
                app.report_text = body;
                app.viewing_archived = archived;
                app.scroll = 0;
                app.screen = Screen::Completion;
            }
        }
        _ => {}
    }
}

fn handle_new_work_key(app: &mut App, code: KeyCode, mods: KeyModifiers) {
    if app.is_busy() {
        if code == KeyCode::Esc {
            app.screen = Screen::Home;
        }
        return;
    }
    match code {
        KeyCode::Esc => app.screen = Screen::Home,
        // Shift/Alt+Enter inserts a newline (multi-line input); Enter submits.
        KeyCode::Enter if mods.intersects(KeyModifiers::SHIFT | KeyModifiers::ALT) => {
            app.input_insert("\n")
        }
        KeyCode::Enter => {
            if !app.input.trim().is_empty() {
                if app.amend {
                    start_continue(app);
                } else {
                    start_planning(app);
                }
                app.screen = Screen::Home;
            }
        }
        KeyCode::Backspace => app.input_backspace(),
        KeyCode::Delete => app.input_delete(),
        KeyCode::Left => app.caret_left(),
        KeyCode::Right => app.caret_right(),
        KeyCode::Home => app.caret_home(),
        KeyCode::End => app.caret_end(),
        KeyCode::Char(c) => app.input_insert(&c.to_string()),
        _ => {}
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
        // New work: start_planning archives the finished intent before overwriting.
        KeyCode::Char('n') => {
            app.input_clear();
            app.toast = None;
            app.amend = false;
            app.screen = Screen::NewWork;
        }
        // Continue: add follow-up tasks to this intent (amend), keep done work.
        KeyCode::Char('c') => {
            app.input_clear();
            app.toast = None;
            app.amend = true;
            app.screen = Screen::NewWork;
        }
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

/// The full intent contract as scrollable markdown (the header only shows a
/// one-line summary; this is the whole goal, scope, acceptance, and any
/// interview clarifications).
fn build_intent_view(app: &App) -> String {
    let Ok(Some(i)) = app.ws.load_intent() else {
        return "No intent yet — press n to describe new work.".to_string();
    };
    let mut s = String::new();
    s.push_str("# Goal\n\n");
    s.push_str(if i.summary.trim().is_empty() {
        "(none)"
    } else {
        i.summary.trim()
    });
    s.push_str("\n\n");
    if !i.allowed_scope.is_empty() {
        s.push_str("## Allowed scope\n\n");
        for x in &i.allowed_scope {
            s.push_str(&format!("- {x}\n"));
        }
        s.push('\n');
    }
    if !i.out_of_scope.is_empty() {
        s.push_str("## Out of scope\n\n");
        for x in &i.out_of_scope {
            s.push_str(&format!("- {x}\n"));
        }
        s.push('\n');
    }
    if !i.acceptance.is_empty() {
        s.push_str("## Acceptance\n\n");
        for a in &i.acceptance {
            if let Some(t) = a.as_str() {
                s.push_str(&format!("- {t}\n"));
            }
        }
        s.push('\n');
    }
    if !i.clarifications.is_empty() {
        s.push_str("## Interview\n\n");
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

fn apply_scroll(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Up => app.scroll = app.scroll.saturating_sub(1),
        KeyCode::Down => app.scroll = app.scroll.saturating_add(1),
        KeyCode::PageUp => app.scroll = app.scroll.saturating_sub(10),
        KeyCode::PageDown => app.scroll = app.scroll.saturating_add(10),
        _ => {}
    }
}

fn redo_all(app: &mut App) {
    if let Ok(mut q) = app.ws.load_queue() {
        let mut n = 0;
        for t in q.tasks.iter_mut() {
            if t.state == TaskState::Done {
                t.state = TaskState::Queued;
                n += 1;
            }
        }
        let _ = app.ws.save_queue(&q);
        app.toast = Some((true, format!("{}: {n}", app.lang.l().redo_done)));
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
                format!("{} model", w.id),
                format!("model:{}", w.id),
                w.model,
            ));
            fields.push(field(
                format!("{} effort", w.id),
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
        let _ = crate::state::save_yaml(&app.ws.config_path(), &cfg);
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
        let _ = crate::state::save_yaml(&app.ws.workers_path(), &wf);
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
        let _ = crate::state::save_yaml(&app.ws.config_path(), &cfg);
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
        None => app.toast = Some((true, app.lang.l().busy.into())),
    }
}

/// Flip a worker's enabled flag (Home workers panel). Routing and planning
/// skip a disabled worker; the change persists to workers.yaml.
fn toggle_worker(app: &mut App, widx: usize) {
    if let Ok(mut wf) = app.ws.load_workers() {
        if let Some(w) = wf.workers.get_mut(widx) {
            w.enabled = !w.enabled;
            let (id, on) = (w.id.clone(), w.enabled);
            let _ = crate::state::save_yaml(&app.ws.workers_path(), &wf);
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
        if let Ok(pid) = std::fs::read_to_string(dir.join("worker.pid")) {
            let pid = pid.trim();
            if !pid.is_empty() {
                let _ = std::process::Command::new("kill").arg(pid).status();
            }
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
        let _ = crate::state::save_yaml(&app.ws.config_path(), &cfg);
    }
    app.reload();
}

fn handle_answer_key(app: &mut App, code: KeyCode, mods: KeyModifiers) {
    if app.is_busy() {
        if code == KeyCode::Esc {
            app.screen = Screen::Home;
        }
        return;
    }
    match code {
        KeyCode::Esc => {
            app.answer_target = None;
            app.screen = Screen::Home;
        }
        KeyCode::Enter if mods.intersects(KeyModifiers::SHIFT | KeyModifiers::ALT) => {
            app.input_insert("\n")
        }
        KeyCode::Enter => {
            if !app.input.trim().is_empty() {
                start_answer(app);
                app.screen = Screen::Home;
            }
        }
        KeyCode::Backspace => app.input_backspace(),
        KeyCode::Delete => app.input_delete(),
        KeyCode::Left => app.caret_left(),
        KeyCode::Right => app.caret_right(),
        KeyCode::Home => app.caret_home(),
        KeyCode::End => app.caret_end(),
        KeyCode::Char(c) => app.input_insert(&c.to_string()),
        _ => {}
    }
}

fn start_planning(app: &mut App) {
    let ws = app.ws.clone();
    let request = app.input.trim().to_string();
    let planner = app
        .snapshot
        .as_ref()
        .map(|s| s.planner.clone())
        .unwrap_or_else(|| "worker".into());
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
        let _ = tx.send(JobMsg::Done(res));
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
        .unwrap_or_else(|| "worker".into());
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
        let _ = tx.send(JobMsg::Done(res));
    });
    app.job = Job::Running {
        label: format!("{} {planner}", lbl.run_word),
        started: Instant::now(),
        rx,
    };
    app.input_clear();
    app.amend = false;
}

fn start_run(app: &mut App) {
    // A Failed/Blocked task blocks the drain (see run_auto's gate), so `r` retries
    // it first; otherwise it runs the next queued task. NeedsUser is resolved via a.
    let (stuck, has_queued) = app
        .snapshot
        .as_ref()
        .map(|s| {
            let stuck = s
                .queue
                .tasks
                .iter()
                .find(|t| {
                    matches!(
                        t.state,
                        TaskState::Blocked | TaskState::Failed | TaskState::Partial
                    )
                })
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
                let tail = r.lines.last().cloned().unwrap_or_default();
                JobResult {
                    ok: true,
                    summary: format!("{} {via} {}: {}", r.task_id, r.worker_id, tail),
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
    let Some(id) = app
        .snapshot
        .as_ref()
        .and_then(|s| s.approvals_needed.first().cloned())
    else {
        app.toast = Some((true, app.lang.l().no_approval.into()));
        return;
    };
    let _ = crate::approvals::grant(&app.ws, &id);
    let ws = app.ws.clone();
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
                let tail = r.lines.last().cloned().unwrap_or_default();
                JobResult {
                    ok: true,
                    summary: format!("{} {via} {}: {}", r.task_id, r.worker_id, tail),
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
                JobResult {
                    ok: last.starts_with("done"),
                    summary: last,
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
    app.pause = Some(pause_job);
    app.job = Job::Running {
        label: format!("{} (auto)", lbl.run_word),
        started: Instant::now(),
        rx,
    };
}

/// Answer-target sentinel: the reply is an interview answer to the planner,
/// not instructions for a task.
const INTERVIEW_TARGET: &str = "__intent__";

/// Can `a` instruct this task? Anything not currently running and not done:
/// queued (run with instructions), partial/blocked/failed (continue or retry
/// with instructions), needs-user (answer the question).
fn answerable(state: TaskState) -> bool {
    !matches!(state, TaskState::Running | TaskState::Done)
}

/// What `a` would answer right now, in priority order: the pending NeedsUser
/// question; the task selected in the queue list (if answerable); else the
/// first answerable task. The reply rides into the task's next packet.
fn compute_answer_target(app: &App) -> Option<(String, String)> {
    let s = app.snapshot.as_ref()?;
    if let Some(p) = &s.pending {
        return Some(p.clone());
    }
    // The ambiguity gate: a answers the PLANNER (interview turn), not a task.
    if let Some((qs, _)) = &s.gate {
        let mut text = String::new();
        for (i, q) in qs.iter().enumerate() {
            text.push_str(&format!("{}. {}\n", i + 1, q));
        }
        return Some((INTERVIEW_TARGET.to_string(), text.trim().to_string()));
    }
    let t = s
        .queue
        .tasks
        .get(app.selected)
        .filter(|t| answerable(t.state))
        .or_else(|| s.queue.tasks.iter().find(|t| answerable(t.state)))?;
    // Show what the previous run says is missing, so the user can instruct.
    let context = crate::run::latest_run_for(&app.ws, &t.id)
        .and_then(|(_, dir)| std::fs::read_to_string(dir.join("result.json")).ok())
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
    Some((t.id.clone(), context))
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
        let _ = tx.send(JobMsg::Done(res));
    });
    app.job = Job::Running {
        label: planner_label,
        started: Instant::now(),
        rx,
    };
}

fn start_answer(app: &mut App) {
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
    let ws = app.ws.clone();
    let answer = app.input.trim().to_string();
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
                let tail = r.lines.last().cloned().unwrap_or_default();
                JobResult {
                    ok: true,
                    summary: format!("{} {resumed_via} {}: {}", r.task_id, r.worker_id, tail),
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
    format!("No handoff for {task_id} yet — run it first.")
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
            .unwrap_or_else(|_| "Latest run has no handoff yet.".into()),
        None => "No handoff yet. Run a task first.".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
