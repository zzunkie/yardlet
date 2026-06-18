//! Minimal TUI localization.
//!
//! The TUI chrome can render in English (default) or Korean. The language is
//! resolved from the workspace `language` setting, falling back to the intent
//! content and the OS locale when set to "auto". Yardlet's canonical state and
//! worker-facing packets are unaffected by this.

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

/// Label table. Every user-visible TUI string lives here.
pub struct L {
    pub subtitle: &'static str,
    pub workspace: &'static str,
    pub workers_word: &'static str,
    pub ready_word: &'static str,
    pub planner: &'static str,
    pub access_word: &'static str,
    pub parallel_word: &'static str,
    pub ime_word: &'static str,
    pub language_word: &'static str,
    pub intent: &'static str,
    pub status: &'static str,
    pub s_running: &'static str,
    pub s_queued: &'static str,
    pub s_needs: &'static str,
    pub s_blocked: &'static str,
    pub s_done: &'static str,
    pub s_failed: &'static str,
    pub s_partial: &'static str,
    pub queue_word: &'static str,
    pub queue_empty: &'static str,
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
    pub footer_home: &'static str,
    /// Shown on Home during a pausable auto-drain: includes `p pause`.
    pub footer_home_busy: &'static str,
    /// Shown on Home during a non-drain job (planning / single run): no `p
    /// pause` (nothing to pause between tasks) — only `Esc stop`.
    pub footer_home_busy_nodrain: &'static str,
    /// Conditionally appended to the Home footer when relevant.
    pub key_answer: &'static str,
    pub key_approve: &'static str,
    pub busy: &'static str,
    pub not_pausable: &'static str,
    pub stopping: &'static str,
    pub pausing: &'static str,
    pub no_pending: &'static str,
    pub no_answer_target: &'static str,
    pub nothing_to_run: &'static str,
    pub approval_needed: &'static str,
    pub no_approval: &'static str,
    pub initialized: &'static str,
    pub newwork_title: &'static str,
    pub newwork_prompt: &'static str,
    pub request_title: &'static str,
    pub footer_newwork: &'static str,
    pub asking_word: &'static str,
    pub no_question: &'static str,
    pub your_answer_title: &'static str,
    pub footer_answer: &'static str,
    pub handoff_title: &'static str,
    pub footer_handoff: &'static str,
    pub intent_title: &'static str,
    pub footer_intent: &'static str,
    pub completion_title: &'static str,
    pub footer_completion: &'static str,
    pub reports_title: &'static str,
    pub footer_reports: &'static str,
    pub redo_done: &'static str,
    pub settings_title: &'static str,
    pub footer_settings: &'static str,
    pub settings_saved: &'static str,
    pub settings_saved_busy: &'static str,
    pub monitor_title: &'static str,
    pub footer_monitor: &'static str,
    pub monitor_no_runs: &'static str,
    // job-result prefixes (mixed with worker-authored content)
    pub planned_via: &'static str,
    pub tasks_word: &'static str,
    pub planning_failed: &'static str,
    pub via_word: &'static str,
    pub run_failed: &'static str,
    pub resumed_via: &'static str,
    pub answer_failed: &'static str,
}

pub const EN: L = L {
    subtitle: "Local AI Workbench",
    workspace: "Workspace: ",
    workers_word: "Workers",
    ready_word: "invocable",
    planner: "Planner",
    access_word: "Access",
    parallel_word: "Parallel tasks",
    ime_word: "Auto IME switch",
    language_word: "Language",
    intent: "Intent: ",
    status: "Status: ",
    s_running: "running",
    s_queued: "queued",
    s_needs: "needs-you",
    s_blocked: "blocked",
    s_done: "done",
    s_failed: "failed",
    s_partial: "partial",
    queue_word: "Queue",
    queue_empty: "  (queue empty \u{2014} press n to describe new work)",
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
    footer_home: "\u{2191}\u{2193}/Enter view task  n new  r run  A auto  m monitor  h handoff  i goal  f access  s settings  l lang  g refresh  R reports  q quit",
    footer_home_busy: "running...  p pause  Esc stop  m monitor  h handoff  i goal  f access  s settings  q quit",
    footer_home_busy_nodrain: "running...  Esc stop  m monitor  h handoff  i goal  f access  s settings  q quit",
    key_answer: "a answer",
    key_approve: "p approve",
    busy: "a worker is running; please wait",
    not_pausable: "not a pausable drain (planning / single run) \u{2014} press Esc to stop",
    stopping: "stopping the worker (the task will need a retry)",
    pausing: "pausing \u{2014} will stop after the current task",
    no_pending: "no task is waiting on you",
    no_answer_target: "no task to answer",
    nothing_to_run: "nothing to run (queue is done or empty)",
    approval_needed: "need approval",
    no_approval: "no task needs approval",
    initialized: "initialized Yardlet workspace (.agents/)",
    newwork_title: " New Work ",
    newwork_prompt: "Describe the work in a few sentences. Yardlet plans, queues, and runs it.",
    request_title: " Request ",
    footer_newwork: "Enter plan   Esc cancel",
    asking_word: "is asking",
    no_question: "(no recorded question \u{2014} see the handoff)",
    your_answer_title: " Your answer ",
    footer_answer: "Enter send & resume   Esc cancel",
    handoff_title: " Handoff \u{00b7} latest run ",
    footer_handoff: "\u{2191}/\u{2193} scroll  Esc/q back",
    intent_title: " Intent \u{00b7} full goal ",
    footer_intent: "\u{2191}/\u{2193} scroll  i/Esc/q back",
    completion_title: " Final report ",
    footer_completion: "n new  c continue  R redo  \u{2191}/\u{2193} scroll  q back",
    reports_title: " Reports ",
    footer_reports: "\u{2191}/\u{2193} select  Enter open  q back",
    redo_done: "requeued for redo",
    settings_title: " Settings ",
    footer_settings: "type to edit   Space cycle   \u{2191}/\u{2193} move   Esc save",
    settings_saved: "settings saved",
    settings_saved_busy: "settings saved \u{2014} applies to the next task (the running one keeps its model)",
    monitor_title: " Run Monitor ",
    footer_monitor: "Tab/\u{2190}\u{2192} switch run \u{00b7} x stop \u{00b7} p pause \u{00b7} Esc/q back",
    monitor_no_runs: "No runs yet. Press r or A on Home to start one.",
    planned_via: "Planned via",
    tasks_word: "tasks",
    planning_failed: "Planning failed:",
    via_word: "via",
    run_failed: "Run failed:",
    resumed_via: "resumed via",
    answer_failed: "Answer/resume failed:",
};

