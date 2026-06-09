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
        Screen::Monitor => render_monitor(frame, app),
        Screen::Handoff => render_handoff(frame, app),
        Screen::Completion => render_completion(frame, app),
    }
}

fn latest_run_dir(runs: &std::path::Path) -> Option<std::path::PathBuf> {
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

/// Turn one worker-output line into a readable monitor line. Worker CLIs stream
/// JSONL events (claude `stream-json`, codex `--json`); extract the human bits
/// (assistant text + tool calls). Non-JSON lines are shown as-is.
fn pretty_event_line(line: &str) -> Option<String> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let v: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return Some(line.to_string()),
    };
    let mut out = Vec::new();
    collect_readable(&v, &mut out);
    if out.is_empty() {
        None
    } else {
        Some(out.join("\n"))
    }
}

fn collect_readable(v: &serde_json::Value, out: &mut Vec<String>) {
    match v {
        serde_json::Value::Object(m) => {
            match m.get("type").and_then(|t| t.as_str()).unwrap_or("") {
                "text" => {
                    if let Some(t) = m.get("text").and_then(|t| t.as_str()) {
                        if !t.trim().is_empty() {
                            out.push(t.trim().to_string());
                        }
                    }
                }
                "tool_use" => {
                    let name = m.get("name").and_then(|n| n.as_str()).unwrap_or("tool");
                    out.push(format!("\u{1f527} {name}"));
                }
                _ => {
                    // codex/agent messages often carry text/message directly.
                    if let Some(t) = m.get("text").and_then(|t| t.as_str()) {
                        if !t.trim().is_empty() {
                            out.push(t.trim().to_string());
                        }
                    } else if let Some(t) = m.get("message").and_then(|t| t.as_str()) {
                        if !t.trim().is_empty() {
                            out.push(t.trim().to_string());
                        }
                    } else {
                        for val in m.values() {
                            collect_readable(val, out);
                        }
                    }
                }
            }
        }
        serde_json::Value::Array(a) => {
            for val in a {
                collect_readable(val, out);
            }
        }
        _ => {}
    }
}

