import Foundation
import XCTest
@testable import NativeHarnessClient

final class RuntimeProcessEnvironmentTests: XCTestCase {
    func testRuntimePathIncludesExecutableDirectoryAndCommonNodeLocations() {
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/custom/runtime/pi"),
            base: ["HOME": "/Users/test", "PATH": "/existing/bin:/usr/bin"]
        )
        let paths = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(paths?.first, "/custom/runtime")
        XCTAssertTrue(paths?.contains("/opt/homebrew/bin") ?? false)
        XCTAssertTrue(paths?.contains("/usr/local/bin") ?? false)
        XCTAssertTrue(paths?.contains("/existing/bin") ?? false)
        XCTAssertEqual(paths?.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testRuntimeOverridesWinWithoutDiscardingAugmentedPath() {
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/opt/homebrew/bin/pi"),
            base: ["HOME": "/Users/test", "PATH": "/usr/bin"],
            overrides: ["PAGER": "cat", "CUSTOM": "value"]
        )

        XCTAssertEqual(environment["PAGER"], "cat")
        XCTAssertEqual(environment["CUSTOM"], "value")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
    }

    /// On Windows a variable's name is the same in any case: the search path is one `Path`, split and joined at
    /// `;` with each folder once in any case, the home folder is `USERPROFILE`, npm's global folder is
    /// preferred, and an isolated account's credentials go whatever case they are written in.
    func testWindowsRulesKeepOnePathAndReadNamesInAnyCase() {
        let windows = ExecutableLookup.windows(pathExtensions: ".COM;.EXE;.BAT;.CMD;.VBS;.JS")
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/C:/Users/test/AppData/Roaming/npm/kimi.cmd"),
            base: ["USERPROFILE": "C:\\Users\\test", "APPDATA": "C:\\Users\\test\\AppData\\Roaming",
                   "Path": "C:\\Windows\\system32;C:\\Program Files\\nodejs\\;c:\\windows\\System32;D:\\",
                   "YARDLET_ACCOUNT_ENVIRONMENT": "isolated", "anthropic_api_key": "secret"],
            overrides: ["PAGER": "cat"],
            lookup: windows)

