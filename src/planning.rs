//! V010-002 conversational planning core.
//!
//! Workers author proposals. This module validates them and dispatches
//! surface-neutral actions. Every canonical write is delegated to `state.rs`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{anyhow, bail, Result};
use chrono::{Local, Utc};
use serde::Serialize;

use crate::schemas::{
    ActivatedIntent, ActivatedQueue, ActivatedTask, ActivationReceipt, DraftRevision,
    PlanningActionKind, PlanningActionReceipt, PlanningActionStatus, PlanningDraftContent,
    PlanningEvent, PlanningEventType, PlanningLifecycle, PlanningProposal, PlanningSession,
    SemanticDiffEntry, TaskState,
};
use crate::state::Workspace;

static ID_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Serialize)]
pub struct PlanningProjection {
    pub session: PlanningSession,
    pub current_draft: Option<DraftRevision>,
    pub pending_proposals: Vec<PlanningProposal>,
    pub events: Vec<PlanningEvent>,
    pub activation: Option<ActivationReceipt>,
    pub exact_active_parity: bool,
    pub channel_turn_count: usize,
    pub rejected_proposal_count: usize,
    pub undo_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActivationGate {
    Legacy,
    Confirmed,
}

fn new_id(prefix: &str) -> String {
    let counter = ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!(
        "{prefix}_{}_{:06}",
        Utc::now().format("%Y%m%d%H%M%S%9f"),
        counter
    )
}

#[derive(Default)]
struct EventFields<'a> {
    action_id: &'a str,
    action_request_digest: &'a str,
    message: &'a str,
    proposal_id: &'a str,
    draft_revision_id: &'a str,
    related_revision_id: &'a str,
}

fn maybe_crash(point: &str) {
    #[cfg(debug_assertions)]
    {
        if std::env::var("YARDLET_TEST_PLANNING_CRASH").as_deref() == Ok(point) {
            std::process::exit(86);
        }
    }
    #[cfg(not(debug_assertions))]
    let _ = point;
}

pub fn digest<T: Serialize>(value: &T) -> Result<String> {
    let bytes = serde_json::to_vec(value)?;
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    Ok(format!("fnv1a64:{hash:016x}"))
}

fn append_event(
    ws: &Workspace,
    session: &mut PlanningSession,
    event_type: PlanningEventType,
    actor: &str,
    fields: EventFields<'_>,
) -> Result<PlanningEvent> {
    reconcile_event_cursor(ws, session)?;
    let event = build_event(session, event_type, actor, fields);
    append_exact_event(ws, session, &event)?;
    Ok(event)
}

fn build_event(
    session: &PlanningSession,
    event_type: PlanningEventType,
    actor: &str,
    fields: EventFields<'_>,
) -> PlanningEvent {
    PlanningEvent {
        schema_version: 2,
        event_id: new_id("evt"),
        session_id: session.session_id.clone(),
        seq: session.next_seq,
        event_type,
        actor: actor.to_string(),
        action_id: fields.action_id.to_string(),
        action_request_digest: fields.action_request_digest.to_string(),
        message: fields.message.to_string(),
        proposal_id: fields.proposal_id.to_string(),
        draft_revision_id: fields.draft_revision_id.to_string(),
        related_revision_id: fields.related_revision_id.to_string(),
        recorded_at: Utc::now().to_rfc3339(),
    }
}

fn append_exact_event(
    ws: &Workspace,
    session: &mut PlanningSession,
    event: &PlanningEvent,
) -> Result<()> {
    let existing = ws
        .load_planning_events(&session.session_id)?
        .into_iter()
        .find(|candidate| candidate.event_id == event.event_id);
    if let Some(existing) = existing {
        if digest(&existing)? != digest(event)? {
            bail!("planning_event_journal: prepared exact event payload mismatch");
        }
        reconcile_event_cursor(ws, session)?;
        return Ok(());
    }
    reconcile_event_cursor(ws, session)?;
    if event.session_id != session.session_id || event.seq != session.next_seq {
        bail!("planning_event_journal: prepared event identity or sequence mismatch");
    }
    ws.save_planning_event(event)?;
    maybe_crash("after_event_write_before_next_seq");
    let previous = session.clone();
    session.next_seq += 1;
    ws.save_planning_session_cas(&previous, session)?;
    Ok(())
}

fn reconcile_event_cursor(ws: &Workspace, session: &mut PlanningSession) -> Result<()> {
    let next = ws
        .load_planning_events(&session.session_id)?
        .iter()
        .map(|event| event.seq)
        .max()
        .map_or(1, |seq| seq + 1);
    if session.next_seq < next {
        let previous = session.clone();
        session.next_seq = next;
        ws.save_planning_session_cas(&previous, session)?;
    }
    Ok(())
}

fn append_action_event_once(
    ws: &Workspace,
    session: &mut PlanningSession,
    event_type: PlanningEventType,
    actor: &str,
    fields: EventFields<'_>,
) -> Result<Option<PlanningEvent>> {
    reconcile_event_cursor(ws, session)?;
    if !fields.action_id.is_empty()
        && ws
            .load_planning_events(&session.session_id)?
            .iter()
            .any(|event| {
                event.event_type == event_type
                    && event.action_id == fields.action_id
                    && (fields.action_request_digest.is_empty()
                        || event.action_request_digest == fields.action_request_digest)
            })
    {
        return Ok(None);
    }
    append_event(ws, session, event_type, actor, fields).map(Some)
}

fn create_session_with_ids(
    ws: &Workspace,
    request: &str,
    intent_id: String,
    queue_id: String,
) -> Result<PlanningSession> {
    if let Some(latest) = ws.load_latest_planning_session()? {
        ensure_no_unresolved_action(ws, &latest.session_id, None)?;
    }
    let workspace_id = ws
        .load_config()
        .map(|config| config.workspace_id)
        .unwrap_or_else(|_| "legacy-workspace".to_string());
    let session_id = new_id("ses");
    let mut session = PlanningSession {
        schema_version: 1,
        session_id: session_id.clone(),
        workspace_id,
        lifecycle: PlanningLifecycle::Open,
        intent_id: intent_id.clone(),
        queue_id,
        initial_request: request.trim().to_string(),
        current_head: None,
        confirmation_id: None,
        next_seq: 1,
        created_at: Utc::now().to_rfc3339(),
    };
    ws.save_planning_session(&session)?;
    append_event(
        ws,
        &mut session,
        PlanningEventType::SessionOpened,
        "system",
        EventFields::default(),
    )?;
    if !request.trim().is_empty() {
        append_event(
            ws,
            &mut session,
            PlanningEventType::UserMessage,
            "user",
            EventFields {
                message: request.trim(),
                ..EventFields::default()
            },
        )?;
    }
    Ok(session)
}

fn create_session(ws: &Workspace, request: &str) -> Result<PlanningSession> {
    let intent_id = format!("intent-{}", Local::now().format("%Y%m%d-%H%M%S%6f"));
    let queue_id = format!("queue-{intent_id}");
    create_session_with_ids(ws, request, intent_id, queue_id)
}

pub fn begin_user_turn(ws: &Workspace, message: &str) -> Result<PlanningSession> {
    if message.trim().is_empty() {
        bail!("planning message must not be empty");
    }
    let _lock = ws.acquire_planning_lock()?;
    if let Some(latest) = ws.load_latest_planning_session()? {
        ensure_no_unresolved_action(ws, &latest.session_id, None)?;
    }
    let mut session = match ws.load_latest_planning_session()? {
        Some(session) if session.lifecycle == PlanningLifecycle::Open => session,
        _ => return create_session(ws, message),
    };
    append_event(
        ws,
        &mut session,
        PlanningEventType::UserMessage,
        "user",
        EventFields {
            message: message.trim(),
            ..EventFields::default()
        },
    )?;
    Ok(session)
}

pub fn latest_open_session(ws: &Workspace) -> Result<PlanningSession> {
    let session = ws
        .load_latest_planning_session()?
        .ok_or_else(|| anyhow!("no planning session; run `yardlet new \"...\"` first"))?;
    if session.lifecycle != PlanningLifecycle::Open {
        bail!(
            "planning session {} is {:?}; confirmed sessions reject free-form mutation",
            session.session_id,
            session.lifecycle
        );
    }
    Ok(session)
}

