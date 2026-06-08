//! Screen rendering for the Yard TUI.

use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, List, ListItem, Paragraph, Wrap};
use ratatui::Frame;

use super::{App, Job, Screen};
use crate::schemas::TaskState;
use crate::snapshot::Snapshot;

const SPINNER: [&str; 4] = ["|", "/", "-", "\\"];

pub fn render(frame: &mut Frame, app: &App) {
    match app.screen {
        Screen::Home => render_home(frame, app),
        Screen::NewWork => render_new_work(frame, app),
        Screen::Answer => render_answer(frame, app),
        Screen::Handoff => render_handoff(frame, app),
    }
}

fn render_home(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let chunks = Layout::vertical([
        Constraint::Length(6), // header
        Constraint::Min(4),    // queue
        Constraint::Length(5), // workers
        Constraint::Length(3), // status / job
        Constraint::Length(3), // footer
    ])
    .split(area);

    match &app.snapshot {
        Some(snap) => {
            render_header(frame, chunks[0], snap);
            render_queue(frame, chunks[1], snap);
            render_workers(frame, chunks[2], snap);
        }
        None => {
            let p = Paragraph::new("No workspace state loaded. Run `yard init`.")
                .block(Block::bordered().title(" Yard "));
            frame.render_widget(p, chunks[0]);
        }
    }
    render_status(frame, chunks[3], app);
    render_footer(
        frame,
        chunks[4],
        "n new   r run next   a answer   h handoff   g refresh   q quit",
    );
}

fn render_header(frame: &mut Frame, area: Rect, snap: &Snapshot) {
    let status = Line::from(vec![
        Span::raw("Status: "),
        Span::styled(
            format!("{} running", snap.count(TaskState::Running)),
            Style::default().fg(Color::Yellow),
        ),
        Span::raw(", "),
        Span::raw(format!("{} queued", snap.count(TaskState::Queued))),
        Span::raw(", "),
        Span::styled(
            format!("{} needs-you", snap.count(TaskState::NeedsUser)),
            Style::default().fg(Color::Magenta),
        ),
        Span::raw(", "),
        Span::styled(
            format!("{} blocked", snap.count(TaskState::Blocked)),
            Style::default().fg(Color::Red),
        ),
        Span::raw(", "),
        Span::styled(
            format!("{} done", snap.count(TaskState::Done)),
            Style::default().fg(Color::Green),
        ),
    ]);
    let lines = vec![
        Line::from(vec![
            Span::raw("Workspace: "),
            Span::styled(snap.config.product.clone(), Style::default().bold()),
            Span::raw(format!(
                "   Workers: {} ready   Planner: {}",
                snap.workers_ready(),
                snap.planner
            )),
        ]),
        Line::from(vec![
            Span::raw("Intent: "),
            Span::styled(
                snap.intent_summary().to_string(),
                Style::default().fg(Color::Cyan),
            ),
        ]),
        status,
    ];
    let block = Block::bordered().title(" Yard \u{00b7} Local AI Workbench ");
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn render_queue(frame: &mut Frame, area: Rect, snap: &Snapshot) {
    let items: Vec<ListItem> = if snap.tasks().is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            "  (queue empty \u{2014} press n to describe new work)",
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
    let block = Block::bordered().title(format!(" Queue ({}) ", snap.tasks().len()));
    frame.render_widget(List::new(items).block(block), area);
}

fn render_workers(frame: &mut Frame, area: Rect, snap: &Snapshot) {
    let items: Vec<ListItem> = snap
        .workers
        .iter()
        .map(|w| {
            let (glyph, color) = match w.readiness.as_str() {
                "ready" => ("\u{2713}", Color::Green),
                "ambiguous" => ("?", Color::Yellow),
                _ => ("\u{2715}", Color::Red),
            };
            ListItem::new(Line::from(vec![
                Span::styled(format!(" {glyph} "), Style::default().fg(color)),
                Span::styled(
                    format!("{:<14}", w.id),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("{:<11}", w.readiness), Style::default().fg(color)),
                Span::styled(
                    w.version
                        .clone()
                        .unwrap_or_else(|| "version unknown".into()),
                    Style::default().fg(Color::DarkGray),
                ),
            ]))
        })
        .collect();
    let block = Block::bordered().title(" Workers \u{00b7} zero-key ");
    frame.render_widget(List::new(items).block(block), area);
}

fn render_status(frame: &mut Frame, area: Rect, app: &App) {
    let line = match &app.job {
        Job::Running { label, started, .. } => {
            let frame_idx = (started.elapsed().as_millis() / 120) as usize % SPINNER.len();
            Line::from(vec![
                Span::styled(
                    format!(" {} ", SPINNER[frame_idx]),
                    Style::default().fg(Color::Yellow).bold(),
                ),
                Span::styled(
                    format!("{label} running ({}s)\u{2026}", started.elapsed().as_secs()),
                    Style::default().fg(Color::Yellow),
                ),
                Span::styled(
                    "   worker is subscription-backed; no API key used",
                    Style::default().fg(Color::DarkGray),
                ),
            ])
        }
        Job::Idle => match &app.toast {
            Some((ok, msg)) => Line::from(Span::styled(
                format!(" {msg}"),
                Style::default().fg(if *ok { Color::Cyan } else { Color::Red }),
            )),
            None => match app.snapshot.as_ref().and_then(|s| s.pending.as_ref()) {
                Some((id, q)) => Line::from(vec![
                    Span::styled(
                        format!(" \u{2691} {id} needs you: "),
                        Style::default().fg(Color::Magenta).bold(),
                    ),
                    Span::raw(truncate(if q.is_empty() { "see handoff" } else { q }, 60)),
                    Span::styled("  (press a)", Style::default().fg(Color::DarkGray)),
                ]),
                None => Line::from(Span::styled(" idle", Style::default().fg(Color::DarkGray))),
            },
        },
    };
    frame.render_widget(Paragraph::new(line).block(Block::bordered()), area);
}

fn render_new_work(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let chunks = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(4),
        Constraint::Length(3),
    ])
    .split(area);

    frame.render_widget(
        Paragraph::new("Describe the work in a few sentences. Yard plans, queues, and runs it.")
            .block(Block::bordered().title(" New Work ")),
        chunks[0],
    );

    let input = format!("{}\u{2588}", app.input); // block cursor
    frame.render_widget(
        Paragraph::new(input)
            .wrap(Wrap { trim: false })
            .block(Block::bordered().title(" Request ")),
        chunks[1],
    );

    render_footer(frame, chunks[2], "Enter plan   Esc cancel");
}

