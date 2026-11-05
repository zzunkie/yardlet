import Foundation

/// What the server keeps of the browser tabs connections watch (§15.25).
struct RemoteServerTabs {
    /// One connection's watch: a task's tab list, the tab whose frames it takes, and the size it asks the tab to be drawn
    /// at.
    struct Watch {
        var taskID: String
        var tabID: String?
        var maxWidth: Int
        var maxHeight: Int
        var viewport: RemoteTabViewport?
        /// The list the connection was last told of.
        var listed: [RemoteBrowserTab]
        /// A new watch on the same connection starts over: a capture of an older one that ends late is dropped.
        var generation: Int
        /// The tab drew since the last capture began; the first frame needs no drawing.
        var painted = true
        /// The last picture sent: the same picture again is not sent.
        var lastImage: Data?
        /// The watch's input may go on; watching the same tab again keeps it, anything else ends it.
        var permit: RemoteTabPermit
        /// The list alone (`listOnly`): no tab, and saved tabs are listed rather than opened.
        var listOnly = false
        /// A picture of the tab failed and the log said why, once per watch.
        var toldNoPicture = false
    }

    /// One connection's frames, kept across its watches until it closes, so watching again neither skips an
    /// acknowledgement nor starts a capture beside one still running, nor comes sooner than the pace allows.
    struct Flow {
        /// The last frame sent, and when, while the client has yet to acknowledge it.
        var frame = 0
        var sentAt: Date?
        var capturing = false
        /// How long after a capture the next may come: short after a change or input, longer while the picture stays.
        var interval: TimeInterval
        var nextCaptureAt: Date
        var timer: Task<Void, Never>?
    }

    var watches: [UUID: Watch] = [:]
    var flows: [UUID: Flow] = [:]
    var generation = 0
    /// What the bridge was last told is watched.
    var reported: Set<RemoteTabWatch> = []
    /// A task's list is read again at most this often, its changes batched.
    var listTimers: [String: Task<Void, Never>] = [:]
    /// Each connection's input, one after another and apart from its other requests, so letting a tab go never waits
    /// for the input before it.
    var inputs: [UUID: Task<Void, Never>] = [:]
    /// How many of each connection's inputs wait or run, at most `maxPendingTabInputs`.
    var pendingInputs: [UUID: Int] = [:]
    /// When each `tabInput` audit line was last written, by device, task, input kind and result.
    var auditedInputs: [String: Date] = [:]
    var auditedWatches: [String: Date] = [:]
}

/// A task's browser tabs on a connection (§15.25): `watchTab` lists them and starts the watched tab's frames, each frame
/// waits for the one before it to be acknowledged (or for `tabFrameAckTimeout`), a frame goes only when the tab drew
/// something new and at most every `tabFrameInterval` (a tab that draws the same picture again is looked at less and
/// less often, up to `tabFrameIdleInterval`), and this pace belongs to the connection, whatever it watches. `tabInput`
/// reaches only the watched tab, in order, under a permit the watch's end revokes. Everything stops when the
/// connection lets the tab go, watches another, or closes; the bridge is told what is watched, so a tab nobody watches
/// paints, and is sized, as before.
extension RemoteServer {
    static let inputAuditWindow: TimeInterval = 60