pub fn current_draft(ws: &Workspace, session: &PlanningSession) -> Result<Option<DraftRevision>> {
    session
        .current_head
        .as_deref()
        .map(|head| ws.load_draft_revision(&session.session_id, head))
        .transpose()
}

pub fn worker_turn_context(
    ws: &Workspace,
    session: &PlanningSession,
    latest_message: &str,
) -> Result<String> {
    let events = ws.load_planning_events(&session.session_id)?;
    let mut out = String::new();
    out.push_str("This is a turn in one conversational planning session.\n");
    out.push_str(&format!("Session: {}\n", session.session_id));
    out.push_str(&format!("Original request: {}\n", session.initial_request));
    if let Some(draft) = current_draft(ws, session)? {
        out.push_str("Current accepted visible draft:\n");
        out.push_str(&serde_json::to_string_pretty(&draft.content)?);
        out.push('\n');
    } else {
        out.push_str("Current accepted visible draft: none\n");
    }
    out.push_str("Visible planning channel:\n");
    for event in events.iter().filter(|event| {
        matches!(
            event.event_type,
            PlanningEventType::UserMessage | PlanningEventType::WorkerMessage
        )
    }) {
        out.push_str(&format!("- {}: {}\n", event.actor, event.message));
    }
    out.push_str("Latest user message:\n");
    out.push_str(latest_message.trim());
    out.push_str(
        "\nReturn a complete replacement proposal. Do not mutate active intent or queue state.\n",
    );
    Ok(out)
}

fn semantic_fields(content: Option<&PlanningDraftContent>) -> BTreeMap<String, serde_json::Value> {
    let mut fields = BTreeMap::new();
    let Some(content) = content else {
        return fields;
    };
    let intent = &content.intent;
    let queue = &content.queue;
    fields.insert("summary".into(), serde_json::json!(intent.summary));
    fields.insert(
        "allowed_scope".into(),
        serde_json::json!(intent.allowed_scope),
    );
    fields.insert(
        "out_of_scope".into(),
        serde_json::json!(intent.out_of_scope),
    );
    fields.insert("acceptance".into(), serde_json::json!(intent.acceptance));
    fields.insert(
        "ambiguity".into(),
        serde_json::json!({
            "score": intent.ambiguity,
            "open_questions": intent.open_questions,
        }),
    );
    fields.insert("tasks".into(), serde_json::json!(queue.tasks));
    fields.insert(
        "dependencies".into(),
        serde_json::json!(queue
            .tasks
            .iter()
            .map(|task| (&task.id, &task.depends_on))
            .collect::<BTreeMap<_, _>>()),
    );
    fields.insert(
        "routing".into(),
        serde_json::json!(queue
            .tasks
            .iter()
            .map(|task| {
                (
                    &task.id,
                    serde_json::json!({
                        "preferred_worker": task.preferred_worker,
                        "model": task.model,
                        "effort": task.effort,
                        "skills": task.skills,
                        "required_capabilities": task.required_capabilities,
                    }),
                )
            })
            .collect::<BTreeMap<_, _>>()),
    );
    fields.insert(
        "validation".into(),
        serde_json::json!(queue
            .tasks
            .iter()
            .map(|task| {
                (
                    &task.id,
                    serde_json::json!({"goal": task.goal, "validation": task.validation}),
                )
            })
            .collect::<BTreeMap<_, _>>()),
    );
    fields
}

fn semantic_diff(
    before: Option<&PlanningDraftContent>,
    after: &PlanningDraftContent,
) -> Vec<SemanticDiffEntry> {
    let before = semantic_fields(before);
    let after = semantic_fields(Some(after));
    let fields = [
        "summary",
        "allowed_scope",
        "out_of_scope",
        "acceptance",
        "ambiguity",
        "tasks",
        "dependencies",
        "routing",
        "validation",
    ];
    fields
        .iter()
        .filter_map(|field| {
            let old = before
                .get(*field)
                .cloned()
                .unwrap_or(serde_json::Value::Null);
            let new = after
                .get(*field)
                .cloned()
                .unwrap_or(serde_json::Value::Null);
            (old != new).then(|| SemanticDiffEntry {
                field: (*field).to_string(),
                before: old,
                after: new,
            })
        })
        .collect()
}

fn validate_draft(session: &PlanningSession, content: &PlanningDraftContent) -> Result<()> {
    if content.intent.id != session.intent_id {
        bail!("proposal intent id does not match planning session");
    }
    if content.queue.queue_id != session.queue_id || content.queue.intent_id != content.intent.id {
        bail!("proposal queue linkage does not match planning session intent");
    }
    if content.intent.summary.trim().is_empty() || content.queue.tasks.is_empty() {
        bail!("proposal requires a summary and at least one task");
    }
    let mut ids = BTreeSet::new();
    for task in &content.queue.tasks {
        if task.id.trim().is_empty() || !ids.insert(task.id.clone()) {
            bail!("proposal task ids must be non-empty and unique");
        }
        if matches!(task.state, TaskState::Running | TaskState::Done) {
            bail!("planning proposal cannot contain running or done tasks");
        }
        if task
            .depends_on
            .iter()
            .any(|dependency| !ids.contains(dependency))
        {
            bail!("proposal dependencies must reference earlier tasks");
        }
    }
    Ok(())
}

pub fn record_worker_proposal(
    ws: &Workspace,
    session_id: &str,
    worker_id: &str,
    attempt_id: &str,
    message: &str,
    rationale: &str,
    content: PlanningDraftContent,
) -> Result<PlanningProposal> {
    let _lock = ws.acquire_planning_lock()?;
    let mut session = ws.load_planning_session(session_id)?;
    ensure_no_unresolved_action(ws, &session.session_id, None)?;
    if session.lifecycle != PlanningLifecycle::Open {
        bail!("confirmed planning session rejects worker proposals");
    }
    validate_draft(&session, &content)?;
    let before = current_draft(ws, &session)?;
    let proposal = PlanningProposal {
        schema_version: 1,
        proposal_id: new_id("prp"),
        session_id: session.session_id.clone(),
        expected_head: session.current_head.clone(),
        producer_worker_id: worker_id.to_string(),
        attempt_id: attempt_id.to_string(),
        rationale: rationale.to_string(),
        content_digest: digest(&content)?,
        semantic_diff: semantic_diff(before.as_ref().map(|draft| &draft.content), &content),
        content,
    };
    ws.save_planning_proposal(&proposal)?;
    append_event(
        ws,
        &mut session,
        PlanningEventType::WorkerMessage,
        worker_id,
        EventFields {
            message,
            proposal_id: &proposal.proposal_id,
            ..EventFields::default()
        },
    )?;
    append_event(
        ws,
        &mut session,
        PlanningEventType::DraftProposed,
        worker_id,
        EventFields {
            message: rationale,
            proposal_id: &proposal.proposal_id,
            ..EventFields::default()
        },
    )?;
    Ok(proposal)
}

fn action_request_digest(
    action: PlanningActionKind,
    action_id: &str,
    expected_head: Option<&str>,
    target: &str,
) -> Result<String> {
    digest(&serde_json::json!({
        "action": action,
        "action_id": action_id,
        "expected_head": expected_head,
        "target": target,
    }))
}

fn action_name(action: PlanningActionKind) -> &'static str {
    match action {
        PlanningActionKind::Accept => "accept",
        PlanningActionKind::Reject => "reject",
        PlanningActionKind::Undo => "undo",
        PlanningActionKind::Answer => "answer",
        PlanningActionKind::Confirm => "confirm",
    }
}

fn ensure_no_unresolved_action(
    ws: &Workspace,
    session_id: &str,
    allowed_action_id: Option<&str>,
) -> Result<()> {
    if let Some(receipt) = ws
        .load_planning_actions(session_id)?
        .into_iter()
        .find(|receipt| {
            receipt.status == PlanningActionStatus::Prepared
                && allowed_action_id != Some(receipt.action_id.as_str())
        })
    {
        bail!(
            "planning_action_in_progress: session {} action {} is still prepared",
            session_id,
            receipt.action_id
        );
    }
    Ok(())
}

