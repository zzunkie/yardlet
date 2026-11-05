import Foundation
import WinSDK

/// A console without a window, which the programs the Windows app starts share. The release app is a windowed
/// program with no console, and Foundation's `Process` asks `CreateProcessW` for no `CREATE_NO_WINDOW`, so each
/// console program it started (a harness's node, Git) opened a console window of its own, in Windows Terminal
/// where that is the default terminal. A child of a process that has a console takes its console instead.
/// `AllocConsoleWithOptions` (Windows 11 24H2 and later) makes one with no window; on an earlier Windows the app
/// keeps none, as before. The app's own standard handles stay as they were, so what it writes still goes where
/// it went.
enum WindowsConsole {
    private struct Options {
        /// `ALLOC_CONSOLE_MODE_NO_WINDOW`.
        var mode: Int32 = 2
        var useShowWindow: Int32 = 0
        var showWindow: UInt16 = 0
    }

    private typealias AllocConsoleWithOptions = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?) -> HRESULT

    /// What happened, for the event log: the call's result and whether a window came with the console.
    @discardableResult
    static func makeHidden() -> String {
        guard GetConsoleWindow() == nil else { return "console: had one" }
        guard let kernel = "kernel32.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
              let address = GetProcAddress(kernel, "AllocConsoleWithOptions") else { return "console: no AllocConsoleWithOptions" }
        // STD_INPUT_HANDLE, STD_OUTPUT_HANDLE and STD_ERROR_HANDLE, which are casts Swift does not import.
        let handles = [-10, -11, -12].map { DWORD(bitPattern: $0) }.map { ($0, GetStdHandle($0)) }
        let allocate = unsafeBitCast(address, to: AllocConsoleWithOptions.self)
        var options = Options()
        var result: Int32 = 0
        let status = withUnsafeMutablePointer(to: &options) { allocate(UnsafeMutableRawPointer($0), &result) }
        for (kind, handle) in handles where handle != nil && handle != INVALID_HANDLE_VALUE {
            SetStdHandle(kind, handle)
        }
        return "console: status \(String(UInt32(bitPattern: status), radix: 16)), result \(result), window \(GetConsoleWindow() != nil)"
    }
}
