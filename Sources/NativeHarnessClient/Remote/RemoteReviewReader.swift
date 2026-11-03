import Foundation
import YardletRemote

/// A review never accepts a free-standing host repository or arbitrary Git revision.
enum RemoteReviewReader {
    static func read(_ query: RemoteReviewQuery, scope: RemoteFileScope) async -> Result<RemoteReviewResult, RemoteError> {
        guard query.isValid else { return .failure(RemoteError(.badRequest)) }
        let service = GitDiffService()
        do {
            var result = RemoteReviewResult()
            let folders = [scope.folder] + scope.otherFolders
            // Check the spelling before resolving any client-supplied path or invoking Git there.
            let selected = query.repository.map { URL(filePath: $0) } ?? scope.folder
            guard folders.contains(where: { $0.standardizedFileURL == selected.standardizedFileURL })
                    || RemoteFileReader.allowsPage(selected.path, in: scope) else {
                return .failure(RemoteError(.notFound))
            }
            if query.operation == .repositories {
                result.repositories = try await service.repositories(containing: folders)
                    .filter { RemoteFileReader.allowsPage($0.path, in: scope) }.map(\.path)
                return .success(result)
            }
            if query.operation == .text, query.revision == nil {
                guard let path = query.path else { return .failure(RemoteError(.badRequest)) }
                let file = query.repository != nil && !path.hasPrefix("/") ? selected.appending(path: path).path : path
                let part = await RemoteFileReader.perform { RemoteFileReader.read(file, offset: 0, in: scope) }
                let read = try part.get()
                guard read.size <= 2 * 1024 * 1024 else { return .failure(RemoteError(.tooLarge)) }
                result.text = String(decoding: read.data, as: UTF8.self)
                return .success(result)
            }
            // A task rooted inside a larger checkout must not expose its siblings through Git.
            let root = try await service.repositoryRoot(workspaceURL: selected)
            guard RemoteFileReader.allowsPage(root.path, in: scope) else { return .failure(RemoteError(.notAllowed)) }
            switch query.operation {
            case .repositories: break
            case .lastTurn: return .failure(RemoteError(.unavailable))
            case .root: result.root = root.path
            case .commits:
                result.commits = try await service.recentCommits(workspaceURL: root).map {
                    RemoteReviewCommit(id: $0.id, shortID: $0.shortID, subject: $0.subject,
                                       timestamp: RemoteJSON.milliseconds($0.date))
                }
            case .baseBranch:
                switch try await service.baseBranch(workspaceURL: root) {
                case let .found(ref): result.baseBranch = ref
                case .missing: result.baseBranch = "missing"
                case .current: result.baseBranch = "current"
                }
            case .diff:
                let target: GitDiffTarget
                switch query.target {
                case "unstaged": target = .unstaged
                case "staged": target = .staged
                case "commit":
                    guard let revision = query.revision, validHash(revision) else { return .failure(RemoteError(.badRequest)) }
                    target = .commit(revision)
                case "branch":
                    guard case let .found(base) = try await service.baseBranch(workspaceURL: root) else {
                        return .failure(RemoteError(.unavailable))
                    }
                    target = .branch(base: base)
                default: return .failure(RemoteError(.badRequest))
                }
                let snapshot = try await service.load(workspaceURL: root, target: target)
                result.text = snapshot.lines.map(\.text).joined(separator: "\n")
                result.truncated = snapshot.isTruncated
            case .text:
                guard let path = query.path, !path.hasPrefix("/"),
                      !path.split(separator: "/").contains(".."), !path.isEmpty else {
                    return .failure(RemoteError(.badRequest))
                }
                if let revision = query.revision {
                    guard revision.isEmpty || revision == "HEAD" || validHash(revision) else {
                        return .failure(RemoteError(.badRequest))
                    }
                    result.text = try await service.fileText(workspaceURL: root, revision: revision, path: path)
                }
            }
            return .success(result)
        } catch GitDiffServiceError.notARepository { return .failure(RemoteError(.notFound)) }
        catch let error as RemoteError { return .failure(error) }
        catch { return .failure(RemoteError(.unavailable)) }
    }

    private static func validHash(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
