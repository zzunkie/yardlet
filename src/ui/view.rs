//! Screen rendering for the Yard TUI. All user-visible strings come from the
//! active language's label table (`super::i18n`).

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, List, ListItem, Paragraph, Wrap};
use ratatui::Frame;
use unicode_width::UnicodeWidthStr;

use super::i18n::L;
use super::{App, Job, Screen};
use crate::schemas::TaskState;
use crate::snapshot::Snapshot;

const SPINNER: [&str; 4] = ["|", "/", "-", "\\"];

/// The drawable area, less a right margin so the box borders are not hidden
/// under a terminal's overlay scrollbar. The margin defaults to 1 column and is
/// tunable with `YARD_RIGHT_MARGIN` (e.g. `YARD_RIGHT_MARGIN=2 yard`) so it can
/// be matched to a terminal without a rebuild.
fn safe_area(frame: &Frame) -> Rect {
    let margin: u16 = std::env::var("YARD_RIGHT_MARGIN")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(2);
    let a = frame.area();
    Rect {
        x: a.x,
        y: a.y,
        width: a.width.saturating_sub(margin).max(1),
        height: a.height,
    }
}

pub fn render(frame: &mut Frame, app: &App) {
    match app.screen {
        Screen::Home => render_home(frame, app),
        Screen::NewWork => render_new_work(frame, app),
        Screen::Answer => render_answer(frame, app),
        Screen::Settings => render_settings(frame, app),
        Screen::Handoff => render_handoff(frame, app),
    }
}

fn render_settings(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(area);
    let items: Vec<ListItem> = match &app.settings {
        Some(d) => d
            .fields
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let selected = i == d.sel;
                let val = if f.value.is_empty() {
                    "(default)".to_string()
                } else {
                    f.value.clone()
                };
                let cursor = if selected { "\u{2588}" } else { "" };
                let marker = if selected { "> " } else { "  " };
                let lstyle = if selected {
                    Style::default().fg(Color::Yellow).bold()
                } else {
                    Style::default()
                };
                let vstyle = if selected {
                    Style::default().fg(Color::Cyan)
                } else {
                    Style::default().fg(Color::Gray)
                };
                ListItem::new(Line::from(vec![
                    Span::styled(marker, lstyle),
                    Span::styled(format!("{:<20}", f.label), lstyle),
                    Span::styled(format!("{val}{cursor}"), vstyle),
                ]))
            })
            .collect(),
        None => Vec::new(),
    };
    frame.render_widget(
        List::new(items).block(Block::bordered().title(l.settings_title)),
        chunks[0],
    );
    render_footer(frame, chunks[1], l.footer_settings);
}

fn render_home(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([
        Constraint::Length(6),
        Constraint::Min(4),
        Constraint::Length(5),
        Constraint::Length(3),
        Constraint::Length(3),
    ])
    .split(area);

    match &app.snapshot {
        Some(snap) => {
            render_header(frame, chunks[0], snap, l);
            render_queue(frame, chunks[1], snap, l);
            render_workers(frame, chunks[2], snap, l);
        }
        None => {
            let p = Paragraph::new("No workspace state loaded. Run `yard init`.")
                .block(Block::bordered().title(" Yard "));
            frame.render_widget(p, chunks[0]);
        }
    }
    render_status(frame, chunks[3], app);
    render_footer(frame, chunks[4], l.footer_home);
}