fn linked_action_event(
    ws: &Workspace,
    session_id: &str,
    action_id: &str,
    request_digest: &str,
    event_type: PlanningEventType,
) -> Result<Option<PlanningEvent>> {
    let matches = ws
        .load_planning_events(session_id)?
        .into_iter()
        .filter(|event| {
            event.event_type == event_type
                && event.action_id == action_id
                && event.action_request_digest == request_digest
        })
        .collect::<Vec<_>>();
    if matches.len() > 1 {
        bail!("planning_event_journal: action/type cardinality violation");
    }
    Ok(matches.into_iter().next())
}

fn validate_terminal_action_effect(ws: &Workspace, receipt: &PlanningActionReceipt) -> Result<()> {
    if receipt.schema_version < 2 {
        return Ok(());
    }
    let event_type = receipt
        .effect_event_type
        .ok_or_else(|| anyhow!("terminal action receipt effect type is missing"))?;
    let event = ws
        .load_planning_events(&receipt.session_id)?
        .into_iter()
        .find(|event| event.event_id == receipt.effect_event_id)
        .ok_or_else(|| anyhow!("terminal action receipt effect event is missing"))?;
    if event.event_type != event_type
        || event.action_id != receipt.action_id
        || event.action_request_digest != receipt.request_digest
    {
        bail!("terminal action receipt effect linkage mismatch");
    }
    if !receipt.effect_event_digest.is_empty() && digest(&event)? != receipt.effect_event_digest {
        bail!("terminal action receipt effect payload mismatch");
    }
    if let Some(expected) = &receipt.effect_event {
        if digest(expected)? != digest(&event)? {
            bail!("terminal action receipt exact effect payload mismatch");
        }
    }
    let valid_result = match receipt.status {
        PlanningActionStatus::Prepared => false,
        PlanningActionStatus::Rejected => event_type == PlanningEventType::ActionRejected,
        PlanningActionStatus::Completed => match receipt.action {
            PlanningActionKind::Accept => {
                matches!(
                    event_type,
                    PlanningEventType::DraftAccepted | PlanningEventType::DraftRevised
                ) && event.draft_revision_id == receipt.result_id
            }
            PlanningActionKind::Reject => {
                event_type == PlanningEventType::DraftRejected
                    && event.proposal_id == receipt.result_id
            }
            PlanningActionKind::Undo => {
                event_type == PlanningEventType::DraftUndo
                    && event.related_revision_id == receipt.result_id
            }
            PlanningActionKind::Answer => {
                event_type == PlanningEventType::UserMessage
                    && receipt.result_id == receipt.session_id
            }
            PlanningActionKind::Confirm => {
                event_type == PlanningEventType::DraftConfirmed
                    && event.related_revision_id == receipt.result_id
            }
        },
    };
    if !valid_result {
        bail!("terminal action receipt effect result mismatch");
    }
    Ok(())
}

fn begin_action(
    ws: &Workspace,
    session: &mut PlanningSession,
    action: PlanningActionKind,
    action_id: &str,
    expected_head: Option<&str>,
    target: &str,
) -> Result<(PlanningActionReceipt, bool)> {
    if action_id.trim().is_empty() {
        bail!("action_id must not be empty");
    }
    ensure_no_unresolved_action(ws, &session.session_id, Some(action_id))?;
    let request_digest = action_request_digest(action, action_id, expected_head, target)?;
    if let Some(existing) = ws.load_planning_action(&session.session_id, action_id)? {
        if existing.request_digest != request_digest {
            bail!("idempotency_conflict for action {action_id}");
        }
        match existing.status {
            PlanningActionStatus::Completed => {
                validate_terminal_action_effect(ws, &existing)?;
                append_action_event_once(
                    ws,
                    session,
                    PlanningEventType::ActionCompleted,
                    "system",
                    EventFields {
                        action_id,
                        action_request_digest: &existing.request_digest,
                        draft_revision_id: &existing.result_id,
                        ..EventFields::default()
                    },
                )?;
                return Ok((existing, true));
            }
            PlanningActionStatus::Rejected => {
                validate_terminal_action_effect(ws, &existing)?;
                append_action_event_once(
                    ws,
                    session,
                    PlanningEventType::ActionRejected,
                    "system",
                    EventFields {
                        action_id,
                        action_request_digest: &existing.request_digest,
                        message: &existing.error,
                        ..EventFields::default()
                    },
                )?;
                bail!(
                    "action_previously_rejected: {}",
                    if existing.error.is_empty() {
                        "unspecified rejection"
                    } else {
                        &existing.error
                    }
                );
            }
            PlanningActionStatus::Prepared => {
                append_action_event_once(
                    ws,
                    session,
                    PlanningEventType::ActionRequested,
                    "user",
                    EventFields {
                        action_id,
                        action_request_digest: &existing.request_digest,
                        message: action_name(action),
                        ..EventFields::default()
                    },
                )?;
                return Ok((existing, false));
            }
        }
    }
    let (prior_intent, prior_queue) = ws.load_active_snapshot_texts()?;
    let receipt = PlanningActionReceipt {
        schema_version: 2,
        action_id: action_id.to_string(),
        session_id: session.session_id.clone(),
        action,
        request_digest,
        status: PlanningActionStatus::Prepared,
        result_id: String::new(),
        error: String::new(),
        effect_event_id: String::new(),
        effect_event_type: None,
        effect_event_digest: String::new(),
        effect_event: None,
        prior_intent_digest: digest(&prior_intent)?,
        prior_queue_digest: digest(&prior_queue)?,
    };
    ws.create_planning_action(&receipt)?;
    append_action_event_once(
        ws,
        session,
        PlanningEventType::ActionRequested,
        "user",
        EventFields {
            action_id,
            action_request_digest: &receipt.request_digest,
            message: action_name(action),
            ..EventFields::default()
        },
    )?;
    Ok((receipt, false))
}

fn reject_action(
    ws: &Workspace,
    session: &mut PlanningSession,
    mut receipt: PlanningActionReceipt,
    reason: &str,
) -> Result<anyhow::Error> {
    let conflicting_effect = ws
        .load_planning_events(&receipt.session_id)?
        .into_iter()
        .any(|event| {
            event.action_id == receipt.action_id
                && !matches!(
                    event.event_type,
                    PlanningEventType::ActionRequested | PlanningEventType::ActionRejected
                )
        });
    if conflicting_effect {
        bail!("planning_action_effect_conflict: prepared action already has an accepted effect");
    }
    let effect = append_action_event_once(
        ws,
        session,
        PlanningEventType::ActionRejected,
        "system",
        EventFields {
            action_id: &receipt.action_id,
            action_request_digest: &receipt.request_digest,
            message: reason,
            ..EventFields::default()
        },
    )?
    .or(linked_action_event(
        ws,
        &receipt.session_id,
        &receipt.action_id,
        &receipt.request_digest,
        PlanningEventType::ActionRejected,
    )?)
    .ok_or_else(|| anyhow!("rejected action effect event is missing"))?;
    maybe_crash("action_after_rejected_effect");
    let previous = receipt.clone();
    receipt.status = PlanningActionStatus::Rejected;
    receipt.error = reason.to_string();
    receipt.effect_event_id = effect.event_id.clone();
    receipt.effect_event_type = Some(effect.event_type);
    receipt.effect_event_digest = digest(&effect)?;
    receipt.effect_event = Some(effect);
    ws.save_planning_action_cas(&previous, &receipt)?;
    Ok(anyhow!(reason.to_string()))
}

