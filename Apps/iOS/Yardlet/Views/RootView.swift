import SwiftUI
import UIKit
import YardletRemote

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// App Lock covers the app while it is locked, and whenever it is not in front with the lock on (the app switcher).
    private var isCovered: Bool { model.lock.isLocked || (model.lock.isEnabled && scenePhase != .active) }

    var body: some View {
        @Bindable var model = model
        Group {
            if let session = model.session {
                HomeView(session: session)
                    .id(session.id)
            } else {
                WelcomeView()
            }
        }
        .background(YardletPalette.background.ignoresSafeArea())
        .tint(YardletPalette.primary)
        .onChange(of: isCovered, initial: true) { _, covered in
            LockCover.shared.show(covered, lock: model.lock)
        }
        // A link opened while the app is locked is asked about once it is unlocked, not over the lock.
        .alert("Connect to this Mac?", isPresented: Binding(get: { model.linkToConfirm != nil && !isCovered },
                                                            set: { if !$0 && !isCovered { model.linkToConfirm = nil } }),
               presenting: model.linkToConfirm) { link in
            Button("Connect") { Task { await model.pair(link) } }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text("This link pairs this phone with \(link.name). Connect only to a Mac you use; it will see this phone's name and can send it notifications.")
        }
        .alert("Couldn't connect", isPresented: Binding(get: { model.pairingError != nil && !isCovered },
                                                       set: { if !$0 && !isCovered { model.pairingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pairingError ?? "")
        }
        // Another device asks the Mac to let it in from the account they share (§12.1, §15.11); any of the Mac's
        // devices may answer, and the first answer wins.
        .alert("A new device wants to connect", isPresented: Binding(get: { linkRequest != nil && !isCovered },
                                                                     set: { _ in }),
               presenting: linkRequest) { request in
            Button("Allow") { model.session?.answerLink(request.id, approve: true) }
            Button("Refuse", role: .cancel) { model.session?.answerLink(request.id, approve: false) }
        } message: { request in
            let device = request.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "A new device")
            Text("Number \(PushNotice.spaced(request.code))") + Text(verbatim: "\n\n")
                + Text("Allow it only if \(device) shows the same number. Refuse a device you don't know.")
        }
    }

    private var linkRequest: HostSession.LinkRequest? { model.session?.linkRequests.first }
}

/// What a locked app shows until the owner unlocks it.
struct LockView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            Text("Yardlet is locked")
                .font(.headline)
                .foregroundStyle(YardletPalette.onSurface)
            if lock.isLocked {
                Button("Unlock") { Task { await lock.unlock() } }
                    .prominentButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YardletPalette.background)
        .tint(YardletPalette.primary)
    }
}

/// App Lock's cover, in a window of its own above the app's, so a sheet or an alert open when the app locked stays
/// under it too.
/// It takes the keyboard's focus with it: whatever was being typed into loses it, so keys pressed while the app is locked
/// go nowhere behind the cover.
@MainActor
final class LockCover {
    static let shared = LockCover()
    private var window: UIWindow?
    private weak var coveredKeyWindow: UIWindow?

    func show(_ covered: Bool, lock: AppLock) {
        guard covered else {
            guard let window, !window.isHidden else { return }
            window.isHidden = true
            coveredKeyWindow?.makeKey()
            return
        }
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: LockView(lock: lock))
            self.window = window
        }
        guard let window, window.isHidden || !window.isKeyWindow else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        coveredKeyWindow = window.windowScene?.keyWindow.flatMap { $0 === window ? nil : $0 }
        window.makeKeyAndVisible()
    }
}
