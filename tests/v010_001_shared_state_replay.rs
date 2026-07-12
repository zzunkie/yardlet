use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

#[derive(Debug, PartialEq, Eq)]
struct ReplaySnapshot {
    channels: Vec<TaskChannel>,
    runnable_tasks: Vec<String>,
    errors: Vec<String>,
    adapted_event_ids: Vec<String>,
    preserved_unknown_fields: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct TaskChannel {
    task_id: String,
    attempts: Vec<AttemptProjection>,
    completion_id: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct AttemptProjection {
    attempt_id: String,
    worker_id: String,
    worker_session_ref: String,
    question_ids: Vec<String>,
    answer_ids: Vec<String>,
    artifact_ids: Vec<String>,
    result: String,
}

#[derive(Debug, PartialEq, Eq)]
struct LegacySnapshot {
    channel_count: usize,
    attempt_ids: Vec<String>,
    recorded_state: String,
    runnability: String,
}

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/v010_001_shared_state")
        .join(name)
}

fn replay_canonical_fixture() -> ReplaySnapshot {
    replay_canonical(&canonical_fixture_value())
}

fn canonical_fixture_value() -> Value {
    let raw = std::fs::read_to_string(fixture_path("canonical.json"))
        .expect("read canonical shared-state fixture");
    serde_json::from_str(&raw).expect("parse canonical fixture JSON")
}

fn replay_after_restart(fixture: &Value, crash_after: usize) -> ReplaySnapshot {
    let events = fixture["events"].as_array().expect("fixture events");
    let cut = crash_after.min(events.len());

    let mut partial = fixture.clone();
    partial["events"] = Value::Array(events[..cut].to_vec());
    let _snapshot_before_restart = replay_canonical(&partial);

    let mut restarted = fixture.clone();
    let mut redelivered = events[..cut].to_vec();
    redelivered.extend(events.iter().cloned());
    restarted["events"] = Value::Array(redelivered);
    replay_canonical(&restarted)
}

fn replay_canonical(fixture: &Value) -> ReplaySnapshot {
    let task_id = string_at(fixture, &["queue", "tasks", "0", "id"]);
    let mut channel = TaskChannel {
        task_id: task_id.clone(),
        attempts: Vec::new(),
        completion_id: None,
    };
    let mut pending_answers = Vec::new();
    let mut errors = Vec::new();
    let mut adapted_event_ids = Vec::new();
    let mut preserved_unknown_fields = Vec::new();
    let mut unique_events = BTreeMap::new();
    for event in fixture["events"].as_array().expect("fixture events") {
        let event_id = event["event_id"].as_str().expect("event id");
        if let Some(existing) = unique_events.get(event_id) {
            if *existing != event {
                errors.push(format!("conflicting_duplicate:{event_id}"));
            }
        } else {
            unique_events.insert(event_id, event);
        }
    }
    let mut events: Vec<&Value> = unique_events.into_values().collect();
    events.sort_by_key(|event| event["seq"].as_u64().expect("event seq"));
    let mut seen_sequences = BTreeSet::new();
    let mut expected_sequence = 1_u64;
    for event in &events {
        let sequence = event["seq"].as_u64().expect("event seq");
        if !seen_sequences.insert(sequence) {
            errors.push(format!("sequence_conflict:{sequence}"));
        } else {
            if sequence > expected_sequence {
                errors.push(format!("sequence_gap:{expected_sequence}-{sequence}"));
            }
            expected_sequence = sequence + 1;
        }
    }

    for event in events {
        let event_id = event["event_id"].as_str().expect("event id");
        let version = event["schema_version"]
            .as_u64()
            .expect("event schema version");
        let event_type = match version {
            0 => {
                adapted_event_ids.push(event_id.to_string());
                event["kind"].as_str().expect("legacy event kind")
            }
            1 => event["type"].as_str().expect("event type"),
            _ => {
                errors.push(format!("unsupported_semantics:{event_id}"));
                continue;
            }
        };
        let known_fields = [
            "schema_version",
            "event_id",
            "session_id",
            "seq",
            "type",
            "kind",
            "recorded_at",
            "actor",
            "action_id",
            "causation_id",
            "correlation_id",
            "task_id",
            "attempt_id",
            "payload",
            "raw_ref",
        ];
        for field in event.as_object().expect("event object").keys() {
            if !known_fields.contains(&field.as_str()) {
                preserved_unknown_fields.push(format!("{event_id}.{field}"));
            }
        }
        match event_type {
            "attempt.prepared" => {
                let payload = &event["payload"];
                let caused_by_answer = payload["caused_by_answer_id"].as_str();
                let mut answer_ids = Vec::new();
                if let Some(answer_id) = caused_by_answer {
                    assert!(
                        pending_answers.iter().any(|pending| pending == answer_id),
                        "attempt must reference a recorded answer"
                    );
                    answer_ids.push(answer_id.to_string());
                }
                channel.attempts.push(AttemptProjection {
                    attempt_id: event["attempt_id"]
                        .as_str()
                        .expect("attempt id")
                        .to_string(),
                    worker_id: payload["worker_id"]
                        .as_str()
                        .expect("worker id")
                        .to_string(),
                    worker_session_ref: payload["worker_session_ref"]
                        .as_str()
                        .expect("worker session ref")
                        .to_string(),
                    question_ids: Vec::new(),
                    answer_ids,
                    artifact_ids: Vec::new(),
                    result: String::new(),
                });
            }
            "question.asked" => {
                attempt_mut(&mut channel, event).question_ids.push(
                    event["payload"]["question_id"]
                        .as_str()
                        .expect("question id")
                        .to_string(),
                );
            }
            "user.answered" => pending_answers.push(
                event["payload"]["answer_id"]
                    .as_str()
                    .expect("answer id")
                    .to_string(),
            ),
            "artifact.created" => {
                attempt_mut(&mut channel, event).artifact_ids.push(
                    event["payload"]["artifact_id"]
                        .as_str()
                        .expect("artifact id")
                        .to_string(),
                );
            }
            "worker.completed" => {
                attempt_mut(&mut channel, event).result = event["payload"]["result"]
                    .as_str()
                    .expect("attempt result")
                    .to_string();
            }
            "completion.recorded" => {
                channel.completion_id = Some(
                    event["payload"]["completion_id"]
                        .as_str()
                        .expect("completion id")
                        .to_string(),
                );
            }
            _ => {}
        }
    }

    let activation = &fixture["activation"];
    let intent = &fixture["intent"];
    let queue = &fixture["queue"];
    let confirmed_draft_head = fixture["drafts"].as_array().and_then(|drafts| {
        let mut confirmed = drafts.iter().filter(|draft| draft["state"] == "confirmed");
        let head = confirmed.next()?;
        confirmed
            .next()
            .is_none()
            .then(|| head["draft_revision_id"].as_str())
            .flatten()
    });
    let confirmed_event = fixture["events"].as_array().is_some_and(|events| {
        events.iter().any(|event| {
            (event["type"] == "draft.confirmed" || event["kind"] == "draft.confirmed")
                && event["payload"]["confirmation_id"] == activation["confirmation_id"]
        })
    });
    let task = &queue["tasks"][0];
    let runnable = errors.is_empty()
        && confirmed_event
        && activation["status"] == "committed"
        && activation["intent_id"] == intent["id"]
        && activation["queue_id"] == queue["id"]
        && queue["intent_id"] == intent["id"]
        && confirmed_draft_head.is_some()
        && activation["draft_revision_id"].as_str() == confirmed_draft_head
        && activation["confirmation_id"] == intent["confirmation_id"]
        && activation["confirmation_id"] == queue["confirmation_id"]
        && activation["intent_digest"] == intent["digest"]
        && activation["queue_digest"] == queue["digest"]
        && activation["confirmation_id"] == task["materialized_by_confirmation_id"]
        && task["state"] == "queued";

    ReplaySnapshot {
        channels: vec![channel],
        runnable_tasks: runnable.then_some(task_id).into_iter().collect(),
        errors,
        adapted_event_ids,
        preserved_unknown_fields,
    }
}

fn replay_legacy_no_index(root: &Path) -> LegacySnapshot {
    assert!(
        !root.join("derived-index.json").exists(),
        "legacy fallback must not depend on a derived index"
    );
    let intent: serde_yaml_ng::Value = serde_yaml_ng::from_str(
        &std::fs::read_to_string(root.join("intent-contract.yaml")).expect("read legacy intent"),
    )
    .expect("parse legacy intent");
    let queue: serde_yaml_ng::Value = serde_yaml_ng::from_str(
        &std::fs::read_to_string(root.join("work-queue.yaml")).expect("read legacy queue"),
    )
    .expect("parse legacy queue");
    assert_eq!(
        intent["id"].as_str(),
        queue["intent_id"].as_str(),
        "legacy intent and queue must share a namespace"
    );

    let task = &queue["tasks"][0];
    let task_id = task["id"].as_str().expect("legacy task id");
    let mut attempts = Vec::new();
    for entry in std::fs::read_dir(root.join("runs")).expect("read legacy runs") {
        let run_dir = entry.expect("legacy run entry").path();
        let run: serde_yaml_ng::Value = serde_yaml_ng::from_str(
            &std::fs::read_to_string(run_dir.join("run.yaml")).expect("read legacy run"),
        )
        .expect("parse legacy run");
        if run["task_id"].as_str() == Some(task_id)
            && run["intent_id"].as_str() == intent["id"].as_str()
        {
            attempts.push((
                run["started_at"].as_str().unwrap_or_default().to_string(),
                run["run_id"].as_str().expect("legacy run id").to_string(),
            ));
        }
    }
    attempts.sort();

    LegacySnapshot {
        channel_count: 1,
        attempt_ids: attempts.into_iter().map(|(_, run_id)| run_id).collect(),
        recorded_state: task["state"]
            .as_str()
            .expect("legacy recorded task state")
            .to_string(),
        runnability: "unknown".to_string(),
    }
}

fn fixture_tree_bytes(root: &Path) -> Vec<(String, Vec<u8>)> {
    fn visit(root: &Path, dir: &Path, files: &mut Vec<(String, Vec<u8>)>) {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
            .expect("read fixture directory")
            .map(|entry| entry.expect("fixture entry").path())
            .collect();
        entries.sort();
        for path in entries {
            if path.is_dir() {
                visit(root, &path, files);
            } else {
                files.push((
                    path.strip_prefix(root)
                        .expect("fixture relative path")
                        .to_string_lossy()
                        .into_owned(),
                    std::fs::read(&path).expect("read fixture bytes"),
                ));
            }
        }
    }

    let mut files = Vec::new();
    visit(root, root, &mut files);
    files
}

fn attempt_mut<'a>(channel: &'a mut TaskChannel, event: &Value) -> &'a mut AttemptProjection {
    let attempt_id = event["attempt_id"].as_str().expect("attempt id");
    channel
        .attempts
        .iter_mut()
        .find(|attempt| attempt.attempt_id == attempt_id)
        .expect("event references a prepared attempt")
}