fn complete_action(
    ws: &Workspace,
    session: &mut PlanningSession,
    mut receipt: PlanningActionReceipt,
    result_id: &str,
    effect: &PlanningEvent,
) -> Result<PlanningActionReceipt> {
    if effect.action_id != receipt.action_id
        || effect.action_request_digest != receipt.request_digest
    {
        bail!("action effect linkage mismatch");
    }
    let previous = receipt.clone();
    receipt.status = PlanningActionStatus::Completed;
    receipt.result_id = result_id.to_string();
    receipt.error.clear();
    receipt.effect_event_id = effect.event_id.clone();
    receipt.effect_event_type = Some(effect.event_type);
    receipt.effect_event_digest = digest(effect)?;
    receipt.effect_event = Some(effect.clone());
    ws.save_planning_action_cas(&previous, &receipt)?;
    append_action_event_once(
        ws,
        session,
        PlanningEventType::ActionCompleted,
        "system",
        EventFields {
            action_id: &receipt.action_id,
            action_request_digest: &receipt.request_digest,
            draft_revision_id: result_id,
            ..EventFields::default()
        },
    )?;
    Ok(receipt)
}

fn prepare_action_effect(
    ws: &Workspace,
    mut receipt: PlanningActionReceipt,
    result_id: &str,
    effect: &PlanningEvent,
) -> Result<PlanningActionReceipt> {
    let effect_digest = digest(effect)?;
    if receipt.result_id.is_empty()
        && receipt.effect_event_id.is_empty()
        && receipt.effect_event_type.is_none()
        && receipt.effect_event_digest.is_empty()
        && receipt.effect_event.is_none()
    {
        let previous = receipt.clone();
        receipt.result_id = result_id.to_string();
        receipt.effect_event_id = effect.event_id.clone();
        receipt.effect_event_type = Some(effect.event_type);
        receipt.effect_event_digest = effect_digest;
        receipt.effect_event = Some(effect.clone());
        ws.save_planning_action_cas(&previous, &receipt)?;
        return Ok(receipt);
    }
    if receipt.result_id != result_id
        || receipt.effect_event_id != effect.event_id
        || receipt.effect_event_type != Some(effect.event_type)
        || receipt.effect_event_digest != effect_digest
        || receipt
            .effect_event
            .as_ref()
            .is_none_or(|expected| digest(expected).ok().as_ref() != Some(&effect_digest))
    {
        bail!("prepared action exact effect metadata mismatch");
    }
    Ok(receipt)
}

fn expected_head_matches(session: &PlanningSession, expected_head: Option<&str>) -> bool {
    session.current_head.as_deref() == expected_head
}

fn proposal_disposition(
    ws: &Workspace,
    session: &PlanningSession,
    proposal_id: &str,
) -> Result<Option<&'static str>> {
    Ok(ws
        .load_planning_events(&session.session_id)?
        .iter()
        .find_map(|event| {
            if event.proposal_id != proposal_id {
                return None;
            }
            match event.event_type {
                PlanningEventType::DraftAccepted | PlanningEventType::DraftRevised => {
                    Some("accepted")
                }
                PlanningEventType::DraftRejected => Some("rejected"),
                _ => None,
            }
        }))
}

fn validate_revision_integrity(
    session: &PlanningSession,
    revision: &DraftRevision,
    expected_revision_id: &str,
) -> Result<()> {
    if revision.session_id != session.session_id
        || revision.draft_revision_id != expected_revision_id
    {
        bail!("revision identity does not match its same-session path");
    }
    validate_draft(session, &revision.content)?;
    if digest(&revision.content)? != revision.content_digest {
        bail!("revision content digest mismatch");
    }
    Ok(())
}

fn validate_undo_linkage(
    ws: &Workspace,
    session: &PlanningSession,
    revision: &DraftRevision,
) -> Result<Option<String>> {
    validate_revision_integrity(session, revision, &revision.draft_revision_id)?;
    let parent_id = revision.parent_revision_id.clone();
    if parent_id.as_deref() == Some(revision.draft_revision_id.as_str()) {
        bail!("revision cannot be its own parent");
    }
    if let Some(parent_id) = parent_id.as_deref() {
        let parent = ws
            .load_draft_revision(&session.session_id, parent_id)
            .map_err(|_| anyhow!("parent revision is missing"))?;
        validate_revision_integrity(session, &parent, parent_id)
            .map_err(|error| anyhow!("parent revision is inconsistent: {error}"))?;
    }
    let linked = ws
        .load_planning_events(&session.session_id)?
        .iter()
        .any(|event| {
            matches!(
                event.event_type,
                PlanningEventType::DraftAccepted | PlanningEventType::DraftRevised
            ) && event.draft_revision_id == revision.draft_revision_id
                && event.proposal_id == revision.proposal_id
                && event.related_revision_id == parent_id.as_deref().unwrap_or("")
        });
    if !linked {
        bail!("revision parent does not match its accepted event");
    }
    Ok(parent_id)
}

pub fn accept_proposal(
    ws: &Workspace,
    proposal_id: &str,
    expected_head: Option<&str>,
    action_id: &str,
) -> Result<DraftRevision> {
    let _lock = ws.acquire_planning_lock()?;
    let mut session = latest_open_session(ws)?;
    let (mut receipt, completed) = begin_action(
        ws,
        &mut session,
        PlanningActionKind::Accept,
        action_id,
        expected_head,
        proposal_id,
    )?;
    if completed {
        return ws.load_draft_revision(&session.session_id, &receipt.result_id);
    }
    if !receipt.result_id.is_empty() {
        let effect = receipt
            .effect_event
            .clone()
            .ok_or_else(|| anyhow!("prepared accept exact effect payload is missing"))?;
        if effect.event_id != receipt.effect_event_id
            || effect.event_type != receipt.effect_event_type.unwrap_or(effect.event_type)
            || effect.action_id != receipt.action_id
            || effect.action_request_digest != receipt.request_digest
            || effect.proposal_id != proposal_id
            || effect.draft_revision_id != receipt.result_id
            || effect.related_revision_id != expected_head.unwrap_or("")
        {
            bail!("prepared accept effect linkage mismatch");
        }
        let revision = if ws
            .draft_revision_path(&session.session_id, &receipt.result_id)
            .is_file()
        {
            ws.load_draft_revision(&session.session_id, &receipt.result_id)?
        } else {
            let proposal = ws.load_planning_proposal(&session.session_id, proposal_id)?;
            DraftRevision {
                schema_version: 1,
                draft_revision_id: receipt.result_id.clone(),
                session_id: session.session_id.clone(),
                proposal_id: proposal.proposal_id,
                parent_revision_id: expected_head.map(str::to_string),
                content_digest: proposal.content_digest,
                content: proposal.content,
            }
        };
        validate_revision_integrity(&session, &revision, &receipt.result_id)?;
        ws.save_draft_revision(&revision)?;
        maybe_crash("accept_after_revision_write");
        append_exact_event(ws, &mut session, &effect)?;
        if session.current_head.as_deref() == expected_head {
            let previous = session.clone();
            session.current_head = Some(revision.draft_revision_id.clone());
            ws.save_planning_session_cas(&previous, &session)?;
        } else if session.current_head.as_deref() != Some(revision.draft_revision_id.as_str()) {
            bail!("prepared accept effect conflicts with current head");
        }
        complete_action(
            ws,
            &mut session,
            receipt,
            &revision.draft_revision_id,
            &effect,
        )?;
        return Ok(revision);
    }
    if !expected_head_matches(&session, expected_head) {
        return Err(reject_action(ws, &mut session, receipt, "stale_head")?);
    }
    if let Some(disposition) = proposal_disposition(ws, &session, proposal_id)? {
        return Err(reject_action(
            ws,
            &mut session,
            receipt,
            &format!("proposal_already_disposed: {disposition}"),
        )?);
    }
    let proposal = ws.load_planning_proposal(&session.session_id, proposal_id)?;
    if proposal.expected_head.as_deref() != expected_head {
        return Err(reject_action(
            ws,
            &mut session,
            receipt,
            "stale_head: proposal was authored against another head",
        )?);
    }
    validate_draft(&session, &proposal.content)?;
    if digest(&proposal.content)? != proposal.content_digest {
        return Err(reject_action(
            ws,
            &mut session,
            receipt,
            "proposal_digest_mismatch",
        )?);
    }
    let revision_id = new_id("drv");
    reconcile_event_cursor(ws, &mut session)?;
    let effect_type = if expected_head.is_some() {
        PlanningEventType::DraftRevised
    } else {
        PlanningEventType::DraftAccepted
    };
    let effect = build_event(
        &session,
        effect_type,
        "user",
        EventFields {
            action_id,
            action_request_digest: &receipt.request_digest,
            proposal_id,
            draft_revision_id: &revision_id,
            related_revision_id: expected_head.unwrap_or(""),
            ..EventFields::default()
        },
    );
    receipt = prepare_action_effect(ws, receipt, &revision_id, &effect)?;
    let revision = DraftRevision {
        schema_version: 1,
        draft_revision_id: revision_id,
        session_id: session.session_id.clone(),
        proposal_id: proposal.proposal_id.clone(),
        parent_revision_id: expected_head.map(str::to_string),
        content_digest: proposal.content_digest.clone(),
        content: proposal.content,
    };
    ws.save_draft_revision(&revision)?;
    maybe_crash("accept_after_revision_write");
    append_exact_event(ws, &mut session, &effect)?;
    maybe_crash("action_after_effect");
    let previous = session.clone();
    session.current_head = Some(revision.draft_revision_id.clone());
    ws.save_planning_session_cas(&previous, &session)?;
    complete_action(
        ws,
        &mut session,
        receipt,
        &revision.draft_revision_id,
        &effect,
    )?;
    Ok(revision)
}

