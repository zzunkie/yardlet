use ratatui::crossterm::event::{KeyCode, KeyModifiers};

use super::i18n::L;
use crate::planning::PlanningProjection;
use crate::schemas::{PlanningDraftContent, PlanningEventType, PlanningProposal};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct ReviewGate {
    pub busy: bool,
    pub editing: bool,
    pub has_pending_proposal: bool,
    pub has_visible_head: bool,
    pub confirmed: bool,
    /// How many proposals are awaiting accept/reject. When more than one, the
    /// review screen exposes Tab/Shift+Tab to move the accept/reject target so
    /// the user never acts on an ambiguous "latest" proposal by surprise.
    pub pending_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ReviewAction {
    Noop,
    Back,
    ScrollUp,
    ScrollDown,
    PageUp,
    PageDown,
    BeginEdit,
    CancelEdit,
    SubmitRevision,
    InsertNewline,
    Insert(char),
    Backspace,
    Delete,
    CaretLeft,
    CaretRight,
    CaretHome,
    CaretEnd,
    CaretUp,
    CaretDown,
    Accept,
    Reject,
    Confirm,
    Refresh,
    /// Move the accept/reject target to the next pending proposal (Tab).
    SelectNext,
    /// Move the accept/reject target to the previous pending proposal (Shift+Tab).
    SelectPrev,
}

#[cfg(test)]
pub(super) fn action_for_key(
    code: KeyCode,
    modifiers: KeyModifiers,
    gate: ReviewGate,
) -> ReviewAction {
    action_for_key_with_enhancement(code, modifiers, false, gate)
}

pub(super) fn action_for_key_with_enhancement(
    code: KeyCode,
    modifiers: KeyModifiers,
    keyboard_enhancement: bool,
    gate: ReviewGate,
) -> ReviewAction {
    if gate.busy {
        return match code {
            KeyCode::Esc | KeyCode::Char('q') => ReviewAction::Back,
            _ => ReviewAction::Noop,
        };
    }
    if gate.editing {
        return match super::text_input::action_for_key(code, modifiers, keyboard_enhancement) {
            super::text_input::TextInputAction::Noop => ReviewAction::Noop,
            super::text_input::TextInputAction::Cancel => ReviewAction::CancelEdit,
            super::text_input::TextInputAction::Submit => ReviewAction::SubmitRevision,
            super::text_input::TextInputAction::InsertNewline => ReviewAction::InsertNewline,
            super::text_input::TextInputAction::Insert(c) => ReviewAction::Insert(c),
            super::text_input::TextInputAction::Backspace => ReviewAction::Backspace,
            super::text_input::TextInputAction::Delete => ReviewAction::Delete,
            super::text_input::TextInputAction::CaretLeft => ReviewAction::CaretLeft,
            super::text_input::TextInputAction::CaretRight => ReviewAction::CaretRight,
            super::text_input::TextInputAction::CaretHome => ReviewAction::CaretHome,
            super::text_input::TextInputAction::CaretEnd => ReviewAction::CaretEnd,
            super::text_input::TextInputAction::CaretUp => ReviewAction::CaretUp,
            super::text_input::TextInputAction::CaretDown => ReviewAction::CaretDown,
        };
    }
    match code {
        KeyCode::Esc | KeyCode::Char('q') => ReviewAction::Back,
        KeyCode::Up => ReviewAction::ScrollUp,
        KeyCode::Down => ReviewAction::ScrollDown,
        KeyCode::PageUp => ReviewAction::PageUp,
        KeyCode::PageDown => ReviewAction::PageDown,
        KeyCode::Char('e') if !gate.confirmed => ReviewAction::BeginEdit,
        KeyCode::Char('a') if gate.has_pending_proposal && !gate.confirmed => ReviewAction::Accept,
        KeyCode::Char('r') if gate.has_pending_proposal && !gate.confirmed => ReviewAction::Reject,
        // Target selection is only meaningful when the choice is ambiguous, i.e.
        // more than one proposal is pending. With one (or none) Tab is inert.
        KeyCode::Tab if gate.pending_count > 1 && !gate.confirmed => ReviewAction::SelectNext,
        KeyCode::BackTab if gate.pending_count > 1 && !gate.confirmed => ReviewAction::SelectPrev,
        KeyCode::Char('c')
            if !gate.has_pending_proposal && gate.has_visible_head && !gate.confirmed =>
        {
            ReviewAction::Confirm
        }
        KeyCode::Char('g') => ReviewAction::Refresh,
        _ => ReviewAction::Noop,
    }
}

fn push_list(out: &mut String, title: &str, values: &[String], none: &str) {
    out.push_str(&format!("### {title}\n"));
    if values.is_empty() {
        out.push_str(&format!("- {none}\n\n"));
    } else {
        for value in values {
            out.push_str("- ");
            out.push_str(value.trim());
            out.push('\n');
        }
        out.push('\n');
    }
}

fn yaml_values(values: &[crate::yaml::Value]) -> Vec<String> {
    values
        .iter()
        .map(|value| {
            crate::yaml::to_string(value)
                .unwrap_or_else(|_| format!("{value:?}"))
                .trim()
                .to_string()
        })
        .collect()
}

fn push_draft(out: &mut String, content: &PlanningDraftContent, l: &L) {
    let intent = &content.intent;
    out.push_str(&format!(
        "### {}\n\n{}\n\n",
        l.planning_goal, intent.summary
    ));
    push_list(
        out,
        l.planning_allowed_scope,
        &intent.allowed_scope,
        l.planning_none,
    );
    push_list(
        out,
        l.planning_out_of_scope,
        &intent.out_of_scope,
        l.planning_none,
    );
    push_list(
        out,
        l.planning_acceptance,
        &yaml_values(&intent.acceptance),
        l.planning_none,
    );
    push_list(
        out,
        l.planning_questions,
        &intent.open_questions,
        l.planning_none,
    );

    out.push_str(&format!("### {}\n", l.planning_tasks));
    for (index, task) in content.queue.tasks.iter().enumerate() {
        out.push_str(&format!("{}. {}  {}\n", index + 1, task.id, task.title));
        out.push_str(&format!(
            "   {}: {}\n",
            l.planning_dependencies,
            if task.depends_on.is_empty() {
                l.planning_none.to_string()
            } else {
                task.depends_on.join(", ")
            }
        ));
        if !task.allowed_scope.is_empty() {
            out.push_str(&format!(
                "   {}: {}\n",
                l.planning_allowed_scope,
                task.allowed_scope.join(", ")
            ));
        }
        if !task.acceptance.is_empty() {
            out.push_str(&format!(
                "   {}: {}\n",
                l.planning_acceptance,
                yaml_values(&task.acceptance).join("; ")
            ));
        }
    }
    out.push('\n');
}

fn json_text(value: &serde_json::Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
}

/// Render one pending proposal. When several are pending, `ordinal` carries the
/// 1-based position and total so the header reads `[k/n]`, and `is_target` adds
/// the accept/reject target marker to the header. For a single pending proposal
/// both are omitted so the original single-pending rendering is unchanged.
fn push_proposal(
    out: &mut String,
    proposal: &PlanningProposal,
    ordinal: Option<(usize, usize)>,
    is_target: bool,
    l: &L,
) {
    let header_suffix = match ordinal {
        Some((index, total)) => {
            let marker = if is_target {
                format!("  \u{25c0} {}", l.planning_target_marker)
            } else {
                String::new()
            };
            format!(" [{index}/{total}]{marker}")
        }
        None => String::new(),
    };
    out.push_str(&format!(
        "## {} {}{}\n\n{}: {}\n{}: {}\n{}: {}\n\n",
        l.planning_proposal,
        proposal.proposal_id,
        header_suffix,
        l.planning_attempt,
        proposal.attempt_id,
        l.planning_expected_head,
        proposal.expected_head.as_deref().unwrap_or(l.planning_none),
        l.planning_rationale,
        proposal.rationale
    ));
    push_draft(out, &proposal.content, l);
    out.push_str(&format!("### {}\n", l.planning_semantic_diff));
    if proposal.semantic_diff.is_empty() {
        out.push_str(&format!("- {}\n\n", l.planning_none));
    } else {
        for entry in &proposal.semantic_diff {
            out.push_str(&format!(
                "- {}\n  {}: {}\n  {}: {}\n",
                entry.field,
                l.planning_before,
                json_text(&entry.before),
                l.planning_after,
                json_text(&entry.after)
            ));
        }
        out.push('\n');
    }
}

pub(super) fn format_projection(projection: &PlanningProjection, target: usize, l: &L) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "{}: {}\n\n",
        l.planning_session, projection.session.session_id
    ));
    out.push_str(&format!("## {}\n", l.planning_conversation));
    for event in projection.events.iter().filter(|event| {
        matches!(
            event.event_type,
            PlanningEventType::UserMessage | PlanningEventType::WorkerMessage
        )
    }) {
        let actor = if event.event_type == PlanningEventType::UserMessage {
            l.conversation_user
        } else {
            l.conversation_worker
        };
        out.push_str(&format!("- {actor}: {}\n", event.message));
    }
    out.push('\n');
    out.push_str(&format!(
        "## {}\n\n{}\n\n",
        l.planning_visible_head,
        projection
            .session
            .current_head
            .as_deref()
            .unwrap_or(l.planning_none)
    ));
    out.push_str(&format!("## {}\n\n", l.planning_visible_draft));
    if let Some(draft) = &projection.current_draft {
        push_draft(&mut out, &draft.content, l);
    } else {
        out.push_str(l.planning_no_visible_draft);
        out.push_str("\n\n");
    }
    out.push_str(&format!("## {}\n\n", l.planning_pending_proposals));
    let pending = &projection.pending_proposals;
    match pending.len() {
        0 => {
            out.push_str(l.planning_no_pending_proposal);
            out.push('\n');
        }
        1 => push_proposal(&mut out, &pending[0], None, true, l),
        total => {
            // Clamp defensively: the caller tracks the target separately, so a
            // shrunk projection must never point past the end.
            let target = target.min(total - 1);
            out.push_str(&format!(
                "> {} ({}/{}) \u{00b7} {}\n\n",
                l.planning_multiple_pending,
                target + 1,
                total,
                l.planning_select_hint
            ));
            for (index, proposal) in pending.iter().enumerate() {
                push_proposal(
                    &mut out,
                    proposal,
                    Some((index + 1, total)),
                    index == target,
                    l,
                );
            }
        }
    }
    out.trim_end().to_string()
}

