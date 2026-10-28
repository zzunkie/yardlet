import Foundation

/// What a site says its passwords must be, in the `passwordrules` attribute's syntax (Apple's proposal
/// to the HTML standard, which Safari and 1Password read; docs/BROWSER_VAULT_DESIGN.md §15), such as
/// `minlength: 8; maxlength: 16; required: lower; required: upper; required: digit; allowed: [-_!]`.
/// Each `required` rule asks for at least one character from its classes; the password draws from the
/// required and allowed classes together.
struct PasswordRules: Equatable, Sendable {
    var required: [Set<Character>] = []
    var allowed: Set<Character> = []
    var minLength: Int?
    var maxLength: Int?
    /// The most times one character may repeat in a row.
    var maxConsecutive: Int?

    /// Printable ASCII without the space, which the rules' `special` and `ascii-printable` hold but a made
    /// password leaves out.
    static let asciiPrintable = Set((0x21...0x7e).map { Character(UnicodeScalar(UInt8($0))) })
    static let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Set("abcdefghijklmnopqrstuvwxyz")
    static let digit = Set("0123456789")
    static let special = asciiPrintable.subtracting(upper).subtracting(lower).subtracting(digit)

    init(required: [Set<Character>] = [], allowed: Set<Character> = [], minLength: Int? = nil, maxLength: Int? = nil,
         maxConsecutive: Int? = nil) {
        self.required = required
        self.allowed = allowed
        self.minLength = minLength
        self.maxLength = maxLength
        self.maxConsecutive = maxConsecutive
    }