pub fn reject_proposal(
    ws: &Workspace,
    proposal_id: &str,
    expected_head: Option<&str>,
    action_id: &str,
) -> Result<()> {
    let _lock = ws.acquire_planning_lock()?;
    let mut session = latest_open_session(ws)?;
    let (receipt, completed) = begin_action(
        ws,
        &mut session,
        PlanningActionKind::Reject,
        action_id,
        expected_head,
        proposal_id,
    )?;
    if completed {
        return Ok(());
    }
    if let Some(effect) = linked_action_event(
        ws,
        &session.session_id,
        action_id,
        &receipt.request_digest,
        PlanningEventType::DraftRejected,
    )? {
        if effect.proposal_id != proposal_id
            || effect.related_revision_id != expected_head.unwrap_or("")
        {
            return Err(reject_action(
                ws,
                &mut session,
                receipt,
                "prepared reject effect linkage mismatch",
            )?);
        }
        complete_action(ws, &mut session, receipt, proposal_id, &effect)?;
        return Ok(());
    }
    if !expected_head_matches(&session, expected_head) {
        return Err(reject_action(ws, &mut session, receipt, "stale_head")?);
    }
    if let Some(disposition) = proposal_disposition(ws, &session, proposal_id)? {
        return Err(reject_action(
            ws,
            &mut session,
            receipt,
            &format!("proposal_already_disposed: {disposition}"),
        )?);
    }
    let proposal = ws.load_planning_proposal(&session.session_id, proposal_id)?;
    if proposal.expected_head.as_deref() != expected_head {
        return Err(reject_action(
            ws,
            &mut session,
            receipt,
            "stale_head: proposal was authored against another head",
        )?);
    }
    let effect = append_event(
        ws,
        &mut session,
        PlanningEventType::DraftRejected,
        "user",
        EventFields {
            action_id,
            action_request_digest: &receipt.request_digest,
            proposal_id,
            related_revision_id: expected_head.unwrap_or(""),
            ..EventFields::default()
        },
    )?;
    maybe_crash("action_after_effect");
    complete_action(ws, &mut session, receipt, proposal_id, &effect)?;
    Ok(())
}

pub fn undo(ws: &Workspace, expected_head: &str, action_id: &str) -> Result<Option<String>> {
    let _lock = ws.acquire_planning_lock()?;
    let mut session = latest_open_session(ws)?;
    let (receipt, completed) = begin_action(
        ws,
        &mut session,
        PlanningActionKind::Undo,
        action_id,
        Some(expected_head),
        expected_head,
    )?;
    if completed {
        return Ok((!receipt.result_id.is_empty()).then_some(receipt.result_id));
    }
    if let Some(effect) = linked_action_event(
        ws,
        &session.session_id,
        action_id,
        &receipt.request_digest,
        PlanningEventType::DraftUndo,
    )? {
        if effect.draft_revision_id != expected_head {
            return Err(reject_action(
                ws,
                &mut session,
                receipt,
                "prepared undo effect linkage mismatch",
            )?);
        }
        let parent =
            (!effect.related_revision_id.is_empty()).then_some(effect.related_revision_id.clone());
        if session.current_head.as_deref() == Some(expected_head) {
            let previous = session.clone();
            session.current_head = parent.clone();
            ws.save_planning_session_cas(&previous, &session)?;
        } else if session.current_head != parent {
            return Err(reject_action(
                ws,
                &mut session,
                receipt,
                "prepared undo effect conflicts with current head",
            )?);
        }
        complete_action(
            ws,
            &mut session,
            receipt,
            parent.as_deref().unwrap_or(""),
            &effect,
        )?;
        return Ok(parent);
    }
    if !expected_head_matches(&session, Some(expected_head)) {
        return Err(reject_action(ws, &mut session, receipt, "stale_head")?);
    }
    let revision = match ws.load_draft_revision(&session.session_id, expected_head) {
        Ok(revision) => revision,
        Err(_) => {
            return Err(reject_action(
                ws,
                &mut session,
                receipt,
                "undo_integrity: current revision is missing",
            )?)
        }
    };
    let parent = match validate_undo_linkage(ws, &session, &revision) {
        Ok(parent) => parent,
        Err(error) => {
            return Err(reject_action(
                ws,
                &mut session,
                receipt,
                &format!("undo_integrity: {error}"),
            )?)
        }
    };
    let effect = append_event(
        ws,
        &mut session,
        PlanningEventType::DraftUndo,
        "user",
        EventFields {
            action_id,
            action_request_digest: &receipt.request_digest,
            draft_revision_id: expected_head,
            related_revision_id: parent.as_deref().unwrap_or(""),
            ..EventFields::default()
        },
    )?;
    maybe_crash("action_after_effect");
    let previous = session.clone();
    session.current_head = parent.clone();
    ws.save_planning_session_cas(&previous, &session)?;
    complete_action(
        ws,
        &mut session,
        receipt,
        parent.as_deref().unwrap_or(""),
        &effect,
    )?;
    Ok(parent)
}

pub fn record_answer(
    ws: &Workspace,
    message: &str,
    expected_head: Option<&str>,
    action_id: &str,
) -> Result<PlanningSession> {
    if message.trim().is_empty() {
        bail!("planning answer must not be empty");
    }
    let _lock = ws.acquire_planning_lock()?;
    let mut session = latest_open_session(ws)?;
    let (receipt, completed) = begin_action(
        ws,
        &mut session,
        PlanningActionKind::Answer,
        action_id,
        expected_head,
        message.trim(),
    )?;
    if completed {
        return Ok(session);
    }
    if let Some(effect) = linked_action_event(
        ws,
        &session.session_id,
        action_id,
        &receipt.request_digest,
        PlanningEventType::UserMessage,
    )? {
        if effect.message != message.trim()
            || effect.related_revision_id != expected_head.unwrap_or("")
        {
            return Err(reject_action(
                ws,
                &mut session,
                receipt,
                "prepared answer effect linkage mismatch",
            )?);
        }
        let session_id = session.session_id.clone();
        complete_action(ws, &mut session, receipt, &session_id, &effect)?;
        return Ok(session);
    }
    if !expected_head_matches(&session, expected_head) {
        return Err(reject_action(ws, &mut session, receipt, "stale_head")?);
    }
    let effect = append_event(
        ws,
        &mut session,
        PlanningEventType::UserMessage,
        "user",
        EventFields {
            action_id,
            action_request_digest: &receipt.request_digest,
            message: message.trim(),
            related_revision_id: expected_head.unwrap_or(""),
            ..EventFields::default()
        },
    )?;
    maybe_crash("action_after_effect");
    let session_id = session.session_id.clone();
    complete_action(ws, &mut session, receipt, &session_id, &effect)?;
    Ok(session)
}

