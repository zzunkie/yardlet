import Foundation
import WinSDK

/// A harness's own sign-in command in a console window of its own, where the Mac runs it in a terminal inside
/// Yardlet (`AccountLoginController`). Windows opens the console in the person's default terminal (Windows Terminal
/// where it is the default); the CLI shows its own sign-in there, opens the browser itself, and the person finishes
/// it there. What npm's shim would start starts instead of the shim (`NPMCommandShim`), in the environment a
/// harness gets (`RuntimeProcessEnvironment`). The window is the person's: it stays open if Yardlet quits, and
/// Yardlet only looks at whether it has ended.
final class WindowsSignInConsole {
    struct Failure: LocalizedError {
        let code: DWORD
        var errorDescription: String? { "Windows error \(code)" }
    }

    private let process: HANDLE

    private init(process: HANDLE) {
        self.process = process
    }

    deinit {
        CloseHandle(process)
    }

    /// The command has ended: the person closed the window, or the CLI finished.
    var hasEnded: Bool {
        // WAIT_OBJECT_0, a cast Swift does not import.
        WaitForSingleObject(process, 0) == 0
    }

    static func open(_ command: AccountInteractiveCommand) throws -> WindowsSignInConsole {
        let lookup = ExecutableLookup.current
        let environment = lookup.normalized(RuntimeProcessEnvironment.values(
            executableURL: command.executableURL, overrides: command.environment))
        let launch = try NPMCommandShim.launch(command.executableURL, arguments: command.arguments,
                                               searchPath: lookup.searchPath(in: environment), lookup: lookup)
            ?? (command.executableURL, command.arguments)
        let program = lookup.nativePath(launch.executable)
        var line = Array(WindowsCommandLine.joined([program] + launch.arguments).utf16) + [0]
        // A Unicode environment block: each `name=value` ended by a zero, and one more zero after the last, sorted
        // by name as Windows keeps it.
        var block: [UInt16] = []
        for name in environment.keys.sorted(by: { $0.uppercased() < $1.uppercased() }) {
            block += Array("\(name)=\(environment[name] ?? "")".utf16) + [0]
        }
        block += [0]
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var information = PROCESS_INFORMATION()
        let home = lookup.nativePath(FileManager.default.homeDirectoryForCurrentUser)
        let started = program.withCString(encodedAs: UTF16.self) { application in
            home.withCString(encodedAs: UTF16.self) { folder in
                block.withUnsafeMutableBufferPointer { values in
                    CreateProcessW(application, &line, nil, nil, false,
                                   DWORD(CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT), values.baseAddress,
                                   folder, &startup, &information)
                }
            }
        }
        guard started, let process = information.hProcess else { throw Failure(code: GetLastError()) }
        if let thread = information.hThread { CloseHandle(thread) }
        return WindowsSignInConsole(process: process)
    }
}

/// The person's default browser.
enum WindowsBrowser {
    /// Opens an https address there; false when Windows did not.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        let result = url.absoluteString.withCString(encodedAs: UTF16.self) { address in
            "open".withCString(encodedAs: UTF16.self) { verb in
                ShellExecuteW(nil, verb, address, nil, nil, SW_SHOWNORMAL)
            }
        }
        // ShellExecuteW reports success as a value above 32.
        return Int(bitPattern: result) > 32
    }
}
