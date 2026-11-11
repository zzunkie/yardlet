import Foundation

/// A Windows command line: one string that the program reads back into its arguments by the C runtime's rules
/// (`CommandLineToArgvW`), as Foundation's `Process` writes one. An argument with a space, a tab or a quote goes in
/// quotes; a quote in it is escaped with a backslash, and backslashes before a quote or the closing quote are
/// doubled, so each argument reads back as it was. A batch file reads its command line by cmd's rules instead,
/// which is why Yardlet never starts one (`NPMCommandShim`).
enum WindowsCommandLine {
    static func joined(_ arguments: [String]) -> String {
        arguments.map(quoted).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\u{0B}" || $0 == "\"" })
        else { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
                continue
            }
            result += String(repeating: "\\", count: character == "\"" ? backslashes * 2 + 1 : backslashes)
            result.append(character)
            backslashes = 0
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }
}
