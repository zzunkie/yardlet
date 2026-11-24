import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class NativeForkMenuRenderingTests: XCTestCase {
    func testActualTurnActionsAndResetCommandContentRenderWithoutAWindow() throws {
        let command = try XCTUnwrap(ClaudeComposerCommands.initial(.object([
            "commands": .array([.object(["name": .string("clear"), "builtin": .bool(true)])])
        ])).first)
        XCTAssertEqual(command.description, L10n.string("Start a new conversation and keep this chat."))
        let directory = try WindowlessRender.directory("native-fork-qa")
        for appearance in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 12) {
                // The turn's actions as its messages draw them, shown as on hover.
                HStack(spacing: 12) {
                    ConversationMessageActionButtons(actions: [ConversationTurnAction.fork, .editTurn].map {
                        $0.messageAction(turn: ConversationTurn(id: "turn-qa", status: .completed, timing: ConversationTurnTiming()),
                                         handlers: ConversationTurnHandlers(edit: { _ in }, fork: {}), harness: .codex)
                    })
                }
                .environment(\.revealsSentMessageActions, true)
                Divider()
                ComposerCommandRow(command: command)
            }.padding(12).frame(width: 340).background(ParityTheme.input).environment(\.colorScheme, appearance)
            // The actions are AppKit buttons, as the copy beside them is, which only a window draws.
            let capture = try WindowlessRender.hosted(view, size: NSSize(width: 340, height: 140),
                                                      appearance: WindowlessRender.Appearance(appearance))
            let bitmap = capture.bitmap
            XCTAssertEqual(bitmap.pixelsWide, Int(340 * capture.backingScaleFactor))
            // Unsupported native render nodes used to produce a yellow/black placeholder.
            var placeholder = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.9, color.greenComponent > 0.75, color.blueComponent < 0.15 { placeholder += 1 }
                }
            }
            XCTAssertEqual(placeholder, 0)
            try WindowlessRender.writePNG(bitmap, to:
                directory.appending(path: appearance == .dark ? "actions-dark.png" : "actions-light.png"))
        }
    }
}
