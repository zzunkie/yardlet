import Foundation

/// What an MCP elicitation (`mcpServer/elicitation/request`) asks of the person, besides a tool
/// approval (`CodexMCPToolApproval`): a form to fill in, or a request Yardlet does not answer.
///
/// A form (`mode` `form`, `openai/form` or `openaiForm`) is read from its `requestedSchema`, the
/// flat object schema of MCP 2025-11-25 `ElicitRequestFormParams` as Codex 0.163 types it
/// (`McpElicitationSchema`): string, number, integer and boolean fields, single and multiple
/// choices, with their formats, ranges, lengths and counts. A schema with anything else in it, a
/// URL (`url`) or device verification (`openai/userVerification`) request, or a mode Yardlet does
/// not know is unsupported: it can be declined or cancelled, never accepted, so nothing the server
/// asked for is answered with an empty `content`.
enum CodexMCPElicitation: Equatable, Sendable {
    /// A form whose fields Yardlet collects and checks before Submit sends them as `content`.
    case form(CodexMCPElicitationForm)
    /// A request Yardlet cannot fill in, with the card's words for why.
    case unsupported(reason: String)

    init(params: JSONValue?) {
        let mode = params?["mode"]?.stringValue
        switch mode {
        case "form", "openai/form", "openaiForm", nil:
            // MCP's default mode is a form; an older server sends a schema without one.
            guard let schema = params?["requestedSchema"] else {
                self = .unsupported(reason: Self.unsupportedForm)
                return
            }
            switch CodexMCPElicitationForm.parse(schema) {
            case let .success(form): self = .form(form)
            case let .failure(problem): self = .unsupported(reason: problem.reason)
            }
        case "url":
            self = .unsupported(reason: L10n.string("Yardlet can't open this MCP sign-in link. Decline or cancel the request."))
        case "openai/userVerification":
            self = .unsupported(reason: L10n.string("Yardlet can't complete this MCP device verification. Decline or cancel the request."))
        default:
            self = .unsupported(reason: L10n.string("Yardlet can't answer this kind of MCP request. Decline or cancel it."))
        }
    }

    static var unsupportedForm: String {
        L10n.string("Yardlet can't fill in this MCP form. Decline or cancel it.")
    }

    /// The answers the card offers: a form is declined, cancelled or submitted with what was
    /// filled in (a form without fields submits `{}` at once); an unsupported request is only
    /// declined or cancelled.
    var responses: [ConversationRequestResponse] {
        var responses: [ConversationRequestResponse] = [
            .init(LocalizedText("Decline"), role: .destructive,
                  route: .codex(.mcpElicitation(action: .decline))),
            .init(LocalizedText("Cancel"), role: .secondary,
                  route: .codex(.mcpElicitation(action: .cancel)))
        ]
        if case let .form(form) = self {
            responses.append(.init(LocalizedText("Submit"), role: .primary,
                                   route: form.fields.isEmpty
                                       ? .codex(.mcpElicitation(action: .accept, content: .object([:])))
                                       : .structured))
        }
        return responses
    }
}

/// What the person entered in one field of an MCP form.
enum CodexMCPElicitationFieldValue: Equatable, Sendable {
    /// The text typed in a text or number field, as typed.
    case text(String)
    case flag(Bool)
    /// The values picked in a choice field.
    case picked(Set<String>)
}

