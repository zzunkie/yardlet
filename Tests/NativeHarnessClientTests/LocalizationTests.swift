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
            "제공자 런타임이 종료되어 승인 요청이 만료되었습니다."
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
        XCTAssertEqual(L10n.string("Review working tree", languageCode: "ko"), "작업 트리 검토")
        XCTAssertEqual(L10n.string("Worktree %@", languageCode: "en"), "Worktree %@")
        XCTAssertEqual(L10n.string("Worktree %@", languageCode: "ko"), "워크트리 %@")
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
        XCTAssertEqual(L10n.string("Review working tree", languageCode: "ko"), "작업 트리 검토")
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
            "제공자 연결"
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
        XCTAssertEqual(L10n.string("What should we build in %@?", languageCode: "ko"), "%@에서 무엇을 만들어 볼까요?")
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
        XCTAssertEqual(
            String(
                format: L10n.string(
                    "To change settings here, allow it in %@'s Settings › Remote › Paired devices.",
                    languageCode: "ko"
                ),
                "Mac Studio"
            ),
            "여기서 설정을 바꾸려면 Mac Studio의 설정 › 원격 연결 › 연결된 기기에서 허용하세요."
        )
    }

    /// Tier 1 (enforced on every PR): English is the single source of truth.
    /// Every `L10n.string/format("...")` literal in `Sources/NativeHarnessClient` must exist in
    /// `en.lproj/Localizable.strings`, with no empty or duplicate keys.
    func testEnglishCatalogCoversAllSourceLiteralsWithoutEmptyOrDuplicateKeys() throws {
        let englishURL = resourcesDirectory.appending(path: "en.lproj/Localizable.strings")
        let parsed = try parseStringsFile(at: englishURL)
        let plist = try loadPropertyListStrings(at: englishURL)

        XCTAssertEqual(parsed.duplicates, [], "en.lproj/Localizable.strings must not contain duplicate keys")
        XCTAssertFalse(parsed.entries.isEmpty)
        XCTAssertEqual(parsed.entries.count, plist.count, "Strict parser and Foundation plist parser agree")

        var englishFormatErrors: [String] = []
        for (key, value) in parsed.entries {
            XCTAssertFalse(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty key in en.lproj")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty value for \(key) in en.lproj")
            switch extractFormatSpecifiers(from: value) {
            case let .success(sig):
                if !sig.placeholders.isEmpty && sig.hasStrayPercent {
                    englishFormatErrors.append("\(key): unescaped '%' in format string")
                }
            case let .failure(error):
                englishFormatErrors.append("\(key): \(error)")
            }
        }
        XCTAssertEqual(englishFormatErrors, [], "en.lproj/Localizable.strings must not contain invalid format strings")

        let sources = repositoryRoot.appending(path: "Sources/NativeHarnessClient")
        let literal = try NSRegularExpression(pattern: #"L10n\.(?:string|format)\(\s*"((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        var checked = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let written = String(text[range])
                guard !written.contains("\\(") else { continue }
                let key = written.replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                checked += 1
                if parsed.entries[key] == nil { missing.append("\(file.lastPathComponent): \(written)") }
            }
        }
        XCTAssertGreaterThan(checked, 1_000, "the scan found the sources")
        XCTAssertEqual(missing, [])
    }

    /// Tier 1 (enforced on every PR): every bundled non-English `.lproj/Localizable.strings`
    /// must parse cleanly, have no duplicate keys or empty values, and preserve exact format-specifier
    /// parity with `en.lproj` (allowing positional reordering like `%2$@ ... %1$@`).
    /// Full 100% key parity and orphan cleanup are checked separately by `scripts/l10n.py check --strict`.
    func testNonEnglishCatalogsAreValidWithExactFormatSpecifierParity() throws {
        let englishURL = resourcesDirectory.appending(path: "en.lproj/Localizable.strings")
        let english = try parseStringsFile(at: englishURL).entries

        let lprojFolders = try FileManager.default
            .contentsOfDirectory(at: resourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .filter {
                let code = $0.deletingPathExtension().lastPathComponent
                return code != "en" && code != "Base"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(lprojFolders.isEmpty, "Expected at least one non-English .lproj catalog")

        for folder in lprojFolders {
            let locale = folder.deletingPathExtension().lastPathComponent
            let stringsURL = folder.appending(path: "Localizable.strings")
            guard FileManager.default.fileExists(atPath: stringsURL.path(percentEncoded: false)) else { continue }

            let parsed = try parseStringsFile(at: stringsURL)
            let plist = try loadPropertyListStrings(at: stringsURL)
            XCTAssertEqual(parsed.duplicates, [], "\(locale).lproj/Localizable.strings must not contain duplicate keys")
            XCTAssertEqual(parsed.entries.count, plist.count, "\(locale).lproj agrees with Foundation plist parser")

            var formatErrors: [String] = []
            for (key, value) in parsed.entries {
                XCTAssertFalse(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty key in \(locale).lproj")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty value for \(key) in \(locale).lproj")
                if let englishValue = english[key],
                   let error = formatSpecifierParityError(english: englishValue, translated: value) {
                    formatErrors.append("[\(locale)] \(key): \(error)")
                }
            }
            XCTAssertEqual(formatErrors, [], "Format specifier mismatch in \(locale).lproj")
        }
    }

    func testFormatSpecifierParityRules() throws {
        XCTAssertNil(formatSpecifierParityError(english: "Hello %@", translated: "こんにちは %@"))
        XCTAssertNil(formatSpecifierParityError(english: "%1$@ to %2$lld", translated: "%2$lld から %1$@"))
        XCTAssertNil(formatSpecifierParityError(english: "%@ %lld", translated: "%2$lld %1$@"))
        XCTAssertNil(formatSpecifierParityError(english: "%.1f%% of input", translated: "입력의 %.1f%%"))
        XCTAssertNil(formatSpecifierParityError(english: "CPU %", translated: "CPU %"))
        XCTAssertNil(formatSpecifierParityError(english: "Battery under 20%", translated: "배터리 20% 미만"))
        // Prose percentages must not false-positive as printf space-flagged specifiers (% d, % o, % f, % s).
        XCTAssertNil(formatSpecifierParityError(english: "50% done", translated: "50% 완료"))
        XCTAssertNil(formatSpecifierParityError(english: "10% off", translated: "10% 할인"))
        XCTAssertNil(formatSpecifierParityError(english: "20% faster", translated: "20% 더 빠름"))
        XCTAssertNil(formatSpecifierParityError(english: "100% safe", translated: "100% 안전"))

        XCTAssertNotNil(formatSpecifierParityError(english: "Hello %@", translated: "Hello"))
        XCTAssertNotNil(formatSpecifierParityError(english: "Hello %@", translated: "Hello %@ %@"))
        XCTAssertNotNil(formatSpecifierParityError(english: "Count %lld", translated: "Count %d"))
        XCTAssertNotNil(formatSpecifierParityError(english: "Count %lld", translated: "Count %@"))
        XCTAssertNotNil(formatSpecifierParityError(english: "%1$@ and %2$@", translated: "%1$@ and %@"))
        XCTAssertNotNil(formatSpecifierParityError(english: "Plain text", translated: "Plain %@"))

        // Unescaped '%' in a format string fails specifically with stray-percent detection.
        let straySig = try extractFormatSpecifiers(from: "%lld% left").get()
        XCTAssertEqual(straySig.placeholders, [1: "lld"])
        XCTAssertTrue(straySig.hasStrayPercent)
        let strayError = try XCTUnwrap(formatSpecifierParityError(english: "%lld%% left", translated: "%lld% left"))
        XCTAssertTrue(strayError.contains("unescaped '%'"), strayError)

        // English format strings with unescaped '%' are also rejected.
        let englishStrayError = try XCTUnwrap(formatSpecifierParityError(english: "%lld% left", translated: "%lld%% left"))
        XCTAssertTrue(englishStrayError.contains("unescaped '%'"), englishStrayError)

        // Malformed percent sequences like %50%, %1$%, %ll% are not accepted as literal %%.
        for bad in ["%lld %50%", "%lld %1$%", "%lld %ll%"] {
            let badSig = try extractFormatSpecifiers(from: bad).get()
            XCTAssertTrue(badSig.hasStrayPercent, "Expected stray percent for \(bad)")
            XCTAssertNotNil(formatSpecifierParityError(english: "%lld%% done", translated: bad))
        }

        // Dynamic '*' width/precision specifiers are rejected rather than silently equating %*d with %d.
        XCTAssertNotNil(formatSpecifierParityError(english: "Count %d", translated: "Count %*d"))
        XCTAssertNotNil(formatSpecifierParityError(english: "Value %f", translated: "Value %.*f"))
    }

    /// Proves that a key present in `en.lproj` but missing in a non-English `.lproj` falls back to
    /// the English catalog's value (not merely the raw key string) and formats safely without crashing.
    func testMissingKeysFallBackToEnglishCatalogValue() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletL10nFallback-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let resources = bundleURL.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources.appending(path: "en.lproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.appending(path: "ja.lproj"), withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>test.yardlet.l10n.fallback</string>
        <key>CFBundleDevelopmentRegion</key><string>en</string>
        </dict></plist>
        """
        try infoPlist.write(to: bundleURL.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)

        let enStrings = """
        "New task" = "New task";
        "Only in English" = "Only in English";
        "Archive split view confirmation" = "Archives all %lld tasks in this split view.";
        """
        let jaStrings = """
        "New task" = "新しいタスク";
        """
        try enStrings.write(to: resources.appending(path: "en.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        try jaStrings.write(to: resources.appending(path: "ja.lproj/Localizable.strings"), atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let enTable = L10n.stringsTable(for: "en", in: bundle)
        let jaBundle = try XCTUnwrap(bundle.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))

        // Translated key uses the target localization.
        XCTAssertEqual(L10n.string("New task", languageCode: "ja", in: bundle), "新しいタスク")

        // Missing identity key falls back to English.
        XCTAssertEqual(L10n.string("Only in English", languageCode: "ja", in: bundle), "Only in English")

        // Missing semantic key whose English value differs from its key falls back to the English
        // catalog VALUE (with its format specifier intact), not the raw key.
        let fallbackFormat = L10n.string("Archive split view confirmation", languageCode: "ja", in: bundle)
        XCTAssertEqual(fallbackFormat, "Archives all %lld tasks in this split view.")
        XCTAssertEqual(String(format: fallbackFormat, Int64(3)), "Archives all 3 tasks in this split view.")

        // Direct `L10n.resolve` against the partial localization bundle matches the same contract.
        XCTAssertEqual(
            L10n.resolve("Archive split view confirmation", in: jaBundle, englishFallback: enTable, defaultValue: "fallback"),
            "Archives all %lld tasks in this split view."
        )
        XCTAssertEqual(
            L10n.resolve("Unknown key", in: jaBundle, englishFallback: enTable, defaultValue: "Custom fallback"),
            "Custom fallback"
        )

        // Unbundled language code also falls back to the English catalog value.
        XCTAssertEqual(
            L10n.string("Archive split view confirmation", languageCode: "fr", in: bundle),
            "Archives all %lld tasks in this split view."
        )
        XCTAssertEqual(L10n.string("Completely unknown key", languageCode: "ja", in: bundle), "Completely unknown key")

        // `bundledLocalizations(in:)` unions `bundle.localizations` with a directory scan so flat
        // `.lproj` directories at the bundle root are discovered even if `bundle.localizations` omits them.
        try FileManager.default.createDirectory(at: bundleURL.appending(path: "zh-Hans.lproj"), withIntermediateDirectories: true)
        let discovered = L10n.bundledLocalizations(in: bundle)
        XCTAssertTrue(discovered.contains("en"))
        XCTAssertTrue(discovered.contains("ja"))
        XCTAssertTrue(discovered.contains("zh-Hans"))
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

        // Settings only lists languages whose `.lproj` catalog is bundled.
        XCTAssertEqual(AppLanguagePreference.availableCases(bundledLocalizations: ["en"]), [.system, .english])
        XCTAssertEqual(AppLanguagePreference.availableCases(bundledLocalizations: ["en", "ko"]), [.system, .english, .korean])

        // Settings offers Relaunch for a language other than the one the bundle chose as Yardlet opened.
        let shown = try XCTUnwrap(L10n.shownLocalization.flatMap(AppLanguagePreference.init(rawValue:)))
        XCTAssertFalse(shown.changesShownLanguage(in: defaults))
        XCTAssertTrue((shown == .english ? AppLanguagePreference.korean : .english).changesShownLanguage(in: defaults))
    }

    // MARK: - Helpers

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var resourcesDirectory: URL {
        repositoryRoot.appending(path: "Sources/NativeHarnessClient/Resources")
    }

    private func loadPropertyListStrings(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "Failed to parse \(url.path) as strings dictionary")
    }

    private struct ParsedStrings {
        let entries: [String: String]
        let duplicates: [String]
    }

    private enum StringsParseError: Error, CustomStringConvertible {
        case syntax(String)
        var description: String {
            switch self { case let .syntax(message): message }
        }
    }

    /// Strict `.strings` parser that preserves duplicate detection (which `PropertyListSerialization`
    /// overwrites silently).
    private func parseStringsFile(at url: URL) throws -> ParsedStrings {
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var line = 1

        func advance() {
            if scalars[index] == "\n" { line += 1 }
            index += 1
        }

        func skipWhitespaceAndComments() throws {
            while index < scalars.count {
                let ch = scalars[index]
                if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                    advance()
                } else if ch == "/" && index + 1 < scalars.count && scalars[index + 1] == "/" {
                    while index < scalars.count && scalars[index] != "\n" { advance() }
                } else if ch == "/" && index + 1 < scalars.count && scalars[index + 1] == "*" {
                    let startLine = line
                    advance(); advance()
                    var closed = false
                    while index + 1 < scalars.count {
                        if scalars[index] == "*" && scalars[index + 1] == "/" {
                            advance(); advance()
                            closed = true
                            break
                        }
                        advance()
                    }
                    if !closed { throw StringsParseError.syntax("\(url.lastPathComponent):\(startLine): unterminated block comment") }
                } else {
                    break
                }
            }
        }

        func readQuotedString() throws -> String {
            let startLine = line
            guard index < scalars.count, scalars[index] == "\"" else {
                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): expected '\"'")
            }
            advance()
            var result = ""
            while index < scalars.count {
                let ch = scalars[index]
                if ch == "\"" {
                    advance()
                    return result
                }
                if ch == "\\" {
                    advance()
                    guard index < scalars.count else {
                        throw StringsParseError.syntax("\(url.lastPathComponent):\(startLine): unterminated escape")
                    }
                    let esc = scalars[index]
                    advance()
                    switch esc {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "U":
                        guard index + 4 <= scalars.count else {
                            throw StringsParseError.syntax("\(url.lastPathComponent):\(line): truncated \\U escape")
                        }
                        let hex = String(String.UnicodeScalarView(scalars[index ..< index + 4]))
                        guard let code = UInt32(hex, radix: 16) else {
                            throw StringsParseError.syntax("\(url.lastPathComponent):\(line): invalid \\U escape \\U\(hex)")
                        }
                        for _ in 0 ..< 4 { advance() }
                        if (0xD800 ... 0xDBFF).contains(code) {
                            guard index + 6 <= scalars.count,
                                  scalars[index] == "\\", scalars[index + 1] == "U" else {
                                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): unpaired UTF-16 high surrogate \\U\(hex)")
                            }
                            let lowHex = String(String.UnicodeScalarView(scalars[index + 2 ..< index + 6]))
                            guard let low = UInt32(lowHex, radix: 16), (0xDC00 ... 0xDFFF).contains(low) else {
                                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): invalid UTF-16 low surrogate \\U\(lowHex)")
                            }
                            for _ in 0 ..< 6 { advance() }
                            let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            guard let scalar = UnicodeScalar(combined) else {
                                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): invalid surrogate pair \\U\(hex)\\U\(lowHex)")
                            }
                            result.unicodeScalars.append(scalar)
                        } else if (0xDC00 ... 0xDFFF).contains(code) {
                            throw StringsParseError.syntax("\(url.lastPathComponent):\(line): unpaired UTF-16 low surrogate \\U\(hex)")
                        } else {
                            guard let scalar = UnicodeScalar(code) else {
                                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): invalid Unicode scalar \\U\(hex)")
                            }
                            result.unicodeScalars.append(scalar)
                        }
                    default:
                        result.unicodeScalars.append(esc)
                    }
                } else {
                    result.unicodeScalars.append(ch)
                    advance()
                }
            }
            throw StringsParseError.syntax("\(url.lastPathComponent):\(startLine): unterminated string literal")
        }

        var entries: [String: String] = [:]
        var duplicates: [String] = []
        while true {
            try skipWhitespaceAndComments()
            if index >= scalars.count { break }
            let key = try readQuotedString()
            try skipWhitespaceAndComments()
            guard index < scalars.count, scalars[index] == "=" else {
                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): expected '=' after key \(key)")
            }
            advance()
            try skipWhitespaceAndComments()
            let value = try readQuotedString()
            try skipWhitespaceAndComments()
            guard index < scalars.count, scalars[index] == ";" else {
                throw StringsParseError.syntax("\(url.lastPathComponent):\(line): expected ';' after value for \(key)")
            }
            advance()
            if entries[key] != nil {
                duplicates.append(key)
            }
            entries[key] = value
        }
        return ParsedStrings(entries: entries, duplicates: duplicates)
    }

    private struct FormatSpecifierSignature: Equatable {
        let placeholders: [Int: String]
        let hasStrayPercent: Bool
    }

    private static let formatSpecifierRegex = try! NSRegularExpression(
        pattern: #"%%|%(?:([1-9][0-9]*)\$)?([-+#0]*)(?:([0-9]+|\*))?(?:\.([0-9]+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiIuUxXoOfeEfFgGcCsSpAa])"#
    )

    private func extractFormatSpecifiers(from text: String) -> Result<FormatSpecifierSignature, StringsParseError> {
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = Self.formatSpecifierRegex.matches(in: text, range: fullRange)
        var placeholders: [Int: String] = [:]
        var nextImplicitIndex = 1
        var sawPositional = false
        var sawImplicit = false
        var stripped = text
        var matchedRanges: [Range<String.Index>] = []

        for match in matches {
            guard let wholeRange = Range(match.range, in: text) else { continue }
            matchedRanges.append(wholeRange)
            let token = String(text[wholeRange])
            if token == "%%" { continue }

            let width = Range(match.range(at: 3), in: text).map { String(text[$0]) }
            let precision = Range(match.range(at: 4), in: text).map { String(text[$0]) }
            if width == "*" || precision == "*" {
                return .failure(.syntax("unsupported dynamic '*' width/precision specifier: \(token)"))
            }

            guard let convRange = Range(match.range(at: 6), in: text) else { continue }
            let conversion = String(text[convRange])
            let length = Range(match.range(at: 5), in: text).map { String(text[$0]) } ?? ""
            let canonicalConv: String = switch conversion {
            case "i", "D": "d"
            case "U": "u"
            case "O": "o"
            case "F": "f"
            default: conversion
            }
            let typeSignature = length + canonicalConv

            let argIndex: Int
            if let posRange = Range(match.range(at: 1), in: text), let parsed = Int(text[posRange]) {
                sawPositional = true
                argIndex = parsed
            } else {
                sawImplicit = true
                argIndex = nextImplicitIndex
                nextImplicitIndex += 1
            }

            if let existing = placeholders[argIndex], existing != typeSignature {
                return .failure(.syntax("conflicting types for argument \(argIndex): \(existing) vs \(typeSignature)"))
            }
            placeholders[argIndex] = typeSignature
        }

        if sawPositional && sawImplicit {
            return .failure(.syntax("mixes positional and non-positional format specifiers"))
        }

        for range in matchedRanges.reversed() {
            stripped.removeSubrange(range)
        }
        return .success(FormatSpecifierSignature(placeholders: placeholders, hasStrayPercent: stripped.contains("%")))
    }

    private func formatSpecifierParityError(english: String, translated: String) -> String? {
        let enSig: FormatSpecifierSignature
        switch extractFormatSpecifiers(from: english) {
        case let .success(sig): enSig = sig
        case let .failure(error): return "invalid English format string: \(error)"
        }
        if !enSig.placeholders.isEmpty && enSig.hasStrayPercent {
            return "unescaped '%' in English format string (use '%%' for a literal percent)"
        }
        let trSig: FormatSpecifierSignature
        switch extractFormatSpecifiers(from: translated) {
        case let .success(sig): trSig = sig
        case let .failure(error): return "invalid translated format string: \(error)"
        }

        if enSig.placeholders != trSig.placeholders {
            return "expected \(enSig.placeholders), got \(trSig.placeholders)"
        }
        if !enSig.placeholders.isEmpty && trSig.hasStrayPercent {
            return "unescaped '%' in format string (use '%%' for a literal percent)"
        }
        return nil
    }
}