pub(super) fn record_revision_turn(
    ws: &crate::state::Workspace,
    message: &str,
    expected_head: Option<&str>,
    action_id: &str,
) -> anyhow::Result<(
    crate::schemas::PlanningSession,
    crate::schemas::PlanningTurnCas,
)> {
    crate::planning::record_answer_exact(ws, message, expected_head, action_id)
}

#[cfg(test)]
mod tests {
    use ratatui::crossterm::event::{KeyCode, KeyModifiers};

    use super::{
        action_for_key, action_for_key_with_enhancement, format_projection, ReviewAction,
        ReviewGate,
    };

    fn proposal_projection() -> (crate::state::Workspace, crate::planning::PlanningProjection) {
        use std::sync::atomic::{AtomicU64, Ordering};
        static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(1);
        let root = std::env::temp_dir().join(format!(
            "yard-ui-planning-review-format-{}-{}",
            std::process::id(),
            FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&root);
        let ws = crate::state::Workspace::at(&root);
        let (session, turn) =
            crate::planning::begin_new_planning_session_exact(&ws, "add searchable orders")
                .unwrap();
        let mut content: crate::schemas::PlanningDraftContent = crate::yaml::from_str(
            r#"
intent:
  schema_version: 1
  id: placeholder
  source: user
  raw_request: add searchable orders
  summary: Search orders
  allowed_scope: [src/orders.rs]
  out_of_scope: [src/payments.rs]
  acceptance: [orders can be searched]
  ambiguity: low
  open_questions: [Should archived orders be included?]
  status: accepted
queue:
  schema_version: 1
  queue_id: placeholder
  intent_id: placeholder
  tasks:
    - id: YARD-101
      title: Add search index
      state: queued
      allowed_scope: [src/orders.rs]
      acceptance: [index is queryable]
    - id: YARD-102
      title: Add order query
      state: queued
      depends_on: [YARD-101]
      allowed_scope: [src/query.rs]
      acceptance: [query returns matching orders]
"#,
        )
        .unwrap();
        content.intent.id = session.intent_id.clone();
        content.queue.intent_id = session.intent_id.clone();
        content.queue.queue_id = session.queue_id.clone();
        crate::planning::record_worker_proposal(
            &ws,
            &turn,
            "planner",
            "attempt-review-format",
            "I prepared the bounded plan.",
            "Keep payment changes out of this slice.",
            content,
        )
        .unwrap();
        let projection = crate::planning::projection(&ws).unwrap();
        (ws, projection)
    }

    fn second_proposal(
        ws: &crate::state::Workspace,
        first: &crate::planning::PlanningProjection,
        attempt: &str,
        summary: &str,
    ) {
        let request = first
            .events
            .iter()
            .find(|event| event.event_type == crate::schemas::PlanningEventType::UserMessage)
            .unwrap();
        let turn = crate::schemas::PlanningTurnCas {
            session_id: first.session.session_id.clone(),
            expected_head: first.session.current_head.clone(),
            request_event_id: request.event_id.clone(),
            request_digest: crate::planning::digest(request).unwrap(),
        };
        let mut content = first.pending_proposals[0].content.clone();
        content.intent.summary = summary.to_string();
        crate::planning::record_worker_proposal(
            ws,
            &turn,
            "planner",
            attempt,
            "A newer proposal is ready.",
            "Apply the requested revision.",
            content,
        )
        .unwrap();
    }

    #[test]
    fn review_keys_are_pure_and_keep_accept_separate_from_confirm() {
        let proposal = ReviewGate {
            busy: false,
            editing: false,
            has_pending_proposal: true,
            has_visible_head: false,
            confirmed: false,
            pending_count: 1,
        };
        assert_eq!(
            action_for_key(KeyCode::Char('a'), KeyModifiers::NONE, proposal),
            ReviewAction::Accept
        );
        // With a single pending proposal there is no ambiguity, so Tab is inert.
        assert_eq!(
            action_for_key(KeyCode::Tab, KeyModifiers::NONE, proposal),
            ReviewAction::Noop
        );
        assert_eq!(
            action_for_key(KeyCode::Char('c'), KeyModifiers::NONE, proposal),
            ReviewAction::Noop
        );

        let accepted = ReviewGate {
            has_pending_proposal: false,
            has_visible_head: true,
            ..proposal
        };
        assert_eq!(
            action_for_key(KeyCode::Char('c'), KeyModifiers::NONE, accepted),
            ReviewAction::Confirm
        );
        assert_eq!(
            action_for_key(KeyCode::Char('a'), KeyModifiers::NONE, accepted),
            ReviewAction::Noop
        );
    }

    #[test]
    fn review_keys_fail_closed_while_busy_and_confirmed() {
        let busy = ReviewGate {
            busy: true,
            editing: false,
            has_pending_proposal: true,
            has_visible_head: true,
            confirmed: false,
            pending_count: 2,
        };
        assert_eq!(
            action_for_key(KeyCode::Char('a'), KeyModifiers::NONE, busy),
            ReviewAction::Noop
        );
        assert_eq!(
            action_for_key(KeyCode::Char('e'), KeyModifiers::NONE, busy),
            ReviewAction::Noop
        );
        // Target selection also fails closed while a worker runs, even with
        // several pending proposals.
        assert_eq!(
            action_for_key(KeyCode::Tab, KeyModifiers::NONE, busy),
            ReviewAction::Noop
        );

        let confirmed = ReviewGate {
            busy: false,
            confirmed: true,
            ..busy
        };
        assert_eq!(
            action_for_key(KeyCode::Char('c'), KeyModifiers::NONE, confirmed),
            ReviewAction::Noop
        );
        // Once confirmed, the plan is settled; Tab must not offer selection.
        assert_eq!(
            action_for_key(KeyCode::Tab, KeyModifiers::NONE, confirmed),
            ReviewAction::Noop
        );
    }

    #[test]
    fn edit_mode_uses_terminal_independent_multiline_keys() {
        let editing = ReviewGate {
            busy: false,
            editing: true,
            has_pending_proposal: false,
            has_visible_head: true,
            confirmed: false,
            pending_count: 0,
        };
        assert_eq!(
            action_for_key(KeyCode::Enter, KeyModifiers::NONE, editing),
            ReviewAction::InsertNewline
        );
        assert_eq!(
            action_for_key(KeyCode::Enter, KeyModifiers::SHIFT, editing),
            ReviewAction::InsertNewline
        );
        assert_eq!(
            action_for_key(KeyCode::Char('s'), KeyModifiers::CONTROL, editing),
            ReviewAction::SubmitRevision
        );
        assert_eq!(
            action_for_key_with_enhancement(KeyCode::Enter, KeyModifiers::CONTROL, false, editing,),
            ReviewAction::InsertNewline
        );
        assert_eq!(
            action_for_key_with_enhancement(KeyCode::Enter, KeyModifiers::CONTROL, true, editing,),
            ReviewAction::SubmitRevision
        );
        assert_eq!(
            action_for_key(KeyCode::Esc, KeyModifiers::NONE, editing),
            ReviewAction::CancelEdit
        );
        assert_eq!(
            action_for_key(KeyCode::Char('a'), KeyModifiers::NONE, editing),
            ReviewAction::Insert('a')
        );
    }

    #[test]
    fn projection_text_contains_every_review_surface() {
        let (ws, projection) = proposal_projection();
        let l = crate::ui::i18n::Lang::En.l();
        let text = format_projection(&projection, 0, l);

        for expected in [
            "add searchable orders",
            "I prepared the bounded plan.",
            "attempt-review-format",
            "Visible head",
            "no accepted visible draft",
            "Search orders",
            "src/orders.rs",
            "src/payments.rs",
            "orders can be searched",
            "YARD-101",
            "YARD-102",
            "YARD-101",
            "Should archived orders be included?",
            "Semantic diff",
            "before",
            "after",
            "Keep payment changes out of this slice.",
        ] {
            assert!(text.contains(expected), "missing {expected:?} in:\n{text}");
        }
        // A single pending proposal is unambiguous: no target marker, no
        // ordinal, no multi-pending banner. This keeps the normal flow's
        // rendering byte-for-byte the same as before selection existed.
        assert!(!text.contains(l.planning_target_marker), "{text}");
        assert!(!text.contains(l.planning_multiple_pending), "{text}");
        assert!(!text.contains("[1/1]"), "{text}");

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn multiple_pending_marks_and_moves_the_accept_reject_target() {
        let (ws, first) = proposal_projection();
        second_proposal(&ws, &first, "attempt-second-target", "Newer search plan");
        let projection = crate::planning::projection(&ws).unwrap();
        assert_eq!(projection.pending_proposals.len(), 2);
        let l = crate::ui::i18n::Lang::En.l();
        let id0 = projection.pending_proposals[0].proposal_id.clone();
        let id1 = projection.pending_proposals[1].proposal_id.clone();
        let marker = l.planning_target_marker;

        // Both proposals are always listed with their position, and the
        // multi-pending banner names the current target.
        let at_first = format_projection(&projection, 0, l);
        assert!(at_first.contains(l.planning_multiple_pending), "{at_first}");
        assert!(
            at_first.contains(&id0) && at_first.contains(&id1),
            "{at_first}"
        );
        assert!(
            at_first.contains("[1/2]") && at_first.contains("[2/2]"),
            "{at_first}"
        );

        // Target index 0: the marker sits on the first proposal (before id1).
        let m0 = at_first.find(marker).expect("marker present");
        let p0 = at_first.find(&id0).unwrap();
        let p1 = at_first.find(&id1).unwrap();
        assert!(
            p0 < m0 && m0 < p1,
            "target 0 marks the first proposal\n{at_first}"
        );
        assert_eq!(at_first.matches(marker).count(), 1, "exactly one target");

        // Target index 1: the marker moves onto the second proposal.
        let at_second = format_projection(&projection, 1, l);
        let m1 = at_second.find(marker).expect("marker present");
        let p1b = at_second.find(&id1).unwrap();
        assert!(m1 > p1b, "target 1 marks the second proposal\n{at_second}");
        assert_eq!(at_second.matches(marker).count(), 1, "exactly one target");

        // An out-of-range target clamps to the last proposal instead of panicking.
        let clamped = format_projection(&projection, 99, l);
        let mc = clamped.find(marker).expect("marker present");
        assert!(
            mc > clamped.find(&id1).unwrap(),
            "clamped target marks the last\n{clamped}"
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn multiple_pending_offers_pure_target_selection_keys() {
        let two_pending = ReviewGate {
            busy: false,
            editing: false,
            has_pending_proposal: true,
            has_visible_head: false,
            confirmed: false,
            pending_count: 2,
        };
        assert_eq!(
            action_for_key(KeyCode::Tab, KeyModifiers::NONE, two_pending),
            ReviewAction::SelectNext
        );
        assert_eq!(
            action_for_key(KeyCode::BackTab, KeyModifiers::NONE, two_pending),
            ReviewAction::SelectPrev
        );
        // Accept/reject stay available alongside selection.
        assert_eq!(
            action_for_key(KeyCode::Char('a'), KeyModifiers::NONE, two_pending),
            ReviewAction::Accept
        );
        assert_eq!(
            action_for_key(KeyCode::Char('r'), KeyModifiers::NONE, two_pending),
            ReviewAction::Reject
        );
    }

    #[test]
    fn isolated_review_accepts_then_confirms_only_the_displayed_head() {
        let (ws, _) = proposal_projection();
        let before = ws.load_active_snapshot_texts().unwrap();
        let mut app = crate::ui::App::new(ws.clone());

        crate::ui::open_planning_review(&mut app);
        assert_eq!(app.screen, crate::ui::Screen::PlanningReview);
        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('a'), KeyModifiers::NONE);

        let accepted = app.planning_review.as_ref().unwrap();
        let displayed_head = accepted.session.current_head.clone().unwrap();
        let session_id = accepted.session.session_id.clone();
        assert!(accepted.pending_proposals.is_empty());
        assert_eq!(ws.load_active_snapshot_texts().unwrap(), before);
        assert!(app
            .toast
            .as_ref()
            .is_some_and(|(ok, message)| *ok && message.contains(&displayed_head)));

        let action_count = ws.load_planning_actions(&session_id).unwrap().len();
        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('a'), KeyModifiers::NONE);
        assert_eq!(
            ws.load_planning_actions(&session_id).unwrap().len(),
            action_count,
            "a duplicate accept key after refresh must be a no-op"
        );

        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('c'), KeyModifiers::NONE);
        let confirmed = app.planning_review.as_ref().unwrap();
        assert_eq!(
            confirmed.activation.as_ref().unwrap().draft_revision_id,
            displayed_head
        );
        assert!(confirmed.exact_active_parity);
        assert_eq!(ws.load_intent().unwrap().unwrap().summary, "Search orders");

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn isolated_review_surfaces_stale_head_without_changing_active_state() {
        let (ws, first) = proposal_projection();
        second_proposal(&ws, &first, "attempt-stale-second", "Newer search plan");
        let before = ws.load_active_snapshot_texts().unwrap();
        let mut app = crate::ui::App::new(ws.clone());
        crate::ui::open_planning_review(&mut app);
        let cached = app.planning_review.as_ref().unwrap().clone();
        let first_id = cached.pending_proposals[0].proposal_id.clone();
        crate::planning::accept_proposal(&ws, &first_id, None, "external-accept").unwrap();

        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('a'), KeyModifiers::NONE);

        assert_eq!(ws.load_active_snapshot_texts().unwrap(), before);
        assert!(app
            .toast
            .as_ref()
            .is_some_and(|(ok, message)| { !*ok && message.contains("stale_head") }));
        assert_ne!(
            app.planning_review.as_ref().unwrap().session.current_head,
            cached.session.current_head
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn isolated_review_selects_then_accepts_the_targeted_pending_proposal() {
        let (ws, first) = proposal_projection();
        second_proposal(&ws, &first, "attempt-second-accept", "Second search plan");
        let before = ws.load_active_snapshot_texts().unwrap();
        let mut app = crate::ui::App::new(ws.clone());
        crate::ui::open_planning_review(&mut app);

        // Two proposals pending; the newest is the default accept/reject target.
        let opened = app.planning_review.as_ref().unwrap();
        assert_eq!(opened.pending_proposals.len(), 2);
        assert_eq!(app.planning_review_target, 1);
        let older_id = opened.pending_proposals[0].proposal_id.clone();
        let newer_id = opened.pending_proposals[1].proposal_id.clone();

        // Tab cycles the target to the older proposal and the on-screen marker
        // follows it (older id, then marker, then newer id).
        crate::ui::handle_planning_review_key(&mut app, KeyCode::Tab, KeyModifiers::NONE);
        assert_eq!(app.planning_review_target, 0);
        let marker = app.lang.l().planning_target_marker;
        let text = app.planning_review_text.clone();
        let m = text.find(marker).expect("target marker rendered");
        assert!(
            text.find(&older_id).unwrap() < m && m < text.find(&newer_id).unwrap(),
            "marker should sit on the selected (older) proposal:\n{text}"
        );

        // Accept acts on the selected (older) proposal, not the latest one.
        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('a'), KeyModifiers::NONE);
        let after = app.planning_review.as_ref().unwrap();
        assert!(
            after
                .pending_proposals
                .iter()
                .all(|p| p.proposal_id != older_id),
            "the selected proposal was disposed"
        );
        assert!(
            after
                .pending_proposals
                .iter()
                .any(|p| p.proposal_id == newer_id),
            "the unselected proposal is still pending"
        );
        // Core CAS safety: accepting a proposal only moves the visible draft
        // head; the active intent/queue snapshot is never touched here.
        assert_eq!(ws.load_active_snapshot_texts().unwrap(), before);
        assert!(app.toast.as_ref().is_some_and(|(ok, _)| *ok));

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn isolated_review_rejects_only_the_selected_pending_proposal() {
        let (ws, first) = proposal_projection();
        second_proposal(&ws, &first, "attempt-second-reject", "Second search plan");
        let before = ws.load_active_snapshot_texts().unwrap();
        let mut app = crate::ui::App::new(ws.clone());
        crate::ui::open_planning_review(&mut app);

        let opened = app.planning_review.as_ref().unwrap();
        assert_eq!(opened.pending_proposals.len(), 2);
        let older_id = opened.pending_proposals[0].proposal_id.clone();
        let newer_id = opened.pending_proposals[1].proposal_id.clone();
        // Default target is the newest proposal; reject it and only it.
        assert_eq!(app.planning_review_target, 1);

        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('r'), KeyModifiers::NONE);
        let after = app.planning_review.as_ref().unwrap();
        assert!(
            after
                .pending_proposals
                .iter()
                .all(|p| p.proposal_id != newer_id),
            "the selected (newest) proposal was rejected"
        );
        assert!(
            after
                .pending_proposals
                .iter()
                .any(|p| p.proposal_id == older_id),
            "the unselected proposal survives the reject"
        );
        // Reject moves neither the visible head nor the active snapshot.
        assert!(after.session.current_head.is_none());
        assert_eq!(ws.load_active_snapshot_texts().unwrap(), before);

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn revision_turn_stays_in_session_and_leaves_active_state_unchanged() {
        let (ws, _) = proposal_projection();
        let proposal = crate::planning::projection(&ws).unwrap().pending_proposals[0].clone();
        let accepted = crate::planning::accept_proposal(
            &ws,
            &proposal.proposal_id,
            proposal.expected_head.as_deref(),
            "accept-before-revision",
        )
        .unwrap();
        let before = ws.load_active_snapshot_texts().unwrap();

        let (session, turn) = super::record_revision_turn(
            &ws,
            "keep the same goal but split the query task",
            Some(&accepted.draft_revision_id),
            "tui-revision-turn",
        )
        .unwrap();

        assert_eq!(session.session_id, proposal.session_id);
        assert_eq!(turn.session_id, proposal.session_id);
        assert_eq!(
            turn.expected_head.as_deref(),
            Some(accepted.draft_revision_id.as_str())
        );
        assert_eq!(ws.load_active_snapshot_texts().unwrap(), before);
        let mut revised_content = accepted.content.clone();
        revised_content.intent.summary = "Search orders with split query work".to_string();
        let revised = crate::planning::record_worker_proposal(
            &ws,
            &turn,
            "planner",
            "attempt-revision-turn",
            "I split the query work.",
            "Keep the revision in the current session.",
            revised_content,
        )
        .unwrap();
        assert_eq!(revised.session_id, proposal.session_id);
        assert_eq!(
            revised.expected_head.as_deref(),
            Some(accepted.draft_revision_id.as_str())
        );
        assert_eq!(ws.load_active_snapshot_texts().unwrap(), before);
        let revised_projection = crate::planning::projection(&ws).unwrap();
        assert_eq!(
            revised_projection.pending_proposals[0].proposal_id,
            revised.proposal_id
        );
        let messages = revised_projection
            .events
            .into_iter()
            .filter(|event| event.event_type == crate::schemas::PlanningEventType::UserMessage)
            .map(|event| event.message)
            .collect::<Vec<_>>();
        assert_eq!(
            messages.last().map(String::as_str),
            Some("keep the same goal but split the query task")
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn planning_job_completion_opens_review_before_queue_completion() {
        let (ws, _) = proposal_projection();
        let mut app = crate::ui::App::new(ws.clone());
        let opened = crate::ui::finish_background_job(
            &mut app,
            crate::ui::JobResult {
                ok: true,
                summary: "planning complete".to_string(),
            },
            true,
        );

        assert!(opened);
        assert_eq!(app.screen, crate::ui::Screen::PlanningReview);
        assert!(app
            .planning_review
            .as_ref()
            .is_some_and(|projection| !projection.pending_proposals.is_empty()));
        assert!(app
            .toast
            .as_ref()
            .is_some_and(|(ok, message)| *ok && message == "planning complete"));

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn isolated_review_rejects_without_moving_visible_or_active_heads() {
        let (ws, _) = proposal_projection();
        let active_before = ws.load_active_snapshot_texts().unwrap();
        let mut app = crate::ui::App::new(ws.clone());
        crate::ui::open_planning_review(&mut app);

        crate::ui::handle_planning_review_key(&mut app, KeyCode::Char('r'), KeyModifiers::NONE);

        let projection = app.planning_review.as_ref().unwrap();
        assert!(projection.pending_proposals.is_empty());
        assert!(projection.session.current_head.is_none());
        assert_eq!(ws.load_active_snapshot_texts().unwrap(), active_before);
        assert!(app
            .toast
            .as_ref()
            .is_some_and(|(ok, message)| *ok && message.contains("Proposal rejected")));

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn review_screen_renders_localized_chrome_and_original_plan_content() {
        use ratatui::backend::TestBackend;
        use ratatui::Terminal;

        let (ws, _) = proposal_projection();
        let mut app = crate::ui::App::new(ws.clone());
        app.lang = crate::ui::i18n::Lang::Ko;
        crate::ui::open_planning_review(&mut app);
        let backend = TestBackend::new(160, 38);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| crate::ui::view::render(frame, &mut app))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let output = (0..buffer.area.height)
            .map(|y| {
                (0..buffer.area.width)
                    .map(|x| buffer[(x, y)].symbol())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        // TestBackend exposes a trailing cell for each double-width Hangul
        // glyph as a space; compact only for localized chrome assertions.
        let compact = output.replace(' ', "");

        assert!(compact.contains("플랜검토"), "{output}");
        assert!(compact.contains("대화"));
        assert!(output.contains("add searchable orders"));
        assert!(output.contains("Search orders"));
        assert!(compact.contains("a수락"));
        assert!(!output.contains("Planning Review"));

        let _ = std::fs::remove_dir_all(ws.root);
    }
}
