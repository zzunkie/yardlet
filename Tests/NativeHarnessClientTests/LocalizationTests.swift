import Foundation
import XCTest
@testable import NativeHarnessClient

final class LocalizationTests: XCTestCase {
    func testEnglishAndKoreanShellStringsLoadFromModuleResources() {
        XCTAssertEqual(L10n.string("New task", languageCode: "en"), "New task")
        XCTAssertEqual(L10n.string("New task", languageCode: "ko"), "새 작업")
        XCTAssertEqual(
            L10n.string("What do you want to build?", languageCode: "ko"),
            "무엇을 만들어 볼까요?"
        )
        XCTAssertEqual(L10n.string("Not installed", languageCode: "ko"), "설치되지 않음")
        XCTAssertEqual(L10n.string("Needs approval", languageCode: "ko"), "승인 필요")
        XCTAssertEqual(L10n.string("Terminal", languageCode: "ko"), "터미널")
        XCTAssertEqual(L10n.string("Show in Finder", languageCode: "ko"), "Finder에서 보기")
        XCTAssertEqual(L10n.string("Approval required", languageCode: "ko"), "승인 필요")
        XCTAssertEqual(
            L10n.string(
                "Approval expired because the provider runtime stopped.",
                languageCode: "ko"
            ),
            "프로바이더 런타임이 종료되어 승인 요청이 만료되었습니다."
        )
        XCTAssertEqual(L10n.string("Allow for session", languageCode: "ko"), "세션 동안 허용")
        XCTAssertEqual(
            String(
                format: L10n.string(
                    "Allow and switch to %@ mode for this session",
                    languageCode: "ko"
                ),
                L10n.string("Accept edits", languageCode: "ko")
            ),
            "허용하고 이 세션을 편집 허용 모드로 전환"
        )
        XCTAssertEqual(
            String(
                format: L10n.string(
                    "Always allow in this project (saved to %@)",
                    languageCode: "ko"
                ),
                ".claude/settings.local.json"
            ),
            "이 프로젝트에서 항상 허용 (.claude/settings.local.json에 저장)"
        )
        XCTAssertEqual(
            String(
                format: L10n.string(
                    "Always allow in every project (saved to %@)",
                    languageCode: "ko"
                ),
                L10n.string("Claude Code user settings", languageCode: "ko")
            ),
            "모든 프로젝트에서 항상 허용 (Claude Code 사용자 설정에 저장)"
        )
        XCTAssertEqual(
            L10n.string("shared .claude/settings.json", languageCode: "ko"),
            "공유 .claude/settings.json"
        )
        XCTAssertEqual(L10n.string("Answer required", languageCode: "ko"), "답변 필요")
        XCTAssertEqual(L10n.string("Answered", languageCode: "en"), "Answered")
        XCTAssertEqual(L10n.string("Submit answers", languageCode: "ko"), "답변 제출")
        XCTAssertEqual(L10n.string("Choose one or more", languageCode: "ko"), "하나 이상 선택")
        XCTAssertEqual(L10n.string("Plan review", languageCode: "ko"), "계획 검토")
        XCTAssertEqual(L10n.string("Plan approved", languageCode: "ko"), "계획 승인됨")
        XCTAssertEqual(L10n.string("Planning continued", languageCode: "ko"), "계획 계속")
        XCTAssertEqual(L10n.string("Proposed plan", languageCode: "ko"), "제안된 계획")
        XCTAssertEqual(L10n.string("Approve plan", languageCode: "ko"), "계획 승인")
        XCTAssertEqual(L10n.string("Keep planning", languageCode: "ko"), "계획 계속하기")
        XCTAssertEqual(
            L10n.string("Tell Claude what to change", languageCode: "ko"),
            "Claude에게 무엇을 바꿀지 알려주세요"
        )
        XCTAssertEqual(
            L10n.string("Tell Claude what to change", languageCode: "en"),
            "Tell Claude what to change"
        )
        XCTAssertEqual(L10n.string("Thinking", languageCode: "ko"), "생각 중")
        XCTAssertEqual(L10n.string("Pin", languageCode: "ko"), "고정")
        XCTAssertEqual(L10n.string("Pinned", languageCode: "ko"), "고정됨")
        XCTAssertEqual(L10n.string("Unpin", languageCode: "ko"), "고정 해제")
        XCTAssertEqual(
            String(
                format: L10n.string("Working for %lld seconds", languageCode: "ko"),
                Int64(7)
            ),
            "7초 동안 작업 중입니다"
        )
        XCTAssertEqual(
            String(
                format: L10n.string("Worked for %lld seconds", languageCode: "ko"),
                Int64(22)
            ),
            "22초 동안 작업함"
        )
        XCTAssertEqual(L10n.string("Clean", languageCode: "ko"), "변경 없음")
        XCTAssertEqual(L10n.string("Stopped", languageCode: "ko"), "중지됨")
        XCTAssertEqual(L10n.string("Browser", languageCode: "ko"), "브라우저")
        XCTAssertEqual(L10n.string("On demand", languageCode: "ko"), "필요할 때만")
        XCTAssertEqual(L10n.string("Codex features", languageCode: "ko"), "Codex 기능")
        XCTAssertEqual(L10n.string("Review working tree", languageCode: "ko"), "작업 트리 리뷰")
        XCTAssertEqual(L10n.string("Worktree %@", languageCode: "en"), "Worktree %@")
        XCTAssertEqual(L10n.string("Worktree %@", languageCode: "ko"), "작업 트리 %@")
        XCTAssertEqual(L10n.string("Task title", languageCode: "ko"), "작업 제목")
        XCTAssertEqual(L10n.string("Rename task", languageCode: "ko"), "작업 이름 변경")
        XCTAssertEqual(L10n.string("New session", languageCode: "ko"), "새 세션")
        XCTAssertEqual(L10n.string("Search tasks", languageCode: "ko"), "작업 검색")
        XCTAssertEqual(L10n.string("Choose which local coding agents can own new tasks.", languageCode: "ko"), "새 작업을 실행할 로컬 코딩 에이전트를 선택하세요.")
        XCTAssertEqual(L10n.string("Not installed", languageCode: "ko"), "설치되지 않음")
        XCTAssertEqual(L10n.string("Collaboration mode", languageCode: "ko"), "협업 모드")
        XCTAssertEqual(
            L10n.string("Choose how the next Codex turn approaches the task.", languageCode: "ko"),
            "다음 Codex 턴이 작업에 접근하는 방식을 선택합니다."
        )
        XCTAssertEqual(L10n.string("Fork task", languageCode: "ko"), "작업 포크")
        XCTAssertEqual(L10n.string("Review working tree", languageCode: "ko"), "작업 트리 리뷰")
        XCTAssertEqual(L10n.string("Harnesses", languageCode: "ko"), "하네스")
        XCTAssertEqual(L10n.string("Close panel", languageCode: "ko"), "패널 닫기")
        XCTAssertEqual(
            L10n.string("Show or hide this task panel", languageCode: "ko"),
            "이 작업 패널을 열거나 닫습니다"
        )
        XCTAssertEqual(
            L10n.string("Connect harnesses and check account status.", languageCode: "ko"),
            "하네스를 연결하고 계정 상태를 확인합니다."
        )
        XCTAssertEqual(L10n.string("Open sign-in page", languageCode: "ko"), "로그인 페이지 열기")
        XCTAssertEqual(
            L10n.string(
                "Environment keys are available, but OpenCode has no stored provider connection.",
                languageCode: "ko"
            ),
            "환경 키를 사용할 수 있지만 OpenCode에 저장된 제공자 연결은 없습니다."
        )
        XCTAssertEqual(
            L10n.string("Antigravity CLI credentials are stored in macOS Keychain.", languageCode: "ko"),
            "Antigravity CLI 인증 정보가 macOS 키체인에 저장되어 있습니다."
        )
        XCTAssertEqual(L10n.string("Interactive CLI terminal", languageCode: "ko"), "대화형 CLI 터미널")
        XCTAssertEqual(
            L10n.string(
                "Click the terminal, then type or paste the response requested by the CLI.",
                languageCode: "ko"
            ),
            "터미널을 클릭한 뒤 CLI가 요청한 응답을 입력하거나 붙여넣으세요."
        )
        XCTAssertEqual(
            L10n.string("Type directly in the terminal. Paste with Command-V.", languageCode: "ko"),
            "터미널에 바로 입력하세요. Command-V로 붙여넣을 수 있습니다."
        )
        XCTAssertEqual(
            L10n.string("Grok has a locally stored OAuth session or API key.", languageCode: "ko"),
            "Grok에 로컬 저장된 OAuth 세션 또는 API 키가 있습니다."
        )
        XCTAssertEqual(
            L10n.string("Grok Build credential store", languageCode: "ko"),
            "Grok Build 인증 저장소"
        )
        XCTAssertEqual(
            L10n.string("Connect provider", languageCode: "ko"),
            "프로바이더 연결"
        )
        XCTAssertEqual(
            L10n.string(
                "Muse Code does not expose a stable account-status probe through MSP v1.",
                languageCode: "ko"
            ),
            "Muse Code는 MSP v1을 통해 안정적인 계정 상태 조회를 제공하지 않습니다."
        )
        XCTAssertEqual(
            L10n.string("Use arrow keys and Enter for CLI-owned choices.", languageCode: "ko"),
            "CLI 선택 화면에서는 화살표와 확인 버튼을 사용하세요."
        )
        XCTAssertEqual(L10n.string("Plugins", languageCode: "ko"), "플러그인")
        XCTAssertEqual(L10n.string("Codex capability sections", languageCode: "ko"), "Codex 기능 섹션")
        XCTAssertEqual(
            L10n.string("Use the left and right arrow keys to switch capability sections.", languageCode: "ko"),
            "왼쪽 및 오른쪽 화살표 키로 Codex 기능 섹션을 전환하세요."
        )
        XCTAssertEqual(L10n.string("Harness features", languageCode: "ko"), "하네스 기능")
        XCTAssertEqual(L10n.string("Thinking level", languageCode: "ko"), "사고 수준")
        XCTAssertEqual(L10n.string("Permission mode", languageCode: "ko"), "권한 모드")
        XCTAssertEqual(L10n.string("Clear search", languageCode: "ko"), "검색 지우기")
        XCTAssertEqual(L10n.string("Task details", languageCode: "ko"), "작업 세부 정보")
        XCTAssertEqual(L10n.string("Local AI workbench", languageCode: "ko"), "로컬 AI 워크벤치")
        XCTAssertEqual(
            L10n.string("Own the loop around your coding agents.", languageCode: "ko"),
            "코딩 에이전트를 둘러싼 루프를 직접 소유하세요."
        )
        XCTAssertEqual(L10n.string("What should we build?", languageCode: "ko"), "무엇을 만들까요?")
        XCTAssertEqual(L10n.string("What should we build in %@?", languageCode: "ko"), "%@에서 무엇을 만들어볼까요?")
        XCTAssertEqual(L10n.string("Local", languageCode: "ko"), "로컬")
        XCTAssertEqual(L10n.string("Load more history", languageCode: "ko"), "기록 더 불러오기")
        XCTAssertEqual(L10n.string("Search Codex history", languageCode: "ko"), "Codex 기록 검색")
        XCTAssertEqual(L10n.string("History match", languageCode: "ko"), "검색 일치 항목")
        XCTAssertEqual(
            L10n.string("No matching Codex history", languageCode: "ko"),
            "일치하는 Codex 기록이 없습니다"
        )
        XCTAssertEqual(
            L10n.string("Searches Codex history when submitted.", languageCode: "ko"),
            "제출하면 Codex 기록을 검색합니다."
        )
        XCTAssertEqual(
            L10n.string("Open Codex task: %@", languageCode: "ko"),
            "Codex 작업 열기: %@"
        )
        XCTAssertEqual(
            L10n.string("Resume this task and show its timeline.", languageCode: "ko"),
            "이 작업을 재개하고 타임라인을 표시합니다."
        )
        XCTAssertEqual(L10n.string("Retry turn", languageCode: "ko"), "턴 다시 시도")
        XCTAssertEqual(L10n.string("Send answer", languageCode: "ko"), "답변 보내기")
        XCTAssertEqual(L10n.string("Fork from here", languageCode: "ko"), "여기서 분기")
        XCTAssertEqual(L10n.string("Settings", languageCode: "ko"), "설정")
        XCTAssertEqual(L10n.string("Settings sections", languageCode: "ko"), "설정 섹션")
        XCTAssertEqual(
            L10n.string("Use the arrow keys to switch settings sections.", languageCode: "ko"),
            "화살표 키로 설정 섹션을 전환하세요."
        )
        XCTAssertEqual(L10n.string("Notifications", languageCode: "ko"), "알림")
        XCTAssertEqual(L10n.string("Enable notifications", languageCode: "ko"), "알림 켜기")
        XCTAssertEqual(L10n.string("Open System Settings", languageCode: "ko"), "시스템 설정 열기")
        XCTAssertEqual(L10n.string("Codex runtime", languageCode: "ko"), "Codex 런타임")
        XCTAssertEqual(L10n.string("Not loaded", languageCode: "ko"), "로드되지 않음")
        XCTAssertEqual(L10n.string("Runtime error", languageCode: "ko"), "런타임 오류")
        XCTAssertEqual(L10n.string("Active flags: %@", languageCode: "ko"), "활성 플래그: %@")
        XCTAssertEqual(L10n.string("Yardlet-owned", languageCode: "ko"), "Yardlet 소유")
        XCTAssertEqual(L10n.string("Runtime-owned", languageCode: "ko"), "런타임 소유")
        XCTAssertEqual(L10n.string("Selected", languageCode: "ko"), "선택됨")
        XCTAssertEqual(L10n.string("Switch to this task surface", languageCode: "ko"), "이 작업 표면으로 전환")
        XCTAssertEqual(L10n.string("Task surfaces", languageCode: "ko"), "작업 표면")
        XCTAssertEqual(
            L10n.string("Use the left and right arrow keys to switch task surfaces.", languageCode: "ko"),
            "왼쪽 및 오른쪽 화살표 키로 작업 표면을 전환하세요."
        )
        XCTAssertEqual(L10n.string("Attached input", languageCode: "ko"), "첨부 입력")
        XCTAssertEqual(L10n.string("Remove attachment", languageCode: "ko"), "첨부 제거")
        XCTAssertEqual(L10n.string("Copy item details", languageCode: "ko"), "항목 세부 정보 복사")
        XCTAssertEqual(L10n.string("Copied item details", languageCode: "ko"), "항목 세부 정보 복사됨")
        XCTAssertEqual(L10n.string("Last turn", languageCode: "ko"), "마지막 턴")
        XCTAssertEqual(L10n.string("Cumulative", languageCode: "ko"), "누적")
        XCTAssertEqual(L10n.string("Input", languageCode: "ko"), "입력")
        XCTAssertEqual(L10n.string("Cached input", languageCode: "ko"), "캐시된 입력")
        XCTAssertEqual(L10n.string("Cache hit", languageCode: "ko"), "캐시 적중")
        XCTAssertEqual(
            String(
                format: L10n.string("%.1f%% of input", languageCode: "ko"),
                locale: Locale(identifier: "ko_KR"),
                arguments: [20.0]
            ),
            "입력의 20.0%"
        )
        XCTAssertEqual(L10n.string("Cache write", languageCode: "ko"), "캐시 쓰기")
        XCTAssertEqual(L10n.string("Output", languageCode: "ko"), "출력")
        XCTAssertEqual(L10n.string("Expanded", languageCode: "ko"), "펼쳐짐")
        XCTAssertEqual(L10n.string("Collapsed", languageCode: "ko"), "접힘")
        XCTAssertEqual(L10n.string("Attached", languageCode: "ko"), "연결됨")
        XCTAssertEqual(L10n.string("Not attached", languageCode: "ko"), "연결되지 않음")
        XCTAssertEqual(L10n.string("Task actions", languageCode: "ko"), "작업 동작")
        XCTAssertEqual(L10n.string("Open task actions", languageCode: "ko"), "작업 동작 열기")
        XCTAssertEqual(L10n.string("Project %@", languageCode: "ko"), "프로젝트 %@")
        XCTAssertEqual(
            L10n.string("Expand or collapse project tasks", languageCode: "ko"),
            "프로젝트 작업 펼치기 또는 접기"
        )
        XCTAssertEqual(L10n.string("Split View", languageCode: "ko"), "분할 화면")
        XCTAssertEqual(L10n.string("End split view", languageCode: "ko"), "분할 해제")
        XCTAssertEqual(L10n.string("Rename split view…", languageCode: "ko"), "분할 화면 이름 변경…")
        XCTAssertEqual(
            String(format: L10n.string("Split view: %@", languageCode: "ko"), "API, 리뷰"),
            "분할 화면: API, 리뷰"
        )
        XCTAssertEqual(
            String(format: L10n.string("Archive split view confirmation", languageCode: "ko"), Int64(2)),
            "이 분할 화면의 작업 2개를 모두 보관합니다."
        )
        XCTAssertEqual(L10n.string("Pane", languageCode: "ko"), "구획")
        XCTAssertEqual(L10n.string("Focused", languageCode: "ko"), "포커스됨")
        XCTAssertEqual(L10n.string("Close pane", languageCode: "ko"), "구획 닫기")
        XCTAssertEqual(L10n.string("Split pane right", languageCode: "ko"), "구획 오른쪽 분할")
        XCTAssertEqual(L10n.string("Split pane down", languageCode: "ko"), "구획 아래 분할")
        XCTAssertEqual(L10n.string("Focus pane left", languageCode: "ko"), "왼쪽 구획 포커스")
        XCTAssertEqual(L10n.string("Focus pane below", languageCode: "ko"), "아래쪽 구획 포커스")
        XCTAssertEqual(L10n.string("Split pane left", languageCode: "ko"), "구획 왼쪽 분할")
        // The existing Codex sandbox label keeps its own meaning.
        XCTAssertEqual(L10n.string("Workspace", languageCode: "ko"), "작업 공간")
        XCTAssertEqual(
            L10n.string(
                "%@ cannot send this attachment. Remove it to send the message.",
                languageCode: "ko"
            ),
            "%@에서는 이 첨부를 보낼 수 없습니다. 첨부를 제거한 뒤 전송하세요."
        )
        XCTAssertEqual(
            L10n.string("%@ cannot send image attachments", languageCode: "ko"),
            "%@에서는 이미지 첨부를 보낼 수 없습니다"
        )
        XCTAssertEqual(
            L10n.string("%@ does not advertise ACP image prompts", languageCode: "ko"),
            "%@에서 ACP 이미지 프롬프트를 지원한다고 알리지 않았습니다"
        )
        XCTAssertEqual(
            L10n.string("Attachment could not be read: %@", languageCode: "ko"),
            "첨부 파일을 읽지 못했습니다: %@"
        )
    }

