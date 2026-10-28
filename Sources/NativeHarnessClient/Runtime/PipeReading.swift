import Foundation

extension FileHandle {
    /// Hands each chunk the other end writes to `chunk`, then calls `end` once when it closes.
    ///
    /// Every pipe Yardlet reads from a child process goes through here. A pipe whose writer has
    /// closed stays readable, so a readability handler left in place at the end of the file is
    /// called again at once with no data, for as long as the handle lives, and keeps a core busy
    /// after the process has exited. The handler is removed before `end` runs.
    func readChunks(_ chunk: @escaping @Sendable (Data) -> Void, atEnd end: @escaping @Sendable () -> Void = {}) {
        readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                end()
                return
            }
            chunk(data)
        }
    }

    /// Yields each chunk the other end writes to `continuation` and finishes it when it closes.
    func readChunks(into continuation: AsyncStream<Data>.Continuation) {
        readChunks({ continuation.yield($0) }, atEnd: { continuation.finish() })
    }
}
