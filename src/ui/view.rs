//! Screen rendering for the Yardlet TUI. All user-visible strings come from the
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
        Screen::Intent => render_intent(frame, app),
        Screen::Completion => render_completion(frame, app),
        Screen::ReportList => render_report_list(frame, app),
    }
}

/// Turn one worker-output line into a readable monitor line. Worker CLIs stream
/// JSONL events (claude `stream-json`, codex `--json`); extract the human bits
/// (assistant text + tool calls). Non-JSON lines are shown as-is.
pub(crate) fn pretty_event_line(line: &str) -> Option<String> {
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
    // Renders entirely from App's MonitorCache: the event loop keeps the cache
    // current (stat per frame, file reads only on growth/run switch), so this
    // function does no filesystem work.
    let l = app.lang.l();
    let area = safe_area(frame);
    let mc = &app.monitor;
    // With parallel runs, the header grows one line for the task tabs.
    let multi = mc.runs.len() > 1;
    let chunks = Layout::vertical([
        Constraint::Length(if multi { 4 } else { 3 }),
        Constraint::Min(4),
        Constraint::Length(3),
    ])
    .split(area);

    let tabs: Option<Line> = multi.then(|| {
        let sel = app.monitor_sel % mc.runs.len();
        let mut spans: Vec<Span> = Vec::new();
        for (i, (task_id, _)) in mc.runs.iter().enumerate() {
            if i > 0 {
                spans.push(Span::raw("  "));
            }
            spans.push(if i == sel {
                Span::styled(task_id.clone(), Style::default().bold().fg(Color::Yellow))
            } else {
                Span::styled(task_id.clone(), Style::default().fg(Color::DarkGray))
            });
        }
        Line::from(spans)
    });
    let header = match &mc.header {
        Some(h) => {
            // State comes from the queue (source of truth); run.yaml's `state`
            // is written once at start and never updated, so it's stale.
            let qstate = app.snapshot.as_ref().and_then(|s| {
                s.queue
                    .tasks
                    .iter()
                    .find(|t| t.id == h.task_id)
                    .map(|t| t.state)
            });
            let (state, state_color) = match qstate {
                Some(TaskState::Running) => ("running".to_string(), Color::Yellow),
                Some(TaskState::Done) => ("done".to_string(), Color::Green),
                Some(TaskState::Failed) => ("failed".to_string(), Color::Red),
                Some(TaskState::Blocked) => ("blocked".to_string(), Color::Red),
                Some(TaskState::NeedsUser) => ("needs-you".to_string(), Color::Magenta),
                Some(TaskState::Partial) => ("partial".to_string(), Color::LightYellow),
                Some(TaskState::Queued) => ("queued".to_string(), Color::Gray),
                None => (h.recorded_state.clone(), Color::Gray),
            };
            Line::from(vec![
                Span::styled(h.run_name.clone(), Style::default().fg(Color::DarkGray)),
                Span::raw("   "),
                Span::styled(format!("task {}", h.task_id), Style::default().bold()),
                Span::raw("   "),
                Span::styled(
                    format!("worker {}", h.worker),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::raw("   "),
                Span::styled(format!("[{state}]"), Style::default().fg(state_color)),
            ])
        }
        None => Line::from(l.monitor_no_runs.to_string()),
    };
    let header_lines: Vec<Line> = match tabs {
        Some(t) => vec![t, header],
        None => vec![header],
    };
    frame.render_widget(
        Paragraph::new(header_lines).block(Block::bordered().title(l.monitor_title)),
        chunks[0],
    );

    let visible = chunks[1].height.saturating_sub(2) as usize;
    let start = mc.log_lines.len().saturating_sub(visible);
    let body = mc.log_lines[start..].join("\n");
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
                let hint = if f.options.is_empty() {
                    String::new()
                } else {
                    let shown: Vec<&str> = f
                        .options
                        .iter()
                        .map(|o| if o.is_empty() { "default" } else { o.as_str() })
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
        Constraint::Length(5),
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
            // Selection continues past the queue into the workers panel.
            let wsel = app.selected.checked_sub(snap.tasks().len());
            render_workers(frame, chunks[2], snap, l, wsel);
        }
        None => {
            let p = Paragraph::new("No workspace state loaded. Run `yardlet init`.")
                .block(Block::bordered().title(" Yardlet "));
            frame.render_widget(p, chunks[0]);
        }
    }
    render_status(frame, chunks[3], app);
    // A freshly installed binary is worth shouting about — the silent
    // status-line note got missed for days. When idle, the footer turns into
    // the restart prompt in cyan so it can't be overlooked.
    if app.update_available && !app.is_busy() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                l.update_ready,
                Style::default().fg(Color::Cyan).bold(),
            )))
            .block(Block::bordered())
            .wrap(Wrap { trim: true }),
            chunks[4],
        );
        return;
    }
    let footer = if app.is_busy() {
        // Only an auto-drain is pausable (`p`); planning / single runs show
        // just `Esc stop` so the footer doesn't advertise a key that no-ops.
        if app.pause.is_some() {
            l.footer_home_busy.to_string()
        } else {
            l.footer_home_busy_nodrain.to_string()
        }
    } else {
        // Only show answer/approve keys when there's actually something to do.
        let mut f = l.footer_home.to_string();
        if let Some(snap) = &app.snapshot {
            let answerable = snap.pending.is_some()
                || snap.gate.is_some()
                || snap
                    .queue
                    .tasks
                    .iter()
                    .any(|t| !matches!(t.state, TaskState::Running | TaskState::Done));
            if answerable {
                f.push_str("  ");
                f.push_str(l.key_answer);
            }
            if !snap.approvals_needed.is_empty() {
                f.push_str("  ");
                f.push_str(l.key_approve);
            }
        }
        f
    };
    render_footer(frame, chunks[4], &footer);
}