fn string_at(value: &Value, path: &[&str]) -> String {
    let mut current = value;
    for part in path {
        current = if let Ok(index) = part.parse::<usize>() {
            &current[index]
        } else {
            &current[*part]
        };
    }
    current.as_str().expect("fixture string").to_string()
}

#[test]
fn canonical_state_replays_one_channel_with_two_accountable_attempts() {
    let snapshot = replay_canonical_fixture();

    assert_eq!(snapshot.channels.len(), 1);
    assert_eq!(snapshot.channels[0].attempts.len(), 2);
    assert_eq!(snapshot.runnable_tasks, vec!["tsk_1"]);

    let first = &snapshot.channels[0].attempts[0];
    assert_eq!(first.attempt_id, "att_1");
    assert_eq!(first.worker_id, "codex");
    assert_eq!(first.worker_session_ref, "worker-session-a");
    assert_eq!(first.question_ids, vec!["qst_1"]);
    assert!(first.answer_ids.is_empty());
    assert!(first.artifact_ids.is_empty());

    let second = &snapshot.channels[0].attempts[1];
    assert_eq!(second.attempt_id, "att_2");
    assert_eq!(second.worker_id, "claude-code");
    assert_eq!(second.worker_session_ref, "worker-session-b");
    assert!(second.question_ids.is_empty());
    assert_eq!(second.answer_ids, vec!["ans_1"]);
    assert_eq!(second.artifact_ids, vec!["art_1"]);
    assert_eq!(second.result, "succeeded");

    assert_eq!(snapshot.channels[0].completion_id.as_deref(), Some("cmp_1"));
}