        XCTAssertEqual(environment.keys.filter { $0.uppercased() == "PATH" }, ["Path"])
        XCTAssertEqual(environment["Path"]?.split(separator: ";").map(String.init), [
            "C:\\Users\\test\\AppData\\Roaming\\npm", "C:\\Users\\test\\.local\\bin", "C:\\Users\\test\\.bun\\bin",
            "C:\\Windows\\system32", "C:\\Program Files\\nodejs", "D:\\"
        ])
        XCTAssertEqual(environment["PAGER"], "cat")
        XCTAssertNil(environment["anthropic_api_key"])
        XCTAssertEqual(windows.extensions, [".com", ".exe", ".bat", ".cmd"])
    }

    /// A bare name is the program it names with PATHEXT's extensions, a real program before a batch file, and
    /// never a script Windows does not start. npm's shim starts Node.js, beside it or in `Path`, on the script it
    /// names with the same arguments; any other batch file is refused.
    func testWindowsLookupPrefersProgramsAndStartsNpmShimsThroughNode() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "WindowsLookup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let npm = folder.appending(path: "npm", directoryHint: .isDirectory)
        let both = folder.appending(path: "both", directoryHint: .isDirectory)
        let nodejs = folder.appending(path: "nodejs", directoryHint: .isDirectory)
        let script = npm.appending(path: "node_modules/fake/cli.js")
        for directory in [npm, both, nodejs, script.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // What npm's cmd-shim writes for a package's `#!/usr/bin/env node` script.
        let shim = #"""
        @ECHO off
        GOTO start
        :find_dp0
        SET dp0=%~dp0
        EXIT /b
        :start
        SETLOCAL
        CALL :find_dp0

        IF EXIST "%dp0%\node.exe" (
          SET "_prog=%dp0%\node.exe"
        ) ELSE (
          SET "_prog=node"
        )

        endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & set PATHEXT=%PATHEXT:;.JS;=;% & "%_prog%"  "%dp0%\node_modules\fake\cli.js" %*

        """#.replacingOccurrences(of: "\n", with: "\r\n")
        try shim.write(to: npm.appending(path: "kimi.cmd"), atomically: true, encoding: .utf8)
        for file in [script, both.appending(path: "kimi.exe"), both.appending(path: "kimi.cmd"),
                     both.appending(path: "tool.js"), nodejs.appending(path: "node.exe")] {
            try Data().write(to: file)
        }
        try "@echo off\r\necho %*\r\n".write(to: both.appending(path: "kimi.cmd"), atomically: true, encoding: .utf8)
        let windows = ExecutableLookup.windows(pathExtensions: ".COM;.EXE;.BAT;.CMD;.VBS;.JS")

        XCTAssertEqual(windows.program(at: npm.appending(path: "kimi")), npm.appending(path: "kimi.cmd"))
        XCTAssertEqual(windows.program(at: both.appending(path: "kimi")), both.appending(path: "kimi.exe"))
        XCTAssertNil(windows.program(at: both.appending(path: "tool")))

        let launch = try NPMCommandShim.launch(npm.appending(path: "kimi.cmd"), arguments: ["acp", "a \"b\""],
                                               searchPath: nodejs.path(percentEncoded: false), lookup: windows)
        XCTAssertEqual(launch?.executable, nodejs.appending(path: "node.exe"))
        XCTAssertEqual(launch?.arguments, [windows.nativePath(script.standardizedFileURL), "acp", "a \"b\""])
        XCTAssertThrowsError(try NPMCommandShim.launch(npm.appending(path: "kimi.cmd"), arguments: [], searchPath: "",
                                                       lookup: windows)) {
            XCTAssertEqual($0 as? NPMCommandShimError, .nodeNotFound("kimi.cmd"))
        }
        XCTAssertThrowsError(try NPMCommandShim.launch(both.appending(path: "kimi.cmd"), arguments: [], searchPath: "",
                                                       lookup: windows)) {
            XCTAssertEqual($0 as? NPMCommandShimError, .notAShim("kimi.cmd"))
        }
        XCTAssertNil(try NPMCommandShim.launch(both.appending(path: "kimi.exe"), arguments: [], searchPath: "", lookup: windows))
        XCTAssertNil(try NPMCommandShim.launch(npm.appending(path: "kimi.cmd"), arguments: [], searchPath: "", lookup: .posix))

        // Older cmd-shims, a script's `#!` arguments, and the shims Yardlet does not start.
        XCTAssertEqual(NPMCommandShim.parse(#"""
            @IF EXIST "%~dp0\node.exe" (
              "%~dp0\node.exe"  "%~dp0\node_modules\npm\bin\npm-cli.js" %*
            ) ELSE (
              @SETLOCAL
              @SET PATHEXT=%PATHEXT:;.JS;=;%
              node  "%~dp0\node_modules\npm\bin\npm-cli.js" %*
            )
            """#), NPMCommandShim.Target(nodeArguments: [], script: ["node_modules", "npm", "bin", "npm-cli.js"],
                                          startsScriptItself: false))
        XCTAssertEqual(NPMCommandShim.parse(shim.replacingOccurrences(of: #""%_prog%"  "#, with: #""%_prog%" --no-warnings "#))?
            .nodeArguments, ["--no-warnings"])
        XCTAssertEqual(NPMCommandShim.parse("@ECHO off\r\nCALL :find_dp0\r\n\"%dp0%\\node_modules\\esbuild\\esbuild.exe\"   %*\r\n"),
                       NPMCommandShim.Target(nodeArguments: [], script: ["node_modules", "esbuild", "esbuild.exe"],
                                             startsScriptItself: true))
        XCTAssertNil(NPMCommandShim.parse(shim.replacingOccurrences(of: "CALL :find_dp0\r\n", with: "CALL :find_dp0\r\n@SET NODE_OPTIONS=--x\r\n")))
        XCTAssertNil(NPMCommandShim.parse(shim.replacingOccurrences(of: #"SET "_prog=node""#, with: #"SET "_prog=sh""#)))
    }

    /// The login shell's `PATH` leads, the app's folders it lacks follow, and nothing else changes;
    /// before a read, the app's environment stays as it is.
    func testLoginShellPathLeadsTheAppsOwn() {
        let base = ["HOME": "/Users/test", "PATH": "/usr/bin:/bin:/app/only"]
        XCTAssertEqual(RuntimeProcessEnvironment.withLoginShellPath("/opt/homebrew/bin:/usr/bin:/bin", base: base),
                       ["HOME": "/Users/test", "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/app/only"])
        XCTAssertEqual(RuntimeProcessEnvironment.withLoginShellPath(nil, base: base), base)
    }

    /// The read starts the shell as a terminal window does, so both the login profile and the
    /// interactive rc file count, and a shell that hangs is given up on at the time limit. zsh runs
    /// with a temporary `ZDOTDIR` and `HOME`, so none of the person's files are read.
    func testTheLoginShellReadTakesTheProfilesAndRcFilesPathAndGivesUpOnAHang() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "LoginShellPath-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["HOME": folder.path(percentEncoded: false), "ZDOTDIR": folder.path(percentEncoded: false),
                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try "export PATH=/from/profile:$PATH\n".write(to: folder.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
        try "export PATH=/from/rc:$PATH\n".write(to: folder.appending(path: ".zshrc"), atomically: true, encoding: .utf8)

        let path = await LoginShellPath.read(shell: URL(filePath: "/bin/zsh"), environment: environment)
        let folders = path?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(folders.first, "/from/rc", path ?? "nil")
        XCTAssertTrue(folders.contains("/from/profile"), path ?? "nil")
        XCTAssertTrue(folders.contains("/usr/bin"), path ?? "nil")

        // A sign-in only the shell has is named, never read: the value stays in the shell.
        try "export PATH=/from/rc:$PATH\nexport ANTHROPIC_API_KEY=value-of-the-key\n"
            .write(to: folder.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let reading = await LoginShellPath.reading(shell: URL(filePath: "/bin/zsh"), environment: environment)
        XCTAssertEqual(reading.claudeSignInVariables, ["ANTHROPIC_API_KEY"])
        XCTAssertEqual(reading.path?.split(separator: ":").first, "/from/rc")

        try "sleep 30\n".write(to: folder.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let started = ContinuousClock.now
        let hung = await LoginShellPath.read(shell: URL(filePath: "/bin/zsh"), environment: environment,
                                             timeout: .milliseconds(500))
        XCTAssertNil(hung)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    /// A Windows command line reads back into the same arguments by the C runtime's rules, a folder with a space,
    /// a quote and a trailing backslash included.
    func testAWindowsCommandLineQuotesWhatTheCRuntimeWouldSplitOrUnescape() {
        XCTAssertEqual(WindowsCommandLine.joined(["auth", "login"]), "auth login")
        XCTAssertEqual(WindowsCommandLine.quoted(#"C:\Users\First Last\AppData\Roaming\npm\claude.js"#),
                       #""C:\Users\First Last\AppData\Roaming\npm\claude.js""#)
        XCTAssertEqual(WindowsCommandLine.quoted(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(WindowsCommandLine.quoted(#"C:\a b\"#), #""C:\a b\\""#)
        XCTAssertEqual(WindowsCommandLine.quoted(#"a\"b c"#), #""a\\\"b c""#)
        XCTAssertEqual(WindowsCommandLine.quoted(""), #""""#)
    }
}