fn activated_records(
    session: &PlanningSession,
    revision: &DraftRevision,
    confirmation_id: &str,
) -> Result<(ActivatedIntent, ActivatedQueue)> {
    let intent = ActivatedIntent {
        intent: revision.content.intent.clone(),
        activation_required: true,
        planning_session_id: session.session_id.clone(),
        confirmation_id: confirmation_id.to_string(),
        draft_revision_id: revision.draft_revision_id.clone(),
        draft_content_digest: revision.content_digest.clone(),
    };
    let queue = ActivatedQueue {
        schema_version: revision.content.queue.schema_version,
        queue_id: revision.content.queue.queue_id.clone(),
        intent_id: revision.content.queue.intent_id.clone(),
        activation_required: true,
        selection_policy: revision.content.queue.selection_policy.clone(),
        tasks: revision
            .content
            .queue
            .tasks
            .iter()
            .cloned()
            .map(|task| ActivatedTask {
                task,
                materialized_by_confirmation_id: confirmation_id.to_string(),
            })
            .collect(),
        planning_session_id: session.session_id.clone(),
        confirmation_id: confirmation_id.to_string(),
        draft_revision_id: revision.draft_revision_id.clone(),
        draft_content_digest: revision.content_digest.clone(),
        materialized_queue: Some(revision.content.queue.clone()),
    };
    Ok((intent, queue))
}

fn activated_queue_digest(queue: &ActivatedQueue) -> Result<String> {
    if let Some(materialized_queue) = &queue.materialized_queue {
        return digest(&serde_json::json!({
            "schema_version": queue.schema_version,
            "queue_id": queue.queue_id,
            "intent_id": queue.intent_id,
            "activation_required": queue.activation_required,
            "planning_session_id": queue.planning_session_id,
            "confirmation_id": queue.confirmation_id,
            "draft_revision_id": queue.draft_revision_id,
            "draft_content_digest": queue.draft_content_digest,
            "materialized_queue": materialized_queue,
        }));
    }
    digest(queue)
}

pub fn confirm(ws: &Workspace, expected_head: &str, action_id: &str) -> Result<ActivationReceipt> {
    confirm_with_policy(ws, expected_head, action_id, true)
}

fn confirm_express(
    ws: &Workspace,
    expected_head: &str,
    action_id: &str,
) -> Result<ActivationReceipt> {
    confirm_with_policy(ws, expected_head, action_id, false)
}

fn confirm_with_policy(
    ws: &Workspace,
    expected_head: &str,
    action_id: &str,
    protect_unfinished_active_queue: bool,
) -> Result<ActivationReceipt> {
    let _lock = ws.acquire_planning_lock()?;
    let mut session = ws
        .load_latest_planning_session()?
        .ok_or_else(|| anyhow!("no planning session; run `yardlet new \"...\"` first"))?;
    let requested_digest = action_request_digest(
        PlanningActionKind::Confirm,
        action_id,
        Some(expected_head),
        expected_head,
    )?;
    let prepared_replay = ws
        .load_planning_action(&session.session_id, action_id)?
        .is_some_and(|receipt| {
            receipt.action == PlanningActionKind::Confirm
                && receipt.status == PlanningActionStatus::Prepared
                && receipt.request_digest == requested_digest
        });
    if !prepared_replay {
        // A new confirmation may only inspect a valid active snapshot. A
        // corrupt guard is an error, never a reason to archive and overwrite.
        validate_active_activation(ws)?;
    }
    let (mut action, completed) = begin_action(
        ws,
        &mut session,
        PlanningActionKind::Confirm,
        action_id,
        Some(expected_head),
        expected_head,
    )?;
    if completed {
        let activation = ws
            .load_activation(&action.result_id)?
            .ok_or_else(|| anyhow!("completed confirmation is missing its activation"))?;
        validate_active_activation(ws)?;
        let active_intent = ws.load_activated_intent()?.ok_or_else(|| {
            anyhow!("completed_confirmation_active_mismatch: active intent missing")
        })?;
        let active_queue = ws.load_activated_queue()?.ok_or_else(|| {
            anyhow!("completed_confirmation_active_mismatch: active queue missing")
        })?;
        if active_intent.confirmation_id != activation.confirmation_id
            || active_queue.confirmation_id != activation.confirmation_id
            || active_intent.planning_session_id != activation.session_id
            || active_queue.planning_session_id != activation.session_id
            || active_intent.draft_revision_id != activation.draft_revision_id
            || active_queue.draft_revision_id != activation.draft_revision_id
            || active_intent.draft_content_digest != activation.draft_content_digest
            || active_queue.draft_content_digest != activation.draft_content_digest
            || digest(&active_intent)? != activation.intent_digest
            || activated_queue_digest(&active_queue)? != activation.queue_digest
        {
            bail!(
                "completed_confirmation_active_mismatch: receipt activation is not the current active plan"
            );
        }
        return Ok(activation);
    }
    if !matches!(
        session.lifecycle,
        PlanningLifecycle::Open | PlanningLifecycle::Confirmed
    ) {
        return Err(reject_action(
            ws,
            &mut session,
            action,
            "confirmed planning session rejects mutation",
        )?);
    }
    if session.lifecycle == PlanningLifecycle::Confirmed
        && (action.result_id.is_empty()
            || session.confirmation_id.as_deref() != Some(action.result_id.as_str()))
    {
        return Err(reject_action(
            ws,
            &mut session,
            action,
            "confirmed session does not match the interrupted confirmation",
        )?);
    }
    if !expected_head_matches(&session, Some(expected_head)) {
        return Err(reject_action(ws, &mut session, action, "stale_head")?);
    }
    let active_queue = ws.load_queue()?;
    if active_queue.tasks.iter().any(|task| {
        task.state == TaskState::Running
            || (protect_unfinished_active_queue
                && matches!(
                    task.state,
                    TaskState::Queued
                        | TaskState::NeedsUser
                        | TaskState::Partial
                        | TaskState::Blocked
                ))
    }) && !prepared_replay
    {
        return Err(reject_action(
            ws,
            &mut session,
            action,
            "active_queue_not_drained: running_queue_isolated",
        )?);
    }
    let revision = match ws.load_draft_revision(&session.session_id, expected_head) {
        Ok(revision) => revision,
        Err(_) => {
            return Err(reject_action(
                ws,
                &mut session,
                action,
                "confirmed draft revision is missing",
            )?)
        }
    };
    if let Err(error) = validate_revision_integrity(&session, &revision, expected_head) {
        return Err(reject_action(
            ws,
            &mut session,
            action,
            &format!("draft_integrity: {error}"),
        )?);
    }
    let first_attempt = action.result_id.is_empty();
    let confirmation_id = if first_attempt {
        let id = new_id("cnf");
        let previous = action.clone();
        action.result_id = id.clone();
        ws.save_planning_action_cas(&previous, &action)?;
        id
    } else {
        action.result_id.clone()
    };
    append_action_event_once(
        ws,
        &mut session,
        PlanningEventType::DraftConfirmPrepared,
        "user",
        EventFields {
            action_id,
            action_request_digest: &action.request_digest,
            draft_revision_id: expected_head,
            ..EventFields::default()
        },
    )?;
    maybe_crash("confirm_after_prepare");
    ws.require_confirmed_activation()?;
    let (intent, queue) = activated_records(&session, &revision, &confirmation_id)?;
    let activation = ActivationReceipt {
        schema_version: 1,
        confirmation_id: confirmation_id.clone(),
        action_id: action_id.to_string(),
        session_id: session.session_id.clone(),
        draft_revision_id: revision.draft_revision_id.clone(),
        draft_content_digest: revision.content_digest.clone(),
        intent_id: intent.intent.id.clone(),
        queue_id: queue.queue_id.clone(),
        intent_digest: digest(&intent)?,
        queue_digest: activated_queue_digest(&queue)?,
        status: "committed".to_string(),
    };

    let (current_intent_text, current_queue_text) = ws.load_active_snapshot_texts()?;
    let current_intent_digest = digest(&current_intent_text)?;
    let current_queue_digest = digest(&current_queue_text)?;
    let expected_intent_digest = digest(&intent)?;
    let expected_queue_digest = activated_queue_digest(&queue)?;
    let current_intent_matches_output = match ws.load_activated_intent()? {
        Some(existing) => digest(&existing)? == expected_intent_digest,
        None => false,
    };
    let current_queue_matches_output = match ws.load_activated_queue()? {
        Some(existing) => activated_queue_digest(&existing)? == expected_queue_digest,
        None => false,
    };
    if current_intent_digest != action.prior_intent_digest && !current_intent_matches_output {
        return Err(reject_action(
            ws,
            &mut session,
            action,
            "interrupted promotion intent snapshot conflicts with prepare",
        )?);
    }
    if current_queue_digest != action.prior_queue_digest && !current_queue_matches_output {
        return Err(reject_action(
            ws,
            &mut session,
            action,
            "interrupted promotion queue snapshot conflicts with prepare",
        )?);
    }
    if current_intent_digest == action.prior_intent_digest && ws.load_intent()?.is_some() {
        crate::report::archive_intent(ws)?;
    }
    if let Some(existing) = ws.load_activation(&confirmation_id)? {
        if digest(&existing)? != digest(&activation)? {
            return Err(reject_action(
                ws,
                &mut session,
                action,
                "interrupted promotion activation conflicts with prepare",
            )?);
        }
    }
    ws.save_activated_intent_snapshot(&intent)?;
    maybe_crash("confirm_after_intent_write");
    ws.save_activated_queue_snapshot(&queue)?;
    ws.save_activation(&activation)?;
    maybe_crash("confirm_after_activation_write");
    if session.lifecycle == PlanningLifecycle::Open {
        let previous = session.clone();
        session.lifecycle = PlanningLifecycle::Confirmed;
        session.confirmation_id = Some(confirmation_id.clone());
        ws.save_planning_session_cas(&previous, &session)?;
    }
    let effect = append_action_event_once(
        ws,
        &mut session,
        PlanningEventType::DraftConfirmed,
        "system",
        EventFields {
            action_id,
            action_request_digest: &action.request_digest,
            draft_revision_id: expected_head,
            related_revision_id: &confirmation_id,
            ..EventFields::default()
        },
    )?
    .or(linked_action_event(
        ws,
        &session.session_id,
        action_id,
        &action.request_digest,
        PlanningEventType::DraftConfirmed,
    )?)
    .ok_or_else(|| anyhow!("confirmed action effect event is missing"))?;
    maybe_crash("confirm_after_effect_before_completion");
    complete_action(ws, &mut session, action, &confirmation_id, &effect)?;
    validate_active_activation(ws)?;
    Ok(activation)
}

