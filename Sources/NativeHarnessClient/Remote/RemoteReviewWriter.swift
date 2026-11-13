import Foundation
import YardletRemote

/// Stage all, Unstage all and Discard for another device's Review (§15.26), through the local Review's own Git path.
/// The client names no path, revision or Git argument: the host reads the repository's changes again and acts on
/// them only while they are the ones the client reviewed.
enum RemoteReviewWriter {
    /// `authorize` throws once the device's permission or connection has ended; it runs immediately before each
    /// step that writes.
    static func write(_ change: RemoteReviewChange, confirmed: Bool, scope: RemoteFileScope,
                      authorize: @Sendable () throws -> Void) async -> RemoteError? {
        guard change.isValid else { return RemoteError(.badRequest) }
        // Discard cannot be undone: the client asks first, as the local Review does.
        guard change.action != .discard || confirmed else { return RemoteError(.notAllowed, reason: .confirmation) }
        let service = GitDiffService()
        do {
            guard let selected = RemoteReviewReader.selection(change.repository, in: scope) else {
                return RemoteError(.notFound)
            }
            guard let root = try await RemoteReviewReader.allowedRoot(of: selected, in: scope, service: service) else {
                return RemoteError(.notAllowed)
            }
            let mutation: GitMutation = switch change.action {
            case .stage: .stage
            case .unstage: .unstage
            case .discard: .discard
            }
            let current = try await service.load(workspaceURL: root, target: mutation == .unstage ? .staged : .unstaged)
            guard !current.isEmpty, !current.isTruncated,
                  RemoteReviewChange.fingerprint(current.text) == change.expected else { return changed }
            try await service.mutate(mutation, workspaceURL: root, expected: current, authorizing: authorize)
            return nil
        } catch GitDiffServiceError.notARepository {
            return RemoteError(.notFound)
        } catch GitDiffServiceError.changedSinceReview {
            return changed
        } catch let error as RemoteError {
            return error
        } catch {
            // Git's own words can name host paths.
            return RemoteError(.unavailable)
        }
    }

    private static let changed = RemoteError(.notAllowed, "The changes differ from the ones reviewed", reason: .changing)
}
