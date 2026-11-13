import Foundation
import QRCodeGenerator

/// A pairing link's QR code drawn in a terminal, from the same library the Windows app's Settings › Remote draws it
/// with: two rows of modules to a line in half-block characters, black on white whatever the terminal's own colours, so
/// a phone's camera reads it on a dark terminal and a light one alike, with a quiet zone of two modules around it.
enum TerminalQRCode {
    static func render(_ text: String) -> String? {
        guard let code = try? QRCode.encode(text: text, ecl: .medium) else { return nil }
        let quiet = 2
        let size = code.size + quiet * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let column = x - quiet, row = y - quiet
            guard column >= 0, row >= 0, column < code.size, row < code.size else { return false }
            return code.getModule(x: column, y: row)
        }
        var lines: [String] = []
        for y in stride(from: 0, to: size, by: 2) {
            // Black text on bright white: the drawn half blocks are the dark modules.
            var line = "\u{1B}[30;107m"
            for x in 0..<size {
                switch (dark(x, y), dark(x, y + 1)) {
                case (false, false): line += " "
                case (true, false): line += "\u{2580}"
                case (false, true): line += "\u{2584}"
                case (true, true): line += "\u{2588}"
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