/// The intent summary as ONE line for the fixed-height header: amend adds
/// "\n\n[follow-up] ..." to the summary, which would wrap and push the status
/// line out of the box. Show the base goal, width-truncated, with a "(+N)"
/// chip when follow-ups exist (the full text lives in the intent contract).
fn intent_oneline(snap: &Snapshot, width: u16, l: &L) -> String {
    let raw = snap.intent_summary();
    let followups = raw.matches("[follow-up]").count();
    let base = raw.split("[follow-up]").next().unwrap_or(raw);
    let base = base.split_whitespace().collect::<Vec<_>>().join(" ");
    let suffix = if followups > 0 {
        format!("  (+{followups})")
    } else {
        String::new()
    };
    let avail = (width as usize).saturating_sub(
        2 + UnicodeWidthStr::width(l.intent) + UnicodeWidthStr::width(suffix.as_str()),
    );
    format!("{}{suffix}", truncate_width(&base, avail))
}

/// Truncate to a display-column budget (Hangul counts as 2), ellipsizing.
fn truncate_width(s: &str, max: usize) -> String {
    use unicode_width::UnicodeWidthChar;
    if UnicodeWidthStr::width(s) <= max {
        return s.to_string();
    }
    let budget = max.saturating_sub(1); // room for the ellipsis
    let mut w = 0;
    let mut out = String::new();
    for c in s.chars() {
        let cw = UnicodeWidthChar::width(c).unwrap_or(0);
        if w + cw > budget {
            break;
        }
        out.push(c);
        w += cw;
    }
    out.push('\u{2026}');
    out
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
            format!("{} {}", snap.count(TaskState::Partial), l.s_partial),
            Style::default().fg(Color::LightYellow),
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
                intent_oneline(snap, area.width, l),
                Style::default().fg(Color::Cyan),
            ),
        ]),
        status,
    ];
    let block = Block::bordered().title(format!(
        " Yardlet v{} \u{00b7} {} ",
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
                    TaskState::Partial => Color::LightYellow,
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

fn render_workers(frame: &mut Frame, area: Rect, snap: &Snapshot, l: &L, selected: Option<usize>) {
    let items: Vec<ListItem> = snap
        .workers
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let (glyph, color, word) = if !w.enabled {
                ("\u{00b7}", Color::DarkGray, l.w_disabled)
            } else {
                match w.readiness.as_str() {
                    "ready" => ("\u{2713}", Color::Green, l.w_ready),
                    "ambiguous" => ("?", Color::Yellow, l.w_ambiguous),
                    _ => ("\u{2715}", Color::Red, l.w_notready),
                }
            };
            let is_sel = selected == Some(i);
            let marker = if is_sel { "\u{25b8}" } else { " " };
            let id_style = if w.enabled {
                Style::default().add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            let id_style = if is_sel {
                id_style.fg(Color::Yellow)
            } else {
                id_style
            };
            let mut spans = vec![
                Span::styled(format!("{marker}{glyph} "), Style::default().fg(color)),
                Span::styled(format!("{:<14}", w.id), id_style),
                Span::styled(format!("{word:<11}"), Style::default().fg(color)),
                Span::styled(
                    w.version
                        .clone()
                        .unwrap_or_else(|| l.version_unknown.to_string()),
                    Style::default().fg(Color::DarkGray),
                ),
            ];
            if is_sel {
                spans.push(Span::styled(
                    l.worker_toggle_hint,
                    Style::default().fg(Color::DarkGray),
                ));
            }
            ListItem::new(Line::from(spans))
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
            // A requested graceful pause (`p`) must surface HERE: while busy this
            // status line replaces the toast area, so otherwise pressing `p`
            // looks like a no-op. The pause flag is persistent, so the notice
            // stays until the drain actually stops after the current task.
            let paused = app
                .pause
                .as_ref()
                .map(|p| p.load(std::sync::atomic::Ordering::Relaxed))
                .unwrap_or(false);
            if paused {
                Line::from(vec![
                    Span::styled(" \u{23f8} ", Style::default().fg(Color::Cyan).bold()),
                    Span::styled(
                        format!("{} ({secs}{})", l.pausing, l.sec_unit),
                        Style::default().fg(Color::Cyan),
                    ),
                ])
            } else {
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
                ])
            }
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
                } else if let Some((qs, turns)) = snap.and_then(|s| s.gate.as_ref()) {
                    Line::from(vec![
                        Span::styled(
                            format!(
                                " \u{270B} {} ({}/{}): ",
                                l.plan_needs,
                                turns + 1,
                                crate::planner::INTERVIEW_CAP
                            ),
                            Style::default().fg(Color::Yellow).bold(),
                        ),
                        Span::raw(truncate(qs.first().map(|q| q.as_str()).unwrap_or(""), 56)),
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
                } else if app.update_available {
                    Line::from(Span::styled(
                        l.update_ready,
                        Style::default().fg(Color::Cyan),
                    ))
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
    place_input_cursor(frame, chunks[1], &app.input, app.input_caret);
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
        .answer_target
        .clone()
        .or_else(|| app.snapshot.as_ref().and_then(|s| s.pending.clone()))
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
    place_input_cursor(frame, chunks[1], &app.input, app.input_caret);
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

fn render_intent(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(area);
    frame.render_widget(
        Paragraph::new(md_lines(&app.intent_text))
            .wrap(Wrap { trim: false })
            .scroll((app.scroll, 0))
            .block(Block::bordered().title(l.intent_title)),
        chunks[0],
    );
    render_footer(frame, chunks[1], l.footer_intent);
}

fn render_report_list(frame: &mut Frame, app: &App) {
    let l = app.lang.l();
    let area = safe_area(frame);
    let chunks = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(area);
    let items: Vec<ListItem> = if app.reports.is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            "(no reports yet)",
            Style::default().fg(Color::DarkGray),
        )))]
    } else {
        let sel = app.report_sel.min(app.reports.len().saturating_sub(1));
        app.reports
            .iter()
            .enumerate()
            .map(|(i, (label, src))| {
                let is_sel = i == sel;
                let marker = if is_sel { "\u{25b8} " } else { "  " };
                let color = if src.is_none() {
                    Color::Cyan
                } else {
                    Color::Gray
                };
                let style = if is_sel {
                    Style::default().fg(color).bold()
                } else {
                    Style::default().fg(color)
                };
                ListItem::new(Line::from(Span::styled(format!("{marker}{label}"), style)))
            })
            .collect()
    };
    frame.render_widget(
        List::new(items).block(Block::bordered().title(l.reports_title)),
        chunks[0],
    );
    render_footer(frame, chunks[1], l.footer_reports);
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
fn place_input_cursor(frame: &mut Frame, area: Rect, input: &str, caret: usize) {
    let inner_w = (area.width.saturating_sub(2)).max(1) as usize;
    // The caret sits after `caret` chars, so wrap only that prefix.
    let prefix: String = input.chars().take(caret).collect();
    let (row, col) = wrapped_caret(&prefix, inner_w);
    // Keep the caret inside the box even when the text outgrows it.
    let max_row = area.height.saturating_sub(3);
    frame.set_cursor_position((
        area.x + 1 + col.min(inner_w.saturating_sub(1) as u16),
        area.y + 1 + row.min(max_row),
    ));
}

