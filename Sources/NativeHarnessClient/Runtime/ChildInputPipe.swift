import Foundation

extension Pipe {
    /// A pipe for a child process's standard input. Once the child has gone, a write fails with an
    /// error the writer already handles, instead of a signal that ends Yardlet: a CLI may exit before
    /// it reads what it was sent. Yardlet's end closes on exec, so no other process Yardlet starts
    /// keeps it open (a terminal's shell is forked with everything Yardlet has open) and the child
    /// still reads the end of its input once Yardlet has gone. The browser host's command pipe is
    /// one of these (`CEFBrowserHostProcess`).
    static func childInput() -> Pipe {
        let pipe = Pipe()
        #if canImport(Darwin)
        let writer = pipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        _ = fcntl(writer, F_SETFD, fcntl(writer, F_GETFD) | FD_CLOEXEC)
        #endif
        return pipe
    }
}

extension FileHandle {
    /// The null device as a child process's standard input, output or error. On Windows, Swift 6.4's `Process`
    /// opens NUL for `nullDevice` without letting the child inherit it, so the child gets a handle that names
    /// nothing, and a CLI that writes to it can stop there: Antigravity CLI's `agy acp` waited on its first log line
    /// and never answered. NUL opened here is handed over as any other file is, inherited. Elsewhere it is
    /// `nullDevice`.
    static func childNullDevice() -> FileHandle {
        #if os(Windows)
        FileHandle(forUpdatingAtPath: #"\\.\NUL"#) ?? .nullDevice
        #else
        .nullDevice
        #endif
    }
}
