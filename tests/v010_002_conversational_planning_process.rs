#[cfg(unix)]
mod unix {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn run_scenario(scenario: &str) {
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let script =
            manifest.join("tests/fixtures/v010_002_conversational_planning/scripts/run.sh");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before Unix epoch")
            .as_nanos();
        let evidence = std::env::temp_dir().join(format!(
            "yardlet-v010-002-{scenario}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&evidence).expect("create V010-002 evidence directory");

        let output = Command::new("bash")
            .arg(&script)
            .arg(env!("CARGO_BIN_EXE_yardlet"))
            .arg(&evidence)
            .arg(scenario)
            .output()
            .expect("run V010-002 process fixture");

        if !output.status.success() {
            panic!(
                "V010-002 scenario {scenario} failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
                evidence.display(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let summary = std::fs::read_to_string(evidence.join("summary.json"))
            .expect("fixture must leave structured summary evidence");
        assert!(summary.contains("\"status\": \"passed\""), "{summary}");
        assert!(
            summary.contains(&format!("\"scenario\": \"{scenario}\"")),
            "{summary}"
        );
        std::fs::remove_dir_all(&evidence).expect("remove successful fixture evidence");
    }

    #[test]
    fn proposal_accept_is_explicit_and_does_not_activate() {
        run_scenario("accept");
    }

    #[test]
    fn proposal_reject_preserves_the_visible_head() {
        run_scenario("reject");
    }

    #[test]
    fn undo_restores_the_parent_revision() {
        run_scenario("undo");
    }

    #[test]
    fn stale_expected_head_is_rejected() {
        run_scenario("stale_head");
    }

    #[test]
    fn restart_restores_history_and_confirmed_provenance() {
        run_scenario("restart_confirm");
    }

    #[test]
    fn partial_or_tampered_promotion_is_not_runnable() {
        run_scenario("partial_promotion");
    }

    #[test]
    fn running_and_confirmed_queues_reject_free_form_planning_mutation() {
        run_scenario("running_isolation");
    }

    #[test]
    fn goal_express_path_records_confirmation_without_a_planner() {
        run_scenario("goal_regression");
    }

    #[test]
    fn three_turn_dogfood_promotes_the_exact_visible_draft() {
        run_scenario("dogfood");
    }

    #[test]
    fn disposed_proposals_cannot_be_accepted_or_rejected_again() {
        run_scenario("terminal_proposal");
    }

    #[test]
    fn undo_rejects_corrupt_current_or_parent_revisions() {
        run_scenario("undo_integrity");
    }

    #[test]
    fn stripped_modern_provenance_does_not_fall_back_to_legacy() {
        run_scenario("stripped_modern");
    }

    #[test]
    fn confirmation_requires_its_completed_matching_action_receipt() {
        run_scenario("activation_action_linkage");
    }

    #[test]
    fn interrupted_confirmation_replay_converges_without_duplicate_effects() {
        run_scenario("confirm_crash_replay");
    }

    #[test]
    fn event_write_before_next_seq_crash_replays_without_a_journal_collision() {
        run_scenario("event_seq_crash");
    }

    #[test]
    fn actual_confirm_write_order_crashes_replay_without_manual_state_repair() {
        run_scenario("confirm_write_order_crash");
    }

    #[test]
    fn prepared_non_confirm_actions_replay_their_existing_effect_once() {
        run_scenario("action_effect_crash");
    }

    #[test]
    fn unfinished_active_queue_and_corrupt_activation_block_confirm_without_clobber() {
        run_scenario("active_queue_guard");
    }

    #[test]
    fn concurrent_cli_actions_converge_to_one_receipt_and_collision_free_journal() {
        run_scenario("concurrent_action");
    }

    #[test]
    fn accept_revision_write_crash_replays_from_the_prepared_exact_effect() {
        run_scenario("accept_revision_crash");
    }

    #[test]
    fn unresolved_prepared_action_interlocks_every_other_session_mutation() {
        run_scenario("prepared_action_interlock");
    }

    #[test]
    fn journal_corruption_fails_closed_for_every_identity_and_cardinality_rule() {
        run_scenario("journal_corruption");
    }

    #[test]
    fn completed_confirm_replay_requires_its_activation_to_still_be_current() {
        run_scenario("completed_active_mismatch");
    }

    #[test]
    fn workspace_mutation_lock_has_a_stable_barrier_and_bounded_timeout() {
        run_scenario("lock_timeout");
    }

    #[test]
    fn runtime_queue_transition_wins_atomically_over_concurrent_confirm() {
        run_scenario("runtime_queue_confirm_race");
    }

    #[test]
    fn v2_terminal_receipts_require_the_exact_immutable_effect_event() {
        run_scenario("receipt_v2_integrity");
    }

    #[test]
    fn persisted_session_storage_identity_and_journal_are_fail_closed() {
        run_scenario("session_storage_integrity");
    }

    #[test]
    fn activated_runtime_envelope_allows_only_task_state_changes() {
        run_scenario("runtime_envelope");
    }

    #[test]
    fn production_queue_writers_are_guarded_by_the_workspace_transaction() {
        run_scenario("writer_inventory");
    }

    #[test]
    fn concurrent_express_goals_are_one_transaction_each() {
        run_scenario("express_concurrency");
    }
}