fn render_header(frame: &mut Frame, area: Rect, snap: &Snapshot, l: &L) {
    let status = Line::from(vec![
        Span::raw(l.status),
        Span::styled(
            format!("{} {}", snap.count(TaskState::Running), l.s_running),
            Style::default().fg(Color::Yellow),
        ),
        Span::raw(", "),
        Span::raw(format!("{} {}", snap.count(TaskState::Queued), l.s_queued)),
        Span::raw(", "),
        Span::styled(
            format!("{} {}", snap.count(TaskState::NeedsUser), l.s_needs),
            Style::default().fg(Color::Magenta),
        ),
        Span::raw(", "),
        Span::styled(
            format!("{} {}", snap.count(TaskState::Blocked), l.s_blocked),
            Style::default().fg(Color::Red),
        ),
        Span::raw(", "),
        Span::styled(
            format!("{} {}", snap.count(TaskState::Done), l.s_done),
            Style::default().fg(Color::Green),
        ),
    ]);
    let lines = vec![
        Line::from(vec![
            Span::raw(l.workspace),
            Span::styled(snap.config.product.clone(), Style::default().bold()),
            Span::raw(format!(
                "   {}: {} {}   {}: {}   {}: {}",
                l.workers_word,
                snap.workers_ready(),
                l.ready_word,
                l.planner,
                snap.planner,
                l.access_word,
                snap.config.default_access,
            )),
        ]),
        Line::from(vec![
            Span::raw(l.intent),
            Span::styled(
                snap.intent_summary().to_string(),
                Style::default().fg(Color::Cyan),
            ),
        ]),
        status,
    ];
    let block = Block::bordered().title(l.app_title);
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn render_queue(frame: &mut Frame, area: Rect, snap: &Snapshot, l: &L) {
    let items: Vec<ListItem> = if snap.tasks().is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            l.queue_empty,
            Style::default().fg(Color::DarkGray),
        )))]
    } else {
        snap.tasks()
            .iter()
            .map(|t| {
                let color = match t.state {
                    TaskState::Done => Color::Green,
                    TaskState::Running => Color::Yellow,
                    TaskState::Blocked | TaskState::Failed => Color::Red,
                    TaskState::NeedsUser => Color::Magenta,
                    TaskState::Queued => Color::Gray,
                };
                ListItem::new(Line::from(vec![
                    Span::styled(format!(" {} ", t.state.glyph()), Style::default().fg(color)),
                    Span::styled(format!("{:<11}", t.id), Style::default().fg(Color::White)),
                    Span::raw(truncate(&t.title, 44)),
                    Span::styled(
                        format!("  {}", t.preferred_worker),
                        Style::default().fg(Color::DarkGray),
                    ),
                ]))
            })
            .collect()
    };
    let block = Block::bordered().title(format!(" {} ({}) ", l.queue_word, snap.tasks().len()));
    frame.render_widget(List::new(items).block(block), area);
}

fn render_workers(frame: &mut Frame, area: Rect, snap: &Snapshot, l: &L) {
    let items: Vec<ListItem> = snap
        .workers
        .iter()
        .map(|w| {
            let (glyph, color, word) = match w.readiness.as_str() {
                "ready" => ("\u{2713}", Color::Green, l.w_ready),
                "ambiguous" => ("?", Color::Yellow, l.w_ambiguous),
                _ => ("\u{2715}", Color::Red, l.w_notready),
            };
            ListItem::new(Line::from(vec![
                Span::styled(format!(" {glyph} "), Style::default().fg(color)),
                Span::styled(
                    format!("{:<14}", w.id),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("{word:<11}"), Style::default().fg(color)),
                Span::styled(
                    w.version
                        .clone()
                        .unwrap_or_else(|| l.version_unknown.to_string()),
                    Style::default().fg(Color::DarkGray),
                ),
            ]))
        })
        .collect();
    let block = Block::bordered().title(l.workers_title);
    frame.render_widget(List::new(items).block(block), area);
}

