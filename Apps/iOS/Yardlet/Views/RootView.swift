import SwiftUI
import YardletRemote

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

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
        .overlay {
            if model.lock.isLocked || (model.lock.isEnabled && scenePhase != .active) {
                LockView(lock: model.lock)
            }
        }
        .alert("Connect to this Mac?", isPresented: Binding(get: { model.linkToConfirm != nil },
                                                            set: { if !$0 { model.linkToConfirm = nil } }),
               presenting: model.linkToConfirm) { link in
            Button("Connect") { Task { await model.pair(link) } }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text("This link pairs this phone with \(link.name). Connect only to a Mac you use; it will see this phone's name and can send it notifications.")
        }
        .alert("Couldn't connect", isPresented: Binding(get: { model.pairingError != nil },
                                                       set: { if !$0 { model.pairingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pairingError ?? "")
        }
    }
}

/// What a locked app shows until the owner unlocks it.
struct LockView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Yardlet is locked").font(.headline)
            if lock.isLocked {
                Button("Unlock") { Task { await lock.unlock() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task { await lock.unlock() }
    }
}
