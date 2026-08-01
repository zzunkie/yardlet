//! Minimal TUI localization.
//!
//! The TUI chrome can render in English (default) or Korean. The language is
//! resolved from the workspace `language` setting, falling back to the intent
//! content and the OS locale when set to "auto". Yardlet's canonical state and
//! worker-facing packets are unaffected by this.

use crate::schemas::{RunnableClass, TaskState};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    En,
    Ko,
}

/// Resolve the UI language from config + content + environment.
pub fn detect(config_lang: &str, intent_summary: &str) -> Lang {
    match config_lang {
        "ko" => Lang::Ko,
        "en" => Lang::En,
        _ => {
            if has_hangul(intent_summary) || env_locale_ko() {
                Lang::Ko
            } else {
                Lang::En
            }
        }
    }
}

fn has_hangul(s: &str) -> bool {
    s.chars().any(|c| ('\u{AC00}'..='\u{D7A3}').contains(&c))
}

fn env_locale_ko() -> bool {
    ["LC_ALL", "LC_MESSAGES", "LANG"].iter().any(|k| {
        std::env::var(k)
            .map(|v| v.to_lowercase().starts_with("ko"))
            .unwrap_or(false)
    })
}

impl Lang {
    pub fn l(self) -> &'static L {
        match self {
            Lang::En => &EN,
            Lang::Ko => &KO,
        }
    }
}

pub fn task_state_label(l: &L, state: TaskState) -> &'static str {
    match state {
        TaskState::Running => l.s_running,
        TaskState::Done => l.s_done,
        TaskState::Failed => l.s_failed,
        TaskState::Blocked => l.s_blocked,
        TaskState::NeedsUser => l.s_needs,
        TaskState::Partial => l.s_partial,
        TaskState::Deferred => l.s_deferred,
        TaskState::Queued => l.s_queued,
    }
}

pub fn recorded_state_label(l: &L, state: &str) -> String {
    match state {
        "running" => l.s_running.to_string(),
        "done" => l.s_done.to_string(),
        "failed" => l.s_failed.to_string(),
        "blocked" => l.s_blocked.to_string(),
        "needs-you" | "needs_user" => l.s_needs.to_string(),
        "partial" => l.s_partial.to_string(),
        "deferred" => l.s_deferred.to_string(),
        "queued" => l.s_queued.to_string(),
        _ => state.to_string(),
    }
}

pub fn runnable_class_label(l: &L, class: RunnableClass) -> &'static str {
    match class {
        RunnableClass::Runnable => l.c_ready,
        RunnableClass::WaitingDecision => l.c_waiting_decision,
        RunnableClass::WaitingApproval => l.c_waiting_approval,
        RunnableClass::WaitingDependency => l.c_waiting_dependency,
        RunnableClass::WaitingCapability => l.c_waiting_capability,
        RunnableClass::Held => l.c_held,
        RunnableClass::SetAside => l.c_set_aside,
        RunnableClass::Running => l.s_running,
        RunnableClass::Done => l.s_done,
    }
}