#[test]
fn confirm_gate_duplicate_delivery_and_crash_restarts_converge() {
    let fixture = canonical_fixture_value();
    let baseline = replay_canonical(&fixture);

    let mut without_confirm = fixture.clone();
    without_confirm["events"]
        .as_array_mut()
        .expect("fixture events")
        .retain(|event| event["type"] != "draft.confirmed");
    assert!(replay_canonical(&without_confirm).runnable_tasks.is_empty());

    let mut without_activation = fixture.clone();
    without_activation
        .as_object_mut()
        .expect("fixture object")
        .remove("activation");
    assert!(replay_canonical(&without_activation)
        .runnable_tasks
        .is_empty());

    let mut uncommitted_activation = fixture.clone();
    uncommitted_activation["activation"]["status"] = Value::from("prepared");
    assert!(replay_canonical(&uncommitted_activation)
        .runnable_tasks
        .is_empty());

    let mut mismatched_intent_digest = fixture.clone();
    mismatched_intent_digest["activation"]["intent_digest"] = Value::from("intent-digest-other");
    assert!(replay_canonical(&mismatched_intent_digest)
        .runnable_tasks
        .is_empty());

    let mut dangling_draft_revision = fixture.clone();
    dangling_draft_revision["activation"]["draft_revision_id"] = Value::from("drv_999");
    assert!(replay_canonical(&dangling_draft_revision)
        .runnable_tasks
        .is_empty());

    let mut mismatched_queue_intent = fixture.clone();
    mismatched_queue_intent["queue"]["intent_id"] = Value::from("int_other");
    assert!(replay_canonical(&mismatched_queue_intent)
        .runnable_tasks
        .is_empty());

    let mut duplicated = fixture.clone();
    let original_events = duplicated["events"]
        .as_array()
        .expect("fixture events")
        .clone();
    duplicated["events"]
        .as_array_mut()
        .expect("fixture events")
        .extend(original_events);
    assert_eq!(replay_canonical(&duplicated), baseline);

    for crash_after in [0, 5, 6, 11, 12, 15, 18] {
        assert_eq!(
            replay_after_restart(&fixture, crash_after),
            baseline,
            "restart must converge after event {crash_after}"
        );
    }
}

