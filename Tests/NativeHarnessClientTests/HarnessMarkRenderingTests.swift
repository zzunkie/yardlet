import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The harness marks before task titles, drawn offscreen into `.build/harness-mark-qa`, light and
/// dark: for every harness with a packaged logo, a sidebar with a pinned (top-level) task and a
/// project holding a selected and an unselected task, one overview per appearance
/// (`sidebar-all-*`), the name labels at the title bar's and new-task menu's sizes (`labels-*`),
/// and each mark's measured contrast against the row (`mark-contrast.txt`). No provider, window
/// server interaction, or app launch.
@MainActor
final class HarnessMarkRenderingTests: XCTestCase {
    private static let markedHarnesses = HarnessCatalog.builtIns.map(\.id).filter {
        HarnessLogoAsset.name(for: $0) != nil
    }

    /// Codex's mark is the ChatGPT app icon: a light plate holding a dark knot, unlike the
    /// earlier dark plate. Its text name stays "Codex".
    func testCodexMarkIsTheChatGPTAppIcon() throws {
        let artwork = try XCTUnwrap(HarnessLogoCatalog.image(for: .codex))
        let bitmap = try XCTUnwrap(artwork.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 128)
        XCTAssertEqual(bitmap.pixelsHigh, 128)
        // Inside the plate's corner, near white; on the knot's left loop, dark.
        let plate = try XCTUnwrap(bitmap.colorAt(x: 30, y: 30)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(plate.brightnessComponent, 0.9)
        XCTAssertEqual(plate.alphaComponent, 1, accuracy: 0.01)
        let knot = try XCTUnwrap(bitmap.colorAt(x: 40, y: 64)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(knot.brightnessComponent, 0.5)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01, "The icon keeps its own rounded shape")
        XCTAssertEqual(HarnessKind.codex.displayName, "Codex")

        // In dark mode, the same icon's dark appearance: a dark plate holding a light knot, so no white tile
        // stands on a dark sidebar.
        let darkArtwork = try XCTUnwrap(HarnessLogoCatalog.image(for: .codex, isDark: true))
        let dark = try XCTUnwrap(darkArtwork.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(dark.pixelsWide, 128)
        XCTAssertEqual(dark.pixelsHigh, 128)
        let darkPlate = try XCTUnwrap(dark.colorAt(x: 30, y: 30)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(darkPlate.brightnessComponent, 0.2)
        XCTAssertEqual(darkPlate.alphaComponent, 1, accuracy: 0.01)
        let darkKnot = try XCTUnwrap(dark.colorAt(x: 40, y: 64)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(darkKnot.brightnessComponent, 0.7)
        XCTAssertEqual(try XCTUnwrap(dark.colorAt(x: 2, y: 2)).alphaComponent, 0, accuracy: 0.01)
    }

    /// Every mark, at the sidebar's 16 points, differs clearly from the row behind it in both
    /// appearances, selected or not: a noticeable share of its pixels stand apart from the
    /// background. White artwork on a transparent ground would fail this on a light sidebar.
    func testEveryMarkStandsApartFromTheSidebarRowInBothAppearances() throws {
        var report: [String] = []
        for appearance in WindowlessRender.Appearance.allCases {
            for isSelected in [false, true] {
                for harness in Self.markedHarnesses {
                    let share = try Self.share(
                        of: HarnessIdentityIcon(harness: harness, size: SidebarMetrics.nestedIconSize),
                        in: appearance, isSelected: isSelected)
                    report.append(String(format: "%@ %@%@ %.2f", harness.rawValue, appearance.suffix,
                                         isSelected ? " selected" : "", share))
                    XCTAssertGreaterThan(share, Self.minimumDistinctShare,
                                         "\(harness.rawValue) \(appearance.suffix) selected: \(isSelected)")
                }
            }
        }
        try report.joined(separator: "\n").write(
            to: WindowlessRender.directory("harness-mark-qa").appending(path: "mark-contrast.txt"),
            atomically: true, encoding: .utf8)
    }

    /// The share of a mark's square that must stand apart from the row behind it. A glyph on a
    /// plate that matches the sidebar (Grok's white plate in light, Antigravity's dark plate in
    /// dark) scores 0.11 to 0.2; bare white artwork on the light sidebar scores 0.03.
    private static let minimumDistinctShare = 0.08

    func testSidebarRowsRenderForEveryMarkedHarness() throws {
        let directory = try WindowlessRender.directory("harness-mark-qa")
        let size = NSSize(width: ParityTheme.sidebarWidth, height: 360)
        var captures: [WindowlessRender.Appearance: [NSBitmapImageRep]] = [:]
        for harness in Self.markedHarnesses {
            let sidebar = try Self.sidebar(for: harness)
            let images = try WindowlessRender.hostedInBothAppearances(
                "sidebar-\(harness.rawValue)", in: directory, size: size
            ) { appearance in
                sidebar
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.sidebar)
            }
            for (appearance, capture) in zip(WindowlessRender.Appearance.allCases, images) {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6), harness.rawValue)
                captures[appearance, default: []].append(capture.bitmap)
            }
        }
        for (appearance, bitmaps) in captures {
            let sheet = try XCTUnwrap(Self.sheet(bitmaps, columns: 5))
            try WindowlessRender.writePNG(sheet, to: directory.appending(path: "sidebar-all-\(appearance.suffix).png"))
        }
    }

    /// Every marked harness's name label as the title bar draws it (14 pt mark, 11.5 pt secondary
    /// text) and as the new-task harness menu draws it (16 pt mark, 13 pt text), in `labels-*`.
    func testHarnessLabelsRenderAtTheirSurfaceSizes() throws {
        let harnesses = Self.markedHarnesses
        let size = NSSize(width: 420, height: CGFloat(harnesses.count) * 24 + 16)
        try WindowlessRender.hostedInBothAppearances(
            "labels", in: WindowlessRender.directory("harness-mark-qa"), size: size
        ) { appearance in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(harnesses, id: \.self) { harness in
                    HStack(spacing: 24) {
                        HarnessIdentityLabel(harness: harness, size: 14)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 170, alignment: .leading)
                        HarnessIdentityLabel(harness: harness)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(height: 24)
                }
            }
            .padding(8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
        }
    }

    // MARK: - Fixtures

    /// A sidebar with one harness's tasks: one pinned, and a project holding the selected task and
    /// another.
    private static func sidebar(for harness: HarnessKind) throws -> some View {
        let folder = URL(filePath: "/tmp/harness-mark-qa/\(harness.rawValue)", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: folder, name: harness.displayName)
        let now = Date()
        func task(_ title: String, minutesAgo: Double, pinned: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                          title: title, titleOrigin: .provider, status: .ready,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60), isPinned: pinned)
        }
        let pinned = task("Pinned task", minutesAgo: 3, pinned: true)
        let selected = task("Selected task", minutesAgo: 1)
        let other = task("Unselected task", minutesAgo: 2)
        let groups = projects.visibleGroups(sessions: [pinned, selected, other])
        let suite = testDefaultsSuite("harness-mark-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disclosure = SidebarDisclosureStore(defaults: defaults)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure.disclosure, selection: .session(selected.id))
        return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(selected.id),
            searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
            projects: projects, onEditProject: { _ in },
            onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
            onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
            disclosure: disclosure)
    }

    // MARK: - Pixels

    /// `mark` drawn at the sidebar's mark size over a sidebar row (selected or not) in an unshown
    /// window, and the share of its pixels that differ clearly from the bare row.
    private static func share<Mark: View>(of mark: Mark, in appearance: WindowlessRender.Appearance,
                                          isSelected: Bool) throws -> Double {
        let side = SidebarMetrics.nestedIconSize
        func row<Content: View>(_ content: Content) -> some View {
            content
                .frame(width: side, height: side)
                .background(isSelected ? ParityTheme.selectedFill : .clear)
                .background(ParityTheme.sidebar)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let size = NSSize(width: side, height: side)
        let drawn = try WindowlessRender.hosted(row(mark), size: size, appearance: appearance, passes: 2)
        let bare = try WindowlessRender.hosted(row(Color.clear), size: size, appearance: appearance, passes: 1)
        let background = try XCTUnwrap(bare.bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        return share(of: drawn.bitmap, differingFrom: background, by: 0.2)
    }

    /// The share of `bitmap`'s pixels whose colour differs from `background` by more than
    /// `threshold` in some sRGB channel.
    private static func share(of bitmap: NSBitmapImageRep, differingFrom background: NSColor,
                              by threshold: CGFloat) -> Double {
        var differing = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let difference = max(abs(color.redComponent - background.redComponent),
                                     abs(color.greenComponent - background.greenComponent),
                                     abs(color.blueComponent - background.blueComponent))
                if difference > threshold { differing += 1 }
            }
        }
        return Double(differing) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
    }

    /// `bitmaps` (all the same size) laid out left to right in rows of `columns`.
    private static func sheet(_ bitmaps: [NSBitmapImageRep], columns: Int) -> NSBitmapImageRep? {
        guard let first = bitmaps.first else { return nil }
        let width = first.pixelsWide, height = first.pixelsHigh
        let rows = (bitmaps.count + columns - 1) / columns
        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * columns, pixelsHigh: height * rows, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: sheet) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (index, bitmap) in bitmaps.enumerated() {
            let column = index % columns, row = index / columns
            bitmap.draw(in: NSRect(x: column * width, y: (rows - 1 - row) * height, width: width, height: height))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return sheet
    }
}