    func watchTab(_ requestID: String, taskID: String, tabID: String?, maxWidth: Int?, maxHeight: Int?,
                  viewport: RemoteTabViewport?, listOnly: Bool = false, on id: UUID) async {
        let device = connections[id]?.deviceID
        let listed: [RemoteBrowserTab]
        switch listOnly ? await bridge.browserTabList(taskID: taskID) : await bridge.browserTabs(taskID: taskID) {
        case let .success(found):
            listed = found
        case let .failure(error):
            respond(.failure(requestID, error), to: id)
            auditWatch(device: device, task: taskID, result: error.code.rawValue)
            return
        }
        if let tabID, !listed.contains(where: { $0.tabId == tabID }) {
            respond(.failure(requestID, RemoteError(.notFound, "The task has no such tab")), to: id)
            return
        }
        guard canContinueRequest(on: id, deviceID: device) else {
            respond(.failure(requestID, RemoteError(.notAllowed)), to: id)
            return
        }
        let chosen = listOnly ? nil : tabID ?? listed.first(where: { $0.active == true })?.tabId ?? listed.first?.tabId
        let previous = tabs.watches[id]
        let sameTab = previous.map { $0.taskID == taskID && $0.tabID == chosen && chosen != nil } ?? false
        if !sameTab { previous?.permit.revoke() }
        tabs.generation += 1
        tabs.watches[id] = RemoteServerTabs.Watch(
            taskID: taskID, tabID: chosen,
            maxWidth: min(maxWidth ?? RemoteProtocol.defaultTabFrameWidth, RemoteProtocol.maxTabFrameSide),
            maxHeight: min(maxHeight ?? RemoteProtocol.defaultTabFrameHeight, RemoteProtocol.maxTabFrameSide),
            viewport: viewport, listed: listed, generation: tabs.generation,
            lastImage: sameTab ? previous?.lastImage : nil, permit: sameTab ? previous?.permit ?? RemoteTabPermit() : RemoteTabPermit(),
            listOnly: listOnly)
        // The pace stays the connection's; only a look scheduled for the last watch is redone for this one.
        if tabs.flows[id] == nil {
            tabs.flows[id] = RemoteServerTabs.Flow(interval: configuration.tabFrameInterval, nextCaptureAt: now())
        }
        tabs.flows[id]?.timer?.cancel()
        tabs.flows[id]?.timer = nil
        var response = RemoteResponse(re: requestID)
        response.taskId = taskID
        response.tabId = chosen
        response.tabs = listed
        respond(response, to: id)
        auditWatch(device: device, task: taskID, result: "ok")
        await reportWatchedTabs()
        scheduleTabFrame(on: id)
    }

    func unwatchTab(_ requestID: String, taskID: String, on id: UUID) {
        if tabs.watches[id]?.taskID == taskID { endTabWatch(on: id, closing: false) }
        respond(RemoteResponse(re: requestID), to: id)
    }

    /// Any frame of the connection's, by its number: one sent under a watch it has since replaced counts too.
    func acknowledgeTabFrame(_ requestID: String, taskID: String, tabID: String, frame: Int, on id: UUID) {
        if var flow = tabs.flows[id], flow.sentAt != nil, flow.frame == frame {
            flow.sentAt = nil
            // A look waiting for this acknowledgement can come now.
            flow.timer?.cancel()
            flow.timer = nil
            tabs.flows[id] = flow
            scheduleTabFrame(on: id)
        }
        respond(RemoteResponse(re: requestID), to: id)
    }

    /// Checks the input and queues it behind the connection's earlier input; the request handling goes on meanwhile.
    func tabInput(_ requestID: String, taskID: String, tabID: String, input: RemoteTabInput, on id: UUID) {
        let device = connections[id]?.deviceID
        let refusal: RemoteError? = if let problem = input.problem {
            problem
        } else if let watch = tabs.watches[id], watch.taskID == taskID, watch.tabID == tabID {
            nil
        } else {
            RemoteError(.notAllowed, "Watch the tab first")
        }
        if let refusal {
            respond(.failure(requestID, refusal), to: id)
            auditInput(device: device, task: taskID, kind: input.kind.rawValue, result: refusal.code.rawValue)
            return
        }
        guard let permit = tabs.watches[id]?.permit else { return }
        // Input waiting behind a slow page is bounded too, beside the messages the connection may hold (§7).
        guard tabs.pendingInputs[id, default: 0] < RemoteProtocol.maxPendingTabInputs else {
            respond(.failure(requestID, RemoteError(.rateLimited, "Too much input waits for the page")), to: id)
            auditInput(device: device, task: taskID, kind: input.kind.rawValue, result: RemoteErrorCode.rateLimited.rawValue)
            return
        }
        tabs.pendingInputs[id, default: 0] += 1
        let earlier = tabs.inputs[id]
        tabs.inputs[id] = Task { [weak self] in
            await earlier?.value
            await self?.performTabInput(requestID, taskID: taskID, tabID: tabID, input: input, permit: permit,
                                        device: device, on: id)
        }
    }

