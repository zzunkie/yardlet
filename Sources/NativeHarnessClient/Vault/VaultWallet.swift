import Foundation

/// The person's addresses and payment cards (docs/BROWSER_VAULT_DESIGN.md §18), kept as one keychain item beside the
/// vault's: filled for the person from the browser panel, never given to an agent. A card keeps no security code.
struct VaultWallet: Codable, Equatable, Sendable {
    var addresses: [VaultAddress] = []
    var cards: [VaultCard] = []

    var isEmpty: Bool { addresses.isEmpty && cards.isEmpty }
}

/// A postal address as forms ask for it, by the `autocomplete` names of the HTML standard.
struct VaultAddress: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var organization = ""
    /// The street address, one line per line of the address (`address-line1`, `address-line2`, …).
    var street = ""
    /// `address-level2`: the city or town.
    var city = ""
    /// `address-level1`: the state, province or 시·도.
    var region = ""
    var postalCode = ""
    var country = ""
    var phone = ""
    var email = ""

    /// The values a page's fields of each kind take, by the HTML `autocomplete` names.
    var values: [String: String] {
        let lines = street.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let names = name.split(separator: " ", maxSplits: 1).map(String.init)
        return ["name": name, "given-name": names.first ?? "", "family-name": names.count > 1 ? names[1] : "",
                "organization": organization, "street-address": lines.joined(separator: "\n"),
                "address-line1": lines.first ?? "", "address-line2": lines.dropFirst().joined(separator: " "),
                "address-level2": city, "address-level1": region, "postal-code": postalCode, "country": country,
                "tel": phone, "email": email].filter { !$1.isEmpty }
    }

    /// The address from a form's fields by their `autocomplete` names; nil without a street and a city or postal code.
    init?(values: [String: String]) {
        func value(_ key: String) -> String { (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let lines = [value("street-address")] + ["address-line1", "address-line2", "address-line3"].map(value)
        street = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        name = value("name").isEmpty ? [value("given-name"), value("family-name")].filter { !$0.isEmpty }.joined(separator: " ")
            : value("name")
        organization = value("organization")
        city = value("address-level2")
        region = value("address-level1")
        postalCode = value("postal-code")
        country = value("country")
        phone = value("tel")
        email = value("email")
        guard !street.isEmpty, !city.isEmpty || !postalCode.isEmpty else { return nil }
    }

    init(name: String = "", organization: String = "", street: String = "", city: String = "", region: String = "",
         postalCode: String = "", country: String = "", phone: String = "", email: String = "") {
        self.name = name
        self.organization = organization
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
        self.email = email
    }

    /// One line for bars: the name, the street's first line and the city.
    var summary: String {
        [name, place].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Where it is, for a list row under the name: the street's first line, the city and the postal code.
    var place: String {
        [street.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", city, postalCode]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The same address apart from case and spacing, so a form sent again offers no second copy.
    func isSame(as other: VaultAddress) -> Bool {
        func plain(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace && $0 != "," } }
        return plain(street) == plain(other.street) && plain(postalCode) == plain(other.postalCode)
            && plain(name) == plain(other.name)
    }
}

/// A payment card: the name on it, its number and its expiry. The security code is never kept, as Chrome keeps
/// none by default: the person types it at each payment.
struct VaultCard: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    /// Digits only.
    var number = ""
    var expiryMonth = 0
    /// Four digits.
    var expiryYear = 0
    var nickname = ""

    init(name: String = "", number: String, expiryMonth: Int, expiryYear: Int, nickname: String = "") {
        self.name = name
        self.number = VaultCard.digits(number)
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear < 100 ? 2000 + expiryYear : expiryYear
        self.nickname = nickname
    }

    static func digits(_ text: String) -> String { text.filter(\.isASCII).filter(\.isNumber) }

    /// Whether a number is a card's: 12 to 19 digits that pass the Luhn check.
    static func isCardNumber(_ text: String) -> Bool {
        let digits = Self.digits(text).compactMap(\.wholeNumberValue)
        guard (12...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
            guard pair.offset % 2 == 1 else { return sum + pair.element }
            let doubled = pair.element * 2
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    /// The card's network by its first digits, as card forms show it.
    var network: String {
        let prefix = { (length: Int) in Int(number.prefix(length)) ?? 0 }
        switch true {
        case number.hasPrefix("4"): return "Visa"
        case (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)): return "Mastercard"
        case number.hasPrefix("34") || number.hasPrefix("37"): return "American Express"
        case number.hasPrefix("6011") || number.hasPrefix("65") || (644...649).contains(prefix(3)): return "Discover"
        case (3528...3589).contains(prefix(4)): return "JCB"
        case number.hasPrefix("62"): return "UnionPay"
        default: return L10n.string("Card")
        }
    }

    var lastFour: String { String(number.suffix(4)) }

    /// `MM/YY`, as card forms ask for it.
    var expiry: String { String(format: "%02d/%02d", expiryMonth, expiryYear % 100) }

    /// How lists and bars name the card without its number: its nickname, else its network, and the last four digits.
    var label: String { "\(nickname.isEmpty ? network : nickname) •••• \(lastFour)" }

    /// The values a page's fields of each kind take, by the HTML `autocomplete` names; never a security code.
    var values: [String: String] {
        ["cc-name": name, "cc-number": number, "cc-exp": expiry, "cc-exp-month": String(format: "%02d", expiryMonth),
         "cc-exp-year": String(expiryYear)].filter { !$1.isEmpty }
    }

    /// How the number and expiry read on a page or in a tool result, for the scrubbing list (design §5.3): the digits,
    /// in groups of four with spaces or dashes (an American Express number in 4, 6 and 5), and the expiry.
    var spellings: [String] {
        let groups = number.count == 15 ? [4, 6, 5] : Array(repeating: 4, count: (number.count + 3) / 4)
        var parts: [String] = []
        var rest = Substring(number)
        for size in groups where !rest.isEmpty {
            parts.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return [number, parts.joined(separator: " "), parts.joined(separator: "-"), expiry,
                String(format: "%02d/%d", expiryMonth, expiryYear)]
    }
}