    func testEnglishAndKoreanCatalogsHaveTheSameNonEmptyKeys() throws {
        let english = try catalog(languageCode: "en")
        let korean = try catalog(languageCode: "ko")

        XCTAssertEqual(Set(english.keys), Set(korean.keys))
        XCTAssertFalse(english.isEmpty)
        XCTAssertTrue(english.allSatisfy { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(english.allSatisfy { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(korean.allSatisfy { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(korean.allSatisfy { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// The app's own `AppleLanguages`, as System Settings writes it per app: a language puts that one
    /// code there, and System removes the key instead of storing a value.
    func testAppLanguageIsTheAppsOwnAppleLanguagesAndSystemRemovesIt() throws {
        let suite = testDefaultsSuite("AppLanguage")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        func stored() -> Any? { defaults.persistentDomain(forName: suite)?[AppLanguagePreference.key] }

        XCTAssertEqual(AppLanguagePreference.stored(in: defaults, domain: suite), .system)
        AppLanguagePreference.store(.english, in: defaults)
        XCTAssertEqual(stored() as? [String], ["en"])
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults, domain: suite), .english)
        AppLanguagePreference.store(.korean, in: defaults)
        XCTAssertEqual(stored() as? [String], ["ko"])
        AppLanguagePreference.store(.system, in: defaults)
        XCTAssertNil(stored())
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults, domain: suite), .system)

        // A region-qualified choice made in System Settings reads as its language.
        defaults.set(["ko-KR"], forKey: AppLanguagePreference.key)
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults, domain: suite), .korean)
    }

    private func catalog(languageCode: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: "\(languageCode).lproj"
            )
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }
}
