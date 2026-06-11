//! Terminal UI (Ratatui).
//!
//! The TUI is the normal interface, but it is never the canonical state store:
//! it reads and writes through Yard's state layer. Long worker runs happen on a
//! background thread so the UI stays responsive; the event loop polls a channel
//! for completion and animates a spinner meanwhile.

mod i18n;
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
    Settings,
    Monitor,
    Completion,
    ReportList,
}

/// One editable settings row. `key` routes the value back to the right file:
/// "access"/"language" -> yard.yaml; "model:<id>"/"effort:<id>" -> workers.yaml.
pub struct Field {
    pub label: String,
    pub key: String,
    pub value: String,
}

pub struct SettingsDraft {
    pub fields: Vec<Field>,
    pub sel: usize,
}

/// Known cycle options for a field key (empty = free text, e.g. a model name).
pub fn field_options(key: &str) -> &'static [&'static str] {
    if key == "access" {
        &["sandboxed", "full"]
    } else if key == "parallel" {
        &["1", "2", "3", "4"]
    } else if key == "language" {
        &["auto", "ko", "en"]
    } else if key.starts_with("effort:") {
        &["", "low", "medium", "high"]
    } else if key == "model:claude-code" {
        &["", "sonnet", "opus", "haiku"]
    } else {
        &[] // e.g. codex model ids vary — type the exact id
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
    pub job: Job,
    pub toast: Option<(bool, String)>,
    pub progress: Option<String>,
    pub handoff_text: String,
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
            job: Job::Idle,
            toast: None,
            progress: None,
            handoff_text: String::new(),
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
            lang,
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
    result
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

fn main_loop(terminal: &mut ratatui::DefaultTerminal, mut app: App) -> Result<()> {
    // Force a full repaint when the screen changes so leaving a content-heavy
    // screen (e.g. the Monitor's live worker output) doesn't leave artifacts
    // bleeding onto the next one.
    let mut last_screen: Option<Screen> = None;
    let mut tick: u32 = 0;
    loop {
        // Drain background-job messages: progress lines stream in; the final
        // Done message ends the job.
        if let Job::Running { rx, .. } = &app.job {
            let mut latest_progress = None;
            let mut finished = None;
            loop {
                match rx.try_recv() {
                    Ok(JobMsg::Progress(s)) => latest_progress = Some(s),
                    Ok(JobMsg::Done(r)) => finished = Some(r),
                    Err(_) => break,
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
            last_screen = Some(app.screen);
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
                app.input.push_str(text);
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
    Ok(())
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
        KeyCode::Char('n') if !app.is_busy() => {
            app.input.clear();
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
            let has_pending = app
                .snapshot
                .as_ref()
                .map(|s| s.pending.is_some())
                .unwrap_or(false);
            if has_pending {
                app.input.clear();
                app.toast = None;
                app.screen = Screen::Answer;
            } else {
                app.toast = Some((true, app.lang.l().no_pending.into()));
            }
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
        // Esc while a worker runs stops it (kills the worker process).
        KeyCode::Esc if app.is_busy() => stop_running_worker(app),
        // Browse the queue and open a task's handoff (works while busy too).
        KeyCode::Up => app.selected = app.selected.saturating_sub(1),
        KeyCode::Down => {
            let len = app
                .snapshot
                .as_ref()
                .map(|s| s.queue.tasks.len())
                .unwrap_or(0);
            if app.selected + 1 < len {
                app.selected += 1;
            }
        }
        KeyCode::Enter => {
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
            app.input.push('\n')
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
        KeyCode::Backspace => {
            app.input.pop();
        }
        KeyCode::Char(c) => app.input.push(c),
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
            app.input.clear();
            app.toast = None;
            app.amend = false;
            app.screen = Screen::NewWork;
        }
        // Continue: add follow-up tasks to this intent (amend), keep done work.
        KeyCode::Char('c') => {
            app.input.clear();
            app.toast = None;
            app.amend = true;
            app.screen = Screen::NewWork;
        }
        // Redo: requeue every done task so the next drain re-runs them.
        KeyCode::Char('R') => redo_all(app),
        _ => apply_scroll(app, code),
    }
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
    let mut fields = vec![
        Field {
            label: l.access_word.to_string(),
            key: "access".into(),
            value: cfg
                .as_ref()
                .map(|c| c.default_access.clone())
                .unwrap_or_default(),
        },
        Field {
            label: l.parallel_word.to_string(),
            key: "parallel".into(),
            value: cfg
                .as_ref()
                .map(|c| c.max_parallel.to_string())
                .unwrap_or_else(|| "1".to_string()),
        },
        Field {
            label: l.language_word.to_string(),
            key: "language".into(),
            value: cfg.map(|c| c.language).unwrap_or_default(),
        },
    ];
    if let Some(wf) = wf {
        for w in wf.workers {
            fields.push(Field {
                label: format!("{} model", w.id),
                key: format!("model:{}", w.id),
                value: w.model,
            });
            fields.push(Field {
                label: format!("{} effort", w.id),
                key: format!("effort:{}", w.id),
                value: w.effort,
            });
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
            // Cycle through known options for this field, if any.
            let f = &mut d.fields[d.sel];
            let opts = field_options(&f.key);
            if !opts.is_empty() {
                let next = opts
                    .iter()
                    .position(|o| *o == f.value)
                    .map(|i| (i + 1) % opts.len())
                    .unwrap_or(0);
                f.value = opts[next].to_string();
            }
            // No preset options (e.g. codex model): type the value instead.
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

fn stop_running_worker(app: &mut App) {
    let runs = app.ws.runs_dir();
    let latest = std::fs::read_dir(&runs)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .max_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
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
        KeyCode::Esc => app.screen = Screen::Home,
        KeyCode::Enter if mods.intersects(KeyModifiers::SHIFT | KeyModifiers::ALT) => {
            app.input.push('\n')
        }
        KeyCode::Enter => {
            if !app.input.trim().is_empty() {
                start_answer(app);
                app.screen = Screen::Home;
            }
        }
        KeyCode::Backspace => {
            app.input.pop();
        }
        KeyCode::Char(c) => app.input.push(c),
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
    app.input.clear();
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
    app.input.clear();
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
        let res = match run::run_auto(&ws, false, Some(pause), None, |s| {
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

fn start_answer(app: &mut App) {
    let Some((task_id, _)) = app.snapshot.as_ref().and_then(|s| s.pending.clone()) else {
        app.toast = Some((false, app.lang.l().no_answer_target.into()));
        return;
    };
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
    app.input.clear();
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
