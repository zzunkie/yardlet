import Foundation

/// Carries an answerable permission request and its answer across the Yardlet Harness Protocol
/// boundary. YHP v1 has no field for a provider question or a submitted plan, so both travel as
/// declared `yardlet.compat` values rather than being flattened into the request's `input`. The
/// tool call a request belongs to and the change it would make travel the same way.
enum PermissionStructureCoding {
    static let questionsKey = "yardlet.compat.permissionQuestions"
    static let planKey = "yardlet.compat.permissionPlan"
    static let answersKey = "yardlet.compat.permissionAnswers"
    static let toolCallIDKey = "yardlet.compat.permissionToolCallID"
    static let previewKey = "yardlet.compat.permissionPreview"
    static let requiresInAppAnswerKey = "yardlet.compat.permissionRequiresInAppAnswer"

    /// Every `yardlet.compat` value a request carries across the boundary.
    static func extensionValues(for request: PermissionRequest) -> [String: JSONValue] {
        var values = extensionValues(for: request.structured)
        if let toolCallID = request.toolCallID { values[toolCallIDKey] = .string(toolCallID) }
        if let preview = request.preview,
           let encoded = try? HarnessProtocolPayloadCodec().encode(preview) {
            values[previewKey] = encoded
        }
        if request.requiresInAppAnswer { values[requiresInAppAnswerKey] = .bool(true) }
        return values
    }

    static func toolCallID(from extensionValues: [String: JSONValue]) -> String? {
        extensionValues[toolCallIDKey]?.stringValue
    }

    static func requiresInAppAnswer(from extensionValues: [String: JSONValue]) -> Bool {
        extensionValues[requiresInAppAnswerKey]?.boolValue == true
    }

    static func preview(from extensionValues: [String: JSONValue]) -> PermissionRequestPreview? {
        extensionValues[previewKey].flatMap {
            try? HarnessProtocolPayloadCodec().decode(PermissionRequestPreview.self, from: $0)
        }
    }

    static func kind(for structure: PermissionRequestStructure?) -> HarnessProtocolPermissionKind {
        switch structure {
        case .questions: .question
        case .plan: .plan
        case nil: .tool
        }
    }

    static func extensionValues(
        for structure: PermissionRequestStructure?
    ) -> [String: JSONValue] {
        switch structure {
        case let .questions(questions):
            return [questionsKey: .array(questions.map(encode))]
        case let .plan(plan):
            return [planKey: .string(plan)]
        case nil:
            return [:]
        }
    }

    static func structure(
        from extensionValues: [String: JSONValue]
    ) -> PermissionRequestStructure? {
        if let entries = extensionValues[questionsKey]?.arrayValue {
            let questions = entries.compactMap(decodeQuestion)
            return questions.isEmpty ? nil : .questions(questions)
        }
        if let plan = extensionValues[planKey]?.stringValue, !plan.isEmpty {
            return .plan(plan)
        }
        return nil
    }

    /// The answers a host submitted, carried on the response's `updatedInput` so the wrapped
    /// adapter receives the same domain value the card produced.
    static func updatedInput(for answers: [PermissionQuestionAnswer]) -> JSONValue {
        .object([answersKey: .array(answers.map(encode))])
    }

    static func answers(from updatedInput: JSONValue?) -> [PermissionQuestionAnswer]? {
        guard let entries = updatedInput?[answersKey]?.arrayValue else { return nil }
        return entries.compactMap(decodeAnswer)
    }

    /// A tool call's asked questions and recorded answers (`HarnessActivity.answeredQuestions`), as a
    /// tool call carries them across the boundary.
    static func encode(_ answered: HarnessAnsweredQuestions) -> JSONValue {
        .object([
            "questions": .array(answered.questions.map(encode)),
            "answers": .array(answered.answers.map(encode))
        ])
    }

    static func answeredQuestions(from value: JSONValue?) -> HarnessAnsweredQuestions? {
        guard let value, let questions = value["questions"]?.arrayValue?.compactMap(decodeQuestion),
              !questions.isEmpty else { return nil }
        return HarnessAnsweredQuestions(
            questions: questions,
            answers: (value["answers"]?.arrayValue ?? []).compactMap(decodeAnswer)
        )
    }

    private static func encode(_ answer: PermissionQuestionAnswer) -> JSONValue {
        var value: [String: JSONValue] = [
            "question": .string(answer.question),
            "selectedLabels": .array(answer.selectedLabels.map(JSONValue.string))
        ]
        if let custom = answer.customAnswer { value["customAnswer"] = .string(custom) }
        return .object(value)
    }

    private static func decodeAnswer(_ entry: JSONValue) -> PermissionQuestionAnswer? {
        guard let question = entry["question"]?.stringValue else { return nil }
        let labels = (entry["selectedLabels"]?.arrayValue ?? []).compactMap(\.stringValue)
        return PermissionQuestionAnswer(question: question, selectedLabels: labels,
                                        customAnswer: entry["customAnswer"]?.stringValue)
    }

    private static func encode(_ question: PermissionQuestion) -> JSONValue {
        var value: [String: JSONValue] = [
            "question": .string(question.question),
            "options": .array(question.options.map { option in
                var encoded: [String: JSONValue] = ["label": .string(option.label)]
                if let description = option.description {
                    encoded["description"] = .string(description)
                }
                if let preview = option.preview { encoded["preview"] = .string(preview) }
                return .object(encoded)
            }),
            "multiSelect": .bool(question.allowsMultipleSelections)
        ]
        if let header = question.header { value["header"] = .string(header) }
        if question.allowsCustomAnswer { value["allowsCustomAnswer"] = .bool(true) }
        if question.requiresAnswer { value["requiresAnswer"] = .bool(true) }
        return .object(value)
    }

    private static func decodeQuestion(_ value: JSONValue) -> PermissionQuestion? {
        guard let question = value["question"]?.stringValue, !question.isEmpty else { return nil }
        let options = (value["options"]?.arrayValue ?? []).compactMap { option in
            option["label"]?.stringValue.map {
                PermissionQuestionOption(
                    label: $0,
                    description: option["description"]?.stringValue,
                    preview: option["preview"]?.stringValue
                )
            }
        }
        return PermissionQuestion(
            question: question,
            header: value["header"]?.stringValue,
            options: options,
            allowsMultipleSelections: value["multiSelect"]?.boolValue == true,
            allowsCustomAnswer: value["allowsCustomAnswer"]?.boolValue == true,
            requiresAnswer: value["requiresAnswer"]?.boolValue == true
        )
    }
}
