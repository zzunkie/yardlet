import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Opt-in review artifacts, not product changes or pixel-golden assertions. Run separately for each
/// AppleLanguages setting with YARDLET_DESIGN_AUDIT=1. All windows stay unshown.
@MainActor
final class DesignAuditRenderingTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        XCTAssertEqual(L10n.string("New task"), AuditCopy.text("New task"),
                       "The app localization and the synthetic copy must use the same language")
    }

    func testLongConversationAtReadingAndSplitWidths() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        let directory = try WindowlessRender.directory("design-audit/conversation")
        let paragraph = AuditCopy.text("The conversation now keeps its reading position when reopened. Long file names and multiline errors should remain readable at the available width. The table and code below describe the change and its verification.")
        let title = AuditCopy.text("Changes and verification")
        let text = """
        ## \(title)

        \(paragraph)

        - **\(AuditCopy.text("Reading position"))**: `Sources/Conversation/ConversationScrollRestorationController.swift`
        - \(paragraph)

        ```swift
        func restoreConversation(_ conversation: Conversation, preserving anchor: ReadingAnchor) async throws {
            let snapshot = try await store.load(conversation.id)
            renderer.restore(snapshot, anchor: anchor)
        }
        ```

        | \(AuditCopy.text("State")) | \(AuditCopy.text("Result")) |
        | --- | --- |
        | \(AuditCopy.text("Restoration")) | \(paragraph) |
        | \(AuditCopy.text("Long file names")) | `ConversationScrollRestorationController.swift` |

        > \(paragraph)

        \(paragraph)
        """
        for width in [CGFloat(760), 420] {
            for appearance in WindowlessRender.Appearance.allCases {
                let size = NSSize(width: width, height: 1000)
                let view = ScrollView {
                    ConversationAgentMessage(itemID: "audit-answer", harness: .claudeCode,
                        text: text, isCommentary: false, isStreaming: false)
                        .padding(.horizontal, ParityTheme.conversationInset).padding(.vertical, 24)
                }.frame(width: width, height: size.height).background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme)
                let host = WindowlessRender.Host(view, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertFalse(host.window.isVisible)
                try WindowlessRender.writePNG(host.capture().bitmap,
                    to: directory.appending(path: "long-\(Int(width))-\(appearance.suffix).png"))
            }
        }
    }

    func testIdentityOptionsAtTheSameWindowSize() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        let directory = try WindowlessRender.directory("design-audit/identity")
        let size = NSSize(width: 1280, height: 820)
        for option in IdentityMock.Option.allCases {
            for appearance in WindowlessRender.Appearance.allCases {
                let view = IdentityMock(option: option, dark: appearance == .dark)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(view, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertFalse(host.window.isVisible)
                try WindowlessRender.writePNG(host.capture().bitmap,
                    to: directory.appending(path: "\(option.rawValue)-\(appearance.suffix).png"))
            }
        }
    }
}

/// Deliberately static proposals: the colors, headline styles and selection details below are
/// candidates for the home and project grouping only. They do not alter the provider surfaces.
private struct IdentityMock: View {
    enum Option: String, CaseIterable { case ink, grove, iris }
    let option: Option
    let dark: Bool

