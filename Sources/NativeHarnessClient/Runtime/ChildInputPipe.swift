import Foundation

extension Pipe {
    /// A pipe for a child process's standard input. Once the child has gone, a write fails with an
    /// error the writer already handles, instead of a signal that ends Yardlet: a CLI may exit before
    /// it reads what it was sent. The browser host's command pipe does the same
    /// (`CEFBrowserHostProcess`).
    static func childInput() -> Pipe {
        let pipe = Pipe()
        #if canImport(Darwin)
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        return pipe
    }
}
