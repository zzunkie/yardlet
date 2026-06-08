//! Minimal TUI localization.
//!
//! The TUI chrome can render in English (default) or Korean. The language is
//! resolved from the workspace `language` setting, falling back to the intent
//! content and the OS locale when set to "auto". Yard's canonical state and
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
    pub app_title: &'static str,
    pub workspace: &'static str,
    pub workers_word: &'static str,
    pub ready_word: &'static str,
    pub planner: &'static str,
    pub access_word: &'static str,
    pub language_word: &'static str,
    pub intent: &'static str,
    pub status: &'static str,
    pub s_running: &'static str,
    pub s_queued: &'static str,
    pub s_needs: &'static str,
    pub s_blocked: &'static str,
    pub s_done: &'static str,
    pub queue_word: &'static str,
    pub queue_empty: &'static str,
    pub workers_title: &'static str,
    pub w_ready: &'static str,
    pub w_ambiguous: &'static str,
    pub w_notready: &'static str,
    pub version_unknown: &'static str,
    pub run_word: &'static str,
    pub sec_unit: &'static str,
    pub subscription_note: &'static str,
    pub idle: &'static str,
    pub needs_you: &'static str,
    pub press_a: &'static str,
    pub see_handoff: &'static str,
    pub footer_home: &'static str,
    pub busy: &'static str,
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
    pub settings_title: &'static str,
    pub footer_settings: &'static str,
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
    app_title: " Yard \u{00b7} Local AI Workbench ",
    workspace: "Workspace: ",
    workers_word: "Workers",
    ready_word: "ready",
    planner: "Planner",
    access_word: "Access",
    language_word: "Language",
    intent: "Intent: ",
    status: "Status: ",
    s_running: "running",
    s_queued: "queued",
    s_needs: "needs-you",
    s_blocked: "blocked",
    s_done: "done",
    queue_word: "Queue",
    queue_empty: "  (queue empty \u{2014} press n to describe new work)",
    workers_title: " Workers \u{00b7} zero-key ",
    w_ready: "ready",
    w_ambiguous: "ambiguous",
    w_notready: "not ready",
    version_unknown: "version unknown",
    run_word: "running",
    sec_unit: "s",
    subscription_note: "   worker is subscription-backed; no API key used",
    idle: " idle",
    needs_you: "needs you",
    press_a: "  (press a)",
    see_handoff: "see handoff",
    footer_home:
        "n new  r run  A auto  a answer  p approve  s settings  h handoff  f access  q quit",
    busy: "a worker is running; please wait",
    no_pending: "no task is waiting on you",
    no_answer_target: "no task to answer",
    nothing_to_run: "nothing to run (queue is done or empty)",
    approval_needed: "need approval",
    no_approval: "no task needs approval",
    initialized: "initialized Yard workspace (.agents/)",
    newwork_title: " New Work ",
    newwork_prompt: "Describe the work in a few sentences. Yard plans, queues, and runs it.",
    request_title: " Request ",
    footer_newwork: "Enter plan   Esc cancel",
    asking_word: "is asking",
    no_question: "(no recorded question \u{2014} see the handoff)",
    your_answer_title: " Your answer ",
    footer_answer: "Enter send & resume   Esc cancel",
    handoff_title: " Handoff \u{00b7} latest run ",
    footer_handoff: "Esc/q back",
    settings_title: " Settings ",
    footer_settings: "type to edit   Space cycle   \u{2191}/\u{2193} move   Esc save",
    planned_via: "Planned via",
    tasks_word: "tasks",
    planning_failed: "Planning failed:",
    via_word: "via",
    run_failed: "Run failed:",
    resumed_via: "resumed via",
    answer_failed: "Answer/resume failed:",
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

pub const KO: L = L {
    app_title: " Yard \u{00b7} 로컬 AI 워크벤치 ",
    workspace: "워크스페이스: ",
    workers_word: "워커",
    ready_word: "준비",
    planner: "플래너",
    access_word: "권한",
    language_word: "언어",
    intent: "목표: ",
    status: "상태: ",
    s_running: "실행",
    s_queued: "대기",
    s_needs: "응답대기",
    s_blocked: "막힘",
    s_done: "완료",
    queue_word: "큐",
    queue_empty: "  (큐 비어 있음 — n 눌러 새 작업 입력)",
    workers_title: " 워커 · 키 불필요 ",
    w_ready: "준비됨",
    w_ambiguous: "모호",
    w_notready: "준비안됨",
    version_unknown: "버전 미상",
    run_word: "실행 중",
    sec_unit: "초",
    subscription_note: "   워커는 구독 기반 · API 키 미사용",
    idle: " 대기",
    needs_you: "응답 필요",
    press_a: "  (a 키)",
    see_handoff: "핸드오프 참고",
    footer_home: "n 새작업  r 실행  A 자동  a 응답  p 승인  s 설정  h 핸드오프  f 권한  q 종료",
    busy: "워커 실행 중 · 잠시만요",
    no_pending: "응답 대기 중인 작업 없음",
    no_answer_target: "응답할 작업 없음",
    nothing_to_run: "실행할 작업 없음 (큐 완료/비어 있음)",
    approval_needed: "승인 필요",
    no_approval: "승인할 작업 없음",
    initialized: "Yard 워크스페이스 생성됨 (.agents/)",
    newwork_title: " 새 작업 ",
    newwork_prompt: "작업을 몇 문장으로 설명하세요. Yard 가 계획·큐·실행합니다.",
    request_title: " 요청 ",
    footer_newwork: "Enter 계획   Esc 취소",
    asking_word: "질문",
    no_question: "(기록된 질문 없음 — 핸드오프 참고)",
    your_answer_title: " 답변 ",
    footer_answer: "Enter 전송·재개   Esc 취소",
    handoff_title: " 핸드오프 · 최근 실행 ",
    footer_handoff: "Esc/q 뒤로",
    settings_title: " 설정 ",
    footer_settings: "입력 수정   Space 순환   \u{2191}/\u{2193} 이동   Esc 저장",
    planned_via: "계획 완료 ·",
    tasks_word: "개 작업",
    planning_failed: "계획 실패:",
    via_word: "·",
    run_failed: "실행 실패:",
    resumed_via: "재개 ·",
    answer_failed: "응답/재개 실패:",
};
