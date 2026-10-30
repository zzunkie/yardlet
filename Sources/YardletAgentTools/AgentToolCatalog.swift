import Foundation

/// One tool as MCP `tools/list` describes it.
package struct AgentToolDefinition: Equatable, Sendable {
    package var name: String
    package var title: String
    package var description: String
    /// JSON Schema for the arguments object.
    package var inputSchema: ToolJSON
    package var readOnly: Bool
    /// The tool reaches beyond Yardlet: a web page for the browser tools. The task suggestion
    /// tools stay inside Yardlet.
    package var openWorld = true
    /// Claude Code keeps the tool in the prompt instead of behind its tool search
    /// (`_meta` `anthropic/alwaysLoad`), as the Claude app loads its own `spawn_task`.
    package var alwaysLoad = false

    package var json: ToolJSON {
        var fields: [String: ToolJSON] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(false),
                "openWorldHint": .bool(openWorld)
            ])
        ]
        if alwaysLoad { fields["_meta"] = .object(["anthropic/alwaysLoad": .bool(true)]) }
        return .object(fields)
    }
}

/// The browser tools Yardlet offers every harness. Each acts on one of the calling task's own browser
/// tabs over the Chrome DevTools Protocol, so the same catalog serves CEF and WebView2: the tab named
/// by `tabId`, or the agent's active tab (the one its panel shows, unless the person kept the panel on
/// another), as the Claude app's Browser pane tools do. The tab tools list, open, front and close the task's tabs.
package enum AgentToolCatalog {
    package static let navigate = "browser_navigate"
    package static let snapshot = "browser_snapshot"
    package static let click = "browser_click"
    package static let type = "browser_type"
    package static let pressKey = "browser_press_key"
    package static let scroll = "browser_scroll"
    package static let selectOption = "browser_select_option"
    package static let waitFor = "browser_wait_for"
    package static let screenshot = "browser_screenshot"
    package static let consoleMessages = "browser_console_messages"
    package static let evaluate = "browser_evaluate"
    package static let handleDialog = "browser_handle_dialog"
    package static let fileUpload = "browser_file_upload"
    package static let resize = "browser_resize"
    package static let handoff = "browser_handoff"
    package static let batch = "browser_batch"
    package static let tabList = "browser_tab_list"
    package static let tabNew = "browser_tab_new"
    package static let tabSelect = "browser_tab_select"
    package static let tabClose = "browser_tab_close"
    /// The tools that manage the task's tabs rather than act on a page.
    package static let tabToolNames: Set<String> = [tabList, tabNew, tabSelect, tabClose]

    /// Tools a batch may contain: every tool except the batch itself and the handoff, which waits for the person.
    package static var batchableNames: [String] {
        browserTools.map(\.name).filter { $0 != batch && $0 != handoff }
    }

    package static func definition(named name: String) -> AgentToolDefinition? {
        browserTools.first { $0.name == name }
    }

    /// Every browser tool's name starts with this; connector tools never do.
    package static let browserToolPrefix = "browser_"

    package static let serverInstructions = """
        Browser tools act on this task's own tabs in Yardlet's built-in Chromium browser, which the \
        user can watch in the task's browser panel: on the active tab, or on the tab a tool's tabId \
        names. browser_tab_new opens another tab, in the background unless foreground is set. Call \
        browser_snapshot to read the page, find an element or text on it, and get element references \
        such as @e3; an element keeps its reference while it stays on the page, and a navigation ends \
        them. Tab ids and element references are the tools' own and the user never sees them: when you \
        tell the user about a tab, name it by its page's title or site, and an element by its label or text. \
        spawn_task flags out-of-scope work for a separate task: the user sees a chip in this \
        conversation and decides whether to start it. The session tools read the person's other \
        Yardlet tasks, message one, start a task, or run a subagent on a harness. The \
        scheduled-task tools create and change the person's Yardlet schedules, which run while Yardlet \
        is open. Other tools come from services the user connected in Yardlet, such as issue trackers \
        or documents; each name starts with its service, and each acts with the user's own account there.
        """

    /// The tools Yardlet itself offers, when the app cannot say which a task has: the browser tools,
    /// the task suggestion tools, the session tools, then the scheduled-task tools.
    package static var builtInTools: [AgentToolDefinition] {
        browserTools + TaskSuggestionToolCatalog.tools + SessionToolCatalog.tools + ScheduleToolCatalog.tools
    }

    private static let tabIDProperty: ToolJSON = .object([
        "type": .string("string"),
        "description": .string("The tab to act on, from browser_tab_list or browser_tab_new. Omit for the active tab.")
    ])

    private static let refProperty: ToolJSON = .object([
        "type": .string("string"),
        "description": .string("Element reference from the tab's latest browser_snapshot, such as @e3.")
    ])

    /// A page tool's input: its own properties and the optional tab.
    private static func pageInput(_ properties: [String: ToolJSON], required: [String] = []) -> ToolJSON {
        var properties = properties
        properties["tabId"] = tabIDProperty
        return object(properties, required: required)
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

    private static func property(_ type: String, _ description: String) -> ToolJSON {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func enumeration(_ values: [String], _ description: String) -> ToolJSON {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ])
    }

    package static let browserTools: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: navigate,
            title: "Navigate",
            description: "Load a URL in this task's browser tab and wait for the page to load. Accepts http, https, "
                + "file, data, and about addresses; a bare host name gets https. Returns the loaded address and title.",
            inputSchema: pageInput(["url": property("string", "The address to load.")], required: ["url"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: snapshot,
            title: "Page snapshot",
            description: "Read the page as an accessibility tree in text, its frames included: this is how to find an "
                + "element or text on the page. Elements you can act on carry references such as @e3 for the other "
                + "browser tools. An element keeps its reference in later snapshots while it stays on the page; a "
                + "reference whose element is not in the latest snapshot stops working, and a navigation of the page "
                + "ends them all.",
            inputSchema: pageInput([:]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: click,
            title: "Click",
            description: "Click an element by its snapshot reference, or a point given in CSS pixels from "
                + "the top-left of the visible page. Uses trusted mouse input.",
            inputSchema: pageInput([
                "ref": refProperty,
                "x": property("number", "Horizontal position in CSS pixels, when no ref is given."),
                "y": property("number", "Vertical position in CSS pixels, when no ref is given."),
                "button": enumeration(["left", "right", "middle"], "Mouse button. Defaults to left."),
                "doubleClick": property("boolean", "Click twice."),
                "modifiers": .object([
                    "type": .string("array"),
                    "items": enumeration(["Alt", "Control", "Meta", "Shift"], "A modifier key held during the click."),
                    "description": .string("Modifier keys held during the click.")
                ])
            ]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: type,
            title: "Type",
            description: "Replace the text of an editable element with the given text using trusted keyboard "
                + "input, and optionally press Enter afterwards.",
            inputSchema: pageInput([
                "ref": refProperty,
                "text": property("string", "The text to enter."),
                "submit": property("boolean", "Press Enter after typing.")
            ], required: ["ref", "text"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: pressKey,
            title: "Press key",
            description: "Press a key or key combination in the focused element, such as Enter, Escape, Tab, "
                + "ArrowDown, Backspace, Shift+Tab, or Meta+a.",
            inputSchema: pageInput([
                "key": property("string", "A key name or a single character, with modifiers joined by +.")
            ], required: ["key"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: scroll,
            title: "Scroll",
            description: "Scroll by a distance in CSS pixels at a point (the page centre by default), or bring "
                + "an element into view by its reference. Returns the page's new scroll position.",
            inputSchema: pageInput([
                "ref": refProperty,
                "deltaX": property("number", "Horizontal distance; positive scrolls right."),
                "deltaY": property("number", "Vertical distance; positive scrolls down."),
                "x": property("number", "Where to scroll, in CSS pixels."),
                "y": property("number", "Where to scroll, in CSS pixels.")
            ]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: selectOption,
            title: "Select option",
            description: "Choose options in a select element by value or visible label.",
            inputSchema: pageInput([
                "ref": refProperty,
                "values": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Option values or labels to select.")
                ])
            ], required: ["ref", "values"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: waitFor,
            title: "Wait for",
            description: "Wait until text appears on the page, until text disappears, or for a number of "
                + "seconds (at most 30). Text matches a part of the visible text (innerText) of the page and of its "
                + "frames from the same origin, ignoring case and runs of spaces, checked every 200 ms; a frame from "
                + "another origin is not read (browser_snapshot reads it). When the time runs out, the result says what "
                + "the page shows.",
            inputSchema: pageInput([
                "text": property("string", "Text to wait for, as a part of the page's visible text."),
                "textGone": property("string", "Text to wait to disappear from the page's visible text."),
                "time": property("number", "Seconds to wait when no text is given."),
                "timeout": property("number", "Seconds to wait for text before failing. Defaults to 10, at most 60.")
            ]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: screenshot,
            title: "Screenshot",
            description: "Capture the visible page, the full page, or one element as an image.",
            inputSchema: pageInput([
                "ref": refProperty,
                "fullPage": property("boolean", "Capture the whole scrollable page."),
                "format": enumeration(["png", "jpeg"], "Image format. Defaults to png.")
            ]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: consoleMessages,
            title: "Console messages",
            description: "List console messages and uncaught errors the page produced since the tab opened.",
            inputSchema: pageInput([
                "onlyErrors": property("boolean", "Return only errors.")
            ]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: evaluate,
            title: "Evaluate JavaScript",
            description: "Run one JavaScript function in the page and return its result as JSON, such as "
                + "\"() => document.title\". With a reference, the element is the function's argument: "
                + "\"(element) => element.textContent\". A promise it returns is awaited for up to 15 seconds.",
            inputSchema: pageInput([
                "function": property("string", "A JavaScript function expression."),
                "ref": refProperty
            ], required: ["function"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: handleDialog,
            title: "Handle dialog",
            description: "Answer the page's open JavaScript dialog (alert, confirm, prompt, or leave-page). The page "
                + "is paused until it is answered, and the other tools say when one is open.",
            inputSchema: pageInput([
                "accept": property("boolean", "Accept (OK) or dismiss (Cancel)."),
                "promptText": property("string", "Text to enter in a prompt dialog before accepting.")
            ], required: ["accept"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: fileUpload,
            title: "Upload files",
            description: "Answer the page's open file chooser with files from this task's project folders, or cancel "
                + "it by giving no paths. A click on the page's file input opens the chooser, and its result says so; "
                + "when none is open yet, this waits up to 2 seconds for one.",
            inputSchema: pageInput([
                "paths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Absolute paths, or paths relative to the task's folder. Empty cancels.")
                ])
            ]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: resize,
            title: "Resize viewport",
            description: "Emulate a screen size in this task's browser tab: preset mobile (375x812, a touch phone with "
                + "Android Chrome's user agent), tablet (768x1024), or desktop, which clears the emulation and returns the "
                + "tab to its own size; or a custom width and height (1 to 9999; narrower than 768 is a phone). The size "
                + "holds for the tab across reloads and navigations, the panel shows a larger one scaled down to fit, and "
                + "Yardlet clears a size you set when your turn ends. A size the person picked in the panel's Viewport menu "
                + "stays until they or you change it. colorScheme emulates prefers-color-scheme (light or dark) on the tab "
                + "until it is set again or your turn ends; preset desktop leaves it. Pages read the device as they load, "
                + "so load the page again after switching. Clicks still arrive as mouse clicks.",
            inputSchema: pageInput([
                "preset": enumeration(["mobile", "tablet", "desktop"], "A device size, or desktop to clear the emulation."),
                "width": property("number", "Custom width in CSS pixels, with height."),
                "height": property("number", "Custom height in CSS pixels, with width."),
                "colorScheme": enumeration(["light", "dark"], "The prefers-color-scheme the page sees.")
            ]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: handoff,
            title: "Hand tab to person",
            description: "Hand this task's browser tab to the person for a step only they can take, such as a CAPTCHA, a "
                + "QR code sign-in or a payment approval, and wait for them. The task's panel shows the tab with the reason "
                + "and Done and Decline buttons, and Yardlet notifies the person. Returns when they answer, when text appears "
                + "on the page if given, or after timeout seconds (default 600); until they answer or your turn ends the tab "
                + "stays handed to them, and calling again waits again. Cannot run in a batch.",
            inputSchema: pageInput([
                "reason": property("string", "What the person is to do in the tab, shown to them."),
                "text": property("string", "Text whose appearance on the page also ends the wait, such as what it shows once signed in."),
                "timeout": property("number", "Seconds to wait. Defaults to 600; a harness's own limit on one call may be shorter.")
            ], required: ["reason"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: batch,
            title: "Batch",
            description: "Run several browser tools in order and stop at the first failure. Each action names "
                + "a browser tool and its input, which may name its own tabId. An action that makes the page navigate "
                + "ends the references of its snapshots, and its result says so.",
            inputSchema: object([
                "actions": .object([
                    "type": .string("array"),
                    "minItems": .integer(1),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    navigate, snapshot, click, type, pressKey, scroll, selectOption, waitFor,
                                    screenshot, consoleMessages, evaluate, handleDialog, fileUpload, resize,
                                    tabList, tabNew, tabSelect, tabClose
                                ].map { .string($0) })
                            ]),
                            "input": .object(["type": .string("object")])
                        ]),
                        "required": .array([.string("name")])
                    ]),
                    "description": .string("The actions to run, in order.")
                ])
            ], required: ["actions"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: tabList,
            title: "List tabs",
            description: "List this task's browser tabs: each tab's id, the origin of its page (not its title, which "
                + "the page writes), which one is active, which one the panel shows and whether the person is using it, "
                + "and say whether the task's browser panel is open.",
            inputSchema: object([:]),
            readOnly: true
        ),
        AgentToolDefinition(
            name: tabNew,
            title: "New tab",
            description: "Open a blank tab in this task's browser and return its id. It opens behind the active tab "
                + "unless foreground is set; load a page in it with browser_navigate and its tabId. A task keeps at "
                + "most 9 tabs.",
            inputSchema: object([
                "foreground": property("boolean", "Make the new tab the active one, which the panel shows unless the "
                    + "person is using another tab there.")
            ]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: tabSelect,
            title: "Select tab",
            description: "Make a tab of this task the active one, which the other tools use without a tabId and the "
                + "panel shows unless the person is using another tab there. Background tabs keep running while the "
                + "tools drive them.",
            inputSchema: object(["tabId": property("string", "The tab to make active.")], required: ["tabId"]),
            readOnly: false
        ),
        AgentToolDefinition(
            name: tabClose,
            title: "Close tab",
            description: "Close a tab of this task. Closing the active tab makes the next one active; closing the "
                + "last tab closes the task's browser panel.",
            inputSchema: object(["tabId": property("string", "The tab to close.")], required: ["tabId"]),
            readOnly: false
        )
    ]
}
