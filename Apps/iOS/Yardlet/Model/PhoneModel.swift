import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit
import UserNotifications
import YardletRemote

/// The app: the Macs this phone paired with, the one shown now, pairing, the demo, notifications and App Lock.
/// Only one Mac's connection is open at a time, the one on screen, and only while the app is in front.
@MainActor
@Observable
final class PhoneModel {
    static let shared = PhoneModel()

    private(set) var hosts: [RemoteSavedHost] = []
    private(set) var session: HostSession?
    private(set) var isPairing = false
    var pairingError: String?
    /// A pairing link opened from outside the app (the camera, a message): asked about before it pairs.
    var linkToConfirm: RemoteSecurePairingURL?
    /// A task a notification asked to open.
    var taskToOpen: String?
    let lock = AppLock()

    @ObservationIgnored private let store: RemoteHostStore
    @ObservationIgnored private let keys = KeychainClientKeys()
    @ObservationIgnored private var demo: DemoMac?
    /// The app is in front: the scene's first `active` opens the connection, so launching starts it once.
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var pushRegistration: (provider: String, token: String)?

    private var selectedHostID: String {
        get { UserDefaults.standard.string(forKey: "selectedHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedHost") }
    }

    private init() {
        let folder = URL.applicationSupportDirectory.appending(path: "remote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The list is useless without the keys, which stay on this device: keep it out of backups too.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)
        store = RemoteHostStore(fileURL: folder.appending(path: "hosts.json"))
        hosts = store.all().filter { keys.load(hostID: $0.id) != nil }
        if let host = hosts.first(where: { $0.id == selectedHostID }) ?? hosts.first { show(host) }
        #if DEBUG
        // Screenshots and checks without touching the screen: `-demo YES [-openTask <task ID>]` at launch, and
        // `-openLink <pairing link>` as if another app opened it.
        if let link = UserDefaults.standard.string(forKey: "openLink"), let url = URL(string: link) { open(url) }
        // `-turnOnAppLock YES`: the Settings switch's own path, as if turned on a moment after launch.
        if UserDefaults.standard.bool(forKey: "turnOnAppLock") {
            Task { [lock] in
                try? await Task.sleep(for: .seconds(2))
                await lock.setEnabled(true)
            }
        }
        if UserDefaults.standard.bool(forKey: "demo") {
            Task {
                await startDemo()
                taskToOpen = UserDefaults.standard.string(forKey: "openTask")
            }
        }
        #endif
    }

    var isDemo: Bool { session?.isDemo == true }

    static var hello: RemoteHandshakeHello {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return RemoteHandshakeHello(name: UIDevice.current.name, platform: "ios", appVersion: version)
    }

    // MARK: - Macs

    func select(_ hostID: String) {
        guard hostID != session?.id, let host = hosts.first(where: { $0.id == hostID }) else { return }
        show(host)
    }

    private func show(_ host: RemoteSavedHost) {
        guard let key = keys.load(hostID: host.id) else { return }
        endDemo()
        session?.stop()
        let session = HostSession(host: host, clientKey: key, hello: Self.hello, store: store)
        attach(session)
        selectedHostID = host.id
    }

    private func attach(_ session: HostSession) {
        session.pushRegistration = pushRegistration
        session.onPushKey = { [hostID = session.id] key, keyID in
            PushKeys.save(key, keyID: keyID, hostID: hostID)
        }
        self.session = session
        if isActive { session.start() }
    }

    /// Removes a Mac: tells it to forget this phone when it can be reached, then deletes its key and entry.
    func remove(_ hostID: String) async {
        if let session, session.id == hostID {
            if session.isConnected { _ = await session.perform(.forgetDevice) }
            session.stop()
            self.session = nil
        }
        keys.delete(hostID: hostID)
        PushKeys.delete(hostID: hostID)
        store.remove(hostID)
        hosts = store.all()
        if let next = hosts.first { show(next) }
    }

    // MARK: - Pairing

    /// A link from outside the app: shown for confirmation first, since anyone can send a link.
    func open(_ url: URL) {
        guard let link = RemoteSecurePairingURL.parse(url) else { return }
        linkToConfirm = link
    }

    /// A link the person scanned or pasted in the app.
    func pair(_ link: RemoteSecurePairingURL) async {
        guard !isPairing else { return }
        isPairing = true
        pairingError = nil
        defer { isPairing = false }
        let previous = store.host(key: link.macKey)
        let key = RemoteKeyPair.generate()
        do {
            let reply = try await RemoteHostConnection.pair(link, clientKey: key, hello: Self.hello)
            // A Mac paired again: the old key goes, and the Mac forgets the old device when it still can (§12).
            if let previous, let session, session.id == previous.id {
                if session.isConnected { _ = await session.perform(.forgetDevice) }
                session.stop()
                self.session = nil
            }
            var host = previous ?? RemoteSavedHost(name: link.name, hostKey: link.macKey, direct: link.hosts,
                                                   relayURL: link.relayURL, room: link.room)
            host.update(from: reply)
            keys.save(key, hostID: host.id)
            if previous != nil { PushKeys.delete(hostID: host.id) }
            store.save(host)
            hosts = store.all()
            show(host)
            requestNotificationPermission()
        } catch let failure as RemoteClientSocket.Failure {
            pairingError = Self.pairingMessage(failure)
        } catch {
            pairingError = String(localized: "Couldn't connect. Try again.")
        }
    }

    static func pairingMessage(_ failure: RemoteClientSocket.Failure) -> String {
        switch failure.error?.code {
        case .pairingInvalid?, .pairingUnavailable?:
            String(localized: "This code expired or was already used. Show a new one on your Mac and scan it again.")
        case .unsupportedVersion?:
            String(localized: "Update Yardlet on your Mac to connect this phone.")
        case .unavailable?:
            String(localized: "Your Mac is busy with other connections. Try again in a moment.")
        default:
            String(localized: "Can't reach your Mac. Check that Yardlet is running there with Allow remote connections on, and that this phone is on the same Wi-Fi or Connect from outside is on.")
        }
    }

    // MARK: - Demo

    func startDemo() async {
        guard !isPairing else { return }
        isPairing = true
        pairingError = nil
        defer { isPairing = false }
        let demo = DemoMac()
        do {
            let link = try await demo.start()
            let key = RemoteKeyPair.generate()
            let reply = try await RemoteHostConnection.pair(link, clientKey: key, hello: Self.hello)
            var host = RemoteSavedHost(name: link.name, hostKey: link.macKey, direct: link.hosts)
            host.update(from: reply)
            session?.stop()
            self.demo = demo
            attach(HostSession(host: host, clientKey: key, hello: Self.hello, store: nil, isDemo: true))
        } catch {
            Logger(subsystem: "com.zzunkie.yardlet.remote", category: "demo")
                .error("The demo did not start: \(String(describing: error), privacy: .public)")
            await demo.stop()
            pairingError = String(localized: "The demo couldn't start.")
        }
    }

    /// Leaves the demo for the saved Macs, or the first screen when there are none.
    func endDemo() {
        guard let demo else { return }
        session?.stop()
        session = nil
        self.demo = nil
        Task { await demo.stop() }
    }

    func leaveDemo() {
        endDemo()
        if let host = hosts.first(where: { $0.id == selectedHostID }) ?? hosts.first { show(host) }
    }

    // MARK: - App state

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            lock.appCameToFront()
            // Opens the connection closed in the background, or tries an open one again now.
            session?.reconnectNow()
        case .background:
            isActive = false
            // The Mac pushes only to a phone it holds no connection from (§16).
            session?.stop()
            lock.appWentAway()
        default:
            break
        }
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func registeredForPush(token: Data) {
        let registration = (provider: PushEnvironment.provider, token: token.map { String(format: "%02x", $0) }.joined())
        pushRegistration = registration
        session?.pushRegistration = registration
    }

    /// A notification opened: its Mac shown, then its task.
    func openNotification(taskID: String?, hostID: String?) {
        if let hostID, hostID != session?.id { select(hostID) }
        if let taskID { taskToOpen = taskID }
    }
}

/// Which APNs environment this build's pushes come from: a build signed for development reads pushes from the
/// sandbox, TestFlight and App Store builds from production. A development or ad hoc build carries its provisioning
/// profile, whose `aps-environment` says which; a build from the App Store or TestFlight carries none.
enum PushEnvironment {
    static let provider: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "apns" }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "<key>aps-environment</key>") else { return "apns" }
        let rest = text[range.upperBound...].prefix(80)
        return rest.contains("development") ? "apns-sandbox" : "apns"
    }()
}
