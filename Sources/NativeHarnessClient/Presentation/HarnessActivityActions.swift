import Foundation

struct HarnessActivityActions: Sendable {
    let open: @MainActor @Sendable (HarnessActivity) -> Void
    let stop: (@MainActor @Sendable (HarnessActivity) -> Void)?
    let isStopping: @MainActor @Sendable (String) -> Bool
    let error: @MainActor @Sendable (String) -> String?
}
