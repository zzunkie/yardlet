import Foundation

/// The simulator tools: an agent sees and drives the iOS simulator or Android emulator its task attached, the device
/// the task's Simulator tab shows (docs/SIMULATOR.md, "Agent tools"). Every tool but `simulator_list` and
/// `simulator_attach` acts on the attached device only, and none attaches one by itself: a device that is on may be
/// one the person uses in Simulator.app or another task's QA device. Building, installing, launching and logs stay
/// with the agent's own tools, which take the device's id these tools give.
package enum SimulatorToolCatalog {
    package static let list = "simulator_list"
    package static let attach = "simulator_attach"
    package static let detach = "simulator_detach"
    package static let screenshot = "simulator_screenshot"
    package static let tap = "simulator_tap"
    package static let swipe = "simulator_swipe"
    package static let type = "simulator_type"
    package static let press = "simulator_press"

    /// The longest a tap, a swipe or a press may last, in seconds.
    package static let longestDuration = 10.0
    /// The most times one `simulator_press` presses.
    package static let mostPresses = 50
    /// The most characters one `simulator_type` enters.
    package static let longestText = 1_000
    /// A tap held longer than this is a long press.
    package static let longPress = 0.5
    /// How long a swipe lasts when the call does not say.
    package static let defaultSwipeDuration = 0.3

    /// The buttons `simulator_press` takes: iOS's and Android's (each platform takes its own).
    package static let buttons = ["home", "lock", "volume_up", "volume_down", "action", "back", "recents", "power"]
    /// The keys `simulator_press` takes.
    package static let keys = ["return", "delete", "tab", "escape", "space", "up", "down", "left", "right", "select_all"]

    package static func definition(named name: String) -> AgentToolDefinition? {
        tools.first { $0.name == name }
    }

    private static func object(_ properties: [String: ToolJSON], required: [String] = []) -> ToolJSON {
        var schema: [String: ToolJSON] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    private static func number(_ description: String, minimum: Double, maximum: Double? = nil) -> ToolJSON {
        var schema: [String: ToolJSON] = [
            "type": .string("number"), "minimum": .number(minimum), "description": .string(description)
        ]
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    private static func enumeration(_ values: [String], _ description: String) -> ToolJSON {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ])
    }

    private static let coordinate = "in the last simulator_screenshot image, from its top-left"

    package static let tools: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: list,
            title: "List simulators",
            description: "List the simulators and emulators Yardlet can show: each device's id, platform, name, OS, state "
                + "(on, off, booting or shutting down), whether this task attached it, whether another task's agent "
                + "uses it (that task's title), whether Yardlet started it, and whether a Simulator tab shows it. The "
                + "other simulator tools act only on the device this task attached with simulator_attach.",
            inputSchema: object([:]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: attach,
            title: "Attach simulator",
            description: "Attach a simulator or emulator to this task by the id or name simulator_list gives, so the "
                + "other simulator tools act on it; a task has one at a time, and attaching another lets go of the "
                + "first. A device that is off starts without a window, which takes a minute or less. The first time "
                + "a device is used, Yardlet asks the person to allow it on a card in this task, and the call waits for "
                + "the answer. The task's side panel shows the device. Returns the device's id, which your own build "
                + "and install tools take (xcrun simctl install <id> <app>, adb -s <id> install <apk>), and its screen "
                + "size, which the coordinates of the other tools use. Other apps and tools can drive the same device "
                + "(Simulator.app, Xcode, XcodeBuildMCP), and their input mixes with these tools'; while another tool "
                + "has a session open on this device, you may leave its input to that tool.",
            inputSchema: object([
                "device": .object([
                    "type": .string("string"),
                    "description": .string("The device's id or name, from simulator_list.")
                ])
            ], required: ["device"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: detach,
            title: "Detach simulator",
            description: "Let go of the device this task attached. A device Yardlet started shuts down a while after no "
                + "task uses it.",
            inputSchema: object([:]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: screenshot,
            title: "Simulator screenshot",
            description: "Capture the attached device's screen as an image, in points on iOS and dp on Android; the "
                + "result names its size. The x and y of simulator_tap and simulator_swipe are positions in this image.",
            inputSchema: object([
                "format": enumeration(["png", "jpeg"], "Image format. Defaults to png.")
            ]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: tap,
            title: "Tap simulator",
            description: "Tap the attached device's screen at a point \(coordinate). A duration over 0.5 seconds is a "
                + "long press.",
            inputSchema: object([
                "x": number("Horizontal position \(coordinate).", minimum: 0),
                "y": number("Vertical position \(coordinate).", minimum: 0),
                "duration": number("Seconds to hold, at most 10.", minimum: 0, maximum: longestDuration)
            ], required: ["x", "y"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: swipe,
            title: "Swipe simulator",
            description: "Drag one finger across the attached device's screen from (x, y) to (x2, y2), \(coordinate): "
                + "this scrolls a list or turns a page. A swipe that starts within 4 points of the screen's edge is the "
                + "system's edge gesture, such as going Home from the bottom edge.",
            inputSchema: object([
                "x": number("Where the finger goes down, horizontally.", minimum: 0),
                "y": number("Where the finger goes down, vertically.", minimum: 0),
                "x2": number("Where the finger lifts, horizontally.", minimum: 0),
                "y2": number("Where the finger lifts, vertically.", minimum: 0),
                "duration": number("Seconds the drag lasts. Defaults to 0.3, at most 10.", minimum: 0,
                                   maximum: longestDuration)
            ], required: ["x", "y", "x2", "y2"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: type,
            title: "Type in simulator",
            description: "Enter text into the attached device's focused field; tap the field first. By default (method "
                + "paste) Yardlet puts the text on the device's clipboard, pastes it, and puts back the text the "
                + "clipboard held: text in any language goes in as written. method keys types on the hardware keyboard "
                + "instead, for a field that refuses a paste (the text does not appear): ASCII only, and it goes in as "
                + "written only while the device's keyboard is set to English. At most 1,000 characters a call.",
            inputSchema: object([
                "text": .object([
                    "type": .string("string"),
                    "maxLength": .integer(Int64(longestText)),
                    "description": .string("The text to enter, at most 1,000 characters.")
                ]),
                "method": enumeration(["paste", "keys"], "paste (the default) or keys, for a field that refuses a paste.")
            ], required: ["text"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: press,
            title: "Press simulator button",
            description: "Press a hardware button or a key on the attached device. Buttons: on iOS home, lock, "
                + "volume_up, volume_down and action; on Android back, home, recents, power, volume_up and volume_down. "
                + "Keys go to the focused field or view: return, delete, tab, escape, space, up, down, left, right and "
                + "select_all.",
            inputSchema: object([
                "button": enumeration(buttons, "A hardware button, when no key is given."),
                "key": enumeration(keys, "A key, when no button is given."),
                "count": .object([
                    "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(Int64(mostPresses)),
                    "description": .string("How many times to press. Defaults to 1, at most 50.")
                ])
            ]),
            readOnly: false
        )
    ]
}