/// Typed progress emitted by the run engine. Identifiers and diagnostic
/// details are interpolated verbatim; only Yardlet-authored chrome changes.
pub enum RunProgress<'a> {
    Ambiguity {
        turn: u32,
        cap: u32,
    },
    Paused,
    WaitingForWorker(&'a str),
    WorkerLongRunning(&'a str),
    /// A Partial the drain cannot continue past. The remediation differs by
    /// cause, so the cause is carried through rather than assumed (issue #40).
    PartialNeedsYou {
        id: &'a str,
        kind: crate::run::PartialReasonKind,
        marker: &'a str,
        detail: Option<&'a str>,
    },
    ParallelOff(&'a str),
    ParallelSequential(&'a str),
    NeedsUserMany(&'a str),
    Stuck(&'a str),
    WaitingGated(&'a str),
    DrainedWithDeferred(&'a [&'a str]),
    DrainedComplete,
    ApprovalRetrySkipped(&'a str),
    Running(&'a str),
    Blocked(&'a str),
    NeedsUser(&'a str),
    PartialContinue(&'a str),
    FailedRetry(&'a str),
}

/// Per-cause stop wording. Only a genuine merge conflict asks for conflict
/// resolution; the others name what actually has to be fixed.
fn partial_needs_you(
    lang: Lang,
    id: &str,
    kind: crate::run::PartialReasonKind,
    marker: &str,
    detail: Option<&str>,
) -> String {
    use crate::run::PartialReasonKind as K;
    let detail_en = detail.map(|d| format!(" ({d})")).unwrap_or_default();
    let detail_ko = detail.map(|d| format!(" ({d})")).unwrap_or_default();
    match (lang, kind) {
        (Lang::En, K::MergeConflict) => format!(
            "stopped: {id} has a merge conflict; resolve it (see handoff), then run auto again"
        ),
        (Lang::Ko, K::MergeConflict) => format!(
            "정지: {id}에 병합 충돌이 있음; 핸드오프를 보고 해결한 뒤 자동 실행을 다시 시작하세요"
        ),
        (Lang::En, K::IntegrationError) => format!(
            "stopped: {id} could not be integrated; there is no conflict to resolve. See the run's handoff for the error, then run auto again"
        ),
        (Lang::Ko, K::IntegrationError) => format!(
            "정지: {id} 통합이 실패함; 해결할 충돌은 없습니다. run 핸드오프에서 오류를 확인한 뒤 자동 실행을 다시 시작하세요"
        ),
        (Lang::En, K::GitFinishUnverified) => format!(
            "stopped: {id} merged cleanly but its Git finish is unverified{detail_en}; fix that, then run auto again"
        ),
        (Lang::Ko, K::GitFinishUnverified) => format!(
            "정지: {id}는 병합은 깨끗했지만 Git finish가 검증되지 않음{detail_ko}; 해결한 뒤 자동 실행을 다시 시작하세요"
        ),
        (Lang::En, K::WorktreeCleanupChanged) => format!(
            "stopped: {id} merged, but its worktree changed during cleanup and was kept; inspect it, then run auto again"
        ),
        (Lang::Ko, K::WorktreeCleanupChanged) => format!(
            "정지: {id}는 병합됐지만 정리 중 worktree가 변경되어 보존됨; 확인한 뒤 자동 실행을 다시 시작하세요"
        ),
        (Lang::En, K::AutoCommitDisabled) => format!(
            "stopped: {id} left uncommitted work and auto-commit is off; commit it, then run auto again"
        ),
        (Lang::Ko, K::AutoCommitDisabled) => format!(
            "정지: {id}가 커밋되지 않은 작업을 남겼고 자동 커밋이 꺼져 있음; 커밋한 뒤 자동 실행을 다시 시작하세요"
        ),
        (Lang::En, K::Other) => {
            format!("stopped: {id} is partial ({marker}); resolve it, then run auto again")
        }
        (Lang::Ko, K::Other) => {
            format!("정지: {id}가 부분 완료 상태({marker}); 해결한 뒤 자동 실행을 다시 시작하세요")
        }
    }
}

pub fn run_progress(lang: Lang, event: RunProgress<'_>) -> String {
    match (lang, event) {
        (Lang::En, RunProgress::Ambiguity { turn, cap }) => format!(
            "stopped: the plan is still guessing (ambiguity high, interview turn {turn}/{cap}); answer its questions or accept the ambiguity"
        ),
        (Lang::Ko, RunProgress::Ambiguity { turn, cap }) => format!(
            "정지: 플랜의 모호성이 아직 높음 (인터뷰 {turn}/{cap}); 질문에 답하거나 모호성을 수락하세요"
        ),
        (Lang::En, RunProgress::Paused) => {
            "paused: stopped after the current task; run auto again to resume".to_string()
        }
        (Lang::Ko, RunProgress::Paused) => {
            "일시정지: 현재 태스크 완료 후 멈춤; 다시 자동 실행하면 재개됩니다".to_string()
        }
        (Lang::En, RunProgress::WaitingForWorker(id)) => {
            format!("waiting for {id}'s worker from a previous session\u{2026}")
        }
        (Lang::Ko, RunProgress::WaitingForWorker(id)) => {
            format!("이전 세션의 {id} 워커를 기다리는 중\u{2026}")
        }
        (Lang::En, RunProgress::WorkerLongRunning(id)) => format!(
            "stopped: {id} has run for 30+ minutes; stop its worker or keep waiting, then run auto again"
        ),
        (Lang::Ko, RunProgress::WorkerLongRunning(id)) => format!(
            "정지: {id}가 30분 넘게 실행 중; 워커를 정지하거나 계속 기다린 뒤 자동 실행을 다시 시작하세요"
        ),
        (
            lang,
            RunProgress::PartialNeedsYou {
                id,
                kind,
                marker,
                detail,
            },
        ) => partial_needs_you(lang, id, kind, marker, detail),
        (Lang::En, RunProgress::ParallelOff(reason)) => {
            format!("parallel off ({reason}); running sequentially")
        }
        (Lang::Ko, RunProgress::ParallelOff(reason)) => {
            format!("병렬 실행 꺼짐 ({reason}); 순차 실행합니다")
        }
        (Lang::En, RunProgress::ParallelSequential(summary)) => {
            format!("parallel sequential: {summary}")
        }
        (Lang::Ko, RunProgress::ParallelSequential(summary)) => {
            format!("병렬화 없이 순차 실행: {summary}")
        }
        (Lang::En, RunProgress::NeedsUserMany(ids)) => format!(
            "stopped: {ids} need you; answer or resolve them, then run auto again"
        ),
        (Lang::Ko, RunProgress::NeedsUserMany(ids)) => format!(
            "정지: {ids}에 사용자 응답 필요; 답하거나 해결한 뒤 자동 실행을 다시 시작하세요"
        ),
        (Lang::En, RunProgress::Stuck(tasks)) => format!(
            "stopped: {tasks}; the blocking task will not complete, so fix, defer, or re-scope it"
        ),
        (Lang::Ko, RunProgress::Stuck(tasks)) => format!(
            "정지: {tasks}; 선행 태스크가 완료될 수 없으므로 수정, 보류 또는 범위 조정이 필요합니다"
        ),
        (Lang::En, RunProgress::WaitingGated(ids)) => {
            format!("stopped: {ids} waiting on approval or dependencies")
        }
        (Lang::Ko, RunProgress::WaitingGated(ids)) => {
            format!("정지: {ids} 승인 또는 의존성 대기 중")
        }
        (Lang::En, RunProgress::DrainedWithDeferred(ids)) => format!(
            "done: queue drained; {} set aside: {}; revive any to continue",
            ids.len(),
            ids.join(", ")
        ),
        (Lang::Ko, RunProgress::DrainedWithDeferred(ids)) => format!(
            "완료: 큐 비움; {}개 보류: {}; 계속하려면 태스크를 되살리세요",
            ids.len(),
            ids.join(", ")
        ),
        (Lang::En, RunProgress::DrainedComplete) => {
            "done: queue drained, all tasks complete".to_string()
        }
        (Lang::Ko, RunProgress::DrainedComplete) => {
            "완료: 큐를 비웠고 모든 태스크가 끝났습니다".to_string()
        }
        (Lang::En, RunProgress::ApprovalRetrySkipped(id)) => {
            format!("{id} requires approval; skipped retry and continued runnable work")
        }
        (Lang::Ko, RunProgress::ApprovalRetrySkipped(id)) => {
            format!("{id} 승인 필요; 재시도를 건너뛰고 실행 가능한 작업을 계속합니다")
        }
        (Lang::En, RunProgress::Running(id)) => format!("running {id}\u{2026}"),
        (Lang::Ko, RunProgress::Running(id)) => format!("{id} 실행 중\u{2026}"),
        (Lang::En, RunProgress::Blocked(id)) => {
            format!("stopped: {id} blocked; resolve it, then run again")
        }
        (Lang::Ko, RunProgress::Blocked(id)) => {
            format!("정지: {id} 막힘; 해결한 뒤 다시 실행하세요")
        }
        (Lang::En, RunProgress::NeedsUser(id)) => {
            format!("stopped: {id} needs you; answer it, then run again")
        }
        (Lang::Ko, RunProgress::NeedsUser(id)) => {
            format!("정지: {id}에 사용자 응답 필요; 답한 뒤 다시 실행하세요")
        }
        (Lang::En, RunProgress::PartialContinue(id)) => {
            format!("{id} is partial; continuing from its checkpoint")
        }
        (Lang::Ko, RunProgress::PartialContinue(id)) => {
            format!("{id} 부분완료; 체크포인트에서 계속합니다")
        }
        (Lang::En, RunProgress::FailedRetry(id)) => format!("{id} failed; retrying"),
        (Lang::Ko, RunProgress::FailedRetry(id)) => format!("{id} 실패; 재시도합니다"),
    }
}

/// Label table. Every user-visible TUI string lives here.
pub struct L {
    pub subtitle: &'static str,
    pub workspace: &'static str,
    pub workers_word: &'static str,
    pub worker_word: &'static str,
    pub task_word: &'static str,
    pub ready_word: &'static str,
    pub planner: &'static str,
    pub access_word: &'static str,
    pub parallel_word: &'static str,
    pub ime_word: &'static str,
    pub language_word: &'static str,
    pub default_word: &'static str,
    pub current_word: &'static str,
    pub follow_up_word: &'static str,
    pub drain_word: &'static str,
    pub model_word: &'static str,
    pub effort_word: &'static str,
    pub unknown_word: &'static str,
    pub auto_word: &'static str,
    pub intent: &'static str,
    pub status: &'static str,
    pub s_running: &'static str,
    pub s_needs: &'static str,
    pub s_blocked: &'static str,
    pub s_done: &'static str,
    pub s_failed: &'static str,
    pub s_partial: &'static str,
    pub s_deferred: &'static str,
    pub s_queued: &'static str,
    pub c_ready: &'static str,
    pub c_waiting_decision: &'static str,
    pub c_waiting_approval: &'static str,
    pub c_waiting_dependency: &'static str,
    pub c_waiting_capability: &'static str,
    pub c_held: &'static str,
    pub c_set_aside: &'static str,
    pub queue_word: &'static str,
    pub queue_empty: &'static str,
    pub waiting_any_order: &'static str,
    pub tag_anytime: &'static str,
    pub tag_input: &'static str,
    pub tag_approval: &'static str,
    pub parallel_running_label: &'static str,
    pub workers_title: &'static str,
    pub w_ready: &'static str,
    pub w_ambiguous: &'static str,
    pub w_notready: &'static str,
    pub w_disabled: &'static str,
    pub worker_on: &'static str,
    pub worker_off: &'static str,
    pub worker_toggle_hint: &'static str,
    pub version_unknown: &'static str,
    pub w_env_clean: &'static str,
    pub w_env_scrubbed: &'static str,
    pub w_env_blocked: &'static str,
    pub w_model: &'static str,
    pub w_model_default: &'static str,
    pub run_word: &'static str,
    pub sec_unit: &'static str,
    pub idle: &'static str,
    pub update_ready: &'static str,
    pub needs_you: &'static str,
    pub plan_needs: &'static str,
    pub press_a: &'static str,
    pub see_handoff: &'static str,
    /// Always-visible leading keys for the idle Home footer.
    pub footer_home: &'static str,
    pub key_tidy: &'static str,
    pub key_defer: &'static str,
    pub key_revive: &'static str,
    pub key_monitor: &'static str,
    pub key_handoff: &'static str,
    pub key_trust: &'static str,
    pub key_quit: &'static str,
    /// Shown on Home during a pausable auto-drain: includes `p pause`.
    pub footer_home_busy: &'static str,
    /// Shown on Home during a non-drain job (planning / single run): no `p
    /// pause` (nothing to pause between tasks) — only `Esc stop`.
    pub footer_home_busy_nodrain: &'static str,
    /// Conditionally appended to the Home footer when relevant.
    pub key_answer: &'static str,
    pub key_approve: &'static str,
    pub key_replan: &'static str,
    /// Offered whenever an open planning session is waiting on the operator.
    pub key_plan_review: &'static str,
    /// Suffixes for the `N ready` breakdown when the scheduler will not start
    /// what the count implies (issue #51).
    pub ready_review_barrier: &'static str,
    pub ready_reviews_serial: &'static str,
    /// Always offered: the full key list. Home's footer can only carry the keys
    /// with a target right now, so the always-valid globals live behind this
    /// one advertised key (issue #71).
    pub key_keys: &'static str,
    pub keys_title: &'static str,
    pub keys_intro: &'static str,
    pub footer_keys: &'static str,
    /// One line per Home action. Every key Home dispatches has an entry here;
    /// `HomeKey::doc` is exhaustive, so a new action cannot compile undocumented.
    pub key_doc_quit: &'static str,
    pub key_doc_restart: &'static str,
    pub key_doc_new: &'static str,
    pub key_doc_replan: &'static str,
    pub key_doc_run: &'static str,
    pub key_doc_auto: &'static str,
    pub key_doc_tidy: &'static str,
    pub key_doc_defer: &'static str,
    pub key_doc_revive: &'static str,
    pub key_doc_approve_or_pause: &'static str,
    pub key_doc_answer: &'static str,
    pub key_doc_goal: &'static str,
    pub key_doc_handoff: &'static str,
    pub key_doc_trust: &'static str,
    pub key_doc_settings: &'static str,
    pub key_doc_monitor: &'static str,
    pub key_doc_refresh: &'static str,
    pub key_doc_language: &'static str,
    pub key_doc_access: &'static str,
    pub key_doc_plan_review: &'static str,
    pub key_doc_reports: &'static str,
    pub key_doc_stop: &'static str,
    pub key_doc_keys: &'static str,
    pub key_doc_up: &'static str,
    pub key_doc_down: &'static str,
    pub key_doc_act: &'static str,
    pub key_doc_toggle_worker: &'static str,
    /// Home rows for an open planning session. The queue is legitimately empty
    /// in this state, so these are the only thing distinguishing "a plan is
    /// waiting" from "there is no work" (issue #65). `{n}` is the count.
    pub home_plan_pending: &'static str,
    pub home_plan_accepted: &'static str,
    pub home_plan_unreadable: &'static str,
    /// Shown when `o` is pressed with no planning session to re-enter.
    pub plan_review_nothing: &'static str,
    pub replan_worker_question_hint: &'static str,
    pub replan_live_queue_hint: &'static str,
    pub replan_nothing_hint: &'static str,
    pub approvals_title: &'static str,
    pub footer_approvals: &'static str,
    pub approvals_empty: &'static str,
    pub approval_batch_approved: &'static str,
    pub approval_batch_deferred: &'static str,
    pub approval_batch_hold_reason: &'static str,
    pub busy: &'static str,
    pub not_pausable: &'static str,
    pub stopping: &'static str,
    pub pausing: &'static str,
    pub no_pending: &'static str,
    pub no_answer_target: &'static str,
    pub nothing_to_run: &'static str,
    pub approval_needed: &'static str,
    pub no_approval: &'static str,
    /// Shown when Enter is pressed on an approval-only task: Enter must never
    /// auto-run it, so it points at the approval flow (`p`) instead.
    pub approval_enter_hint: &'static str,
    /// Shown when Enter is pressed on a deferred (set-aside) task.
    pub deferred_enter_hint: &'static str,
    pub initialized: &'static str,
    pub startup_loading: &'static str,
    pub startup_recovery: &'static str,
    pub startup_probe: &'static str,
    pub startup_failed: &'static str,
    pub background_job_failed: &'static str,
    pub no_workspace_state: &'static str,
    pub footer_startup_loading: &'static str,
    pub footer_startup_failed: &'static str,
    pub newwork_title: &'static str,
    pub newwork_prompt: &'static str,
    pub replan_title: &'static str,
    pub replan_prompt: &'static str,
    pub request_title: &'static str,
    pub footer_newwork: &'static str,
    pub footer_replan: &'static str,
    pub asking_word: &'static str,
    pub no_question: &'static str,
    pub answer_context_title: &'static str,
    pub worker_output_title: &'static str,
    pub conversation_title: &'static str,
    pub compact_summary_title: &'static str,
    pub question_title: &'static str,
    pub conversation_worker: &'static str,
    pub conversation_user: &'static str,
    pub no_answer_context: &'static str,
    pub your_answer_title: &'static str,
    pub footer_answer: &'static str,
    pub footer_answer_approve: &'static str,
    pub handoff_title: &'static str,
    pub footer_handoff: &'static str,
    pub intent_title: &'static str,
    pub footer_intent: &'static str,
    pub trust_title: &'static str,
    pub footer_trust: &'static str,
    pub completion_title: &'static str,
    pub footer_completion: &'static str,
    pub reports_title: &'static str,
    pub footer_reports: &'static str,
    pub reports_empty: &'static str,
    pub report_empty: &'static str,
    pub history_promoted: &'static str,
    pub history_promote_failed: &'static str,
    pub archive_failed: &'static str,
    pub redo_done: &'static str,
    pub settings_title: &'static str,
    pub footer_settings: &'static str,
    pub settings_saved: &'static str,
    pub settings_saved_busy: &'static str,
    pub monitor_title: &'static str,
    pub footer_monitor: &'static str,
    pub monitor_no_runs: &'static str,
    // conversational planning review
    pub planning_review_title: &'static str,
    pub planning_session: &'static str,
    pub planning_conversation: &'static str,
    pub planning_visible_head: &'static str,
    pub planning_visible_draft: &'static str,
    pub planning_no_visible_draft: &'static str,
    pub planning_pending_proposals: &'static str,
    pub planning_no_pending_proposal: &'static str,
    pub planning_multiple_pending: &'static str,
    pub planning_select_hint: &'static str,
    pub planning_target_marker: &'static str,
    /// Header marker for a pending proposal whose authored head no longer
    /// matches the visible head, so accepting it would fail the core CAS check.
    pub planning_stale_marker: &'static str,
    pub planning_proposal: &'static str,
    pub planning_attempt: &'static str,
    pub planning_expected_head: &'static str,
    pub planning_rationale: &'static str,
    pub planning_goal: &'static str,
    pub planning_allowed_scope: &'static str,
    pub planning_out_of_scope: &'static str,
    pub planning_acceptance: &'static str,
    pub planning_tasks: &'static str,
    pub planning_dependencies: &'static str,
    pub planning_questions: &'static str,
    pub planning_semantic_diff: &'static str,
    pub planning_before: &'static str,
    pub planning_after: &'static str,
    pub planning_none: &'static str,
    pub planning_revision_title: &'static str,
    pub footer_planning_review: &'static str,
    pub footer_planning_review_busy: &'static str,
    pub footer_planning_revision: &'static str,
    pub planning_review_failed: &'static str,
    pub planning_accepted: &'static str,
    pub planning_rejected: &'static str,
    pub planning_confirmed: &'static str,
    // job-result prefixes (mixed with worker-authored content)
    pub planned_via: &'static str,
    pub tasks_word: &'static str,
    pub planning_failed: &'static str,
    pub via_word: &'static str,
    pub run_failed: &'static str,
    pub resumed_via: &'static str,
    pub answer_failed: &'static str,
    pub trust_report_failed: &'static str,
    pub no_intent: &'static str,
    pub no_task_handoff: &'static str,
    pub no_latest_handoff: &'static str,
    pub latest_handoff_failed: &'static str,
    pub cannot_defer_state: &'static str,
    pub deferred_tasks: &'static str,
    pub cannot_revive_state: &'static str,
    pub revived_tasks: &'static str,
    pub tidy_word: &'static str,
    pub migrated_word: &'static str,
    pub archived_word: &'static str,
    pub channel_worker_started: &'static str,
    pub channel_tool_started: &'static str,
    pub channel_tool_completed: &'static str,
    pub channel_question: &'static str,
    pub channel_user: &'static str,
    pub channel_checkpoint: &'static str,
    pub channel_worker_completed: &'static str,
    pub channel_task_completed: &'static str,
    pub channel_validation_started: &'static str,
    pub channel_validation_completed: &'static str,
    pub passed_word: &'static str,
}

pub const EN: L = L {
    subtitle: "Local AI Workbench",
    workspace: "Workspace: ",
    workers_word: "Workers",
    worker_word: "worker",
    task_word: "task",
    ready_word: "invocable",
    planner: "Planner",
    access_word: "Access",
    parallel_word: "Parallel tasks",
    ime_word: "Auto IME switch",
    language_word: "Language",
    default_word: "default",
    current_word: "current",
    follow_up_word: "follow-up",
    drain_word: "drain",
    model_word: "model",
    effort_word: "effort",
    unknown_word: "unknown",
    auto_word: "auto",
    intent: "Intent: ",
    status: "Status: ",
    s_running: "running",
    s_needs: "needs-you",
    s_blocked: "blocked",
    s_done: "done",
    s_failed: "failed",
    s_partial: "partial",
    s_deferred: "deferred",
    s_queued: "queued",
    c_ready: "ready",
    c_waiting_decision: "awaiting decision",
    c_waiting_approval: "awaiting approval",
    c_waiting_dependency: "blocked on deps",
    c_waiting_capability: "needs worker",
    c_held: "held",
    c_set_aside: "set aside",
    queue_word: "Queue",
    queue_empty: "  (queue empty \u{2014} press n to describe new work)",
    waiting_any_order: "Waiting work is order-independent: select any marked row, then answer or approve in place.",
    tag_anytime: "anytime",
    tag_input: "input",
    tag_approval: "approval",
    parallel_running_label: "Running in parallel",
    workers_title: " Workers ",
    w_ready: "invocable",
    w_ambiguous: "ambiguous",
    w_notready: "not ready",
    w_disabled: "off",
    worker_on: "enabled",
    worker_off: "disabled",
    worker_toggle_hint: "  Enter/Space toggle",
    version_unknown: "version unknown",
    w_env_clean: "env clean",
    w_env_scrubbed: "scrubbed",
    w_env_blocked: "env blocked",
    w_model: "model",
    w_model_default: "CLI default",
    run_word: "running",
    sec_unit: "s",
    idle: " idle",
    update_ready: " \u{2B06} new yard build installed \u{2014} press u to restart into it",
    needs_you: "needs you",
    plan_needs: "the plan has questions \u{2014} interview",
    press_a: "  (press a)",
    see_handoff: "see handoff",
    footer_home: "\u{2191}\u{2193} select  Enter action  n new  r run  A auto",
    key_tidy: "t tidy",
    key_defer: "d defer",
    key_revive: "v revive",
    key_monitor: "m monitor",
    key_handoff: "h handoff",
    key_trust: "T trust",
    key_quit: "q quit",
    footer_home_busy: "running...  p pause  Esc stop  m monitor  h handoff  i goal  f access  s settings  ? keys  q quit",
    footer_home_busy_nodrain: "running...  Esc stop  m monitor  h handoff  i goal  f access  s settings  ? keys  q quit",
    key_answer: "a answer",
    key_approve: "p approve",
    key_replan: "P replan",
    key_plan_review: "o plan review",
    ready_review_barrier: " held by the review barrier",
    ready_reviews_serial: "reviews run one at a time",
    key_keys: "? keys",
    keys_title: " Home keys ",
    keys_intro: "Every key Home accepts. The footer only lists the ones with something to act on right now; all of these work.",
    footer_keys: "\u{2191}/\u{2193}/PgUp/PgDn scroll  Esc/q/? back",
    key_doc_quit: "quit Yardlet",
    key_doc_restart: "restart into a newly installed binary (offered when one is ready)",
    key_doc_new: "describe new work",
    key_doc_replan: "replan this intent from a settled queue",
    key_doc_run: "run the next task",
    key_doc_auto: "drain the queue",
    key_doc_tidy: "archive settled work",
    key_doc_defer: "set the selected task aside",
    key_doc_revive: "bring a deferred task back",
    key_doc_approve_or_pause: "approve the selected task, or pause a running drain",
    key_doc_answer: "answer the open question",
    key_doc_goal: "show the intent contract",
    key_doc_handoff: "show the latest handoff",
    key_doc_trust: "trust and autonomy panel",
    key_doc_settings: "open settings",
    key_doc_monitor: "follow the worker's live output",
    key_doc_refresh: "reload the workspace and re-probe worker readiness",
    key_doc_language: "switch language",
    key_doc_access: "toggle the worker access level",
    key_doc_plan_review: "open the planning review",
    key_doc_reports: "reports and past intents",
    key_doc_stop: "stop the running worker",
    key_doc_keys: "this list",
    key_doc_up: "move the selection up",
    key_doc_down: "move the selection down",
    key_doc_act: "act on the selected row",
    key_doc_toggle_worker: "enable or disable the selected worker",
    home_plan_pending: "\u{25b6} {n} plan proposal(s) waiting for review: press o",
    home_plan_accepted: "\u{25b6} an accepted plan is waiting to be confirmed into the queue: press o",
    home_plan_unreadable: "\u{25b6} a planning session exists but could not be read: press o for the error",
    plan_review_nothing: "no open planning session to review; press n to describe new work",
    replan_worker_question_hint: "a worker question is open; press a and answer it instead of replanning",
    replan_live_queue_hint: "the queue still has live work; finish or settle it before replanning",
    replan_nothing_hint: "this settled queue has no failed approach to replan; press n for follow-up work",
    approvals_title: " Approvals ",
    footer_approvals: "\u{2191}\u{2193} select row  Space include/exclude  Enter/p approve selected  A approve all  d hold selected  q back",
    approvals_empty: "no tasks are waiting for approval",
    approval_batch_approved: "approved",
    approval_batch_deferred: "held",
    approval_batch_hold_reason: "held from the TUI approval screen",
    busy: "a worker is running \u{2014} press m to watch it, or Esc to stop",
    not_pausable: "not a pausable drain (planning / single run) \u{2014} press Esc to stop",
    stopping: "stopping the worker (the task will need a retry)",
    pausing: "pausing \u{2014} will stop after the current task",
    no_pending: "nothing needs your answer right now \u{2014} press r to run the next task, or n to add work",
    no_answer_target: "no task to answer \u{2014} press r to run, or n to add work",
    nothing_to_run: "nothing to run \u{2014} the queue is empty or every task is done; press n to add work",
    approval_needed: "need approval",
    no_approval: "no task is waiting for approval \u{2014} press r to run, or A to auto-run the queue",
    approval_enter_hint: "needs approval before it can run \u{2014} press p to approve, then it runs",
    deferred_enter_hint: "deferred \u{2014} set aside by a decision, not scheduled to run",
    initialized: "initialized Yardlet workspace (.agents/)",
    startup_loading: "Starting Yardlet safely",
    startup_recovery: "Validating activation and recovering interrupted work",
    startup_probe: "Checking worker readiness",
    startup_failed: "Startup failed:",
    background_job_failed: "Background job ended unexpectedly; state will be recovered",
    no_workspace_state: "No workspace state loaded.",
    footer_startup_loading: "startup in progress  q quit",
    footer_startup_failed: "g retry  q quit",
    newwork_title: " New Work ",
    newwork_prompt: "Describe the work in a few sentences. Yardlet plans, queues, and runs it.",
    replan_title: " Replan This Intent ",
    replan_prompt: "Describe the replacement direction. Yardlet keeps the same intent id and proposes a new plan for this failure-settled queue.",
    request_title: " Request ",
    footer_newwork: "Enter newline   Ctrl+S submit   Ctrl+Enter submit (when supported)   Esc cancel",
    footer_replan: "Enter newline   Ctrl+S start same-intent replan   Ctrl+Enter submit (when supported)   Esc cancel",
    asking_word: "is asking",
    no_question: "(no recorded question \u{2014} see the handoff)",
    answer_context_title: " Answer context ",
    worker_output_title: "Latest worker output",
    conversation_title: "Conversation",
    compact_summary_title: "Compact summary",
    question_title: "Question",
    conversation_worker: "Worker",
    conversation_user: "You",
    no_answer_context: "No related worker output or conversation was recorded.",
    your_answer_title: " Your answer ",
    footer_answer: "PgUp/PgDn context   Enter newline   Ctrl+S send & resume   Ctrl+Enter send (when supported)   Esc cancel",
    footer_answer_approve: "PgUp/PgDn context   Enter newline   Ctrl+S send, approve & resume   Ctrl+Enter send (when supported)   Esc cancel",
    handoff_title: " Handoff \u{00b7} latest run ",
    footer_handoff: "\u{2191}/\u{2193} scroll  Esc/q back",
    intent_title: " Intent \u{00b7} full goal ",
    footer_intent: "\u{2191}/\u{2193} scroll  i/Esc/q back",
    trust_title: " Trust \u{00b7} autonomy ",
    footer_trust: "\u{2191}/\u{2193} scroll  T/Esc/q back",
    completion_title: " Final report ",
    footer_completion: "n new  c continue  R redo  \u{2191}/\u{2193} scroll  q back",
    reports_title: " Reports ",
    footer_reports: "\u{2191}/\u{2193} select  Enter open  q back",
    reports_empty: "(no reports yet)",
    report_empty: "(no report)",
    history_promoted: "promoted follow-up",
    history_promote_failed: "Could not promote follow-up:",
    archive_failed: "Could not archive and clear live work:",
    redo_done: "requeued for redo",
    settings_title: " Settings ",
    footer_settings: "type to edit   Space cycle   \u{2191}/\u{2193} move   Esc save",
    settings_saved: "settings saved",
    settings_saved_busy: "settings saved \u{2014} applies to the next task (the running one keeps its model)",
    monitor_title: " Run Monitor ",
    footer_monitor: "\u{2191}\u{2193}/PgUp/PgDn scroll \u{00b7} End follow \u{00b7} Tab/\u{2190}\u{2192} switch run \u{00b7} x stop \u{00b7} p pause \u{00b7} Esc/q back",
    monitor_no_runs: "No runs yet. Press r or A on Home to start one.",
    planning_review_title: " Planning Review ",
    planning_session: "Session",
    planning_conversation: "Conversation",
    planning_visible_head: "Visible head",
    planning_visible_draft: "Accepted visible draft",
    planning_no_visible_draft: "no accepted visible draft",
    planning_pending_proposals: "Pending proposals",
    planning_no_pending_proposal: "no pending proposal",
    planning_multiple_pending: "Multiple proposals pending",
    planning_select_hint: "Tab switches the target",
    planning_target_marker: "accept/reject target",
    planning_stale_marker: "stale: newer head accepted",
    planning_proposal: "Proposal",
    planning_attempt: "Attempt",
    planning_expected_head: "Expected head",
    planning_rationale: "Rationale",
    planning_goal: "Goal",
    planning_allowed_scope: "Allowed scope",
    planning_out_of_scope: "Out of scope",
    planning_acceptance: "Acceptance",
    planning_tasks: "Tasks",
    planning_dependencies: "Dependencies",
    planning_questions: "Questions",
    planning_semantic_diff: "Semantic diff",
    planning_before: "before",
    planning_after: "after",
    planning_none: "none",
    planning_revision_title: " Revision request ",
    footer_planning_review: "\u{2191}/\u{2193}/PgUp/PgDn scroll  a accept  r reject  Tab target  e revise  c confirm  g refresh  Esc/q back",
    footer_planning_review_busy: "planning revision...  Esc/q back",
    footer_planning_revision: "Enter newline   Ctrl+S send revision   Ctrl+Enter submit (when supported)   Esc cancel",
    planning_review_failed: "Planning review failed:",
    planning_accepted: "Proposal accepted as visible draft",
    planning_rejected: "Proposal rejected",
    planning_confirmed: "Exact visible draft confirmed",
    planned_via: "Planned via",
    tasks_word: "tasks",
    planning_failed: "Planning failed:",
    via_word: "via",
    run_failed: "Run failed:",
    resumed_via: "resumed via",
    answer_failed: "Answer/resume failed:",
    trust_report_failed: "Could not build the trust report:",
    no_intent: "No intent yet; press n to describe new work.",
    no_task_handoff: "No handoff for this task yet; run it first.",
    no_latest_handoff: "No handoff yet. Run a task first.",
    latest_handoff_failed: "Latest run has no handoff yet.",
    cannot_defer_state: "cannot defer this state",
    deferred_tasks: "Deferred",
    cannot_revive_state: "only deferred tasks can be revived",
    revived_tasks: "Revived",
    tidy_word: "tidy",
    migrated_word: "migrated",
    archived_word: "archived",
    channel_worker_started: "worker started",
    channel_tool_started: "tool started",
    channel_tool_completed: "tool completed",
    channel_question: "question",
    channel_user: "user",
    channel_checkpoint: "worker checkpoint recorded",
    channel_worker_completed: "worker completed",
    channel_task_completed: "task completed",
    channel_validation_started: "validation started",
    channel_validation_completed: "validation completed",
    passed_word: "passed",
};

pub const KO: L = L {
    subtitle: "로컬 AI 워크벤치",
    workspace: "워크스페이스: ",
    workers_word: "워커",
    worker_word: "워커",
    task_word: "태스크",
    ready_word: "호출가능",
    planner: "플래너",
    access_word: "권한",
    parallel_word: "병렬 작업 수",
    ime_word: "한/영 자동 전환",
    language_word: "언어",
    default_word: "기본",
    current_word: "현재",
    follow_up_word: "후속작업",
    drain_word: "실행 기록",
    model_word: "모델",
    effort_word: "추론 강도",
    unknown_word: "알 수 없음",
    auto_word: "자동",
    intent: "목표: ",
    status: "상태: ",
    s_running: "실행",
    s_needs: "응답대기",
    s_blocked: "막힘",
    s_done: "완료",
    s_failed: "실패",
    s_partial: "부분완료",
    s_deferred: "보류",
    s_queued: "대기",
    c_ready: "실행가능",
    c_waiting_decision: "결정대기",
    c_waiting_approval: "승인대기",
    c_waiting_dependency: "의존대기",
    c_waiting_capability: "워커대기",
    c_held: "멈춤",
    c_set_aside: "보류",
    queue_word: "큐",
    queue_empty: "  (큐 비어 있음 — n 눌러 새 작업 입력)",
    waiting_any_order: "대기 작업은 큐 순서와 무관합니다: 표시된 행을 골라 그 자리에서 답변/승인하세요.",
    tag_anytime: "아무때나",
    tag_input: "입력",
    tag_approval: "승인",
    parallel_running_label: "병렬 실행 중",
    workers_title: " 워커 ",
    w_ready: "호출가능",
    w_ambiguous: "모호",
    w_notready: "준비안됨",
    w_disabled: "꺼짐",
    worker_on: "켜짐",
    worker_off: "꺼짐",
    worker_toggle_hint: "  Enter/Space 토글",
    version_unknown: "버전 미상",
    w_env_clean: "환경 깨끗",
    w_env_scrubbed: "스크럽",
    w_env_blocked: "환경 차단",
    w_model: "모델",
    w_model_default: "CLI 기본",
    run_word: "실행 중",
    sec_unit: "초",
    idle: " 대기",
    update_ready: " \u{2B06} 새 yard 빌드 설치됨 \u{2014} u 누르면 재시작해서 반영",
    needs_you: "응답 필요",
    plan_needs: "플랜 확정 질문 \u{2014} 인터뷰",
    press_a: "  (a 키)",
    see_handoff: "핸드오프 참고",
    footer_home: "\u{2191}\u{2193} 선택  Enter 행동  n 새작업  r 실행  A 자동",
    key_tidy: "t 정리",
    key_defer: "d 보류",
    key_revive: "v 되살림",
    key_monitor: "m 모니터",
    key_handoff: "h 핸드오프",
    key_trust: "T 신뢰",
    key_quit: "q 종료",
    footer_home_busy: "실행 중...  p 일시정지  Esc 정지  m 모니터  h 핸드오프  i 목표  f 권한  s 설정  ? 키목록  q 종료",
    footer_home_busy_nodrain: "실행 중...  Esc 정지  m 모니터  h 핸드오프  i 목표  f 권한  s 설정  ? 키목록  q 종료",
    key_answer: "a 답변",
    key_approve: "p 승인",
    key_replan: "P 재계획",
    key_plan_review: "o 플랜 검토",
    ready_review_barrier: " 리뷰 배리어 대기",
    ready_reviews_serial: "리뷰는 한 번에 하나씩",
    key_keys: "? 키목록",
    keys_title: " 홈 키 목록 ",
    keys_intro: "홈에서 받는 모든 키입니다. 푸터에는 지금 대상이 있는 키만 나오지만, 아래는 전부 동작합니다.",
    footer_keys: "\u{2191}/\u{2193}/PgUp/PgDn 스크롤  Esc/q/? 뒤로",
    key_doc_quit: "Yardlet 종료",
    key_doc_restart: "새로 설치된 바이너리로 재시작 (준비됐을 때만 제공)",
    key_doc_new: "새 작업 입력",
    key_doc_replan: "종결된 큐를 같은 인텐트로 재계획",
    key_doc_run: "다음 태스크 실행",
    key_doc_auto: "큐 자동 드레인",
    key_doc_tidy: "종결된 작업 아카이브",
    key_doc_defer: "선택한 태스크 보류",
    key_doc_revive: "보류한 태스크 되살림",
    key_doc_approve_or_pause: "선택한 태스크 승인, 또는 진행 중인 드레인 일시정지",
    key_doc_answer: "열린 질문에 답변",
    key_doc_goal: "인텐트 계약 보기",
    key_doc_handoff: "최신 핸드오프 보기",
    key_doc_trust: "신뢰·자율성 패널",
    key_doc_settings: "설정 열기",
    key_doc_monitor: "워커 실시간 출력 따라가기",
    key_doc_refresh: "워크스페이스 새로고침 + 워커 준비 상태 재확인",
    key_doc_language: "언어 전환",
    key_doc_access: "워커 권한 수준 전환",
    key_doc_plan_review: "플랜 검토 화면 열기",
    key_doc_reports: "리포트와 지난 인텐트",
    key_doc_stop: "실행 중인 워커 정지",
    key_doc_keys: "이 목록",
    key_doc_up: "선택 위로",
    key_doc_down: "선택 아래로",
    key_doc_act: "선택한 행에 대해 행동",
    key_doc_toggle_worker: "선택한 워커 켜기/끄기",
    home_plan_pending: "\u{25b6} 검토 대기 중인 플랜 제안 {n}건: o 키",
    home_plan_accepted: "\u{25b6} 수락된 플랜이 큐 확정을 기다리는 중: o 키",
    home_plan_unreadable: "\u{25b6} 플래닝 세션이 있으나 읽을 수 없음: o 키로 오류 확인",
    plan_review_nothing: "검토할 열린 플래닝 세션이 없습니다. 새 작업은 n을 누르세요",
    replan_worker_question_hint: "워커 질문이 열려 있음. 재계획 대신 a 눌러 답변하세요",
    replan_live_queue_hint: "큐에 진행 중인 작업이 있음. 완료하거나 종결한 뒤 재계획하세요",
    replan_nothing_hint: "이 종결 큐에는 재계획할 실패 접근이 없음. 후속 작업은 n을 누르세요",
    approvals_title: " 승인 ",
    footer_approvals: "\u{2191}\u{2193} 행 선택  Space 포함/제외  Enter/p 선택 승인  A 전체 승인  d 선택 보류  q 뒤로",
    approvals_empty: "승인 대기 중인 작업 없음",
    approval_batch_approved: "승인됨",
    approval_batch_deferred: "보류됨",
    approval_batch_hold_reason: "TUI 승인 화면에서 보류",
    busy: "워커 실행 중 \u{2014} m 눌러 진행 보기, 또는 Esc 정지",
    not_pausable: "일시정지 대상이 아님 (플래닝 / 단일 실행) \u{2014} 멈추려면 Esc",
    stopping: "워커 정지 중 (태스크는 재시도 필요)",
    pausing: "일시정지 \u{2014} 현재 태스크 끝나면 멈춤",
    no_pending: "지금 답할 작업 없음 \u{2014} r 눌러 다음 작업 실행, 또는 n 눌러 새 작업 추가",
    no_answer_target: "응답할 작업 없음 \u{2014} r 눌러 실행, 또는 n 눌러 새 작업 추가",
    nothing_to_run: "실행할 작업 없음 \u{2014} 큐가 비어 있거나 모두 끝남; n 눌러 새 작업 추가",
    approval_needed: "승인 필요",
    no_approval: "승인 대기 중인 작업 없음 \u{2014} r 눌러 실행, 또는 A 눌러 큐 자동 실행",
    approval_enter_hint: "실행 전 승인 필요 \u{2014} p 눌러 승인하면 실행됩니다",
    deferred_enter_hint: "보류됨 \u{2014} 결정으로 미뤄둔 작업이라 실행 대상이 아님",
    initialized: "Yardlet 워크스페이스 생성됨 (.agents/)",
    startup_loading: "Yardlet 안전 시작 중",
    startup_recovery: "활성화 검증 및 중단 작업 복구 중",
    startup_probe: "워커 준비 상태 확인 중",
    startup_failed: "시작 실패:",
    background_job_failed: "백그라운드 작업이 예기치 않게 종료됨; 상태를 복구합니다",
    no_workspace_state: "워크스페이스 상태를 불러오지 못했습니다.",
    footer_startup_loading: "시작 준비 중  q 종료",
    footer_startup_failed: "g 재시도  q 종료",
    newwork_title: " 새 작업 ",
    newwork_prompt: "작업을 몇 문장으로 설명하세요. Yardlet 가 계획·큐·실행합니다.",
    replan_title: " 같은 목표 재계획 ",
    replan_prompt: "대체 방향을 설명하세요. 같은 intent id를 유지하고 실패 종결 큐의 새 계획을 제안합니다.",
    request_title: " 요청 ",
    footer_newwork: "Enter 줄바꿈   Ctrl+S 전송   Ctrl+Enter 전송(지원 터미널)   Esc 취소",
    footer_replan: "Enter 줄바꿈   Ctrl+S same-intent 재계획 시작   Ctrl+Enter 전송(지원 터미널)   Esc 취소",
    asking_word: "질문",
    no_question: "(기록된 질문 없음 — 핸드오프 참고)",
    answer_context_title: " 답변 문맥 ",
    worker_output_title: "최신 워커 출력",
    conversation_title: "대화 기록",
    compact_summary_title: "요약",
    question_title: "질문",
    conversation_worker: "워커",
    conversation_user: "사용자",
    no_answer_context: "관련 워커 출력이나 대화 기록이 없습니다.",
    your_answer_title: " 답변 ",
    footer_answer: "PgUp/PgDn 문맥 스크롤   Enter 줄바꿈   Ctrl+S 전송·재개   Ctrl+Enter 전송(지원 터미널)   Esc 취소",
    footer_answer_approve: "PgUp/PgDn 문맥 스크롤   Enter 줄바꿈   Ctrl+S 전송·승인·재개   Ctrl+Enter 전송(지원 터미널)   Esc 취소",
    handoff_title: " 핸드오프 · 최근 실행 ",
    footer_handoff: "\u{2191}/\u{2193} 스크롤  Esc/q 뒤로",
    intent_title: " 목표 \u{00b7} 전문 ",
    footer_intent: "\u{2191}/\u{2193} 스크롤  i/Esc/q 뒤로",
    trust_title: " 신뢰 \u{00b7} 자율성 ",
    footer_trust: "\u{2191}/\u{2193} 스크롤  T/Esc/q 뒤로",
    completion_title: " 최종 보고 ",
    footer_completion: "n 새작업  c 이어서  R 재작업  \u{2191}/\u{2193} 스크롤  q 뒤로",
    reports_title: " 보고 / 이력 ",
    footer_reports: "\u{2191}/\u{2193} 선택  Enter 열기  q 뒤로",
    reports_empty: "(보고 없음)",
    report_empty: "(보고 없음)",
    history_promoted: "후속작업 승격됨",
    history_promote_failed: "후속작업 승격 실패:",
    archive_failed: "라이브 작업 아카이브/초기화 실패:",
    redo_done: "재작업 대기로 전환",
    settings_title: " 설정 ",
    footer_settings: "입력 수정   Space 순환   \u{2191}/\u{2193} 이동   Esc 저장",
    settings_saved: "설정 저장됨",
    settings_saved_busy: "설정 저장됨 \u{2014} 다음 태스크부터 적용 (실행 중인 작업은 기존 모델 유지)",
    monitor_title: " 실행 모니터 ",
    footer_monitor: "\u{2191}\u{2193}/PgUp/PgDn 스크롤 \u{00b7} End 따라가기 \u{00b7} Tab/\u{2190}\u{2192} 런 전환 \u{00b7} x 정지 \u{00b7} p 일시정지 \u{00b7} Esc/q 뒤로",
    monitor_no_runs: "아직 실행 없음. Home 에서 r 또는 A 로 시작.",
    planning_review_title: " 플랜 검토 ",
    planning_session: "세션",
    planning_conversation: "대화",
    planning_visible_head: "표시 중인 헤드",
    planning_visible_draft: "수락된 표시 초안",
    planning_no_visible_draft: "수락된 표시 초안 없음",
    planning_pending_proposals: "검토 대기 제안",
    planning_no_pending_proposal: "검토 대기 제안 없음",
    planning_multiple_pending: "여러 제안이 검토 대기 중",
    planning_select_hint: "Tab으로 대상 전환",
    planning_target_marker: "accept/reject 대상",
    planning_stale_marker: "만료: 이후 헤드가 수락됨",
    planning_proposal: "제안",
    planning_attempt: "시도",
    planning_expected_head: "기준 헤드",
    planning_rationale: "근거",
    planning_goal: "목표",
    planning_allowed_scope: "허용 범위",
    planning_out_of_scope: "제외 범위",
    planning_acceptance: "수용 기준",
    planning_tasks: "태스크",
    planning_dependencies: "의존성",
    planning_questions: "질문",
    planning_semantic_diff: "의미 변경",
    planning_before: "이전",
    planning_after: "이후",
    planning_none: "없음",
    planning_revision_title: " 수정 요청 ",
    footer_planning_review: "\u{2191}/\u{2193}/PgUp/PgDn 스크롤  a 수락  r 거절  Tab 대상  e 수정  c 확정  g 새로고침  Esc/q 뒤로",
    footer_planning_review_busy: "플랜 수정 중...  Esc/q 뒤로",
    footer_planning_revision: "Enter 줄바꿈   Ctrl+S 수정 요청 전송   Ctrl+Enter 전송(지원 터미널)   Esc 취소",
    planning_review_failed: "플랜 검토 실패:",
    planning_accepted: "제안을 표시 초안으로 수락함",
    planning_rejected: "제안을 거절함",
    planning_confirmed: "표시된 정확한 초안을 확정함",
    planned_via: "계획 완료 ·",
    tasks_word: "개 작업",
    planning_failed: "계획 실패:",
    via_word: "·",
    run_failed: "실행 실패:",
    resumed_via: "재개 ·",
    answer_failed: "응답/재개 실패:",
    trust_report_failed: "신뢰 보고서 생성 실패:",
    no_intent: "아직 목표가 없습니다. n을 눌러 새 작업을 설명하세요.",
    no_task_handoff: "이 태스크의 핸드오프가 아직 없습니다. 먼저 실행하세요.",
    no_latest_handoff: "핸드오프가 아직 없습니다. 먼저 태스크를 실행하세요.",
    latest_handoff_failed: "최근 실행에 핸드오프가 없습니다.",
    cannot_defer_state: "이 상태는 보류할 수 없음",
    deferred_tasks: "보류됨",
    cannot_revive_state: "보류된 태스크만 되살릴 수 있음",
    revived_tasks: "되살림",
    tidy_word: "정리",
    migrated_word: "이전됨",
    archived_word: "보관됨",
    channel_worker_started: "워커 시작",
    channel_tool_started: "도구 시작",
    channel_tool_completed: "도구 완료",
    channel_question: "질문",
    channel_user: "사용자",
    channel_checkpoint: "워커 체크포인트 기록",
    channel_worker_completed: "워커 완료",
    channel_task_completed: "태스크 완료",
    channel_validation_started: "검증 시작",
    channel_validation_completed: "검증 완료",
    passed_word: "통과",
};

#[cfg(test)]
mod tests {
    use super::*;

    /// Issue #40: every Partial with a marker used to stop the drain with the
    /// merge-conflict message, sending the operator after a conflict that does
    /// not exist. Only a real conflict may ask for conflict resolution.
    #[test]
    fn partial_stop_message_names_the_actual_cause() {
        use crate::run::PartialReasonKind as K;
        let render = |lang, kind, marker, detail| {
            run_progress(
                lang,
                RunProgress::PartialNeedsYou {
                    id: "YARD-001",
                    kind,
                    marker,
                    detail,
                },
            )
        };

        for lang in [Lang::En, Lang::Ko] {
            let conflict = render(lang, K::MergeConflict, "merge_conflict", None);
            assert!(
                conflict.contains("conflict") || conflict.contains("충돌"),
                "{conflict}"
            );

            for (kind, marker) in [
                (K::IntegrationError, "integration_error"),
                (K::GitFinishUnverified, "git_finish_unverified"),
                (K::WorktreeCleanupChanged, "worktree_cleanup_changed"),
                (K::AutoCommitDisabled, "auto_commit_disabled"),
            ] {
                let rendered = render(lang, kind, marker, None);
                assert!(rendered.contains("YARD-001"), "{rendered}");
                assert!(
                    !rendered.contains("merge conflict") && !rendered.contains("병합 충돌"),
                    "{marker} must not be reported as a merge conflict: {rendered}"
                );
            }
        }

        // An unknown marker is surfaced verbatim rather than guessed at.
        let other = render(Lang::En, K::Other, "some_new_reason", None);
        assert!(other.contains("some_new_reason"), "{other}");

        // A blocked Git finish names the checks that failed.
        let blocked = render(
            Lang::En,
            K::GitFinishUnverified,
            "git_finish_unverified",
            Some("cargo clippy"),
        );
        assert!(blocked.contains("cargo clippy"), "{blocked}");
    }

    #[test]
    fn explicit_config_wins() {
        assert_eq!(detect("ko", ""), Lang::Ko);
        assert_eq!(detect("en", "관리자 검색"), Lang::En);
    }

    #[test]
    fn auto_detects_hangul() {
        assert_eq!(detect("auto", "관리자 주문 검색 추가"), Lang::Ko);
    }

    #[test]
    fn korean_status_labels_do_not_leak_english_state_tokens() {
        let l = Lang::Ko.l();
        let labels = [
            task_state_label(l, TaskState::Running).to_string(),
            task_state_label(l, TaskState::Done).to_string(),
            task_state_label(l, TaskState::Failed).to_string(),
            task_state_label(l, TaskState::Blocked).to_string(),
            task_state_label(l, TaskState::NeedsUser).to_string(),
            task_state_label(l, TaskState::Partial).to_string(),
            task_state_label(l, TaskState::Deferred).to_string(),
            task_state_label(l, TaskState::Queued).to_string(),
            recorded_state_label(l, "needs-you"),
        ];
        let leaked = [
            "running",
            "done",
            "failed",
            "blocked",
            "needs-you",
            "partial",
            "deferred",
            "queued",
        ];
        for label in labels {
            for token in leaked {
                assert!(
                    !label.contains(token),
                    "Korean label leaked English token {token}: {label}"
                );
            }
        }
    }

    #[test]
    fn task_state_formatter_covers_every_variant_in_both_languages() {
        let states = [
            TaskState::Running,
            TaskState::Done,
            TaskState::Failed,
            TaskState::Blocked,
            TaskState::NeedsUser,
            TaskState::Partial,
            TaskState::Deferred,
            TaskState::Queued,
        ];
        let expected_en = [
            "running",
            "done",
            "failed",
            "blocked",
            "needs-you",
            "partial",
            "deferred",
            "queued",
        ];
        let expected_ko = [
            "실행",
            "완료",
            "실패",
            "막힘",
            "응답대기",
            "부분완료",
            "보류",
            "대기",
        ];

        for ((state, en), ko) in states.into_iter().zip(expected_en).zip(expected_ko) {
            assert_eq!(task_state_label(Lang::En.l(), state), en);
            assert_eq!(task_state_label(Lang::Ko.l(), state), ko);
        }
    }

    #[test]
    fn locale_tables_have_nonempty_fields_for_every_primary_screen() {
        for lang in [Lang::En, Lang::Ko] {
            let l = lang.l();
            let primary_screen_fields = [
                l.subtitle,
                l.queue_word,
                l.footer_home,
                l.planning_review_title,
                l.footer_planning_review,
                l.monitor_title,
                l.footer_monitor,
                l.task_word,
                l.worker_word,
                l.completion_title,
                l.footer_completion,
                l.settings_title,
                l.footer_settings,
                l.default_word,
                l.model_word,
                l.effort_word,
                l.reports_title,
                l.reports_empty,
                l.run_failed,
                l.startup_failed,
            ];
            assert!(
                primary_screen_fields
                    .iter()
                    .all(|field| !field.trim().is_empty()),
                "{lang:?} has an empty primary-screen i18n field"
            );
        }
    }

    #[test]
    fn typed_run_progress_localizes_chrome_but_preserves_dynamic_content() {
        let id = "YARD-KEEP";
        let detail = "/tmp/KEEP --model MODEL-KEEP";
        let en_running = run_progress(Lang::En, RunProgress::Running(id));
        let ko_running = run_progress(Lang::Ko, RunProgress::Running(id));
        assert_eq!(en_running, "running YARD-KEEP\u{2026}");
        assert_eq!(ko_running, "YARD-KEEP 실행 중\u{2026}");

        let en_detail = run_progress(Lang::En, RunProgress::ParallelOff(detail));
        let ko_detail = run_progress(Lang::Ko, RunProgress::ParallelOff(detail));
        assert!(en_detail.contains(detail));
        assert!(ko_detail.contains(detail));
        assert!(en_detail.starts_with("parallel off"));
        assert!(ko_detail.starts_with("병렬 실행 꺼짐"));
    }

    #[test]
    fn planner_input_footers_match_the_multiline_submit_contract() {
        for lang in [Lang::En, Lang::Ko] {
            let l = lang.l();
            for footer in [
                l.footer_newwork,
                l.footer_replan,
                l.footer_planning_revision,
            ] {
                assert!(footer.contains("Enter"), "{lang:?}: {footer}");
                assert!(footer.contains("Ctrl+S"), "{lang:?}: {footer}");
                assert!(footer.contains("Ctrl+Enter"), "{lang:?}: {footer}");
                assert!(footer.contains("Esc"), "{lang:?}: {footer}");
                assert!(!footer.contains("Shift/Alt"), "{lang:?}: {footer}");
            }
        }
    }

    #[test]
    fn answer_input_footers_match_the_multiline_submit_contract() {
        // The Answer input now uses the same Enter=newline / Ctrl+S=submit branch
        // as the planner, while keeping the read-only context scroll keys.
        for lang in [Lang::En, Lang::Ko] {
            let l = lang.l();
            for footer in [l.footer_answer, l.footer_answer_approve] {
                assert!(footer.contains("Enter"), "{lang:?}: {footer}");
                assert!(footer.contains("Ctrl+S"), "{lang:?}: {footer}");
                assert!(footer.contains("Ctrl+Enter"), "{lang:?}: {footer}");
                assert!(footer.contains("Esc"), "{lang:?}: {footer}");
                assert!(footer.contains("PgUp/PgDn"), "{lang:?}: {footer}");
                assert!(!footer.contains("Shift/Alt"), "{lang:?}: {footer}");
            }
        }
    }
}