    private var accent: Color {
        switch option {
        case .ink: dark ? Color(red: 0.55, green: 0.72, blue: 0.98) : Color(red: 0.08, green: 0.23, blue: 0.42)
        case .grove: dark ? Color(red: 0.48, green: 0.82, blue: 0.68) : Color(red: 0.08, green: 0.40, blue: 0.29)
        case .iris: dark ? Color(red: 0.72, green: 0.65, blue: 0.98) : Color(red: 0.36, green: 0.27, blue: 0.67)
        }
    }
    private var headline: Font.Design { option == .grove ? .rounded : .default }
    private var projectFont: Font.Design { option == .iris ? .monospaced : .default }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240).background(ParityTheme.sidebar)
            Rectangle().fill(ParityTheme.separator).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(AuditCopy.text("New task")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "rectangle.split.2x1").foregroundStyle(.secondary)
                }.padding(.horizontal, 24).frame(height: 50)
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AuditCopy.text("What are we working on?"))
                                .font(.system(size: 24, weight: .semibold, design: headline))
                            Text(AuditCopy.text("Start a task or pick up where you left off."))
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        composer
                        VStack(alignment: .leading, spacing: 16) {
                            section(AuditCopy.text("Needs your attention"))
                            task(AuditCopy.text("Review the storage migration"),
                                 detail: AuditCopy.text("Approval requested · workspace"), symbol: "hand.raised")
                            task(AuditCopy.text("Choose the new navigation labels"),
                                 detail: AuditCopy.text("A question · design-kit"), symbol: "questionmark.bubble")
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            section(AuditCopy.text("Projects"))
                            project("workspace", subtitle: AuditCopy.text("2 running · 1 needs attention"))
                            project("design-kit", subtitle: AuditCopy.text("Updated 12 minutes ago"))
                            project("website", subtitle: AuditCopy.text("All tasks complete"))
                        }
                    }.frame(maxWidth: 768).padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                }
            }.background(ParityTheme.canvas)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Text("Yardlet").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                Spacer()
                Image(systemName: "sidebar.left").foregroundStyle(.secondary)
            }.frame(height: 26)
            HStack {
                Image(systemName: "square.and.pencil")
                Text(AuditCopy.text("New task"))
                Spacer()
                Text("⌘N").foregroundStyle(.secondary).font(.system(size: 12))
            }.font(.system(size: 13, weight: .medium)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 12) {
                Text(AuditCopy.text("Projects")).font(.system(size: 12)).foregroundStyle(.secondary)
                sidebarProject("workspace", selected: true)
                sidebarTask(AuditCopy.text("Review the storage migration"))
                sidebarTask(AuditCopy.text("Restore conversation position"))
                sidebarProject("design-kit", selected: false)
                sidebarTask(AuditCopy.text("Choose navigation labels"))
                sidebarProject("website", selected: false)
            }
            VStack(alignment: .leading, spacing: 16) {
                Label(AuditCopy.text("Chats"), systemImage: "bubble.left")
                Label(AuditCopy.text("Schedules"), systemImage: "calendar")
                Label(AuditCopy.text("Mailbox"), systemImage: "tray")
            }.font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Label(AuditCopy.text("Settings"), systemImage: "gearshape").font(.system(size: 13))
        }.padding(16)
    }

    private func sidebarProject(_ name: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            Text(name).font(.system(size: 13, weight: .medium, design: projectFont))
            Spacer()
        }.foregroundStyle(selected ? accent : Color.primary).frame(height: 28)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                if selected && option == .ink { Rectangle().fill(accent).frame(width: 2, height: 20) }
                if selected && option == .grove {
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4, height: 12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if selected && option == .iris { Rectangle().fill(accent).frame(width: 88, height: 1) }
            }
    }

    private func sidebarTask(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            .padding(.leading, 24).foregroundStyle(.secondary)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(AuditCopy.text("Describe a task…")).foregroundStyle(.secondary).font(.system(size: 14))
            HStack(spacing: 16) {
                Image(systemName: "plus")
                Text("workspace").font(.system(size: 13, weight: .medium, design: projectFont))
                Image(systemName: "chevron.down").font(.system(size: 8))
                Spacer()
                Text("Claude Code · Opus").font(.system(size: 13)).foregroundStyle(.secondary)
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? Color.black : Color.white).frame(width: 28, height: 28)
                    .background(accent, in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(16).background(ParityTheme.input, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ParityTheme.strongSeparator, lineWidth: 1))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 18, weight: .semibold, design: headline))
    }

    private func task(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func project(_ name: String, subtitle: String) -> some View {
        HStack {
            Text(name).font(.system(size: 14, weight: .medium, design: projectFont))
            Spacer()
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

/// Optional synthetic copy supplied by the local reviewer. No customer conversations are loaded.
private enum AuditCopy {
    static let translations: [String: String] = {
        guard let path = ProcessInfo.processInfo.environment["YARDLET_AUDIT_COPY"],
              let data = try? Data(contentsOf: URL(filePath: path)),
              let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return strings
    }()
    static func text(_ english: String) -> String { translations[english] ?? english }
}
