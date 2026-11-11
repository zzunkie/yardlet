import Foundation

/// Files and image data pasted or dropped on a composer join the same typed inputs the
/// attachment and context pickers produce; nothing new travels on the wire.
enum ComposerAttachmentIntake {
    struct Result: Equatable {
        var inputs: [CodexUserInput] = []
        var notice: String?
    }

    /// Media the harness can carry becomes an attachment, exactly as the `+` picker admits it.
    /// Every other file or folder becomes a context mention, as the `@` picker makes it, so a
    /// source file is referenced by path rather than refused or inlined.
    static func inputs(
        forFiles urls: [URL],
        policy: HarnessComposerInputPolicy,
        isDirectory: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    ) -> Result {
        var result = Result()
        for url in urls {
            let input: CodexUserInput?
            switch isDirectory(url) ? .unsupported : CodexUserInput.localAttachmentKind(for: url) {
            case .image where policy.carriesImages,
                 .audio where policy.acceptsAudioAttachments:
                input = CodexUserInput.localAttachment(for: url)
            default:
                input = policy.showsMentionControl ? CodexUserInput.localMention(for: url) : nil
            }
            if let input {
                if !result.inputs.contains(input) { result.inputs.append(input) }
            } else {
                result.notice = L10n.string("Unsupported attachment type")
            }
        }
        return result
    }

    /// Pasted image data has no file of its own. Providers read local images by path, so it is
    /// written once to a private temporary folder that only this user can read.
    static var pastedImageDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Yardlet Pasted Images", directoryHint: .isDirectory)
    }

    private static let pastedImageComponents = pastedImageDirectory.standardizedFileURL.pathComponents

    /// A file `storePastedImage` wrote, whose name (`image.png`) Yardlet made up rather than the person.
    static func isPastedImage(_ url: URL, in directory: URL? = nil) -> Bool {
        // `<directory>/<UUID>/image.<extension>`
        guard url.isFileURL, url.lastPathComponent.hasPrefix("image.") else { return false }
        let folder = directory.map { $0.standardizedFileURL.pathComponents } ?? pastedImageComponents
        return Array(url.standardizedFileURL.pathComponents.dropLast(2)) == folder
    }

    static func storePastedImage(_ data: Data, fileExtension: String = "png", in directory: URL = pastedImageDirectory) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let privateFolder: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: privateFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: privateFolder)
        let file = folder.appending(path: "image.\(fileExtension)")
        try StateFile.write(data, to: file, isPrivate: true)
        return file
    }
}
