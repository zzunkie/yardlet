import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Terminal tabs printing a lot at once cost the main thread what their output costs, whatever the
/// number of tabs: the panel draws nothing again while they print (none of what it reads changes),
/// and a tab it does not show is in no window and draws nothing. SwiftTerm parses each tab's output on
/// the main queue in reads of up to 128 KB and draws a shown tab at most once a frame. Four tabs
/// printing 4 × 100,000 lines are timed against one tab printing as much; the times go to the log.
@MainActor
final class TerminalTabsPerformanceTests: XCTestCase {
    func testTabsPrintingALotRedrawNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-terminal-tabs-\(UUID().uuidString)")
        let folder = root.appending(path: "yardlet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let launch = ShellLaunchEnvironment.isolatedZsh(in: root)
        for (tabCount, lines) in [(1, 400_000), (4, 100_000)] {
            let workspace = TaskWorkspaceState()
            let host = WindowlessRender.Host(
                TabsHost(workspace: workspace, folder: folder, launch: launch).frame(width: 1_000, height: 320),
                size: NSSize(width: 1_000, height: 320), appearance: .light)
            defer { host.close() }
            host.settle()
            // Each tab's shell starts once the panel has shown it.
            for index in 0..<tabCount {
                if index > 0 { workspace.openTerminalTab(in: folder, launch: launch, taskID: nil) }
                let shell = workspace.terminals[index]
                await host.settle(until: { shell.isAtPrompt && shell.bufferText.contains("%") })
            }
            let shells = workspace.terminals
            let appBefore = Self.footprint(of: getpid())

            let panel = Invalidations {
                _ = (workspace.terminalRevision, workspace.panels)
                for shell in shells {
                    _ = (shell.name, shell.isRunning, shell.exitCode, shell.terminationSignal, shell.generation,
                         shell.dismissedFolderNotice, shell.hasEnded)
                }
            }
            let lag = MainActorGapProbe()
            await lag.start()
            let started = ContinuousClock.now
            for shell in shells { shell.send("seq 1 \(lines); echo done-$((6*7))\r") }
            await host.settle(until: { shells.allSatisfy { $0.isAtPrompt && $0.bufferText.contains("done-42") } },
                              timeout: 120)
            let elapsed = ContinuousClock.now - started
            let longest = await lag.stop()
            panel.stop()
            let shellMemory = Self.childProcesses().map(Self.footprint).reduce(0, +)
            print("terminal-tabs-cost: \(tabCount) tab(s) × \(lines) lines: \(elapsed), "
                  + "longest main-thread gap \(longest), panel invalidations \(panel.count), "
                  + "app memory +\((Self.footprint(of: getpid()) - appBefore) >> 20) MB for full scrollbacks, "
                  + "shells \(shellMemory >> 20) MB")
            XCTAssertEqual(panel.count, 0, "\(tabCount) tabs: printing changed what the panel draws")
            workspace.endTerminal()
        }
    }
}

extension TerminalTabsPerformanceTests {
    /// A process's memory as Activity Monitor counts it.
    static func footprint(of pid: pid_t) -> Int64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : 0
    }

    /// The test's own child processes: the tabs' shells.
    static func childProcesses() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, count))))
    }
}

/// The terminal panel as a task's screen builds it.
private struct TabsHost: View {
    let workspace: TaskWorkspaceState
    let folder: URL
    let launch: ShellLaunchEnvironment

    var body: some View {
        let _ = workspace.terminalRevision
        let shell = workspace.terminal(in: folder, launch: launch, taskID: nil)
        TerminalPane(session: shell,
                     tabs: TerminalTabsContext(workspace: workspace, folder: folder, launch: launch, taskID: nil),
                     onClose: {})
            .id(ObjectIdentifier(shell))
    }
}