    private func performTabInput(_ requestID: String, taskID: String, tabID: String, input: RemoteTabInput,
                                 permit: RemoteTabPermit, device: String?, on id: UUID) async {
        defer { if let left = tabs.pendingInputs[id] { tabs.pendingInputs[id] = left > 1 ? left - 1 : nil } }
        let error = permit.isValid ? await bridge.tabInput(taskID: taskID, tabID: tabID, input: input, permit: permit)
            : RemoteError(.notAllowed, "The watch ended")
        respond(error.map { .failure(requestID, $0) } ?? RemoteResponse(re: requestID), to: id)
        auditInput(device: device, task: taskID, kind: input.kind.rawValue, result: error?.code.rawValue ?? "ok")
        // What the input does shows soon: the next look comes at the short interval again.
        guard error == nil, tabs.watches[id]?.tabID == tabID, var flow = tabs.flows[id] else { return }
        flow.interval = configuration.tabFrameInterval
        flow.nextCaptureAt = min(flow.nextCaptureAt, now().addingTimeInterval(configuration.tabFrameInterval))
        if flow.timer != nil, !flow.capturing, flow.sentAt == nil {
            flow.timer?.cancel()
            flow.timer = nil
        }
        tabs.flows[id] = flow
        scheduleTabFrame(on: id)
    }

    /// The connection let its watch go (`closing` false: its pace stays, for a watch that follows), or closed.
    func endTabWatch(on id: UUID, closing: Bool = true) {
        let watch = tabs.watches.removeValue(forKey: id)
        watch?.permit.revoke()
        tabs.flows[id]?.timer?.cancel()
        tabs.flows[id]?.timer = nil
        if closing {
            tabs.flows[id] = nil
            tabs.inputs[id] = nil
            tabs.pendingInputs[id] = nil
        }
        if watch != nil { Task { await self.reportWatchedTabs() } }
    }

    // MARK: - Frames

    func tabPainted(taskID: String, tabID: String) {
        for (id, watch) in tabs.watches where watch.taskID == taskID && watch.tabID == tabID {
            tabs.watches[id]?.painted = true
            scheduleTabFrame(on: id)
        }
    }