fn render_answer(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let chunks = Layout::vertical([
        Constraint::Min(4),    // the question
        Constraint::Length(5), // your answer
        Constraint::Length(3), // footer
    ])
    .split(area);

    let (task_id, question) = app
        .snapshot
        .as_ref()
        .and_then(|s| s.pending.clone())
        .unwrap_or_else(|| ("(none)".into(), String::new()));
    let q_body = if question.is_empty() {
        "(no recorded question — see the handoff)".to_string()
    } else {
        question
    };
    frame.render_widget(
        Paragraph::new(q_body)
            .wrap(Wrap { trim: true })
            .block(Block::bordered().title(format!(" {task_id} is asking "))),
        chunks[0],
    );

    let input = format!("{}\u{2588}", app.input);
    frame.render_widget(
        Paragraph::new(input)
            .wrap(Wrap { trim: false })
            .block(Block::bordered().title(" Your answer ")),
        chunks[1],
    );
    render_footer(frame, chunks[2], "Enter send & resume   Esc cancel");
}

fn render_handoff(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let chunks = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(area);
    frame.render_widget(
        Paragraph::new(app.handoff_text.clone())
            .wrap(Wrap { trim: false })
            .block(Block::bordered().title(" Handoff \u{00b7} latest run ")),
        chunks[0],
    );
    render_footer(frame, chunks[1], "Esc/q back");
}

fn render_footer(frame: &mut Frame, area: Rect, keys: &str) {
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            keys,
            Style::default().fg(Color::DarkGray),
        )))
        .alignment(Alignment::Left)
        .block(Block::bordered()),
        area,
    );
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
