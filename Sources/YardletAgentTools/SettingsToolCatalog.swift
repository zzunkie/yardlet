import Foundation

/// The tools that let a task's agent read and change Yardlet's own settings when the person asks in the
/// conversation, so they need not find the switch in Settings: one lists every switch and choice Settings
/// offers, with its words as Settings shows them, its value and whether changing it asks the person; the other
/// changes one through the same path as its Settings control. The app answers both from the one catalog
/// Settings draws its rows from, and decides there which change waits for the person's approval card
/// (docs/AGENT_BROWSER_TOOLS.md, "Settings tools"). Listed with the session tools.
package enum SettingsToolCatalog {
    package static let list = "list_settings"
    package static let update = "update_setting"

    /// The first line of a change's result: `Changed the Yardlet setting “{title}” from “{old}” to “{new}”
    /// (settingId: {id}).` The words "(settingId: " are only Yardlet's, so the conversation draws a call
    /// whose result begins so as the change it made (`changed(inResult:)`).
    package static let changedMarker = " (settingId: "

    package static func changedLine(title: String, from old: String, to new: String, id: String) -> String {
        "Changed the Yardlet setting “\(title)” from “\(old)” to “\(new)”\(changedMarker)\(id))."
    }

    /// A change read back from its result's first line.
    package struct Change: Equatable, Sendable {
        package var id: String
        package var title: String
        package var from: String
        package var to: String

        package init(id: String, title: String, from: String, to: String) {
            self.id = id
            self.title = title
            self.from = from
            self.to = to
        }
    }

    package static func changed(inResult result: String?) -> Change? {
        guard let line = result?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              line.hasPrefix("Changed the Yardlet setting “"), line.hasSuffix(")."),
              let marker = line.range(of: changedMarker, options: .backwards) else { return nil }
        let id = String(line[marker.upperBound..<line.index(line.endIndex, offsetBy: -2)])
        let words = line[line.index(line.startIndex, offsetBy: "Changed the Yardlet setting “".count)..<marker.lowerBound]
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), words.hasSuffix("”"),
              let from = words.range(of: "” from “"), let to = words.range(of: "” to “", options: .backwards),
              from.upperBound <= to.lowerBound else { return nil }
        return Change(id: id, title: String(words[..<from.lowerBound]),
                      from: String(words[from.upperBound..<to.lowerBound]),
                      to: String(words[to.upperBound..<words.index(before: words.endIndex)]))
    }

    package static func definition(named name: String) -> AgentToolDefinition? {
        tools.first { $0.name == name }
    }

    package static var tools: [AgentToolDefinition] { [listTool, updateTool] }

    private static let listTool = AgentToolDefinition(
        name: list,
        title: "List Yardlet settings",
        description: "List Yardlet's settings as Settings shows them: each one's id, section, title and help in the "
            + "person's language, current value, allowed values, and whether changing it asks the person. Account "
            + "sign-ins, connectors, saved passwords, paired devices and instruction text are not settings here.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ]),
        readOnly: true,
        openWorld: false
    )

    private static let updateTool = AgentToolDefinition(
        name: update,
        title: "Change a Yardlet setting",
        description: "Change one Yardlet setting from list_settings, as its switch or choice in Settings changes it. "
            + "Some ask the person on an approval card first, and a declined card changes nothing.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("The setting's id from list_settings.")
                ]),
                "value": .object([
                    "type": .string("string"),
                    "description": .string("One of the setting's values from list_settings: \"on\" or \"off\" for a "
                        + "switch.")
                ])
            ]),
            "required": .array([.string("id"), .string("value")]),
            "additionalProperties": .bool(false)
        ]),
        readOnly: false,
        openWorld: false
    )
}