    /// Looks at the tab again once the last frame is acknowledged (or its acknowledgement is overdue), the tab drew
    /// since, and the connection's interval passed.
    private func scheduleTabFrame(on id: UUID) {
        guard let watch = tabs.watches[id], watch.tabID != nil, watch.painted, let flow = tabs.flows[id], !flow.capturing,
              flow.timer == nil else { return }
        var wakeAt = flow.nextCaptureAt
        if let sentAt = flow.sentAt { wakeAt = max(wakeAt, sentAt.addingTimeInterval(configuration.tabFrameAckTimeout)) }
        let delay = max(0, wakeAt.timeIntervalSince(now()))
        let generation = watch.generation
        tabs.flows[id]?.timer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.captureTabFrame(on: id, generation: generation)
        }
    }

    private func captureTabFrame(on id: UUID, generation: Int) async {
        tabs.flows[id]?.timer = nil
        guard var watch = tabs.watches[id], watch.generation == generation, let tabID = watch.tabID,
              var flow = tabs.flows[id], !flow.capturing else { return }
        if let sentAt = flow.sentAt {
            // Still due: an acknowledgement reschedules; otherwise this look waits out the timeout.
            guard now() >= sentAt.addingTimeInterval(configuration.tabFrameAckTimeout) else {
                scheduleTabFrame(on: id)
                return
            }
            flow.sentAt = nil
        }
        flow.capturing = true
        // The slot is taken when the look begins, whatever comes of it, so no watch looks again sooner.
        flow.nextCaptureAt = now().addingTimeInterval(configuration.tabFrameInterval)
        watch.painted = false
        tabs.flows[id] = flow
        tabs.watches[id] = watch
        let result = await bridge.captureTab(taskID: watch.taskID, tabID: tabID, maxWidth: watch.maxWidth,
                                             maxHeight: watch.maxHeight)
        tabs.flows[id]?.capturing = false
        guard var current = tabs.watches[id], current.generation == generation, current.tabID == tabID,
              var pace = tabs.flows[id] else {
            // The watch changed meanwhile: its own look follows.
            scheduleTabFrame(on: id)
            return
        }
        let time = now()
        switch result {
        case let .success(frame) where frame.image == current.lastImage || frame.image.count > RemoteProtocol.maxTabFrameBytes:
            // Nothing new to show (or too large to send): looked at less often until the tab changes.
            pace.interval = min(pace.interval * 2, configuration.tabFrameIdleInterval)
            pace.nextCaptureAt = time.addingTimeInterval(pace.interval)
        case let .success(frame):
            pace.frame += 1
            pace.sentAt = time
            current.lastImage = frame.image
            pace.interval = configuration.tabFrameInterval
            pace.nextCaptureAt = time.addingTimeInterval(pace.interval)
            var event = RemoteEvent(.tabFrame)
            event.taskId = current.taskID
            event.tabId = tabID
            event.frame = pace.frame
            event.image = frame.image
            event.mediaType = frame.mediaType
            event.width = frame.width
            event.height = frame.height
            event.viewportWidth = frame.viewportWidth
            event.viewportHeight = frame.viewportHeight
            send(event, to: id)
        case let .failure(error):
            // A page that cannot be pictured now (a dialog over it, its renderer gone, a file outside the task's): tried
            // again later. The client waits for a picture meanwhile, so the log says why, once per watch.
            if !current.toldNoPicture, let connection = connections[id] {
                current.toldNoPicture = true
                RemoteLog.notice("Remote: \(Self.describe(connection)) gets no picture of the tab it watches: \(error.message)")
            }
            current.painted = true
            pace.interval = configuration.tabFrameIdleInterval
            pace.nextCaptureAt = time.addingTimeInterval(pace.interval)
        }
        tabs.watches[id] = current
        tabs.flows[id] = pace
        scheduleTabFrame(on: id)
    }

    // MARK: - The list

    /// A watched task's tabs may have changed: read again shortly, batched, and tell the connections that watch it.
    func browserTabsChanged(_ taskID: String) {
        guard tabs.listTimers[taskID] == nil, tabs.watches.values.contains(where: { $0.taskID == taskID }) else { return }
        let interval = configuration.tasksInterval
        tabs.listTimers[taskID] = Task { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.refreshBrowserTabs(taskID)
        }
    }

    private func refreshBrowserTabs(_ taskID: String) async {
        tabs.listTimers[taskID] = nil
        guard tabs.watches.values.contains(where: { $0.taskID == taskID }) else { return }
        // Saved tabs open again only for a watch of a tab, as its `watchTab` opened them.
        let opening = tabs.watches.values.contains { $0.taskID == taskID && !$0.listOnly }
        let listed = (try? await (opening ? bridge.browserTabs(taskID: taskID) : bridge.browserTabList(taskID: taskID)).get()) ?? []
        var watchesChanged = false
        for (id, watch) in tabs.watches where watch.taskID == taskID && watch.listed != listed {
            tabs.watches[id]?.listed = listed
            // A tab that closed has no more frames or input; the client watches another.
            if let tabID = watch.tabID, !listed.contains(where: { $0.tabId == tabID }) {
                watch.permit.revoke()
                tabs.watches[id]?.tabID = nil
                tabs.flows[id]?.timer?.cancel()
                tabs.flows[id]?.timer = nil
                watchesChanged = true
            }
            var event = RemoteEvent(.browserTabsChanged)
            event.taskId = taskID
            event.tabs = listed
            send(event, to: id)
        }
        if watchesChanged { await reportWatchedTabs() }
    }

    func reportWatchedTabs() async {
        let watched = Set(tabs.watches.values.map {
            RemoteTabWatch(taskID: $0.taskID, tabID: $0.tabID, viewport: $0.tabID == nil ? nil : $0.viewport)
        })
        guard watched != tabs.reported else { return }
        tabs.reported = watched
        await bridge.setWatchedTabs(watched)
    }

    private func auditWatch(device: String?, task: String, result: String) {
        let time = now()
        tabs.auditedWatches = tabs.auditedWatches.filter { time.timeIntervalSince($0.value) < Self.inputAuditWindow }
        let key = [device ?? "", task, result].joined(separator: "\u{0}")
        guard tabs.auditedWatches[key] == nil else { return }
        tabs.auditedWatches[key] = time
        audit?.record(device: device, type: "watchTab", task: task, result: result, at: time)
    }

    /// The audit log gets the kind of input and its task, never what was typed, the same line at most once a minute.
    private func auditInput(device: String?, task: String, kind: String, result: String) {
        let time = now()
        tabs.auditedInputs = tabs.auditedInputs.filter { time.timeIntervalSince($0.value) < Self.inputAuditWindow }
        let key = [device ?? "", task, kind, result].joined(separator: "\u{0}")
        guard tabs.auditedInputs[key] == nil else { return }
        tabs.auditedInputs[key] = time
        audit?.record(device: device, type: "tabInput", task: task, input: kind, result: result, at: time)
    }
}
