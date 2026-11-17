import Foundation
import YardletRemote

/// Pictures and files on their way to a host: a picture the harness takes as one goes as an image (§15.14),
/// anything else up in parts as a file (§15.20). A pasted picture waits in a private temporary folder until
/// it is sent or removed.
@MainActor
enum RemoteAttachments {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg"]

    static func add(_ url: URL, to draft: TaskComposerDraft) {
        let input: CodexUserInput = imageTypes.contains(url.pathExtension.lowercased())
            ? .localImage(url) : .mention(name: url.lastPathComponent, path: url)
        if !draft.attachments.contains(input) { draft.attachments.append(input) }
    }

    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "yardlet-remote-attachments", directoryHint: .isDirectory)
    }

    static func write(_ png: Data) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: "Image \(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url, options: [.atomic])) != nil else { return nil }
        return url
    }

    /// Pasted pictures of a sent message are let go: the Mac's, here, and Windows', where the composer's paste keeps
    /// them (`ComposerAttachmentIntake.storePastedImage`).
    static func discard(_ attachments: [CodexUserInput]) {
        for case let .localImage(url, _) in attachments
            where url.path.hasPrefix(folder.path) || ComposerAttachmentIntake.isPastedImage(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The images and the uploaded files' IDs a message carries; nil when one could not go (the model
    /// says why).
    static func prepare(_ attachments: [CodexUserInput], for model: RemoteHostModel, acceptsImages: Bool,
                        acceptsFiles: Bool) async -> (images: [RemoteImage], files: [String])? {
        var images: [RemoteImage] = []
        var files: [String] = []
        for attachment in attachments {
            let url: URL
            switch attachment {
            case let .localImage(path, _), let .image(path, _), let .mention(_, path): url = path
            default: continue
            }
            if acceptsImages, images.count < RemoteProtocol.maxImages, imageTypes.contains(url.pathExtension.lowercased()),
               let data = try? Data(contentsOf: url), data.count <= RemoteProtocol.maxImageBytes {
                let type = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                images.append(RemoteImage(type: type, data: data))
                continue
            }
            guard acceptsFiles else {
                model.commandError = L10n.string("This task takes no files.")
                return nil
            }
            guard files.count < RemoteProtocol.maxFiles else { break }
            let mediaType = FileTypes.mimeType(forExtension: url.pathExtension) ?? "application/octet-stream"
            guard let id = await model.upload(url, mediaType: mediaType) else { return nil }
            files.append(id)
        }
        return (images, files)
    }
}