pub fn activate_express_draft(
    ws: &Workspace,
    goal: &str,
    content: PlanningDraftContent,
) -> Result<ActivationReceipt> {
    let session = {
        let _lock = ws.acquire_planning_lock()?;
        create_session_with_ids(
            ws,
            goal,
            content.intent.id.clone(),
            content.queue.queue_id.clone(),
        )?
    };
    validate_draft(&session, &content)?;
    let proposal = record_worker_proposal(
        ws,
        &session.session_id,
        "yardlet-core",
        "express-goal",
        "Express goal draft generated deterministically without a planning worker.",
        "The goal command is the user's explicit confirmation operation.",
        content,
    )?;
    let accepted = accept_proposal(
        ws,
        &proposal.proposal_id,
        None,
        &new_id("act_express_accept"),
    )?;
    confirm_express(
        ws,
        &accepted.draft_revision_id,
        &new_id("act_express_confirm"),
    )
}

fn provenance_present(intent: &ActivatedIntent, queue: &ActivatedQueue) -> bool {
    intent.activation_required
        || queue.activation_required
        || !intent.confirmation_id.is_empty()
        || !intent.draft_revision_id.is_empty()
        || !intent.planning_session_id.is_empty()
        || !intent.draft_content_digest.is_empty()
        || !queue.confirmation_id.is_empty()
        || !queue.draft_revision_id.is_empty()
        || !queue.planning_session_id.is_empty()
        || !queue.draft_content_digest.is_empty()
        || queue
            .tasks
            .iter()
            .any(|task| !task.materialized_by_confirmation_id.is_empty())
}

fn queue_provenance_present(queue: &ActivatedQueue) -> bool {
    queue.activation_required
        || !queue.confirmation_id.is_empty()
        || !queue.draft_revision_id.is_empty()
        || !queue.planning_session_id.is_empty()
        || !queue.draft_content_digest.is_empty()
        || queue
            .tasks
            .iter()
            .any(|task| !task.materialized_by_confirmation_id.is_empty())
}

fn inconsistent(reason: &str) -> anyhow::Error {
    anyhow!("unconfirmed_or_inconsistent: {reason}")
}

pub fn validate_active_activation(ws: &Workspace) -> Result<ActivationGate> {
    let workspace_requires_activation = ws
        .confirmed_activation_required()
        .map_err(|_| inconsistent("activation requirement marker is invalid"))?;
    let Some(intent) = ws.load_activated_intent()? else {
        let queue = ws.load_activated_queue()?;
        if queue
            .as_ref()
            .is_some_and(|queue| workspace_requires_activation || queue_provenance_present(queue))
        {
            return Err(inconsistent("active intent is missing"));
        }
        return Ok(ActivationGate::Legacy);
    };
    let queue = ws
        .load_activated_queue()?
        .ok_or_else(|| inconsistent("active queue is missing"))?;
    if !workspace_requires_activation && !provenance_present(&intent, &queue) {
        return Ok(ActivationGate::Legacy);
    }
    if intent.activation_required != queue.activation_required {
        return Err(inconsistent("active snapshot origin marker mismatch"));
    }
    if queue.intent_id != intent.intent.id {
        return Err(inconsistent("queue.intent_id != intent.id"));
    }
    if intent.confirmation_id.is_empty()
        || queue.confirmation_id != intent.confirmation_id
        || intent.planning_session_id.is_empty()
        || queue.planning_session_id != intent.planning_session_id
    {
        return Err(inconsistent(
            "intent and queue confirmation linkage mismatch",
        ));
    }
    let activation = ws
        .load_activation(&intent.confirmation_id)?
        .ok_or_else(|| inconsistent("activation receipt is missing"))?;
    if activation.status != "committed" {
        return Err(inconsistent("activation status is not committed"));
    }
    if activation.action_id.is_empty() {
        return Err(inconsistent("activation action id is missing"));
    }
    if activation.confirmation_id != intent.confirmation_id
        || activation.confirmation_id != queue.confirmation_id
    {
        return Err(inconsistent("activation confirmation id mismatch"));
    }
    if activation.session_id != intent.planning_session_id
        || activation.session_id != queue.planning_session_id
    {
        return Err(inconsistent("activation session id mismatch"));
    }
    if activation.intent_id != intent.intent.id || activation.queue_id != queue.queue_id {
        return Err(inconsistent("activation output id mismatch"));
    }
    if activation.draft_revision_id != intent.draft_revision_id
        || activation.draft_revision_id != queue.draft_revision_id
    {
        return Err(inconsistent("activation draft revision mismatch"));
    }
    if activation.draft_content_digest != intent.draft_content_digest
        || activation.draft_content_digest != queue.draft_content_digest
    {
        return Err(inconsistent("activation draft content digest mismatch"));
    }
    let action = ws
        .load_planning_action(&activation.session_id, &activation.action_id)?
        .ok_or_else(|| inconsistent("confirm action receipt is missing"))?;
    let expected_action_digest = action_request_digest(
        PlanningActionKind::Confirm,
        &activation.action_id,
        Some(&activation.draft_revision_id),
        &activation.draft_revision_id,
    )?;
    if action.session_id != activation.session_id
        || action.action_id != activation.action_id
        || action.action != PlanningActionKind::Confirm
        || action.status != PlanningActionStatus::Completed
        || action.result_id != activation.confirmation_id
        || action.request_digest != expected_action_digest
        || action.effect_event_type != Some(PlanningEventType::DraftConfirmed)
        || action.effect_event_id.is_empty()
    {
        return Err(inconsistent(
            "activation does not match a completed confirm action receipt",
        ));
    }
    let effect = ws
        .load_planning_events(&activation.session_id)?
        .into_iter()
        .find(|event| event.event_id == action.effect_event_id)
        .ok_or_else(|| inconsistent("confirm action effect event is missing"))?;
    if effect.event_type != PlanningEventType::DraftConfirmed
        || effect.action_id != action.action_id
        || effect.action_request_digest != action.request_digest
        || effect.draft_revision_id != activation.draft_revision_id
        || effect.related_revision_id != activation.confirmation_id
    {
        return Err(inconsistent("confirm action effect event linkage mismatch"));
    }
    if activation.intent_digest != digest(&intent)? {
        return Err(inconsistent("active intent digest mismatch"));
    }
    if activation.queue_digest != activated_queue_digest(&queue)? {
        return Err(inconsistent("active queue digest mismatch"));
    }
    if queue
        .tasks
        .iter()
        .any(|task| task.materialized_by_confirmation_id != activation.confirmation_id)
    {
        return Err(inconsistent("task materialization confirmation mismatch"));
    }
    let session = ws
        .load_planning_session(&activation.session_id)
        .map_err(|_| inconsistent("planning session is missing"))?;
    if session.session_id != activation.session_id
        || session.intent_id != activation.intent_id
        || session.queue_id != activation.queue_id
        || session.lifecycle != PlanningLifecycle::Confirmed
        || session.current_head.as_deref() != Some(activation.draft_revision_id.as_str())
        || session.confirmation_id.as_deref() != Some(activation.confirmation_id.as_str())
    {
        return Err(inconsistent("confirmed session head mismatch"));
    }
    let revision = ws
        .load_draft_revision(&activation.session_id, &activation.draft_revision_id)
        .map_err(|_| inconsistent("confirmed draft revision is missing"))?;
    if revision.session_id != activation.session_id
        || revision.draft_revision_id != activation.draft_revision_id
    {
        return Err(inconsistent("confirmed draft identity mismatch"));
    }
    if validate_draft(&session, &revision.content).is_err()
        || digest(&revision.content)? != revision.content_digest
        || revision.content_digest != activation.draft_content_digest
    {
        return Err(inconsistent("confirmed draft digest mismatch"));
    }
    let active_content = PlanningDraftContent {
        intent: intent.intent,
        queue: queue
            .materialized_queue
            .clone()
            .unwrap_or_else(|| queue.as_work_queue()),
    };
    if digest(&active_content)? != revision.content_digest {
        return Err(inconsistent("active plan fields differ from visible draft"));
    }
    Ok(ActivationGate::Confirmed)
}

