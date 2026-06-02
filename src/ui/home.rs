//! Home screen: a read-only dashboard rendered from `.agents/` state.
//!
//! It does not require a worker to render and never touches API keys.

use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, List, ListItem, Paragraph, Wrap};
use ratatui::Frame;

use crate::schemas::TaskState;
use crate::snapshot::Snapshot;

pub fn render(frame: &mut Frame, snap: &Snapshot) {
    let area = frame.area();
    let chunks = Layout::vertical([
        Constraint::Length(6), // header
        Constraint::Min(5),    // queue
        Constraint::Length(7), // workers
        Constraint::Length(3), // footer
    ])
    .split(area);

    render_header(frame, chunks[0], snap);
    render_queue(frame, chunks[1], snap);
    render_workers(frame, chunks[2], snap);
    render_footer(frame, chunks[3]);
}

fn render_header(frame: &mut Frame, area: ratatui::layout::Rect, snap: &Snapshot) {
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
            Span::raw(format!("   Workers: {} ready", snap.workers_ready())),
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

fn render_queue(frame: &mut Frame, area: ratatui::layout::Rect, snap: &Snapshot) {
    let items: Vec<ListItem> = if snap.tasks().is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            "  (queue empty — open New Work to create an intent and tasks)",
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
                    Span::styled(format!("{:<10}", t.id), Style::default().fg(Color::White)),
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

fn render_workers(frame: &mut Frame, area: ratatui::layout::Rect, snap: &Snapshot) {
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

fn render_footer(frame: &mut Frame, area: ratatui::layout::Rect) {
    let line = Line::from(vec![
        Span::styled(" q/Esc ", Style::default().fg(Color::Black).bg(Color::Gray)),
        Span::raw(" quit    "),
        Span::styled(
            "read-only view \u{00b7} use the CLI for init / run (yard run --next)",
            Style::default().fg(Color::DarkGray),
        ),
    ]);
    frame.render_widget(Paragraph::new(line).block(Block::bordered()), area);
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        format!("{s:<width$}", width = max)
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('\u{2026}');
        out
    }
}