pub const KO: L = L {
    subtitle: "로컬 AI 워크벤치",
    workspace: "워크스페이스: ",
    workers_word: "워커",
    ready_word: "호출가능",
    planner: "플래너",
    access_word: "권한",
    parallel_word: "병렬 작업 수",
    ime_word: "한/영 자동 전환",
    language_word: "언어",
    intent: "목표: ",
    status: "상태: ",
    s_running: "실행",
    s_queued: "대기",
    s_needs: "응답대기",
    s_blocked: "막힘",
    s_done: "완료",
    s_failed: "실패",
    s_partial: "부분",
    queue_word: "큐",
    queue_empty: "  (큐 비어 있음 — n 눌러 새 작업 입력)",
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
    footer_home: "\u{2191}\u{2193}/Enter 태스크 보기  n 새작업  r 실행  A 자동  m 모니터  h 핸드오프  i 목표  f 권한  s 설정  l 언어  g 새로고침  R 보고  q 종료",
    footer_home_busy: "실행 중...  p 일시정지  Esc 정지  m 모니터  h 핸드오프  i 목표  f 권한  s 설정  q 종료",
    footer_home_busy_nodrain: "실행 중...  Esc 정지  m 모니터  h 핸드오프  i 목표  f 권한  s 설정  q 종료",
    key_answer: "a 답변",
    key_approve: "p 승인",
    busy: "워커 실행 중 · 잠시만요",
    not_pausable: "일시정지 대상이 아님 (플래닝 / 단일 실행) \u{2014} 멈추려면 Esc",
    stopping: "워커 정지 중 (태스크는 재시도 필요)",
    pausing: "일시정지 \u{2014} 현재 태스크 끝나면 멈춤",
    no_pending: "응답 대기 중인 작업 없음",
    no_answer_target: "응답할 작업 없음",
    nothing_to_run: "실행할 작업 없음 (큐 완료/비어 있음)",
    approval_needed: "승인 필요",
    no_approval: "승인할 작업 없음",
    initialized: "Yardlet 워크스페이스 생성됨 (.agents/)",
    newwork_title: " 새 작업 ",
    newwork_prompt: "작업을 몇 문장으로 설명하세요. Yardlet 가 계획·큐·실행합니다.",
    request_title: " 요청 ",
    footer_newwork: "Enter 계획   Esc 취소",
    asking_word: "질문",
    no_question: "(기록된 질문 없음 — 핸드오프 참고)",
    your_answer_title: " 답변 ",
    footer_answer: "Enter 전송·재개   Esc 취소",
    handoff_title: " 핸드오프 · 최근 실행 ",
    footer_handoff: "\u{2191}/\u{2193} 스크롤  Esc/q 뒤로",
    intent_title: " 목표 \u{00b7} 전문 ",
    footer_intent: "\u{2191}/\u{2193} 스크롤  i/Esc/q 뒤로",
    completion_title: " 최종 보고 ",
    footer_completion: "n 새작업  c 이어서  R 재작업  \u{2191}/\u{2193} 스크롤  q 뒤로",
    reports_title: " 보고 / 이력 ",
    footer_reports: "\u{2191}/\u{2193} 선택  Enter 열기  q 뒤로",
    redo_done: "재작업 대기로 전환",
    settings_title: " 설정 ",
    footer_settings: "입력 수정   Space 순환   \u{2191}/\u{2193} 이동   Esc 저장",
    settings_saved: "설정 저장됨",
    settings_saved_busy: "설정 저장됨 \u{2014} 다음 태스크부터 적용 (실행 중인 작업은 기존 모델 유지)",
    monitor_title: " 실행 모니터 ",
    footer_monitor: "Tab/\u{2190}\u{2192} 런 전환 \u{00b7} x 정지 \u{00b7} p 일시정지 \u{00b7} Esc/q 뒤로",
    monitor_no_runs: "아직 실행 없음. Home 에서 r 또는 A 로 시작.",
    planned_via: "계획 완료 ·",
    tasks_word: "개 작업",
    planning_failed: "계획 실패:",
    via_word: "·",
    run_failed: "실행 실패:",
    resumed_via: "재개 ·",
    answer_failed: "응답/재개 실패:",
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_config_wins() {
        assert_eq!(detect("ko", ""), Lang::Ko);
        assert_eq!(detect("en", "관리자 검색"), Lang::En);
    }

    #[test]
    fn auto_detects_hangul() {
        assert_eq!(detect("auto", "관리자 주문 검색 추가"), Lang::Ko);
    }
}
