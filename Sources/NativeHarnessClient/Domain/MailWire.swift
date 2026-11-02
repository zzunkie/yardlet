import Foundation

/// The bytes a mail server sent that its client has not read yet. The IMAP and SMTP clients fill it from
/// their socket and take whole lines and IMAP literals from it, however the socket split the bytes.
struct MailReadBuffer {
    private var bytes: [UInt8] = []
    private var start = 0
    /// Where the search for the next line end resumes, so a long line that arrives a byte at a time is
    /// scanned once.
    private var scanned = 0

    var count: Int { bytes.count - start }

    mutating func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    /// The next line without its line end, when all of it has arrived. Lines end in CRLF; a bare LF is
    /// taken as one too.
    mutating func takeLine() -> [UInt8]? {
        var index = max(start, scanned)
        while index < bytes.count {
            if bytes[index] == 0x0A {
                let end = index > start && bytes[index - 1] == 0x0D ? index - 1 : index
                let line = Array(bytes[start..<end])
                consume(upTo: index + 1)
                return line
            }
            index += 1
        }
        scanned = index
        return nil
    }

    /// The next `count` bytes, when all of them have arrived.
    mutating func take(_ count: Int) -> [UInt8]? {
        guard self.count >= count else { return nil }
        let taken = Array(bytes[start..<start + count])
        consume(upTo: start + count)
        return taken
    }

    /// Forgets what arrived: after STARTTLS, anything the server sent before TLS began is not trusted.
    mutating func removeAll() {
        bytes.removeAll()
        start = 0
        scanned = 0
    }

    private mutating func consume(upTo index: Int) {
        start = index
        scanned = index
        if start == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            start = 0
            scanned = 0
        } else if start > 64 * 1024, start > bytes.count / 2 {
            bytes.removeSubrange(0..<start)
            start = 0
            scanned = 0
        }
    }
}

enum MailWireText {
    /// `message` with every line ending in CRLF, as IMAP and SMTP carry mail, whether it was built with
    /// bare LF or CR line ends. With `dotStuffed`, a line that starts with a dot gets a second one, so
    /// SMTP's DATA does not take it for the end of the message (RFC 5321, section 4.5.2).
    static func crlfLines(_ message: Data, dotStuffed: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(message.count + message.count / 40 + 8)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            defer { previous = byte }
            switch byte {
            case 0x0A:
                if previous != 0x0D { out += [0x0D, 0x0A] }
                atLineStart = true
            case 0x0D:
                out += [0x0D, 0x0A]
                atLineStart = true
            default:
                if dotStuffed, atLineStart, byte == 0x2E { out.append(0x2E) }
                out.append(byte)
                atLineStart = false
            }
        }
        return out
    }
}