pub fn active_is_confirmed_or_running(ws: &Workspace) -> Result<bool> {
    let queue = ws.load_queue()?;
    if queue
        .tasks
        .iter()
        .any(|task| task.state == TaskState::Running)
    {
        return Ok(true);
    }
    Ok(validate_active_activation(ws)? == ActivationGate::Confirmed)
}

pub fn projection(ws: &Workspace) -> Result<PlanningProjection> {
    let _lock = ws.acquire_planning_lock()?;
    let session = ws
        .load_latest_planning_session()?
        .ok_or_else(|| anyhow!("no planning session; run `yardlet new \"...\"` first"))?;
    let events = ws.load_planning_events(&session.session_id)?;
    let proposals = ws.load_planning_proposals(&session.session_id)?;
    let disposed = events
        .iter()
        .filter(|event| {
            matches!(
                event.event_type,
                PlanningEventType::DraftAccepted
                    | PlanningEventType::DraftRevised
                    | PlanningEventType::DraftRejected
            )
        })
        .map(|event| event.proposal_id.as_str())
        .collect::<BTreeSet<_>>();
    let pending_proposals = proposals
        .into_iter()
        .filter(|proposal| !disposed.contains(proposal.proposal_id.as_str()))
        .collect::<Vec<_>>();
    let current_draft = current_draft(ws, &session)?;
    let activation = session
        .confirmation_id
        .as_deref()
        .map(|id| ws.load_activation(id))
        .transpose()?
        .flatten();
    let exact_active_parity = activation.is_some()
        && matches!(
            validate_active_activation(ws),
            Ok(ActivationGate::Confirmed)
        );
    let channel_turn_count = events
        .iter()
        .filter(|event| event.event_type == PlanningEventType::UserMessage)
        .count();
    let rejected_proposal_count = events
        .iter()
        .filter(|event| event.event_type == PlanningEventType::DraftRejected)
        .count();
    let undo_count = events
        .iter()
        .filter(|event| event.event_type == PlanningEventType::DraftUndo)
        .count();
    Ok(PlanningProjection {
        session,
        current_draft,
        pending_proposals,
        events,
        activation,
        exact_active_parity,
        channel_turn_count,
        rejected_proposal_count,
        undo_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draft() -> PlanningDraftContent {
        crate::yaml::from_str(
            r#"
intent:
  schema_version: 1
  id: intent-planning-test
  source: user
  raw_request: bounded test
  summary: bounded test
  allowed_scope: [src/planning.rs]
  out_of_scope: [src/ui/**]
  acceptance: [exact promotion]
  ambiguity: low
  status: accepted
queue:
  schema_version: 1
  queue_id: queue-intent-planning-test
  intent_id: intent-planning-test
  tasks:
    - id: YARD-001
      title: implement exact promotion
      state: queued
      allowed_scope: [src/planning.rs]
      acceptance: [exact promotion]
"#,
        )
        .expect("parse planning draft fixture")
    }

    fn temp_workspace(label: &str) -> Workspace {
        let counter = ID_COUNTER.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "yardlet-planning-{label}-{}-{counter}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        Workspace::at(&root)
    }

    #[test]
    fn semantic_diff_covers_every_contract_plan_surface() {
        let entries = semantic_diff(None, &draft());
        let fields = entries
            .iter()
            .map(|entry| entry.field.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            fields,
            vec![
                "summary",
                "allowed_scope",
                "out_of_scope",
                "acceptance",
                "ambiguity",
                "tasks",
                "dependencies",
                "routing",
                "validation",
            ]
        );
    }

    #[test]
    fn express_activation_round_trips_as_exact_confirmed_draft() {
        let ws = temp_workspace("exact");
        let activation = activate_express_draft(&ws, "bounded test", draft()).unwrap();
        assert_eq!(activation.status, "committed");
        assert_eq!(
            validate_active_activation(&ws).unwrap(),
            ActivationGate::Confirmed
        );
        assert!(projection(&ws).unwrap().exact_active_parity);
        let _ = std::fs::remove_dir_all(&ws.root);
    }

    #[test]
    fn every_confirmation_linkage_predicate_fails_closed_when_tampered() {
        for case in [
            "queue_intent",
            "confirmation",
            "draft_revision",
            "intent_digest",
            "queue_digest",
            "activation_status",
            "materialized_by",
        ] {
            let ws = temp_workspace(case);
            let activation = activate_express_draft(&ws, "bounded test", draft()).unwrap();
            let mut intent = ws.load_activated_intent().unwrap().unwrap();
            let mut queue = ws.load_activated_queue().unwrap().unwrap();
            let mut receipt = ws
                .load_activation(&activation.confirmation_id)
                .unwrap()
                .unwrap();
            match case {
                "queue_intent" => queue.intent_id = "forged-intent".into(),
                "confirmation" => intent.confirmation_id = "forged-confirmation".into(),
                "draft_revision" => receipt.draft_revision_id = "forged-draft".into(),
                "intent_digest" => receipt.intent_digest = "forged-digest".into(),
                "queue_digest" => receipt.queue_digest = "forged-digest".into(),
                "activation_status" => receipt.status = "prepared".into(),
                "materialized_by" => {
                    queue.tasks[0].materialized_by_confirmation_id = "forged-confirmation".into()
                }
                _ => unreachable!(),
            }
            ws.save_activated_intent_snapshot(&intent).unwrap();
            ws.save_activated_queue_snapshot(&queue).unwrap();
            crate::state::save_yaml(&ws.activation_path(&receipt.confirmation_id), &receipt)
                .unwrap();
            let error = validate_active_activation(&ws).unwrap_err().to_string();
            assert!(
                error.contains("unconfirmed_or_inconsistent"),
                "{case}: {error}"
            );
            let _ = std::fs::remove_dir_all(&ws.root);
        }
    }
}