fn render_status(frame: &mut Frame, area: Rect, app: &App) {
    let l = app.lang.l();
    let line = match &app.job {
        Job::Running { label, started, .. } => {
            let frame_idx = (started.elapsed().as_millis() / 120) as usize % SPINNER.len();
            let secs = started.elapsed().as_secs();
            let body = match &app.progress {
                Some(p) => format!("{p}  ({secs}{})", l.sec_unit),
                None => format!("{label} {} ({secs}{})\u{2026}", l.run_word, l.sec_unit),
            };
            Line::from(vec![
                Span::styled(
                    format!(" {} ", SPINNER[frame_idx]),
                    Style::default().fg(Color::Yellow).bold(),
                ),
                Span::styled(body, Style::default().fg(Color::Yellow)),
                Span::styled(l.subscription_note, Style::default().fg(Color::DarkGray)),
            ])
        }
        Job::Idle => match &app.toast {
            Some((ok, msg)) => Line::from(Span::styled(
                format!(" {msg}"),
                Style::default().fg(if *ok { Color::Cyan } else { Color::Red }),
            )),
            None => {
                let snap = app.snapshot.as_ref();
                if let Some((id, q)) = snap.and_then(|s| s.pending.as_ref()) {
                    Line::from(vec![
                        Span::styled(
                            format!(" \u{2691} {id} {}: ", l.needs_you),
                            Style::default().fg(Color::Magenta).bold(),
                        ),
                        Span::raw(truncate(if q.is_empty() { l.see_handoff } else { q }, 60)),
                        Span::styled(l.press_a, Style::default().fg(Color::DarkGray)),
                    ])
                } else if let Some(s) = snap.filter(|s| !s.approvals_needed.is_empty()) {
                    Line::from(vec![
                        Span::styled(
                            format!(
                                " \u{2691} {} {} ({}) ",
                                s.approvals_needed.len(),
                                l.approval_needed,
                                s.approvals_needed.join(", ")
                            ),
                            Style::default().fg(Color::Magenta).bold(),
                        ),
                        Span::styled("(p)", Style::default().fg(Color::DarkGray)),
                    ])
                } else {
                    Line::from(Span::styled(l.idle, Style::default().fg(Color::DarkGray)))
                }
            }
        },
    };
    frame.render_widget(Paragraph::new(line).block(Block::bordered()), area);
}

fn render_new_work(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(4),
        Constraint::Length(3),
    ])
    .split(area);

    frame.render_widget(
        Paragraph::new(l.newwork_prompt).block(Block::bordered().title(l.newwork_title)),
        chunks[0],
    );
    frame.render_widget(
        Paragraph::new(app.input.as_str())
            .wrap(Wrap { trim: false })
            .block(Block::bordered().title(l.request_title)),
        chunks[1],
    );
    place_input_cursor(frame, chunks[1], &app.input);
    render_footer(frame, chunks[2], l.footer_newwork);
}

fn render_answer(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([
        Constraint::Min(4),
        Constraint::Length(5),
        Constraint::Length(3),
    ])
    .split(area);

    let (task_id, question) = app
        .snapshot
        .as_ref()
        .and_then(|s| s.pending.clone())
        .unwrap_or_else(|| ("(none)".into(), String::new()));
    let q_body = if question.is_empty() {
        l.no_question.to_string()
    } else {
        question
    };
    frame.render_widget(
        Paragraph::new(q_body)
            .wrap(Wrap { trim: true })
            .block(Block::bordered().title(format!(" {task_id} {} ", l.asking_word))),
        chunks[0],
    );
    frame.render_widget(
        Paragraph::new(app.input.as_str())
            .wrap(Wrap { trim: false })
            .block(Block::bordered().title(l.your_answer_title)),
        chunks[1],
    );
    place_input_cursor(frame, chunks[1], &app.input);
    render_footer(frame, chunks[2], l.footer_answer);
}

fn render_handoff(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(area);
    frame.render_widget(
        Paragraph::new(app.handoff_text.clone())
            .wrap(Wrap { trim: false })
            .block(Block::bordered().title(l.handoff_title)),
        chunks[0],
    );
    render_footer(frame, chunks[1], l.footer_handoff);
}

fn render_footer(frame: &mut Frame, area: Rect, keys: &str) {
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            keys,
            Style::default().fg(Color::DarkGray),
        )))
        .block(Block::bordered()),
        area,
    );
}

/// Position the real terminal cursor at the end of the input so the terminal's
/// IME composition (Korean/CJK) renders inline, instead of lagging a character.
/// Width is measured in display columns (Hangul is 2 wide).
fn place_input_cursor(frame: &mut Frame, area: Rect, input: &str) {
    let inner_w = (area.width.saturating_sub(2)).max(1) as usize;
    let w = UnicodeWidthStr::width(input);
    let row = (w / inner_w) as u16;
    let col = (w % inner_w) as u16;
    frame.set_cursor_position((area.x + 1 + col, area.y + 1 + row));
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        format!("{s:<max$}")
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('\u{2026}');
        out
    }
}
