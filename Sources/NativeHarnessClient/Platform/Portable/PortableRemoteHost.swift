import Foundation
import YardletRemote

extension RemoteHostPlatform {
    /// The relay alone: no direct-path listener, interfaces or network watch, and nothing kept awake. The relay the
    /// build carries is in files beside its executable. The Windows app has its own
    /// (Platform/Windows/WindowsRemoteHost.swift).
    static var current: RemoteHostPlatform {
        RemoteHostPlatform(makeListener: { _, _ in nil }, watchNetwork: { _ in nil }, interfaces: { [] },
                           resolveName: { _ in nil }, isOnPower: { false }, holdAwake: { _ in nil },
                           computerName: { ProcessInfo.processInfo.hostName },
                           builtInRelay: { RemoteHostPlatform.relay(besides: Bundle.main.executableURL) })
    }
}