/// Where the caret lands after `input`, under the same wrapping the renderer
/// applies: greedy word wrap, and a double-width char (Hangul) that would
/// straddle the right edge moves wholly to the next row. The old width/inner
/// division drifted one cell per wrapped line for Korean text.
fn wrapped_caret(input: &str, width: usize) -> (u16, u16) {
    use unicode_width::UnicodeWidthChar;
    let width = width.max(1);
    let mut row = 0usize;
    let mut col = 0usize;
    for (li, line) in input.split('\n').enumerate() {
        if li > 0 {
            row += 1;
            col = 0;
        }
        // Alternate whitespace runs (wrap char-by-char) and words (move whole
        // to the next row when they no longer fit; hard-break only when a
        // word is wider than the box).
        let mut chars = line.chars().peekable();
        while let Some(&c) = chars.peek() {
            if c.is_whitespace() {
                chars.next();
                if col + 1 > width {
                    row += 1;
                    col = 0;
                }
                col += 1;
                continue;
            }
            let mut word = String::new();
            while let Some(&c) = chars.peek() {
                if c.is_whitespace() {
                    break;
                }
                word.push(c);
                chars.next();
            }
            let ww = UnicodeWidthStr::width(word.as_str());
            if col + ww <= width {
                col += ww;
            } else if ww <= width {
                row += 1;
                col = ww;
            } else {
                // Wider than the box: hard-break, double-width aware.
                if col > 0 {
                    row += 1;
                    col = 0;
                }
                for ch in word.chars() {
                    let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
                    if col + cw > width {
                        row += 1;
                        col = 0;
                    }
                    col += cw;
                }
            }
        }
    }
    (row as u16, col as u16)
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn truncate_width_respects_hangul_columns() {
        assert_eq!(truncate_width("hello", 10), "hello");
        // "가나다라" = 8 cols; budget 5 -> 2 chars (4 cols) + ellipsis
        assert_eq!(truncate_width("가나다라", 5), "가나\u{2026}");
    }

    #[test]
    fn caret_tracks_hangul_double_width_wrapping() {
        // width 5, one long Hangul "word" (width 2 each): 가나 fits (4),
        // 다 would straddle -> moves to the next row whole.
        assert_eq!(wrapped_caret("가나다", 5), (1, 2));
        // ASCII word wrap: "hello world" at width 8 — "world" moves whole.
        assert_eq!(wrapped_caret("hello world", 8), (1, 5));
        // Explicit newline resets the column and counts a row.
        assert_eq!(wrapped_caret("ab\ncd", 10), (1, 2));
        // Earlier lines that wrap are counted too (the old code missed this).
        assert_eq!(wrapped_caret("가나다\nx", 5), (2, 1));
        // Korean prose with spaces: words move wholly, like the renderer.
        // width 6: "안녕 하세요" -> 안녕(4)+space(5), 하세요(6) doesn't fit -> row 1.
        assert_eq!(wrapped_caret("안녕 하세요", 6), (1, 6));
    }
}