#[test]
fn legacy_no_index_fallback_is_read_only_and_never_false_runnable() {
    let legacy_root = fixture_path("legacy_no_index");
    assert!(!legacy_root.join("derived-index.json").exists());
    let before = fixture_tree_bytes(&legacy_root);

    let snapshot = replay_legacy_no_index(&legacy_root);

    assert_eq!(snapshot.channel_count, 1);
    assert_eq!(snapshot.attempt_ids, vec!["run-legacy-1", "run-legacy-2"]);
    assert_eq!(snapshot.recorded_state, "queued");
    assert_eq!(snapshot.runnability, "unknown");
    assert_eq!(fixture_tree_bytes(&legacy_root), before);
}

#[test]
fn versions_and_additive_fields_replay_while_required_unknowns_fail_closed() {
    let mut fixture = canonical_fixture_value();
    let events = fixture["events"].as_array_mut().expect("fixture events");
    let old_event = events
        .iter_mut()
        .find(|event| event["event_id"] == "evt_09_attempt_1_started")
        .expect("old-version representative event");
    old_event["schema_version"] = Value::from(0);
    old_event["kind"] = old_event["type"].take();

    let additive_event = events
        .iter_mut()
        .find(|event| event["event_id"] == "evt_15_artifact_created")
        .expect("additive representative event");
    additive_event["future_display_hint"] = Value::from("preview-inline");

    let tolerant = replay_canonical(&fixture);
    assert_eq!(tolerant.runnable_tasks, vec!["tsk_1"]);
    assert_eq!(tolerant.adapted_event_ids, vec!["evt_09_attempt_1_started"]);
    assert_eq!(
        tolerant.preserved_unknown_fields,
        vec!["evt_15_artifact_created.future_display_hint"]
    );

    let mut unsupported = fixture.clone();
    unsupported["events"]
        .as_array_mut()
        .expect("fixture events")
        .push(serde_json::json!({
            "schema_version": 2,
            "event_id": "evt_19_required_unknown",
            "session_id": "ses_fixture",
            "seq": 19,
            "type": "task.authorization.v2",
            "actor": { "kind": "system", "id": "future_core" },
            "task_id": "tsk_1",
            "payload": { "required_for": ["runnability"] }
        }));
    let unsupported_snapshot = replay_canonical(&unsupported);
    assert!(unsupported_snapshot.runnable_tasks.is_empty());
    assert_eq!(
        unsupported_snapshot.errors,
        vec!["unsupported_semantics:evt_19_required_unknown"]
    );
}

