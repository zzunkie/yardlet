import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Settings › Usage drawn for review into `.build/token-usage-qa/`: the sheet as it opens (820×620)
/// and the whole page in one tall image, in both appearances, from `TokenUsageFixture`.
@MainActor
final class TokenUsageRenderingTests: XCTestCase {
    func testSettingsUsagePage() throws {
        let directory = try WindowlessRender.directory("token-usage-qa")
        let now = Date()
        let overview = TokenUsageFixture.overview(now: now)
        let context = SettingsUsageContext(overview: { overview }, isCounting: { true },
                                           limitsCheckedAt: { now.addingTimeInterval(-60) })
        for (name, size) in [("settings-usage", NSSize(width: 820, height: 620)),
                             ("settings-usage-full", NSSize(width: 820, height: 1_480))] {
            for appearance in WindowlessRender.Appearance.allCases {
                let host = WindowlessRender.Host(
                    SettingsCenterView(size: CGSize(width: size.width, height: size.height),
                                       initialSection: SettingsSection.usage.rawValue,
                                       notificationCenter: MenuBarQuietNotificationCenter(), usage: context)
                        .environment(\.colorScheme, appearance.colorScheme),
                    size: size, appearance: appearance)
                defer { host.close() }
                host.settle(passes: 8)
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                if appearance == .light, name == "settings-usage-full" {
                    let text = host.accessibilityElements().map(\.description).joined(separator: "\n")
                    try text.write(to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
