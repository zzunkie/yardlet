import Foundation
import YardletAgentTools

/// How `simulator_attach` left the task's side panel.
enum SimulatorPanelShowing: Equatable, Sendable {
    /// The panel shows the task's Simulator tab.
    case shown
    /// The person was using another tab of the panel: the Simulator tab stands beside it, and the panel stays on theirs.
    case besidePersonsTab
    /// No panel of this Yardlet shows the task.
    case notShown
}

/// Runs the simulator tools (`SimulatorToolCatalog`, docs/SIMULATOR.md, "Agent tools") against the device the calling
/// task attached, through the simulator center (`SimulatorCenter`) and each platform's driver
/// (`SimulatorDeviceDriving`). The checks that keep an agent to its own device live here, in code: a tool acts only on
/// the task's attached device, which only `simulator_attach` attaches; the person allows each device before a task's
/// agent first uses it, whatever the task's permission mode (`SimulatorApprovals`); positions stay on the screen, and
/// durations, counts and text within their limits. A real Android device's approval holds only in the task it was
/// given in, and its card says what the device can reach.
@MainActor
final class SimulatorAgentTools {
    /// How long after the person's last input on a device the tools say they are using it, as the browser tools say
    /// of a tab (`BrowserHostClient.personUseWindow`).
    static let personUseWindow: TimeInterval = 30
    /// How long a tap holds when the call gives no duration.
    static let tapHold = 0.08
    /// How often a swipe moves its finger.
    static let swipeStep = 0.016
    /// At most this many devices go into a message that lists them; `simulator_list` lists them all.
    static let listedDeviceLimit = 30

