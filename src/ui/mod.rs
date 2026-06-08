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
};
use ratatui::crossterm::execute;

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
}

pub struct JobResult {
    pub ok: bool,
    pub summary: String,
}

pub enum Job {
    Idle,
    Running {
        label: String,
        started: Instant,
        rx: Receiver<JobResult>,
    },
}

pub struct App {
    pub ws: Workspace,
    pub screen: Screen,
    pub snapshot: Option<Snapshot>,
    pub input: String,
    pub job: Job,
    pub toast: Option<(bool, String)>,
    pub handoff_text: String,
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
            handoff_text: String::new(),
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
    let result = main_loop(&mut terminal, app);
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    result
}

fn main_loop(terminal: &mut ratatui::DefaultTerminal, mut app: App) -> Result<()> {
    loop {
        // Drain a finished background job.
        if let Job::Running { rx, .. } = &app.job {
            if let Ok(res) = rx.try_recv() {
                app.toast = Some((res.ok, res.summary));
                app.job = Job::Idle;
                app.reload();
            }
        }

        terminal.draw(|frame| view::render(frame, &app))?;

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
            Screen::NewWork => handle_new_work_key(&mut app, key.code),
            Screen::Answer => handle_answer_key(&mut app, key.code),
            Screen::Handoff => {
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
        KeyCode::Char('g') if !app.is_busy() => app.reload(),
        KeyCode::Char('l') if !app.is_busy() => toggle_language(app),
        _ if app.is_busy() => app.toast = Some((true, app.lang.l().busy.into())),
        _ => {}
    }
    false
}

fn handle_new_work_key(app: &mut App, code: KeyCode) {
    if app.is_busy() {
        if code == KeyCode::Esc {
            app.screen = Screen::Home;
        }
        return;
    }
    match code {
        KeyCode::Esc => app.screen = Screen::Home,
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

fn handle_answer_key(app: &mut App, code: KeyCode) {
    if app.is_busy() {
        if code == KeyCode::Esc {
            app.screen = Screen::Home;
        }
        return;
    }
    match code {
        KeyCode::Esc => app.screen = Screen::Home,
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
        let res = match crate::planner::run_planning(&ws, &request, None) {
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
        let _ = tx.send(res);
    });
    app.job = Job::Running {
        label: format!("{} {planner}", lbl.run_word),
        started: Instant::now(),
        rx,
    };
    app.input.clear();
}

fn start_run(app: &mut App) {
    // Prefer the next queued task; if none, retry the first stuck (blocked/failed)
    // one so the user is never dead-ended in the TUI.
    let (has_queued, stuck) = app
        .snapshot
        .as_ref()
        .map(|s| {
            let has_queued = s.queue.tasks.iter().any(|t| t.state == TaskState::Queued);
            let stuck = s
                .queue
                .tasks
                .iter()
                .find(|t| matches!(t.state, TaskState::Blocked | TaskState::Failed))
                .map(|t| t.id.clone());
            (has_queued, stuck)
        })
        .unwrap_or((false, None));

    let target = if has_queued { None } else { stuck };
    if !has_queued && target.is_none() {
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
        let _ = tx.send(res);
    });
    app.job = Job::Running {
        label: lbl.run_word.into(),
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
        let _ = tx.send(res);
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