fn render_monitor(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(4),
        Constraint::Length(3),
    ])
    .split(area);

    let dir = latest_run_dir(&app.ws.runs_dir());
    let header = match &dir {
        Some(d) => {
            let yaml = std::fs::read_to_string(d.join("run.yaml")).unwrap_or_default();
            let field = |k: &str| {
                yaml.lines()
                    .find_map(|ln| ln.trim().strip_prefix(k))
                    .map(|v| v.trim().trim_matches('"').to_string())
                    .unwrap_or_default()
            };
            // State comes from the queue (source of truth); run.yaml's `state`
            // is written once at start and never updated, so it's stale.
            let task_id = field("task_id:");
            let qstate = app
                .snapshot
                .as_ref()
                .and_then(|s| s.queue.tasks.iter().find(|t| t.id == task_id).map(|t| t.state));
            let (state, state_color) = match qstate {
                Some(TaskState::Running) => ("running".to_string(), Color::Yellow),
                Some(TaskState::Done) => ("done".to_string(), Color::Green),
                Some(TaskState::Failed) => ("failed".to_string(), Color::Red),
                Some(TaskState::Blocked) => ("blocked".to_string(), Color::Red),
                Some(TaskState::NeedsUser) => ("needs-you".to_string(), Color::Magenta),
                Some(TaskState::Queued) => ("queued".to_string(), Color::Gray),
                None => (field("state:"), Color::Gray),
            };
            Line::from(vec![
                Span::styled(
                    d.file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("")
                        .to_string(),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::raw("   "),
                Span::styled(format!("task {task_id}"), Style::default().bold()),
                Span::raw("   "),
                Span::styled(
                    format!("worker {}", field("worker:")),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::raw("   "),
                Span::styled(format!("[{state}]"), Style::default().fg(state_color)),
            ])
        }
        None => Line::from(l.monitor_no_runs.to_string()),
    };
    frame.render_widget(
        Paragraph::new(header).block(Block::bordered().title(l.monitor_title)),
        chunks[0],
    );

    let body = match &dir {
        Some(d) => {
            let log = std::fs::read_to_string(d.join("worker-output.log")).unwrap_or_default();
            let pretty: Vec<String> = log.lines().filter_map(pretty_event_line).collect();
            let visible = chunks[1].height.saturating_sub(2) as usize;
            let start = pretty.len().saturating_sub(visible);
            pretty[start..].join("\n")
        }
        None => String::new(),
    };
    frame.render_widget(
        Paragraph::new(body)
            .wrap(Wrap { trim: true })
            .block(Block::bordered()),
        chunks[1],
    );

    render_footer(frame, chunks[2], l.footer_monitor);
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
                let opts = super::field_options(&f.key);
                let hint = if opts.is_empty() {
                    String::new()
                } else {
                    let shown: Vec<&str> = opts
                        .iter()
                        .map(|o| if o.is_empty() { "default" } else { o })
                        .collect();
                    format!("({})", shown.join(" | "))
                };
                ListItem::new(Line::from(vec![
                    Span::styled(marker, lstyle),
                    Span::styled(pad_cols(&f.label, 18), lstyle),
                    Span::styled(pad_cols(&format!("{val}{cursor}"), 16), vstyle),
                    Span::styled(hint, Style::default().fg(Color::DarkGray)),
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

/// Render lightweight markdown (headings, bullets, **bold**, `code`, rules) to
/// styled lines for the handoff/report screens.
fn md_lines(text: &str) -> Vec<Line<'static>> {
    text.lines().map(md_line).collect()
}

fn md_line(line: &str) -> Line<'static> {
    if let Some(h) = line.strip_prefix("### ") {
        Line::from(Span::styled(
            h.to_string(),
            Style::default().fg(Color::Green).bold(),
        ))
    } else if let Some(h) = line.strip_prefix("## ") {
        Line::from(Span::styled(
            h.to_string(),
            Style::default().fg(Color::Yellow).bold(),
        ))
    } else if let Some(h) = line.strip_prefix("# ") {
        Line::from(Span::styled(
            h.to_string(),
            Style::default().fg(Color::Cyan).bold(),
        ))
    } else if matches!(line.trim(), "---" | "***" | "___") {
        Line::from(Span::styled(
            "\u{2500}".repeat(48),
            Style::default().fg(Color::DarkGray),
        ))
    } else {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed
            .strip_prefix("- ")
            .or_else(|| trimmed.strip_prefix("* "))
        {
            let indent = line.len() - trimmed.len();
            let mut spans = vec![
                Span::raw(" ".repeat(indent)),
                Span::styled("\u{2022} ", Style::default().fg(Color::DarkGray)),
            ];
            spans.extend(inline_spans(rest));
            Line::from(spans)
        } else {
            Line::from(inline_spans(line))
        }
    }
}

fn inline_spans(s: &str) -> Vec<Span<'static>> {
    let base = Style::default();
    let mut out: Vec<Span<'static>> = Vec::new();
    let mut buf = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '`' {
            if !buf.is_empty() {
                out.push(Span::styled(std::mem::take(&mut buf), base));
            }
            let mut code = String::new();
            for n in chars.by_ref() {
                if n == '`' {
                    break;
                }
                code.push(n);
            }
            out.push(Span::styled(code, Style::default().fg(Color::Cyan)));
        } else if c == '*' && chars.peek() == Some(&'*') {
            chars.next();
            if !buf.is_empty() {
                out.push(Span::styled(std::mem::take(&mut buf), base));
            }
            let mut bold = String::new();
            while let Some(n) = chars.next() {
                if n == '*' && chars.peek() == Some(&'*') {
                    chars.next();
                    break;
                }
                bold.push(n);
            }
            out.push(Span::styled(bold, base.bold()));
        } else {
            buf.push(c);
        }
    }
    if !buf.is_empty() {
        out.push(Span::styled(buf, base));
    }
    if out.is_empty() {
        out.push(Span::raw(""));
    }
    out
}

fn render_home(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([
        Constraint::Length(6),
        Constraint::Min(4),
        Constraint::Length(5),
        Constraint::Length(3),
        Constraint::Length(4),
    ])
    .split(area);

    match &app.snapshot {
        Some(snap) => {
            render_header(frame, chunks[0], snap, l);
            render_queue(frame, chunks[1], snap, l, app.selected);
            render_workers(frame, chunks[2], snap, l);
        }
        None => {
            let p = Paragraph::new("No workspace state loaded. Run `yard init`.")
                .block(Block::bordered().title(" Yard "));
            frame.render_widget(p, chunks[0]);
        }
    }
    render_status(frame, chunks[3], app);
    let footer = if app.is_busy() {
        l.footer_home_busy
    } else {
        l.footer_home
    };
    render_footer(frame, chunks[4], footer);
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
            format!("{} {}", snap.count(TaskState::Failed), l.s_failed),
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
    let block = Block::bordered().title(format!(
        " Yard v{} \u{00b7} {} ",
        env!("CARGO_PKG_VERSION"),
        l.subtitle
    ));
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn render_queue(frame: &mut Frame, area: Rect, snap: &Snapshot, l: &L, selected: usize) {
    let items: Vec<ListItem> = if snap.tasks().is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            l.queue_empty,
            Style::default().fg(Color::DarkGray),
        )))]
    } else {
        let sel = selected.min(snap.tasks().len().saturating_sub(1));
        snap.tasks()
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let color = match t.state {
                    TaskState::Done => Color::Green,
                    TaskState::Running => Color::Yellow,
                    TaskState::Blocked | TaskState::Failed => Color::Red,
                    TaskState::NeedsUser => Color::Magenta,
                    TaskState::Queued => Color::Gray,
                };
                let is_sel = i == sel;
                let marker = if is_sel { "\u{25b8}" } else { " " };
                let id_style = if is_sel {
                    Style::default().fg(Color::White).bold()
                } else {
                    Style::default().fg(Color::White)
                };
                ListItem::new(Line::from(vec![
                    Span::styled(
                        format!("{marker}{} ", t.state.glyph()),
                        Style::default().fg(color),
                    ),
                    Span::styled(format!("{:<11}", t.id), id_style),
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
        Paragraph::new(md_lines(&app.handoff_text))
            .wrap(Wrap { trim: false })
            .scroll((app.scroll, 0))
            .block(Block::bordered().title(l.handoff_title)),
        chunks[0],
    );
    render_footer(frame, chunks[1], l.footer_handoff);
}

fn render_completion(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(area);
    frame.render_widget(
        Paragraph::new(md_lines(&app.report_text))
            .wrap(Wrap { trim: false })
            .scroll((app.scroll, 0))
            .block(Block::bordered().title(l.completion_title)),
        chunks[0],
    );
    render_footer(frame, chunks[1], l.footer_completion);
}

fn render_footer(frame: &mut Frame, area: Rect, keys: &str) {
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            keys,
            Style::default().fg(Color::DarkGray),
        )))
        .block(Block::bordered())
        .wrap(Wrap { trim: true }),
        area,
    );
}

/// Position the real terminal cursor at the end of the input so the terminal's
/// IME composition (Korean/CJK) renders inline, instead of lagging a character.
/// Width is measured in display columns (Hangul is 2 wide).
fn place_input_cursor(frame: &mut Frame, area: Rect, input: &str) {
    let inner_w = (area.width.saturating_sub(2)).max(1) as usize;
    // Account for explicit newlines (Shift/Alt+Enter) plus wrapping of the last
    // line so the cursor (and the terminal's IME overlay) sit at the caret.
    let newlines = input.matches('\n').count() as u16;
    let last_line = input.rsplit('\n').next().unwrap_or("");
    let w = UnicodeWidthStr::width(last_line);
    let row = newlines + (w / inner_w) as u16;
    let col = (w % inner_w) as u16;
    frame.set_cursor_position((area.x + 1 + col, area.y + 1 + row));
}

/// Pad `s` with trailing spaces until its display width reaches `cols` (Hangul
/// counts as 2). Always leaves at least a 2-space gap when it overflows.
fn pad_cols(s: &str, cols: usize) -> String {
    let w = UnicodeWidthStr::width(s);
    let pad = if w < cols { cols - w } else { 2 };
    format!("{s}{}", " ".repeat(pad))
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