/// An MCP elicitation's form, its fields in the order they are asked: required fields in the
/// order `required` lists them, then the others by name (the request's JSON object does not keep
/// the server's order of `properties`).
struct CodexMCPElicitationForm: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let value: String
        let title: String
    }

    enum TextFormat: String, Equatable, Sendable {
        case email
        case uri
        case date
        case dateTime = "date-time"
    }

    enum Kind: Equatable, Sendable {
        case text(format: TextFormat?, minLength: Int?, maxLength: Int?)
        case number(isInteger: Bool, minimum: Double?, maximum: Double?)
        case boolean
        case choice([Option])
        case choices([Option], minItems: Int?, maxItems: Int?)
    }

    struct Field: Identifiable, Equatable, Sendable {
        /// The property's name, which `content` answers under.
        let id: String
        let title: String?
        let description: String?
        let isRequired: Bool
        let kind: Kind
        let defaultValue: CodexMCPElicitationFieldValue?

        var label: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? id }
    }

    /// Why a field's value cannot be sent.
    enum Issue: Error, Equatable, Sendable {
        case missing
        case tooShort(Int)
        case tooLong(Int)
        case format(TextFormat)
        case notANumber
        case notAnInteger
        case belowMinimum(Double)
        case aboveMaximum(Double)
        case tooFewChoices(Int)
        case tooManyChoices(Int)
        case unknownChoice

        var message: String {
            switch self {
            case .missing: L10n.string("Required")
            case let .tooShort(count): L10n.format("Use at least %lld characters", Int64(count))
            case let .tooLong(count): L10n.format("Use at most %lld characters", Int64(count))
            case .format(.email): L10n.string("Enter an email address")
            case .format(.uri): L10n.string("Enter a full URL, such as https://example.com")
            case .format(.date): L10n.string("Enter a date as YYYY-MM-DD")
            case .format(.dateTime): L10n.string("Enter a date and time as YYYY-MM-DDThh:mm:ssZ")
            case .notANumber: L10n.string("Enter a number")
            case .notAnInteger: L10n.string("Enter a whole number")
            case let .belowMinimum(minimum): L10n.format("Enter %@ or more", CodexMCPElicitationForm.text(minimum))
            case let .aboveMaximum(maximum): L10n.format("Enter %@ or less", CodexMCPElicitationForm.text(maximum))
            case let .tooFewChoices(count): L10n.format("Choose at least %lld", Int64(count))
            case let .tooManyChoices(count): L10n.format("Choose at most %lld", Int64(count))
            case .unknownChoice: L10n.string("Choose one of the options")
            }
        }
    }

    let fields: [Field]
    /// What an answered form sent, read back from the request's recorded response; empty when it
    /// was declined, cancelled, rejected or sent without content. Nil while the request waits.
    var recorded: [String: CodexMCPElicitationFieldValue]? = nil

    // MARK: - Answer

    /// What a field holds: for an answered form, what was sent and nothing else; while it waits,
    /// what the person entered, else the schema's default.
    func value(of field: Field, in input: [String: CodexMCPElicitationFieldValue]) -> CodexMCPElicitationFieldValue? {
        if let recorded { return recorded[field.id] }
        return input[field.id] ?? field.defaultValue
    }

    /// The form as its request stands: an answered one reads as the `content` Codex was sent.
    func answered(_ resolution: CodexServerRequestResolution) -> CodexMCPElicitationForm {
        var form = self
        switch resolution {
        case .pending:
            form.recorded = nil
        case .rejected:
            form.recorded = [:]
        case let .resolved(response):
            let content = response?["action"]?.stringValue == "accept" ? response?["content"]?.objectValue ?? [:] : [:]
            form.recorded = [:]
            for field in fields {
                if let value = content[field.id].flatMap({ Self.recordedValue($0, field.kind) }) {
                    form.recorded?[field.id] = value
                }
            }
        }
        return form
    }

    /// A sent value as the field holds it, or nil when it does not fit the field.
    private static func recordedValue(_ value: JSONValue, _ kind: Kind) -> CodexMCPElicitationFieldValue? {
        switch (kind, value) {
        case let (.text, .string(text)): .text(text)
        case let (.number(isInteger, _, _), .integer(number)) where isInteger: .text(String(number))
        case (.number, _): value.doubleValue.map { .text(text($0)) }
        case let (.boolean, .bool(flag)): .flag(flag)
        case let (.choice, .string(choice)): .picked([choice])
        case (.choices, _): strings(value).map { .picked(Set($0)) }
        default: nil
        }
    }

    /// Why `field` cannot be sent as it is, or nil when it can (an optional field left empty is
    /// left out of `content`).
    func issue(of field: Field, in input: [String: CodexMCPElicitationFieldValue]) -> Issue? {
        switch Self.answer(field, value(of: field, in: input)) {
        case .success: nil
        case let .failure(issue): issue
        }
    }

    /// The form's `content`: each answered field under its name, with the type its schema names;
    /// nil while a required field is empty or any field is invalid.
    func content(_ input: [String: CodexMCPElicitationFieldValue]) -> JSONValue? {
        var content: [String: JSONValue] = [:]
        for field in fields {
            switch Self.answer(field, value(of: field, in: input)) {
            case let .success(value?): content[field.id] = value
            case .success(nil): continue
            case .failure: return nil
            }
        }
        return .object(content)
    }

    /// A field holds no answer: required fields keep Submit off, optional ones are left out.
    ///
    /// `required` asks for a value to be present, so an empty string or an empty list counts as
    /// an answer where the schema says it is one: its `default` is `""` or `[]`, or its `minItems`
    /// is 0. Otherwise a blank text or nothing picked is no answer yet.
    private static func answer(_ field: Field, _ value: CodexMCPElicitationFieldValue?) -> Result<JSONValue?, Issue> {
        let unanswered: Result<JSONValue?, Issue> = field.isRequired ? .failure(.missing) : .success(nil)
        switch field.kind {
        case let .text(format, minLength, maxLength):
            guard case let .text(text)? = value else { return unanswered }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field.defaultValue != .text("") {
                return unanswered
            }
            // JSON Schema counts a string's length in code points.
            let length = text.unicodeScalars.count
            if let minLength, length < minLength { return .failure(.tooShort(minLength)) }
            if let maxLength, length > maxLength { return .failure(.tooLong(maxLength)) }
            if let format, !matches(text, format) { return .failure(.format(format)) }
            return .success(.string(text))
        case let .number(isInteger, minimum, maximum):
            guard case let .text(raw)? = value else { return unanswered }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return unanswered }
            let number: JSONValue
            let amount: Double
            if isInteger {
                guard text.wholeMatch(of: /[+-]?[0-9]+/) != nil else {
                    return .failure(text.wholeMatch(of: decimal) != nil ? .notAnInteger : .notANumber)
                }
                guard let integer = Int64(text.hasPrefix("+") ? String(text.dropFirst()) : text) else {
                    return .failure(.notANumber)
                }
                number = .integer(integer)
                amount = Double(integer)
            } else {
                // Plain decimals only: no hexadecimal, `inf` or `nan`, which `Double(_:)` reads.
                guard text.wholeMatch(of: decimal) != nil, let double = Double(text), double.isFinite else {
                    return .failure(.notANumber)
                }
                number = .number(double)
                amount = double
            }
            if let minimum, amount < minimum { return .failure(.belowMinimum(minimum)) }
            if let maximum, amount > maximum { return .failure(.aboveMaximum(maximum)) }
            return .success(number)
        case .boolean:
            // A switch always shows a value, and the value it shows is the one sent.
            guard case let .flag(flag)? = value else { return .success(.bool(false)) }
            return .success(.bool(flag))
        case let .choice(options):
            guard case let .picked(picked)? = value, !picked.isEmpty else {
                return unanswered
            }
            guard picked.count == 1, let choice = picked.first, options.contains(where: { $0.value == choice }) else {
                return .failure(.unknownChoice)
            }
            return .success(.string(choice))
        case let .choices(options, minItems, maxItems):
            guard case let .picked(picked)? = value else { return unanswered }
            if picked.isEmpty, minItems != 0, field.defaultValue != .picked([]) { return unanswered }
            guard picked.allSatisfy({ choice in options.contains { $0.value == choice } }) else {
                return .failure(.unknownChoice)
            }
            if let minItems, picked.count < minItems { return .failure(.tooFewChoices(minItems)) }
            if let maxItems, picked.count > maxItems { return .failure(.tooManyChoices(maxItems)) }
            return .success(.array(options.filter { picked.contains($0.value) }.map { .string($0.value) }))
        }
    }

    nonisolated(unsafe) private static let decimal = /[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?/

    private static func matches(_ text: String, _ format: TextFormat) -> Bool {
        switch format {
        case .email:
            return text.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil
        case .uri:
            guard text.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\S+/) != nil else { return false }
            return URLComponents(string: text)?.scheme != nil
        case .date:
            guard text.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else { return false }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            // The formatter rolls an impossible day over; the date must read back as typed.
            guard let date = formatter.date(from: text) else { return false }
            return formatter.string(from: date) == text
        case .dateTime:
            // RFC 3339: a real date, `T`, a time of day with optional fractions, and a zone. The
            // formatter rolls an impossible day or hour over, so each part is checked first; a leap
            // second (`:60`) is not taken.
            guard text.wholeMatch(
                of: /[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])/
            ) != nil, matches(String(text.prefix(10)), .date) else { return false }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = text.contains(".")
                ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            return formatter.date(from: text.uppercased()) != nil
        }
    }

    /// A limit as the card writes it: without a fraction when it has none.
    static func text(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }

    // MARK: - Schema

    struct Problem: Error, Equatable {
        /// The field the schema cannot be read at, or nil for the schema itself.
        let field: String?

        var reason: String {
            guard let field else { return CodexMCPElicitation.unsupportedForm }
            return L10n.format("Yardlet can't fill in the field “%@” of this MCP form. Decline or cancel it.", field)
        }
    }

    /// The form `schema` describes, or where it asks for something Yardlet does not collect.
    static func parse(_ schema: JSONValue) -> Result<CodexMCPElicitationForm, Problem> {
        let schemaProblem = Problem(field: nil)
        guard let object = schema.objectValue, object["type"]?.stringValue == "object",
              let properties = object["properties"]?.objectValue else { return .failure(schemaProblem) }
        let known: Set<String> = ["$schema", "type", "properties", "required", "title", "description", "additionalProperties"]
        guard Set(object.keys).isSubset(of: known) else { return .failure(schemaProblem) }
        if let additional = object["additionalProperties"], additional != .bool(false) { return .failure(schemaProblem) }

        var required: [String] = []
        switch object["required"] {
        case nil, .null?:
            break
        case let .array(names)?:
            for name in names {
                guard let name = name.stringValue, properties[name] != nil, !required.contains(name) else {
                    return .failure(schemaProblem)
                }
                required.append(name)
            }
        default:
            return .failure(schemaProblem)
        }

        var fields: [Field] = []
        let order = required + properties.keys.filter { !required.contains($0) }.sorted()
        for name in order {
            guard let property = properties[name]?.objectValue,
                  let field = field(name, property, isRequired: required.contains(name)) else {
                return .failure(Problem(field: name))
            }
            fields.append(field)
        }
        return .success(CodexMCPElicitationForm(fields: fields))
    }

    /// One property as a field, or nil when it carries a type, keyword or value Yardlet does not
    /// check: a field the server limits in a way the card does not enforce is not sent unchecked.
    private static func field(_ name: String, _ property: [String: JSONValue], isRequired: Bool) -> Field? {
        let title = optionalString(property["title"])
        let description = optionalString(property["description"])
        guard let title, let description else { return nil }
        func keys(_ allowed: Set<String>) -> Bool {
            Set(property.keys).isSubset(of: allowed.union(["type", "title", "description", "default"]))
        }
        func make(_ kind: Kind, _ defaultValue: CodexMCPElicitationFieldValue?) -> Field {
            Field(id: name, title: title.value, description: description.value, isRequired: isRequired,
                  kind: kind, defaultValue: defaultValue)
        }
        let defaultValue = property["default"].flatMap { $0 == .null ? nil : $0 }

        switch property["type"]?.stringValue {
        case "string":
            if let values = property["enum"] {
                guard keys(["enum", "enumNames"]), let values = strings(values), !values.isEmpty else { return nil }
                var titles = values
                if let names = property["enumNames"], names != .null {
                    guard let names = strings(names), names.count == values.count else { return nil }
                    titles = names
                }
                return choice(zip(values, titles).map { Option(value: $0, title: $1) }, defaultValue, make)
            }
            if let oneOf = property["oneOf"] {
                guard keys(["oneOf"]), let options = constOptions(oneOf) else { return nil }
                return choice(options, defaultValue, make)
            }
            guard keys(["format", "minLength", "maxLength"]) else { return nil }
            var format: TextFormat?
            if let raw = property["format"], raw != .null {
                guard let value = raw.stringValue.flatMap(TextFormat.init(rawValue:)) else { return nil }
                format = value
            }
            guard let minLength = count(property["minLength"]), let maxLength = count(property["maxLength"]),
                  (minLength.value ?? 0) <= (maxLength.value ?? Int.max) else { return nil }
            var initial: CodexMCPElicitationFieldValue?
            if let defaultValue {
                guard let text = defaultValue.stringValue else { return nil }
                initial = .text(text)
            }
            return make(.text(format: format, minLength: minLength.value, maxLength: maxLength.value), initial)
        case "number", "integer":
            guard keys(["minimum", "maximum"]) else { return nil }
            let isInteger = property["type"]?.stringValue == "integer"
            guard let minimum = finite(property["minimum"]), let maximum = finite(property["maximum"]),
                  (minimum.value ?? -.infinity) <= (maximum.value ?? .infinity) else { return nil }
            var initial: CodexMCPElicitationFieldValue?
            if let defaultValue {
                guard let number = defaultValue.doubleValue, number.isFinite,
                      !isInteger || number.rounded() == number else { return nil }
                initial = .text(text(number))
            }
            return make(.number(isInteger: isInteger, minimum: minimum.value, maximum: maximum.value), initial)
        case "boolean":
            guard keys([]) else { return nil }
            var initial: CodexMCPElicitationFieldValue?
            if let defaultValue {
                guard let flag = defaultValue.boolValue else { return nil }
                initial = .flag(flag)
            }
            return make(.boolean, initial)
        case "array":
            guard keys(["items", "minItems", "maxItems"]), let items = property["items"]?.objectValue else { return nil }
            let options: [Option]
            if let values = items["enum"] {
                guard Set(items.keys) == ["type", "enum"], items["type"]?.stringValue == "string",
                      let values = strings(values), !values.isEmpty, Set(values).count == values.count else { return nil }
                options = values.map { Option(value: $0, title: $0) }
            } else if let anyOf = items["anyOf"] {
                guard Set(items.keys) == ["anyOf"], let titled = constOptions(anyOf) else { return nil }
                options = titled
            } else {
                return nil
            }
            guard let minItems = count(property["minItems"]), let maxItems = count(property["maxItems"]),
                  (minItems.value ?? 0) <= (maxItems.value ?? Int.max) else { return nil }
            var initial: CodexMCPElicitationFieldValue?
            if let defaultValue {
                guard let picked = strings(defaultValue) else { return nil }
                initial = .picked(Set(picked))
            }
            return make(.choices(options, minItems: minItems.value, maxItems: maxItems.value), initial)
        default:
            return nil
        }
    }

    private static func choice(
        _ options: [Option], _ defaultValue: JSONValue?, _ make: (Kind, CodexMCPElicitationFieldValue?) -> Field
    ) -> Field? {
        guard Set(options.map(\.value)).count == options.count else { return nil }
        var initial: CodexMCPElicitationFieldValue?
        if let defaultValue {
            guard let value = defaultValue.stringValue else { return nil }
            initial = .picked([value])
        }
        return make(.choice(options), initial)
    }

    /// A present-or-absent value: `.some(nil)` when absent or null, nil when it has the wrong type.
    private struct Present<Value> { let value: Value? }

    private static func optionalString(_ value: JSONValue?) -> Present<String>? {
        switch value {
        case nil, .null?: Present(value: nil)
        case let .string(text)?: Present(value: text)
        default: nil
        }
    }

    private static func count(_ value: JSONValue?) -> Present<Int>? {
        switch value {
        case nil, .null?: return Present(value: nil)
        case let .integer(number)? where number >= 0 && number <= Int64(Int32.max): return Present(value: Int(number))
        case let .number(number)? where number >= 0 && number <= Double(Int32.max) && number.rounded() == number:
            return Present(value: Int(number))
        default: return nil
        }
    }

    private static func finite(_ value: JSONValue?) -> Present<Double>? {
        switch value {
        case nil, .null?: return Present(value: nil)
        default:
            guard let number = value?.doubleValue, number.isFinite else { return nil }
            return Present(value: number)
        }
    }

    private static func strings(_ value: JSONValue) -> [String]? {
        guard let array = value.arrayValue else { return nil }
        let strings = array.compactMap(\.stringValue)
        return strings.count == array.count ? strings : nil
    }

    private static func constOptions(_ value: JSONValue) -> [Option]? {
        guard let array = value.arrayValue, !array.isEmpty else { return nil }
        let options = array.compactMap { item -> Option? in
            guard let object = item.objectValue, Set(object.keys) == ["const", "title"],
                  let value = object["const"]?.stringValue, let title = object["title"]?.stringValue else { return nil }
            return Option(value: value, title: title)
        }
        guard options.count == array.count, Set(options.map(\.value)).count == options.count else { return nil }
        return options
    }
}
