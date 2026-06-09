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
    self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyEventKind,
    KeyModifiers, KeyboardEnhancementFlags, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
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
    } else if key == "language" {
        &["auto", "ko", "en"]
    } else if key.starts_with("effort:") {
        &["", "low", "medium", "high"]
    } else {
        &[]
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
    pub settings: Option<SettingsDraft>,
    pub last_title: Option<String>,
    pub lang: i18n::Lang,
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
            settings: None,
            last_title: None,
            lang,
        }
    }

    fn reload(&mut self) {
        if let Ok(s) = Snapshot::load(&self.ws) {
            self.lang = i18n::detect(&s.config.language, s.intent_summary());
            self.snapshot = Some(s);
        }
    }

    fn is_busy(&self) -> bool {
        matches!(self.job, Job::Running { .. })
    }
}

pub fn run(ws: &Workspace, just_created: bool) -> Result<()> {
    let mut terminal = ratatui::init();
    let mut app = App::new(ws.clone());
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
            if let Some(p) = latest_progress {
                app.progress = Some(p);
                // Refresh the queue snapshot so Home reflects the drain's
                // task-by-task progress instead of the state frozen at job start.
                app.reload();
            }
            if let Some(r) = finished {
                app.toast = Some((r.ok, r.summary));
                app.job = Job::Idle;
                app.progress = None;
                app.reload();
            }
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

        match app.screen {
            Screen::Home => {
                if handle_home_key(&mut app, key.code) {
                    break;
                }
            }
            Screen::NewWork => handle_new_work_key(&mut app, key.code, key.modifiers),
            Screen::Answer => handle_answer_key(&mut app, key.code, key.modifiers),
            Screen::Settings => handle_settings_key(&mut app, key.code),
            Screen::Handoff | Screen::Monitor => {
                if matches!(key.code, KeyCode::Esc | KeyCode::Char('q')) {
                    app.screen = Screen::Home;
                }
            }
        }
    }
    Ok(())
}

/// Returns true to quit.
fn handle_home_key(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Char('q') => return true,
        KeyCode::Char('n') if !app.is_busy() => {
            app.input.clear();
            app.toast = None;
            app.screen = Screen::NewWork;
        }
        KeyCode::Char('r') if !app.is_busy() => start_run(app),
        KeyCode::Char('A') if !app.is_busy() => start_auto(app),
        KeyCode::Char('p') if !app.is_busy() => start_approve(app),
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
            app.screen = Screen::Handoff;
        }
        // Settings can be opened mid-run; saved changes apply to the next task.
        KeyCode::Char('s') => open_settings(app),
        // Monitor can be opened mid-run to watch the worker's live output.
        KeyCode::Char('m') => app.screen = Screen::Monitor,
        // Refresh is safe mid-run and lets you re-read the live queue/snapshot.
        KeyCode::Char('g') => app.reload(),
        KeyCode::Char('l') if !app.is_busy() => toggle_language(app),
        // Access can be toggled even mid-run; it takes effect on the next task.
        KeyCode::Char('f') => toggle_access(app),
        // Esc while a worker runs stops it (kills the worker process).
        KeyCode::Esc if app.is_busy() => stop_running_worker(app),
        _ if app.is_busy() => app.toast = Some((true, app.lang.l().busy.into())),
        _ => {}
    }
    false
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
                start_planning(app);
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
            } else {
                f.value.push(' ');
            }
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
                .find(|t| matches!(t.state, TaskState::Blocked | TaskState::Failed))
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
    let (tx, rx) = mpsc::channel();
    let txp = tx.clone();
    thread::spawn(move || {
        let res = match run::run_auto(&ws, false, |s| {
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

fn load_latest_handoff(app: &App) -> String {
    let runs = app.ws.runs_dir();
    let mut newest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
    if let Ok(rd) = std::fs::read_dir(&runs) {
        for e in rd.flatten() {
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
    }
    match newest {
        Some((_, dir)) => std::fs::read_to_string(dir.join("handoff.md"))
            .unwrap_or_else(|_| "Latest run has no handoff yet.".into()),
        None => "No runs yet. Press r on Home to run the next task.".into(),
    }
}
