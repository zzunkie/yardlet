import Foundation

/// Editing is a local draft operation, never a provider retry or a connection attempt.
enum TranscriptRecoveryProjection {
    static func errorSummary(_ message: String) -> String {
        // The CLI's own words name a screen a task here does not have.
        if ProviderSignIn.asksToSignIn(message) { return ProviderSignIn.prompt }
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8))
        let source = (value?["message"]?.stringValue ?? value?["error"]?["message"]?.stringValue)
            .map(unwrappedErrorMessage) ?? message
        let firstLine = source.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? source
        // Only the summary is bounded. Details and copying retain the exact diagnostic payload.
        return firstLine.count > 300 ? String(firstLine.prefix(300)) + "…" : firstLine
    }

    /// A provider sometimes passes an upstream JSON error body through as its message.
    static func unwrappedErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let inner = value["error"]?["message"]?.stringValue ?? value["message"]?.stringValue,
              !inner.isEmpty else { return trimmed }
        return inner
    }

    static func codexErrorDetails(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if case let .string(message) = value {
            return message.isEmpty ? nil : message
        }
        // Codex may supply an object containing the message and diagnostic fields.
        // Keep all of those fields available in the disclosure and copy payload.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func editableRequest(
        for errorID: UUID,
        entries: [TranscriptEntry],
        status: SessionStatus
    ) -> String? {
        guard status == .ready || status == .failed,
              let errorIndex = entries.firstIndex(where: { $0.id == errorID }),
              case .error = entries[errorIndex].content,
              !entries.suffix(from: errorIndex + 1).contains(where: { entry in
                  switch entry.content {
                  case .user, .assistant, .error, .usageLimit: true
                  case .activity(_, .running), .permission(_, .pending): true
                  default: false
                  }
              }),
              let request = entries[..<errorIndex].last(where: {
                  if case .user = $0.content { return true }
                  return false
              }), case let .user(text, _) = request.content,
              // A schedule's prompt is not the person's to edit.
              request.origin == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              // A shell command's output is not a request to put back in the composer.
              ClaudeBashMessage.parse(text) == nil
        else { return nil }
        return text
    }
}