    var center: @MainActor () -> SimulatorCenter
    let approvals: SimulatorApprovals
    var drivers: [SimulatorPlatform: any SimulatorDeviceDriving]
    /// Asks the person, on a card in the calling task, to let the task's agent use the device, and waits for the
    /// answer: true to go ahead. The app asks (`AppModel.asksToUseSimulator`); without it (tests) the answer is no.
    var askPerson: @MainActor (SimulatorDevice, UUID) async -> Bool = { _, _ in false }
    /// Shows the task's Simulator tab, unless the person is using another tab of its panel.
    var showPanel: @MainActor (UUID) -> SimulatorPanelShowing = { _ in .notShown }
    /// When the person last used the device in a Simulator tab.
    var lastPersonInput: @MainActor (SimulatorDeviceIdentity) -> Date? = { _ in nil }
    /// A task's title, for a device another task's agent uses.
    var taskTitle: @MainActor (UUID) -> String? = { _ in nil }
    var now: @MainActor () -> Date = { Date() }
    /// The waits inside a tap or a swipe; tests pass one that does not wait.
    var sleep: @Sendable (Double) async -> Void = { seconds in
        try? await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded())))
    }

    init(center: @escaping @MainActor () -> SimulatorCenter, approvals: SimulatorApprovals,
         drivers: [SimulatorPlatform: any SimulatorDeviceDriving] = [:]) {
        self.center = center
        self.approvals = approvals
        self.drivers = drivers
    }

    func run(tool: String, arguments: ToolJSON, task: UUID) async -> AgentToolResult {
        guard center().isEnabled else { return Self.featureOff }
        switch tool {
        case SimulatorToolCatalog.list: return await list(for: task)
        case SimulatorToolCatalog.attach: return await attach(arguments, task: task)
        case SimulatorToolCatalog.detach: return detach(task)
        case SimulatorToolCatalog.screenshot, SimulatorToolCatalog.tap, SimulatorToolCatalog.swipe,
             SimulatorToolCatalog.type, SimulatorToolCatalog.press:
            return await act(tool, arguments, task: task)
        default: return .error("Unknown Yardlet tool: \(tool)")
        }
    }

    /// The task went away: a real device's approval for it goes too.
    func taskRemoved(_ task: UUID) {
        approvals.taskRemoved(task)
    }

    // MARK: - simulator_list

    private func list(for task: UUID) async -> AgentToolResult {
        let center = center()
        await center.refreshDevices()
        let devices: [ToolJSON] = center.entries(for: task).map { entry in
            var fields: [String: ToolJSON] = [
                "device": .string(entry.device.toolID),
                "platform": .string(Self.platformName(entry.device.platform)),
                "name": .string(entry.device.name),
                "os": .string(entry.device.osName),
                "state": .string(Self.stateName(entry.device.state)),
                "realDevice": .bool(entry.device.identity.kind.isPhysical),
                "attached": .bool(entry.isAttachedHere),
                "startedByYardlet": .bool(entry.isStartedByYardlet),
                "shown": .bool(entry.isShown)
            ]
            if let holder = entry.claimingTask {
                fields["usedBy"] = .string(holder == task ? "this task" : taskTitle(holder) ?? "another task")
            }
            return .object(fields)
        }
        var note = devices.isEmpty ? "No simulator or emulator is listed." : "Attach one with simulator_attach to use it."
        let missing = Self.unavailablePlatforms(center)
        if !missing.isEmpty { note += " " + missing }
        return .text(SessionToolText.json(ToolJSON.object(["devices": .array(devices), "note": .string(note)])))
    }

    // MARK: - simulator_attach

    private func attach(_ arguments: ToolJSON, task: UUID) async -> AgentToolResult {
        let center = center()
        guard let query = arguments["device"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return Self.invalid("device names the device to attach: its id or name from simulator_list.")
        }
        let device: SimulatorDevice
        switch await center.resolve(query) {
        case let .success(found): device = found
        case let .failure(refusal): return refused(refusal, task: task)
        }
        if let refusal = center.attachRefusal(device.identity, to: task, by: .agent) {
            return refused(refusal, task: task)
        }
        if let declined = await approval(of: device, for: task) { return declined }
        switch await center.attach(device.identity, to: task, by: .agent) {
        case let .refused(refusal):
            return refused(refusal, task: task)
        case let .failed(device, message):
            return Self.didNotStart(device, message)
        case let .attached(attachment):
            var lines = ["Attached \(attachment.device.name) (\(attachment.device.osName)) to this task. "
                + "Its id is \(attachment.device.toolID): \(Self.ownToolsLine(attachment.device))"]
            switch await screen(of: attachment.device) {
            case let .success(screen):
                let units = Self.units(attachment.device.platform)
                lines.append("Its screen is \(screen.width)×\(screen.height) \(units): simulator_screenshot images are "
                    + "this size, and the x and y of simulator_tap and simulator_swipe are positions in them.")
            case let .failure(error):
                lines.append("Yardlet cannot show or drive its screen: \(error.message)")
            }
            lines.append(Self.originLine(attachment))
            switch showPanel(task) {
            case .shown: lines.append("The task's side panel shows it.")
            case .besidePersonsTab:
                lines.append("The person is using another tab of the task's side panel, so a Simulator tab was added "
                    + "beside it and the panel stays on theirs.")
            case .notShown: break
            }
            if let person = personNote(attachment.device) { lines.append(person) }
            return .text(lines.joined(separator: "\n"))
        }
    }

    // MARK: - simulator_detach

    private func detach(_ task: UUID) -> AgentToolResult {
        let center = center()
        guard let identity = center.attachment(of: task) else { return .text("This task has no attached device.") }
        let device = center.device(identity)
        let wasStarted = center.startedByYardlet[identity] != nil
        center.detach(task)
        if let device, center.attachment(of: task) == nil, !center.claims.keys.contains(identity) {
            drivers[device.platform]?.release(device)
        }
        var text = "Let go of \(device?.name ?? identity.value)."
        if wasStarted {
            text += " As Yardlet started it, it shuts down 10 minutes after no task attaches it."
        }
        return .text(text)
    }

    // MARK: - Tools on the attached device

    private func act(_ tool: String, _ arguments: ToolJSON, task: UUID) async -> AgentToolResult {
        let center = center()
        guard let identity = center.attachment(of: task) else { return await notAttached(task) }
        if let invalid = Self.checkWithoutScreen(tool, arguments) { return invalid }
        // Asked before the device is read again and started if it shut down, which `prepareAttachedDevice` does.
        let known = center.device(identity)
            ?? SimulatorDevice(identity: identity, name: identity.value, state: .off, osName: "", osVersion: "")
        if let declined = await approval(of: known, for: task) { return declined }
        let attachment: SimulatorAttachment
        switch await center.prepareAttachedDevice(for: task) {
        case let .attached(prepared): attachment = prepared
        case let .refused(refusal): return refused(refusal, task: task)
        case let .failed(device, message): return Self.didNotStart(device, message)
        }
        let device = attachment.device
        guard let driver = drivers[device.platform] else { return Self.noDriver(device) }
        let screen: SimulatorToolScreen
        switch await self.screen(of: device) {
        case let .success(found): screen = found
        case let .failure(error):
            return .failure("Yardlet cannot reach \(device.name)'s screen: \(error.message)", .unreachable, retry: .later)
        }
        var result: AgentToolResult
        do {
            result = try await perform(tool, arguments, on: device, screen: screen, driver: driver)
        } catch let error as SimulatorDriveError {
            result = .failure("\(tool) did not finish on \(device.name): \(error.message)", .outcomeUnknown,
                              retry: .afterChecking)
        } catch {
            result = .failure("\(tool) did not finish on \(device.name): \(error.localizedDescription)", .outcomeUnknown,
                              retry: .afterChecking)
        }
        center.noteToolUse(for: task)
        var notes: [String] = []
        if attachment.startedNow {
            notes.append("Yardlet started \(device.name) again first: it had shut down while unused.")
        }
        if let person = personNote(device) { notes.append(person) }
        if !notes.isEmpty { result.content.append(.text(notes.joined(separator: " "))) }
        return result
    }

    private func perform(_ tool: String, _ arguments: ToolJSON, on device: SimulatorDevice, screen: SimulatorToolScreen,
                         driver: any SimulatorDeviceDriving) async throws -> AgentToolResult {
        let units = Self.units(device.platform)
        switch tool {
        case SimulatorToolCatalog.screenshot:
            let format = SimulatorToolImageFormat(rawValue: arguments["format"]?.stringValue ?? "png") ?? .png
            let image = try await driver.screenshot(of: device, format: format)
            return AgentToolResult(content: [
                .image(data: image.data.base64EncodedString(), mimeType: "image/\(format.rawValue)"),
                .text("Screenshot of \(device.name), \(image.width)×\(image.height) \(units).")
            ])
        case SimulatorToolCatalog.tap:
            guard let x = Self.number(arguments["x"]), let y = Self.number(arguments["y"]),
                  let point = SimulatorScreenFraction(x: x, y: y, on: screen) else {
                return Self.offScreen(screen, units: units)
            }
            let duration = Self.number(arguments["duration"])
            try driver.touch(.down, at: point, on: device)
            await sleep(duration ?? Self.tapHold)
            try driver.touch(.up, at: point, on: device)
            let place = "(\(BrowserAgentTools.format(x)), \(BrowserAgentTools.format(y)))"
            if let duration, duration > SimulatorToolCatalog.longPress {
                return .text("Long-pressed \(place) on \(device.name) for \(BrowserAgentTools.format(duration)) seconds.")
            }
            return .text("Tapped \(place) on \(device.name).")
        case SimulatorToolCatalog.swipe:
            guard let x = Self.number(arguments["x"]), let y = Self.number(arguments["y"]),
                  let x2 = Self.number(arguments["x2"]), let y2 = Self.number(arguments["y2"]),
                  let from = SimulatorScreenFraction(x: x, y: y, on: screen),
                  let to = SimulatorScreenFraction(x: x2, y: y2, on: screen) else {
                return Self.offScreen(screen, units: units)
            }
            let duration = Self.number(arguments["duration"]) ?? SimulatorToolCatalog.defaultSwipeDuration
            try await swipe(from: from, to: to, over: duration, on: device, driver: driver)
            let path = "(\(BrowserAgentTools.format(x)), \(BrowserAgentTools.format(y))) to "
                + "(\(BrowserAgentTools.format(x2)), \(BrowserAgentTools.format(y2)))"
            return .text("Swiped from \(path) on \(device.name) over \(BrowserAgentTools.format(duration)) seconds.")
        case SimulatorToolCatalog.type:
            let text = arguments["text"]?.stringValue ?? ""
            if arguments["method"]?.stringValue == "keys" {
                try await driver.typeKeys(text, on: device)
                return .text("Typed \(text.count) characters on \(device.name)'s hardware keyboard. They go in as "
                    + "written only while its keyboard is set to English; take a screenshot to check.")
            }
            guard let toolchain = center().toolchain(for: device.platform) else { return Self.noDriver(device) }
            do {
                try await driver.paste(text, on: device, with: toolchain)
            } catch let error as SimulatorDriveError {
                return .failure("Yardlet could not use \(device.name)'s clipboard, so nothing was entered: "
                    + "\(error.message). method keys types ASCII text on its hardware keyboard instead.",
                    .unreachable, retry: .withChanges)
            }
            return .text("Pasted \(text.count) characters into \(device.name)'s focused field. A field that refuses a "
                + "paste stays as it was; method keys types instead.")
        case SimulatorToolCatalog.press:
            let count = Self.integer(arguments["count"]) ?? 1
            if let name = arguments["button"]?.stringValue, let button = SimulatorToolButton(rawValue: name) {
                guard driver.buttons.contains(button) else {
                    return Self.invalid("\(device.name) has no \(name) button. \(Self.platformName(device.platform)) "
                        + "devices have \(driver.buttons.map(\.rawValue).joined(separator: ", ")).")
                }
                for _ in 0..<count { try await driver.press(button, on: device) }
                return .text("Pressed \(name)\(count > 1 ? " \(count) times" : "") on \(device.name).")
            }
            let name = arguments["key"]?.stringValue ?? ""
            guard let key = SimulatorToolKey(rawValue: name) else { return Self.invalid("Give a button or a key.") }
            for _ in 0..<count { try await driver.press(key, on: device) }
            return .text("Pressed \(name)\(count > 1 ? " \(count) times" : "") on \(device.name).")
        default:
            return .error("Unknown Yardlet tool: \(tool)")
        }
    }

    /// One finger down at `from`, moved in even steps to `to` over the duration, and lifted there.
    private func swipe(from: SimulatorScreenFraction, to: SimulatorScreenFraction, over duration: Double,
                       on device: SimulatorDevice, driver: any SimulatorDeviceDriving) async throws {
        let steps = max(1, min(Int((duration / Self.swipeStep).rounded()), 1_000))
        try driver.touch(.down, at: from, on: device)
        for step in 1...steps {
            await sleep(duration / Double(steps))
            let progress = Double(step) / Double(steps)
            let point = SimulatorScreenFraction(fractionX: from.x + (to.x - from.x) * progress,
                                                y: from.y + (to.y - from.y) * progress)
            try driver.touch(.move, at: point, on: device)
        }
        try driver.touch(.up, at: to, on: device)
    }

    // MARK: - Checks

    /// The arguments that need no screen to check: durations, counts, text, names. Positions are checked against the
    /// screen once it is known.
    static func checkWithoutScreen(_ tool: String, _ arguments: ToolJSON) -> AgentToolResult? {
        if arguments["duration"] != nil {
            guard let duration = number(arguments["duration"]),
                  (0...SimulatorToolCatalog.longestDuration).contains(duration) else {
                return invalid("duration is in seconds, from 0 to 10.")
            }
        }
        switch tool {
        case SimulatorToolCatalog.screenshot:
            if let format = arguments["format"]?.stringValue, SimulatorToolImageFormat(rawValue: format) == nil {
                return invalid("format is png or jpeg.")
            }
        case SimulatorToolCatalog.type:
            let text = arguments["text"]?.stringValue ?? ""
            guard !text.isEmpty else { return invalid("text is empty; give the text to enter.") }
            guard text.count <= SimulatorToolCatalog.longestText else {
                return invalid("text has \(text.count) characters, and one call enters at most 1,000. Send the rest in "
                    + "another call.")
            }
            switch arguments["method"]?.stringValue {
            case nil, "paste": break
            case "keys":
                if let other = text.unicodeScalars.first(where: { !isTypableASCII($0) }) {
                    return invalid("method keys types ASCII only (letters, digits, punctuation, spaces, tabs and new "
                        + "lines), and this text has “\(Character(other))”. method paste enters any text.")
                }
            default: return invalid("method is paste or keys.")
            }
        case SimulatorToolCatalog.press:
            let button = arguments["button"]?.stringValue
            let key = arguments["key"]?.stringValue
            guard (button == nil) != (key == nil) else {
                return invalid("Give a button or a key, not both: buttons are "
                    + "\(SimulatorToolCatalog.buttons.joined(separator: ", ")); keys are "
                    + "\(SimulatorToolCatalog.keys.joined(separator: ", ")).")
            }
            if let button, SimulatorToolButton(rawValue: button) == nil {
                return invalid("button is one of \(SimulatorToolCatalog.buttons.joined(separator: ", ")).")
            }
            if let key, SimulatorToolKey(rawValue: key) == nil {
                return invalid("key is one of \(SimulatorToolCatalog.keys.joined(separator: ", ")).")
            }
            if arguments["count"] != nil {
                guard let count = integer(arguments["count"]), (1...SimulatorToolCatalog.mostPresses).contains(count) else {
                    return invalid("count is from 1 to 50.")
                }
            }
        default:
            break
        }
        return nil
    }

    /// A character the hardware keyboard types from a US layout: printable ASCII, a tab or a new line.
    static func isTypableASCII(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value) || scalar == "\n" || scalar == "\t"
    }

    /// A number given as JSON's number or integer, or as a string of one.
    static func number(_ value: ToolJSON?) -> Double? {
        switch value {
        case let .number(number): number.isFinite ? number : nil
        case let .integer(integer): Double(integer)
        case let .string(string): Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: nil
        }
    }

    static func integer(_ value: ToolJSON?) -> Int? {
        guard let number = number(value), number.rounded() == number, abs(number) < 1e9 else { return nil }
        return Int(number)
    }

    // MARK: - Approval

    /// Asks the person when they have not let this task use the device yet; nil when the tool may go ahead.
    private func approval(of device: SimulatorDevice, for task: UUID) async -> AgentToolResult? {
        guard !approvals.isApproved(device.identity, for: task) else { return nil }
        guard await askPerson(device, task) else {
            return .failure("The person did not allow this task to use \(device.name), so nothing was done.",
                            .refused, retry: .no)
        }
        approvals.approve(device.identity, for: task)
        return nil
    }

    // MARK: - Results

    private func screen(of device: SimulatorDevice) async -> Result<SimulatorToolScreen, SimulatorDriveError> {
        guard let driver = drivers[device.platform], let toolchain = center().toolchain(for: device.platform) else {
            return .failure(SimulatorDriveError(message: "this Yardlet cannot show \(Self.platformName(device.platform)) "
                + "screens"))
        }
        do {
            return .success(try await driver.prepare(device, with: toolchain))
        } catch let error as SimulatorDriveError {
            return .failure(error)
        } catch {
            return .failure(SimulatorDriveError(message: error.localizedDescription))
        }
    }

    private func personNote(_ device: SimulatorDevice) -> String? {
        guard let last = lastPersonInput(device.identity) else { return nil }
        let seconds = max(0, now().timeIntervalSince(last))
        guard seconds < Self.personUseWindow else { return nil }
        let when = seconds < 2 ? "just now" : "\(Int(seconds)) seconds ago"
        return "The person is using \(device.name) in a Simulator tab (their last input was \(when)), so your input "
            + "mixes with theirs."
    }

    private func notAttached(_ task: UUID) async -> AgentToolResult {
        let center = center()
        await center.refreshDevices()
        let entries = center.entries(for: task)
        var message = "This task has no attached device. Attach one with simulator_attach first"
        if entries.isEmpty {
            message += "; no simulator or emulator is listed."
        } else {
            let shown = entries.prefix(Self.listedDeviceLimit).map { entry in
                "\(entry.device.name) (\(entry.device.osName), \(Self.stateName(entry.device.state)), id "
                    + "\(entry.device.toolID))"
            }
            message += ": " + shown.joined(separator: "; ")
            if entries.count > Self.listedDeviceLimit {
                message += "; and \(entries.count - Self.listedDeviceLimit) more, which simulator_list lists"
            }
            message += "."
        }
        return .failure(message, .notFound, retry: .withChanges,
                        details: ["next": .string(SimulatorToolCatalog.attach)])
    }

    private func refused(_ refusal: SimulatorRefusal, task: UUID) -> AgentToolResult {
        let free = refusal.freeRunningDevices.prefix(Self.listedDeviceLimit).map { "\($0.name) (id \($0.toolID))" }
        let freeLine = free.isEmpty ? "" : " Devices that are on and free: \(free.joined(separator: ", "))."
        switch refusal.reason {
        case .disabled:
            return Self.featureOff
        case let .unknownDevice(query):
            return .failure("No listed device has the id or name \(query). simulator_list lists them.\(freeLine)",
                            .notFound, retry: .withChanges)
        case let .ambiguousDevice(query, matches):
            let named = matches.prefix(Self.listedDeviceLimit).map {
                "\($0.name) (\($0.osName), id \($0.toolID))"
            }
            return .failure("More than one device is named \(query): \(named.joined(separator: "; ")). Give its id.",
                            .invalidArguments, retry: .withChanges,
                            details: ["devices": .array(matches.map { .string($0.toolID) })])
        case let .unavailable(platform, availability):
            return .failure("\(Self.platformName(platform)) devices cannot be used on this computer: "
                + "\(Self.describe(availability)).", .refused, retry: .no)
        case let .claimedByAnotherTask(holder):
            let title = taskTitle(holder).map { "the task “\($0)”" } ?? "another task"
            return .failure("The agent of \(title) uses this device now, and one task's agent at a time may. The person "
                + "can give it to this task from the Simulator tab's device menu.\(freeLine)", .refused, retry: .later)
        case let .startLimit(limit):
            return .failure("Yardlet already runs \(limit) devices it started for agents, and an agent starts no more. "
                + "Attach a device that is on, or detach one this or another task no longer needs.\(freeLine)",
                            .refused, retry: .withChanges)
        case .notAttached:
            return .failure("This task has no attached device. Attach one with simulator_attach first.", .notFound,
                            retry: .withChanges, details: ["next": .string(SimulatorToolCatalog.attach)])
        }
    }

    private static func didNotStart(_ device: SimulatorDevice, _ message: String) -> AgentToolResult {
        .failure("\(device.name) is attached to this task, but it did not start: \(message). The next simulator tool "
            + "tries again.", .unreachable, retry: .later)
    }

    private static func noDriver(_ device: SimulatorDevice) -> AgentToolResult {
        .failure("This Yardlet cannot drive \(platformName(device.platform)) devices yet; \(device.name) stays attached "
            + "for your own tools.", .refused, retry: .no)
    }

    private static func offScreen(_ screen: SimulatorToolScreen, units: String) -> AgentToolResult {
        .failure("Positions must be on the screen: x from 0 to \(screen.width) and y from 0 to \(screen.height), in "
            + "\(units) of the last simulator_screenshot image.", .invalidArguments, retry: .withChanges,
            details: ["width": .integer(Int64(screen.width)), "height": .integer(Int64(screen.height))])
    }

    private static func invalid(_ message: String) -> AgentToolResult {
        .failure(message, .invalidArguments, retry: .withChanges)
    }

    static let featureOff = AgentToolResult.failure(
        "The Simulator feature is off in Yardlet's settings. The person can turn it on in Settings → General → "
            + "Simulator.", .refused, retry: .no)

    static func ownToolsLine(_ device: SimulatorDevice) -> String {
        switch device.platform {
        case .iOS:
            "pass it to your own build and install tools (xcrun simctl install \(device.toolID) <app>, "
                + "xcrun simctl launch \(device.toolID) <bundle id>, or a build tool's simulator id)."
        case .android:
            "pass it to your own build and install tools (adb -s \(device.toolID) install <apk>)."
        }
    }

    /// Where the attached device came from, and what that means for the agent.
    private static func originLine(_ attachment: SimulatorAttachment) -> String {
        if attachment.isStartedByYardlet { return startedByYardletLine(startedNow: attachment.startedNow) }
        if attachment.device.identity.kind.isPhysical {
            return "It is a real Android device: the person's own accounts may be signed in on it, and Yardlet never "
                + "turns it on or off."
        }
        return "It was started outside Yardlet, so another app or tool may be using it."
    }

    static func startedByYardletLine(startedNow: Bool) -> String {
        (startedNow ? "Yardlet started it for this call" : "Yardlet started it")
            + ", and shuts it down when it goes unused: 30 minutes after the last turn of the tasks that attach it, or "
            + "10 minutes after none does."
    }

    static func units(_ platform: SimulatorPlatform) -> String {
        platform == .iOS ? "points" : "dp"
    }

    static func platformName(_ platform: SimulatorPlatform) -> String {
        platform == .iOS ? "iOS" : "Android"
    }

    static func stateName(_ state: SimulatorDeviceState) -> String {
        switch state {
        case .on: "on"
        case .off: "off"
        case .booting: "booting"
        case .shuttingDown: "shutting down"
        }
    }

    static func describe(_ availability: SimulatorAvailability) -> String {
        switch availability {
        case .available: "available"
        case .xcodeMissing: "Xcode is not installed"
        case .xcodeNotSetUp: "Xcode has not finished its first launch"
        case .runtimeMissing: "no iOS simulator runtime is installed"
        case let .xcodeNotSupportedYet(version): "Yardlet cannot show the screens of Xcode \(version ?? "this version") yet"
        case .sdkMissing: "no Android SDK with adb and the emulator is installed"
        }
    }

    /// What keeps a platform's devices out of the list, for the person to fix.
    private static func unavailablePlatforms(_ center: SimulatorCenter) -> String {
        SimulatorPlatform.allCases.compactMap { platform -> String? in
            guard let check = center.checks[platform], !check.availability.listsDevices else { return nil }
            return "\(platformName(platform)): \(describe(check.availability))."
        }.joined(separator: " ")
    }
}