#[test]
fn conflicting_duplicate_event_is_quarantined_and_non_runnable() {
    let mut fixture = canonical_fixture_value();
    let mut conflict = fixture["events"][6].clone();
    conflict["payload"]["confirmation_id"] = Value::from("cnf_conflict");
    fixture["events"]
        .as_array_mut()
        .expect("fixture events")
        .push(conflict);

    let snapshot = replay_canonical(&fixture);

    assert!(snapshot.runnable_tasks.is_empty());
    assert_eq!(
        snapshot.errors,
        vec!["conflicting_duplicate:evt_07_task_materialized"]
    );
}

#[test]
fn sequence_gap_and_collision_are_fail_closed() {
    let fixture = canonical_fixture_value();

    let mut gap = fixture.clone();
    gap["events"]
        .as_array_mut()
        .expect("fixture events")
        .retain(|event| event["seq"] != 10);
    let gap_snapshot = replay_canonical(&gap);
    assert!(gap_snapshot.runnable_tasks.is_empty());
    assert_eq!(gap_snapshot.errors, vec!["sequence_gap:10-11"]);

    let mut collision = fixture.clone();
    collision["events"]
        .as_array_mut()
        .expect("fixture events")
        .push(serde_json::json!({
            "schema_version": 1,
            "event_id": "evt_collision",
            "session_id": "ses_fixture",
            "seq": 7,
            "type": "worker.message",
            "actor": { "kind": "worker", "id": "codex" },
            "task_id": "tsk_1",
            "attempt_id": "att_1",
            "payload": { "text": "late duplicate sequence" }
        }));
    let collision_snapshot = replay_canonical(&collision);
    assert!(collision_snapshot.runnable_tasks.is_empty());
    assert_eq!(collision_snapshot.errors, vec!["sequence_conflict:7"]);
}

#[test]
fn fixture_ids_and_causation_form_a_complete_stable_chain() {
    let fixture = canonical_fixture_value();
    let events = fixture["events"].as_array().expect("fixture events");
    assert_eq!(events.len(), 18);

    let mut prior_ids = BTreeSet::new();
    for (index, event) in events.iter().enumerate() {
        let event_id = event["event_id"].as_str().expect("stable event id");
        assert!(prior_ids.insert(event_id), "duplicate event id {event_id}");
        assert_eq!(event["seq"].as_u64(), Some((index + 1) as u64));
        if index > 0 {
            let cause = event["causation_id"]
                .as_str()
                .expect("non-root event has causation id");
            assert!(
                prior_ids.contains(cause),
                "causation must reference an earlier event: {event_id} -> {cause}"
            );
        }
    }

    assert_eq!(fixture["drafts"][1]["draft_revision_id"], "drv_2");
    assert_eq!(fixture["activation"]["confirmation_id"], "cnf_1");
    assert_eq!(fixture["queue"]["tasks"][0]["id"], "tsk_1");
    assert_eq!(events[7]["attempt_id"], "att_1");
    assert_eq!(events[9]["payload"]["question_id"], "qst_1");
    assert_eq!(events[11]["payload"]["answer_id"], "ans_1");
    assert_eq!(events[12]["attempt_id"], "att_2");
    assert_eq!(events[14]["payload"]["artifact_id"], "art_1");
    assert_eq!(events[15]["payload"]["evaluation_id"], "eval_1");
    assert_eq!(events[17]["payload"]["completion_id"], "cmp_1");
}

#[test]
fn replay_ignores_delivery_order_wall_clock_and_derived_index() {
    let fixture = canonical_fixture_value();
    let baseline = replay_canonical(&fixture);
    let mut reordered = fixture.clone();
    reordered
        .as_object_mut()
        .expect("fixture object")
        .remove("derived_index");
    let events = reordered["events"].as_array_mut().expect("fixture events");
    events.reverse();
    for (index, event) in events.iter_mut().enumerate() {
        event["recorded_at"] = Value::from(format!("2099-12-31T23:59:{index:02}Z"));
    }

    assert_eq!(replay_canonical(&reordered), baseline);
}