    /// The attribute's rules; nil when it names none Yardlet reads. Unknown rules and classes are passed
    /// over, as browsers pass over what they do not know.
    init?(_ text: String) {
        var found = false
        for rule in text.split(separator: ";") {
            guard let colon = rule.firstIndex(of: ":") else { continue }
            let name = rule[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(rule[rule.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch name {
            case "required":
                let classes = Self.classes(value)
                guard !classes.isEmpty else { continue }
                required.append(classes)
            case "allowed":
                allowed.formUnion(Self.classes(value))
            case "minlength":
                guard let length = Int(value), length > 0 else { continue }
                minLength = max(minLength ?? 0, length)
            case "maxlength":
                guard let length = Int(value), length > 0 else { continue }
                maxLength = min(maxLength ?? .max, length)
            case "max-consecutive":
                guard let count = Int(value), count > 0 else { continue }
                maxConsecutive = min(maxConsecutive ?? .max, count)
            default:
                continue
            }
            found = true
        }
        guard found else { return nil }
    }

    /// A comma-separated list of named classes and custom ones in brackets (`[-().]`).
    private static func classes(_ value: String) -> Set<Character> {
        var characters = Set<Character>()
        var rest = Substring(value)
        while let first = rest.first {
            if first == "[" {
                // A `]` the class holds comes last, just before the closing one: `[-abc]]`.
                let body = rest.dropFirst()
                var close = body.firstIndex(of: "]") ?? body.endIndex
                if close < body.endIndex, body[body.index(after: close)...].first == "]" { close = body.index(after: close) }
                characters.formUnion(body[..<close].filter { asciiPrintable.contains($0) })
                rest = close < body.endIndex ? body[body.index(after: close)...] : ""
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                switch rest[..<end].trimmingCharacters(in: .whitespaces).lowercased() {
                case "upper": characters.formUnion(upper)
                case "lower": characters.formUnion(lower)
                case "digit": characters.formUnion(digit)
                case "special": characters.formUnion(special)
                // A generated password stays in printable ASCII, which every site that takes Unicode takes too.
                case "ascii-printable", "unicode": characters.formUnion(asciiPrintable)
                default: break
                }
                rest = rest[end...]
            }
            rest = rest.drop { $0 == "," || $0 == " " }
        }
        return characters
    }
}

/// Makes the strong passwords the vault suggests for new-password fields (design §15): Chrome's
/// generator by default (15 characters of upper and lower case letters and digits, at least one of
/// each, without the look-alikes `l I o O 0 1`) with one of Chrome's symbols added, since many sites
/// insist on one and Yardlet has no list of each site's rules; a site's `passwordrules` replace that,
/// and a field's `minlength` and `maxlength` bound the length. Each character is drawn from the system's
/// secure random bytes without modulo bias.
enum VaultPasswordGenerator {
    /// `count` bytes from the system's secure random source (`SecRandomCopyBytes` on macOS); nil when it
    /// fails, and then no password is made.
    typealias RandomBytes = @Sendable (_ count: Int) -> [UInt8]?

    /// The standard library's generator, which is cryptographically secure on the platforms Yardlet
    /// builds for; the macOS app passes `SecRandomCopyBytes` instead.
    static let systemRandomBytes: RandomBytes = { count in
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    static let defaultLength = 15
    /// Chrome's sets (`password_generator.cc`), without characters easily read as others.
    static let lower = Set("abcdefghijkmnpqrstuvwxyz")
    static let upper = Set("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Set("23456789")
    static let symbols = Set("-_.:!")
    static let lookAlikes = Set("lIoO01")

    static let defaultRules = PasswordRules(required: [lower, upper, digits, symbols],
                                            allowed: lower.union(upper).union(digits))

    /// A password for a field with the site's `passwordrules` (nil for none) and the field's own
    /// `minlength` and `maxlength` (0 or less for none). Nil only when the random source fails.
    static func generate(rules: PasswordRules?, fieldMinLength: Int = 0, fieldMaxLength: Int = 0,
                         random: @escaping RandomBytes) -> String? {
        var rules = rules ?? defaultRules
        if rules.required.isEmpty && rules.allowed.isEmpty {
            // Lengths alone: Yardlet's classes within them.
            rules.required = defaultRules.required
            rules.allowed = defaultRules.allowed
        }
        let required = rules.required.map(withoutLookAlikes)
        let alphabet = withoutLookAlikes(rules.required.reduce(rules.allowed) { $0.union($1) })
        let longest = [rules.maxLength, fieldMaxLength > 0 ? fieldMaxLength : nil].compactMap { $0 }.min()
        let shortest = max(rules.minLength ?? 0, fieldMinLength)
        var length = max(defaultLength, shortest)
        if let longest { length = min(length, longest) }
        length = max(length, 1)

        var draw = UnbiasedDraw(random: random)
        // A site's rule against repeats, and Chrome's against `--` and `__`, can need another try; a
        // thousand would mean rules no password meets, and the last try stands.
        var password: [Character] = []
        for _ in 0..<1000 {
            guard let made = make(length: length, required: required, alphabet: alphabet, draw: &draw) else { return nil }
            password = made
            if let most = rules.maxConsecutive, longestRun(made) > most { continue }
            if String(made).contains("--") || String(made).contains("__") { continue }
            break
        }
        return String(password)
    }

    /// One character from each required class, the rest from the whole alphabet, in shuffled order
    /// (Chrome's way); when the length is shorter than the classes, the first classes win.
    private static func make(length: Int, required: [Set<Character>], alphabet: Set<Character>,
                             draw: inout UnbiasedDraw) -> [Character]? {
        let alphabet = alphabet.sorted()
        var characters: [Character] = []
        for set in required.prefix(length) {
            guard let pick = draw.element(of: set.sorted()) else { return nil }
            characters.append(pick)
        }
        while characters.count < length {
            guard let pick = draw.element(of: alphabet) else { return nil }
            characters.append(pick)
        }
        // Fisher-Yates.
        for index in stride(from: characters.count - 1, to: 0, by: -1) {
            guard let other = draw.index(below: index + 1) else { return nil }
            characters.swapAt(index, other)
        }
        return characters
    }

    /// A class without the look-alikes, unless that would leave it empty.
    private static func withoutLookAlikes(_ set: Set<Character>) -> Set<Character> {
        let kept = set.subtracting(lookAlikes)
        return kept.isEmpty ? set : kept
    }

    private static func longestRun(_ characters: [Character]) -> Int {
        var longest = 0, run = 0
        var previous: Character?
        for character in characters {
            run = character == previous ? run + 1 : 1
            longest = max(longest, run)
            previous = character
        }
        return longest
    }
}

/// Uniform choices from secure random bytes: a 32-bit draw at or above the largest multiple of the range
/// is drawn again, so no choice is likelier than another (no modulo bias).
struct UnbiasedDraw {
    let random: VaultPasswordGenerator.RandomBytes
    private var buffer: [UInt8] = []

    init(random: @escaping VaultPasswordGenerator.RandomBytes) {
        self.random = random
    }

    mutating func index(below count: Int) -> Int? {
        guard count > 0 else { return nil }
        let range = UInt64(count)
        let limit = (UInt64(1) << 32) / range * range
        while true {
            guard let value = next() else { return nil }
            if UInt64(value) < limit { return Int(UInt64(value) % range) }
        }
    }

    mutating func element<T>(of elements: [T]) -> T? {
        index(below: elements.count).map { elements[$0] }
    }

    private mutating func next() -> UInt32? {
        if buffer.count < 4 {
            guard let more = random(256), more.count == 256 else { return nil }
            buffer += more
        }
        let value = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        buffer.removeFirst(4)
        return value
    }
}
