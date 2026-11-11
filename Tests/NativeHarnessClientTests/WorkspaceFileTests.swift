import XCTest
@testable import NativeHarnessClient

final class WorkspaceFileTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "yardlet-file-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ path: String, text: String, in root: URL) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRelativeUnicodeLinkAndAbsoluteColonLocationResolveToSameFile() throws {
        let root = try workspace()
        let path = "Sources/한글 👩🏽‍💻.swift"
        let file = try write(path, text: "first\nsecond\n", in: root)
        let relative = try XCTUnwrap(URL(string: path + "#L2C3"))
        let absolute = URL(filePath: file.path + ":2:3")
        let expected = WorkspaceFileLocation(relativePath: path, line: 2, column: 3)
        XCTAssertEqual(try WorkspaceFileLocation.resolve(relative, in: root), expected)
        XCTAssertEqual(try WorkspaceFileLocation.resolve(absolute, in: root), expected)
        XCTAssertEqual(try WorkspaceFileLocation.resolve(URL(string: "Sources/../Sources/한글 👩🏽‍💻.swift#L2-L4")!, in: root).line, 2)
    }

    func testRealColonFilenameDoesNotBecomeLineNumber() throws {
        let root = try workspace()
        let url = try write("notes:42", text: "colon filename", in: root)
        XCTAssertEqual(try WorkspaceFileLocation.resolve(url, in: root), .init(relativePath: "notes:42"))
    }

    func testOutsideTraversalRemoteHostAndSymlinkAreRejected() throws {
        let root = try workspace(), outside = try workspace()
        let external = try write("outside.txt", text: "outside", in: outside)
        let symlink = root.appending(path: "escape.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        for url in [external, symlink, URL(string: "../outside.txt")!, URL(string: "https://example.com/file.txt")!, URL(string: "file://other-host/tmp/file.txt")!, root] {
            XCTAssertThrowsError(try WorkspaceFileLocation.resolve(url, in: root), "\(url)")
        }
        XCTAssertThrowsError(try WorkspaceFileService.read(.init(relativePath: "../outside.txt"), in: root))
    }

    /// Whether a path is in a folder is decided by whole names after `.` and `..`, never by a string prefix. On
    /// Windows a path starts at a drive or a share, `\` and `/` both separate names, and names compare in any case
    /// but keep their composition, as NTFS compares them; `\x` and `C:x` depend on where they are read from.
    func testPathsAreInsideAFolderByWholeNamesAndOnWindowsInAnyCase() {
        let posix = PathRules.posix
        XCTAssertEqual(posix.relativePath(of: "/work/app/./src//a.swift", in: "/work/app/"), "src/a.swift")
        XCTAssertEqual(posix.relativePath(of: "/work/app", in: "/work/app"), "")
        XCTAssertTrue(posix.isInside("/work/app/x", folder: "/"))
        XCTAssertFalse(posix.isStrictlyInside("/work/app", folder: "/work/app"))
        for (path, folder) in [("/work/application", "/work/app"), ("/work/app/../secret", "/work/app"),
                               ("/Work/App/x", "/work/app"), ("work/app/x", "work/app"), ("/work/app/x", ""),
                               ("C:\\work\\app\\x", "C:\\work\\app")] {
            XCTAssertNil(posix.relativePath(of: path, in: folder), "\(path) in \(folder)")
        }
        XCTAssertEqual(posix.names("a\\b/c"), ["a\\b", "c"])

        let windows = PathRules.windows
        for path in ["C:\\Users\\me", "c:/x", "C:\\", "/C:/Users/me", "\\\\server\\share\\x", "//server/share",
                     "\\\\?\\C:\\x", "\\\\?\\UNC\\server\\share\\x"] {
            XCTAssertTrue(windows.isAbsolute(path), path)
            XCTAssertFalse(windows.isRelative(path), path)
        }
        for path in ["\\Users\\me", "C:Users", "C:", "Users\\me", "\\\\server", "\\\\server\\", ""] {
            XCTAssertFalse(windows.isAbsolute(path), path)
        }
        XCTAssertTrue(windows.isRelative("src\\a.swift"))
        XCTAssertFalse(windows.isRelative("\\src"))
        XCTAssertFalse(windows.isRelative("C:src"))
        XCTAssertEqual(windows.names("a\\b/c"), ["a", "b", "c"])
        XCTAssertEqual(windows.relativePath(of: "c:\\USERS\\Me\\Proj\\src\\a.swift", in: "C:\\Users\\me\\proj"), "src/a.swift")
        XCTAssertEqual(windows.relativePath(of: "/C:/Users/me/proj/a", in: "C:\\Users\\me\\proj\\"), "a")
        XCTAssertEqual(windows.relativePath(of: "\\\\?\\C:\\Users\\me\\proj\\a", in: "C:/Users/me/proj"), "a")
        XCTAssertEqual(windows.relativePath(of: "\\\\Server\\Share\\proj\\a", in: "//server/share/proj"), "a")
        XCTAssertEqual(windows.relativePath(of: "\\\\?\\UNC\\server\\share\\a", in: "\\\\server\\share"), "a")
        XCTAssertEqual(windows.relativePath(of: "C:\\Ä\\x", in: "C:\\ä"), "x")
        // Windows drops the periods and spaces a name ends in and reads a device's name as the device, so a path with
        // such a name is in no folder: its text does not say where it leads. POSIX reads every name as written.
        for name in [".. ", "...", ". .", "notes.", "notes ", "NUL", "nul.txt", "Con", "COM1", "com9:", "LPT\u{B9}", "aux .log"] {
            XCTAssertNil(windows.relativePath(of: "C:\\Users\\me\\proj\\\(name)\\x", in: "C:\\Users\\me\\proj"), name)
            XCTAssertNil(windows.relativePath(of: "C:\\Users\\me\\proj\\\(name)", in: "C:\\Users\\me\\proj"), name)
            XCTAssertEqual(posix.relativePath(of: "/work/app/\(name)", in: "/work/app"), name)
        }
        for name in [".gitignore", "a.b", "console", "COM10", "null", "auxiliary.txt", "..x", "x y"] {
            XCTAssertEqual(windows.relativePath(of: "C:\\proj\\\(name)", in: "C:\\proj"), name)
        }
        // A `..` at a share's root stays there, as Windows reads it.
        XCTAssertEqual(windows.relativePath(of: "\\\\server\\share\\..\\other\\x", in: "\\\\server\\share\\other"), "x")
        for (path, folder) in [("C:\\Users\\me\\project", "C:\\Users\\me\\proj"), ("C:\\Users\\me\\proj\\..\\other", "C:\\Users\\me\\proj"),
                               ("D:\\Users\\me\\proj\\a", "C:\\Users\\me\\proj"), ("\\\\server\\other\\a", "\\\\server\\share"),
                               ("\\\\server\\share\\..\\other\\x", "\\\\server\\other"), ("\\Users\\me\\proj\\a", "C:\\Users\\me\\proj"),
                               ("C:\\e\u{301}\\x", "C:\\\u{E9}"), ("C:\\SS\\x", "C:\\ß"), ("C:\\Users\\me\\proj\\a", "C:")] {
            XCTAssertNil(windows.relativePath(of: path, in: folder), "\(path) in \(folder)")
        }
        XCTAssertEqual(windows.path(of: URL(string: "file://server/share/x")!), "//server/share/x")
        XCTAssertEqual(posix.path(of: URL(string: "file://server/share/x")!), "/share/x")
    }

    /// A link the person clicks opens any file on the Mac, as the Codex and Claude apps do: one outside
    /// the task's folder by its absolute path, read-only, and one inside through `/private` all the same.
    func testAPersonOpensAFileOutsideTheFolderReadOnly() throws {
        let root = try workspace(), outside = try workspace()
        let inside = try write("Sources/a.swift", text: "a\n", in: root)
        let external = try write("Application Support/notes.md", text: "outside\n", in: outside)
        let location = try WorkspaceFileLocation.opening(URL(filePath: external.path + ":1"), in: root)
        XCTAssertTrue(location.isOutsideWorkspace)
        XCTAssertEqual(location.line, 1)
        XCTAssertEqual(try WorkspaceFileLocation.opening(
            URL(string: "../\(outside.lastPathComponent)/Application%20Support/notes.md")!, in: root).relativePath,
            location.relativePath)
        let document = try WorkspaceFileService.read(location, in: root)
        XCTAssertEqual(document.text, "outside\n")
        XCTAssertFalse(document.isEditable)
        XCTAssertThrowsError(try WorkspaceFileService.save(path: location.relativePath, text: "changed", expectedDigest: document.sourceDigest!,
                                                           encoding: .utf8, in: root))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "outside\n")
        let link = outside.appending(path: "AGENTS.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertEqual(try WorkspaceFileService.read(.opening(link, in: root), in: root).text, "outside\n")
        let linked = URL(filePath: "/private" + inside.path(percentEncoded: false))
        XCTAssertEqual(try WorkspaceFileLocation.opening(inside.path.hasPrefix("/var/") ? linked : inside, in: root),
                       .init(relativePath: "Sources/a.swift"))
        for url in [URL(string: "https://example.com/file.txt")!, URL(string: "file://other-host/tmp/file.txt")!] {
            XCTAssertThrowsError(try WorkspaceFileLocation.opening(url, in: root), "\(url)")
        }
    }

    func testIndexOmitsCachesAndEscapingLinksWithoutRequiringGit() throws {
        let root = try workspace(), outside = try workspace()
        let file = try write("Sources/한글.swift", text: "", in: root)
        _ = try write("README.md", text: "", in: root)
        _ = try write(".hidden-note", text: "", in: root)
        for dir in [".git", ".build", "node_modules", ".venv"] { _ = try write("\(dir)/hidden.txt", text: "", in: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "alias.swift"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "external"), withDestinationURL: outside)
        let index = try WorkspaceFileService.index(in: root)
        XCTAssertEqual(Set(index.paths), ["Sources/한글.swift", "README.md", ".hidden-note"])
        XCTAssertFalse(index.isLimited)
        let limited = try WorkspaceFileService.index(in: root, limit: 1)
        XCTAssertEqual(limited.paths.count, 1)
        XCTAssertTrue(limited.isLimited)
        XCTAssertThrowsError(try WorkspaceFileService.index(in: root.appending(path: "missing")))
    }

    func testReadPreservesUTF8UTF16AndEmptyText() throws {
        let root = try workspace(), exact = "첫 줄 👩🏽‍💻\r\nsecond\tline\n"
        let file = try write("text.swift", text: exact, in: root)
        XCTAssertEqual(try WorkspaceFileService.read(.resolve(file, in: root), in: root).text, exact)
        try exact.data(using: .utf16)!.write(to: root.appending(path: "utf16.txt"))
        XCTAssertEqual(try WorkspaceFileService.read(.init(relativePath: "utf16.txt"), in: root).text, exact)
        _ = try write("empty.txt", text: "", in: root)
        XCTAssertEqual(try WorkspaceFileService.read(.init(relativePath: "empty.txt"), in: root).lineStarts, [0])
        // Text that is not UTF-8 (zsh's history keeps Korean in its own bytes) reads with U+FFFD, read-only.
        try Data("echo ".utf8 + [0x83, 0xED, 0x95] + Array("\nls\n".utf8)).write(to: root.appending(path: ".zsh_history"))
        let history = try WorkspaceFileService.read(.init(relativePath: ".zsh_history"), in: root)
        XCTAssertTrue(history.text.hasPrefix("echo \u{FFFD}"))
        XCTAssertTrue(history.text.hasSuffix("\nls\n"))
        XCTAssertTrue(history.isLossy)
        XCTAssertFalse(history.isEditable)
    }

    func testMissingBinaryAndDirectoryReadsFail() throws {
        let root = try workspace()
        try Data([0x01, 0x00, 0xFF]).write(to: root.appending(path: "binary.bin"))
        // A large image is a file the panel cannot show, not a text shown in part.
        var image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        image.append(Data(repeating: 65, count: WorkspaceFileService.wholeTextBytes))
        try image.write(to: root.appending(path: "large.png"))
        try FileManager.default.createDirectory(at: root.appending(path: "folder"), withIntermediateDirectories: false)
        for path in ["missing.txt", "binary.bin", "large.png", "folder"] {
            XCTAssertThrowsError(try WorkspaceFileService.read(.init(relativePath: path), in: root), path)
        }
        XCTAssertThrowsError(try WorkspaceFileService.read(.init(relativePath: "large.png"), in: root)) { error in
            guard case .unsupported = error as? WorkspaceFileError else { return XCTFail("\(error)") }
        }
    }

    /// Up to 2 MB a file is colored and editable; up to 20 MB it opens whole, plain and read only;
    /// past that the panel shows its first 2 MB, cut after a line break.
    func testTextOpensWholeTo20MBColoredAndEditableTo2MBAndShowsTheBeginningPastThat() throws {
        let root = try workspace()
        let line = "let value = \"글자\" // 42\n"
        func file(_ name: String, over bytes: Int) throws -> String {
            let text = String(repeating: line, count: bytes / line.utf8.count + 1)
            try Data(text.utf8).write(to: root.appending(path: name))
            return text
        }
        let smallText = String(repeating: line, count: WorkspaceFileService.highlightedBytes / line.utf8.count)
        try Data(smallText.utf8).write(to: root.appending(path: "small.swift"))
        let small = try WorkspaceFileService.read(.init(relativePath: "small.swift"), in: root)
        XCTAssertEqual(small.text, smallText)
        XCTAssertFalse(small.tokens.isEmpty)
        XCTAssertTrue(small.isEditable)
        XCTAssertFalse(small.isPartial)

        let mediumText = try file("medium.swift", over: WorkspaceFileService.highlightedBytes)
        let medium = try WorkspaceFileService.read(.init(relativePath: "medium.swift"), in: root)
        XCTAssertEqual(medium.text, mediumText)
        XCTAssertEqual(medium.lineStarts.count, mediumText.utf8.count / line.utf8.count + 1)
        XCTAssertTrue(medium.tokens.isEmpty)
        XCTAssertFalse(medium.isEditable)
        XCTAssertFalse(medium.isPartial)
        XCTAssertNotNil(medium.sourceDigest, "A draft from when the file was small is still compared with it")

        let largeText = try file("large.swift", over: WorkspaceFileService.wholeTextBytes)
        let large = try WorkspaceFileService.read(.init(relativePath: "large.swift"), in: root)
        XCTAssertTrue(large.isPartial)
        XCTAssertFalse(large.isEditable)
        XCTAssertNil(large.sourceDigest)
        XCTAssertTrue(large.tokens.isEmpty)
        XCTAssertTrue(large.text.hasSuffix("\n"))
        XCTAssertEqual(large.text.utf8.count, WorkspaceFileService.partialBytes / line.utf8.count * line.utf8.count)
        XCTAssertTrue(largeText.hasPrefix(large.text))
    }

    func testTheBeginningOfALargeFileEndsOnAWholeCharacter() throws {
        let root = try workspace()
        // No line break: the cut falls inside a three-byte character, which is left out.
        try Data(String(repeating: "가", count: WorkspaceFileService.wholeTextBytes / 3 + 1).utf8)
            .write(to: root.appending(path: "korean.txt"))
        let korean = try WorkspaceFileService.read(.init(relativePath: "korean.txt"), in: root)
        XCTAssertTrue(korean.isPartial)
        XCTAssertEqual(korean.text.utf8.count, WorkspaceFileService.partialBytes / 3 * 3)
        XCTAssertTrue(korean.text.allSatisfy { $0 == "가" })
        XCTAssertEqual(korean.lineStarts, [0])

        // UTF-16 without a line break: half of a surrogate pair is left out.
        let emoji = String(repeating: "😀", count: WorkspaceFileService.wholeTextBytes / 4 + 1)
        try XCTUnwrap(WorkspaceFileEncoding.utf16LittleEndian.data(emoji)).write(to: root.appending(path: "emoji.txt"))
        let wide = try WorkspaceFileService.read(.init(relativePath: "emoji.txt"), in: root)
        XCTAssertTrue(wide.isPartial)
        XCTAssertEqual(wide.encoding, .utf16LittleEndian)
        XCTAssertEqual(wide.text.count, (WorkspaceFileService.partialBytes - 2) / 4)
        XCTAssertTrue(wide.text.allSatisfy { $0 == "😀" })

        // UTF-16 with line breaks ends after the last one.
        let lines = String(repeating: "줄 👩🏽‍💻\n", count: WorkspaceFileService.wholeTextBytes / 20 + 1)
        try XCTUnwrap(WorkspaceFileEncoding.utf16BigEndian.data(lines)).write(to: root.appending(path: "lines.txt"))
        let big = try WorkspaceFileService.read(.init(relativePath: "lines.txt"), in: root)
        XCTAssertEqual(big.encoding, .utf16BigEndian)
        XCTAssertTrue(big.text.hasSuffix("👩🏽‍💻\n"))
        XCTAssertTrue(lines.hasPrefix(big.text))
    }

    func testUTF16LineRangesClampWithoutOverflow() {
        let text = "👩🏽‍💻\r\n가나다\n"
        let document = WorkspaceFileDocument(path: "text.txt", text: text)
        XCTAssertEqual((text as NSString).substring(with: document.range(line: 1)), "👩🏽‍💻\r\n")
        XCTAssertEqual((text as NSString).substring(with: document.range(line: 2)), "가나다\n")
        XCTAssertEqual(document.range(line: .max), NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(document.range(line: .min), document.range(line: 1))
        XCTAssertEqual(document.range(line: 2, column: .min).location, document.lineStarts[1])
        XCTAssertEqual(document.range(line: 2, column: .max).location, document.lineStarts[2])
        XCTAssertEqual(document.line(atUTF16Offset: document.lineStarts[1]), 2)
        XCTAssertEqual(document.line(atUTF16Offset: .max), 3)
        XCTAssertEqual(document.line(atUTF16Offset: .min), 1)
    }

    @MainActor
    func testNewestOpenWinsAndPickerCancelsPendingRead() async throws {
        let root = try workspace()
        _ = try write("first.txt", text: String(repeating: "old\n", count: 10_000), in: root)
        _ = try write("second.txt", text: "new", in: root)
        let state = WorkspaceFilesState()
        state.open(.init(relativePath: "first.txt"), in: root)
        state.open(.init(relativePath: "second.txt", line: 1), in: root)
        try await waitUntil { !state.isLoading }
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.document?.text, "new")
        state.open(.init(relativePath: "second.txt"), in: root, refresh: true)
        XCTAssertNil(state.document) // Do not consume a new line link against the stale document.
        state.open(.init(relativePath: "second.txt", line: 1), in: root)
        try await waitUntil { !state.isLoading }
        XCTAssertEqual(state.document?.text, "new")
        let id = state.navigationID
        state.didNavigate(UUID())
        XCTAssertEqual(state.requestedLocation?.line, 1)
        state.didNavigate(id)
        XCTAssertNil(state.requestedLocation)
        state.open(.init(relativePath: "first.txt"), in: root)
        state.showPicker()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.document)
        XCTAssertNil(state.preferences.selectedPath)
        XCTAssertFalse(state.isLoading)
    }

    @MainActor
    func testAnEditKeepsTheShownColorsUntilItsOwnAreWorkedOut() async throws {
        let root = try workspace()
        _ = try write("Source.swift", text: "let a = 1\n", in: root)
        let state = WorkspaceFilesState()
        state.open(.init(relativePath: "Source.swift"), in: root)
        try await waitUntil { !state.isLoading }
        let opened = try XCTUnwrap(state.document)
        XCTAssertFalse(opened.tokens.isEmpty)
        XCTAssertTrue(state.canEdit)

        let text = "let a = 1\nlet b = \"two\" // three\n"
        state.edit(text)
        let edited = try XCTUnwrap(state.document)
        XCTAssertEqual(edited.highlightID, opened.highlightID, "The reader keeps the colors it shows while the person types")
        XCTAssertTrue(edited.tokens.isEmpty)
        try await waitUntil { state.document?.highlightID != opened.highlightID }
        let colored = try XCTUnwrap(state.document)
        XCTAssertNotEqual(colored.highlightID, opened.highlightID)
        XCTAssertEqual(colored.revision, edited.revision)
        XCTAssertEqual(colored.tokens, TranscriptCodeSyntax.tokens(in: text, language: "swift"))

        // A newer edit wins over colors still being worked out for an older text.
        state.edit("let c = 3\n")
        state.edit("let d = 4\n")
        try await waitUntil { state.document?.tokens.isEmpty != true }
        XCTAssertEqual(state.document?.tokens, TranscriptCodeSyntax.tokens(in: "let d = 4\n", language: "swift"))
    }

    @MainActor
    func testAFileOver2MBOpensReadOnlyAndKeepsAnEarlierDraft() async throws {
        let root = try workspace()
        let text = String(repeating: "line\n", count: WorkspaceFileService.editableBytes / 5 + 1)
        _ = try write("large.txt", text: text, in: root)
        let state = WorkspaceFilesState()
        state.open(.init(relativePath: "large.txt"), in: root)
        try await waitUntil { !state.isLoading }
        XCTAssertEqual(state.document?.utf16Length, text.utf16.count)
        XCTAssertFalse(state.canEdit)
        state.edit("changed")
        XCTAssertNil(state.preferences.drafts)
        XCTAssertEqual(state.document?.utf16Length, text.utf16.count)

        // A draft written while the file was small stays editable and says the file changed.
        state.preferences.drafts = ["large.txt": .init(text: "draft", originalText: "small", digest: "old", encoding: .utf8)]
        state.open(.init(relativePath: "large.txt"), in: root, refresh: true)
        try await waitUntil { !state.isLoading }
        XCTAssertEqual(state.document?.text, "draft")
        XCTAssertTrue(state.document?.isEditable == true)
        XCTAssertEqual(state.saveError, WorkspaceFileError.changedOnDisk.localizedDescription)
    }

    @MainActor
    func testSearchAndRecoveryAfterFileDisappears() async throws {
        let root = try workspace()
        let file = try write("Sources/한글.swift", text: "source", in: root)
        let state = WorkspaceFilesState()
        await state.loadIndex(in: root)
        state.preferences.query = "sources 한글"
        XCTAssertEqual(state.matches, ["Sources/한글.swift"])
        try FileManager.default.removeItem(at: file)
        state.open(file, in: root)
        try await waitUntil { !state.isLoading }
        XCTAssertNotNil(state.fileError)
        state.showPicker()
        await state.loadIndex(in: root, force: true)
        XCTAssertNil(state.fileError)
        XCTAssertTrue(state.matches.isEmpty)
        // A file outside the folder opens too; one that is not there says so.
        state.open(URL(filePath: "/outside-workspace.txt"), in: root)
        try await waitUntil { !state.isLoading }
        XCTAssertNotNil(state.fileError)
        state.open(URL(string: "file://other-host/tmp/file.txt")!, in: root)
        XCTAssertNotNil(state.fileError)
        XCTAssertNil(state.preferences.selectedPath)
        state.showPicker()
        XCTAssertNil(state.fileError)
    }

    @MainActor
    func testFilesSelectionAndSeparateBookmarksSurviveOtherPanelsAndRestart() throws {
        let repository = InMemoryTaskWorkspaceRepository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID(), second = UUID()
        let state = store.state(for: first)
        state.files.preferences = .init(selectedPath: "Source.swift", query: "Source", bookmarks: [
            "Source.swift": .init(line: 83, lineOffset: 4, horizontalOffset: 90),
            "Other.txt": .init(line: 12, lineOffset: 2, horizontalOffset: 0)])
        state.setPanels(.init(trailingSurfaceID: "files", isTerminalPresented: true))
        state.setPanels(.init(trailingSurfaceID: "sideChat", isTerminalPresented: true))
        store.state(for: second).files.preferences.selectedPath = "Second.swift"
        store.persistNow()
        let restarted = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(restarted.state(for: first).files.preferences, state.files.preferences)
        XCTAssertEqual(restarted.state(for: second).files.preferences.selectedPath, "Second.swift")
        XCTAssertNil(restarted.state(for: second).files.preferences.bookmarks["Source.swift"])
        XCTAssertFalse(restarted.state(for: first).terminalStartRequested)
        let beforeFiles = Data("{\"version\":1,\"panels\":{\"isTerminalPresented\":false},\"layout\":{\"panelWidth\":420,\"terminalHeight\":240,\"isExpanded\":false},\"transcript\":{\"fraction\":0,\"followsLatest\":true},\"codex\":{\"fraction\":0,\"followsLatest\":true}}".utf8)
        XCTAssertEqual(TaskWorkspaceState(snapshot: try JSONDecoder().decode(TaskWorkspaceSnapshot.self, from: beforeFiles)).files.preferences, .init())
        XCTAssertEqual(TaskWorkspaceState(snapshot: .init(panels: .init(trailingSurfaceID: "files"))).panels.trailingSurfaceID, "files")
    }
}
