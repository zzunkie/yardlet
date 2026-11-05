import Foundation
import Network
import YardletLidSleep
import YardletRemote

extension RemoteHostPlatform {
    /// The Mac's: the v2 listener advertised with Bonjour, the interfaces and the MagicDNS name, network
    /// changes from `NWPathMonitor`, and a process activity that keeps the Mac awake.
    static var current: RemoteHostPlatform {
        RemoteHostPlatform(
            makeListener: { server, identity in
                RemoteSecureListener(server: server, staticKey: identity.noise, advertisement: .of(identity))
            },
            watchNetwork: { changed in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { _ in changed() }
                monitor.start(queue: DispatchQueue(label: "yardlet.remote.paths"))
                return { monitor.cancel() }
            },
            interfaces: RemoteAddressSelection.systemInterfaces,
            resolveName: RemoteAddressSelection.magicDNSName(for:),
            isOnPower: { !PowerConditions.current().onBattery },
            holdAwake: { reason in
                let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: reason)
                return { ProcessInfo.processInfo.endActivity(activity) }
            },
            computerName: { Host.current().localizedName ?? "Mac" },
            builtInRelay: {
                (Bundle.main.object(forInfoDictionaryKey: RemoteControlService.builtInRelayURLKey) as? String).map {
                    ($0, Bundle.main.object(forInfoDictionaryKey: RemoteControlService.builtInRelayAlternateURLKey) as? String)
                }
            })
    }
}

extension RemoteControlService {
    /// The remote for the app: its bridge to the model, its files under `~/.yardlet/remote`, and its
    /// keys in the Keychain.
    static func live(model: AppModel) -> RemoteControlService {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "remote", directoryHint: .isDirectory)
        return RemoteControlService(
            bridge: AppModelRemoteBridge(model: model, makePreview: RemoteImagePreviewMaker.make, browser: RemoteTabBridge.Environment(
                client: AppModel.macBrowserClient, usesMacEditingCommands: true,
                marksTypedSecrets: {
                    let vault = MacAgentToolService.shared.vault
                    return vault.isAllowedBuild && (vault.isEnabled || vault.isWalletEnabled)
                })),
            deviceStore: RemoteDeviceStore(fileURL: folder.appending(path: "devices.json")),
            audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log")),
            identityStore: KeychainRemoteIdentityStore.live(),
            accountToken: KeychainRemoteSecret.accountToken(),
            webSignIn: { url, scheme in try await RemoteAccountSignIn().signIn(at: url, callbackScheme: scheme) })
    }
}
