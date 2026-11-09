// Yardlet browser host: runs Chromium (CEF, windowless) outside Yardlet so that closing the
// browser panel can end every Chromium process. Yardlet starts it with pipes on standard input and
// output and a Mach bootstrap name for IOSurfaces; end of input ends the host.

import AppKit
import Foundation
import IOSurface
import YardletCEFBridge

// An event written after Yardlet is gone fails with EPIPE (EventOutput) instead of ending the host before
// it shuts Chromium down. Chromium ignores SIGPIPE in its processes the same way.
signal(SIGPIPE, SIG_IGN)

let arguments = HostArguments.parse()
let output = EventOutput()
let layout = HostBundleLayout()

// CEF requires NSApp to implement CefAppProtocol, so the subclass must create NSApp first.
let application = YardletBrowserHostApplication.shared
application.setActivationPolicy(.prohibited)

func fail(_ message: String) -> Never {
    output.write(["failed": ["message": message]])
    HostLog.write("Yardlet Browser Host: \(message)")
    exit(1)
}

var loadError = [UInt8](repeating: 0, count: 512)
let loaded = loadError.withUnsafeMutableBufferPointer { buffer in
    buffer.withMemoryRebound(to: CChar.self) {
        yardlet_cef_load(layout.cefBinary.path(percentEncoded: false), $0.baseAddress, $0.count)
    }
}
guard loaded == 1 else { fail(String(decoding: loadError.prefix { $0 != 0 }, as: UTF8.self)) }

let host = MainActor.assumeIsolated { () -> BrowserHost in
    let host = BrowserHost(arguments: arguments, output: output)
    BrowserHost.shared = host
    return host
}
guard MainActor.assumeIsolated({ host.surfaces != nil }) else {
    fail("Mach bootstrap name \(arguments.surfacePortName) was not found")
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

var callbacks = YardletCEFCallbacks(
    event: { tab, kind, text, detail, number in
        let text = string(text), detail = string(detail)
        MainActor.assumeIsolated {
            BrowserHost.shared.event(tab: Int(tab), kind: kind, text: text, detail: detail, number: number)
        }
    },
    devTools: { tab, message, length in
        guard let message else { return }
        let text = String(decoding: UnsafeRawBufferPointer(start: message, count: length), as: UTF8.self)
        MainActor.assumeIsolated { BrowserHost.shared.devTools(tab: Int(tab), message: text) }
    },
    paint: { tab, layer, buffer, width, height in
        guard let buffer else { return }
        MainActor.assumeIsolated {
            BrowserHost.shared.paint(tab: Int(tab), layer: layer, buffer: buffer, width: Int(width), height: Int(height))
        }
    },
    acceleratedPaint: { tab, layer, surface, format in
        guard let surface else { return }
        let ioSurface = Unmanaged<IOSurfaceRef>.fromOpaque(surface).takeUnretainedValue()
        MainActor.assumeIsolated {
            BrowserHost.shared.acceleratedPaint(tab: Int(tab), layer: layer, surface: ioSurface, format: format)
        }
    },
    popupRect: { tab, rect in
        MainActor.assumeIsolated { BrowserHost.shared.popupRect(tab: Int(tab), rect: rect) }
    },
    contextMenu: { tab, menuID, x, y, items, count in
        var values: [[String: Any]] = []
        for index in 0..<Int(count) {
            guard let item = items?[index] else { continue }
            let isSeparator = item.kind == 1
            var value: [String: Any] = [
                "title": item.title.map { String(cString: $0) } ?? "",
                "isEnabled": item.isEnabled != 0 && item.kind != 4,
                "isChecked": item.isChecked != 0
            ]
            if !isSeparator { value["commandID"] = Int(item.commandID) }
            values.append(value)
        }
        nonisolated(unsafe) let items = values
        MainActor.assumeIsolated {
            BrowserHost.shared.contextMenu(tab: Int(tab), menuID: menuID, x: x, y: y, items: items)
        }
    },
    compositionBounds: { tab, rects, count in
        let values = (0..<Int(count)).compactMap { rects?[$0] }
        MainActor.assumeIsolated { BrowserHost.shared.compositionBounds(tab: Int(tab), rects: values) }
    },
    javaScriptDialog: { tab, id, kind, message, defaultPrompt, origin, isReload in
        let message = string(message) ?? "", prompt = string(defaultPrompt) ?? "", origin = string(origin) ?? ""
        MainActor.assumeIsolated {
            BrowserHost.shared.javaScriptDialog(tab: Int(tab), id: id, kind: kind, message: message,
                                                defaultPrompt: prompt, origin: origin, isReload: isReload != 0)
        }
    },
    fileDialog: { tab, id, mode, title, defaultPath, extensions, count in
        let extensions = (0..<Int(count)).compactMap { extensions?[$0].map { String(cString: $0) } }
        let title = string(title) ?? "", defaultPath = string(defaultPath) ?? ""
        MainActor.assumeIsolated {
            BrowserHost.shared.fileDialog(tab: Int(tab), id: id, mode: mode, title: title, defaultPath: defaultPath,
                                          extensions: extensions)
        }
    },
    downloadPath: { tab, id, suggestedName in
        let name = string(suggestedName) ?? "download"
        let path = MainActor.assumeIsolated { BrowserHost.shared.downloadPath(tab: Int(tab), id: id, suggestedName: name) }
        return path.map { strdup($0) }
    },
    download: { tab, id, state, path, received, total in
        let path = string(path) ?? ""
        MainActor.assumeIsolated {
            BrowserHost.shared.download(tab: Int(tab), id: id, state: state, path: path, received: received, total: total)
        }
    },
    findResult: { tab, matches, active, isFinal in
        MainActor.assumeIsolated {
            BrowserHost.shared.findResult(tab: Int(tab), matches: matches, activeMatch: active, isFinal: isFinal != 0)
        }
    },
    accessibility: { tab, kind, json, length in
        guard let json else { return }
        let data = Data(bytes: json, count: length)
        MainActor.assumeIsolated { BrowserHost.shared.accessibility.receive(tab: Int(tab), kind: kind, json: data) }
    },
    scrollOffset: { tab, x, y in
        MainActor.assumeIsolated { BrowserHost.shared.scrollOffset(tab: Int(tab), x: x, y: y) }
    },
    favicon: { tab, url, png, length in
        let data = png.map { Data(bytes: $0, count: length) } ?? Data()
        let url = url.map { String(cString: $0) } ?? ""
        MainActor.assumeIsolated { BrowserHost.shared.favicon(tab: Int(tab), url: url, png: data) }
    },
    permissionPrompt: { tab, id, origin, permissions in
        let origin = string(origin) ?? ""
        MainActor.assumeIsolated {
            BrowserHost.shared.permissionPrompt(tab: Int(tab), id: id, origin: origin, permissions: permissions)
        }
    },
    permissionPromptDismissed: { tab, id in
        MainActor.assumeIsolated { BrowserHost.shared.permissionPromptDismissed(tab: Int(tab), id: id) }
    }
)

let rootCache = arguments.rootCachePath.isEmpty
    ? FileManager.default.temporaryDirectory.appending(path: "Yardlet-Browser-Host-\(getpid())").path(percentEncoded: false)
    : arguments.rootCachePath
let profile = arguments.profilePath.isEmpty ? rootCache + "/Default" : arguments.profilePath
try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
MainActor.assumeIsolated { host.profiles = TaskProfiles(rootCache: rootCache, defaultProfile: profile) }
try? FileManager.default.createDirectory(atPath: rootCache + "/Logs", withIntermediateDirectories: true)
let usesLoginKeychain = CookieKeychain.usesLoginKeychain()
let switches = CookieKeychain.switches(arguments.switches, usesLoginKeychain: usesLoginKeychain)
HostLog.write("Yardlet Browser Host: cookie key in "
    + (usesLoginKeychain ? "the login keychain (Developer ID)" : "the mock keychain"))

let initialized = layout.cefFramework.path(percentEncoded: false).withCString { framework in
    layout.hostBundle.path(percentEncoded: false).withCString { bundle in
        layout.helperExecutable.path(percentEncoded: false).withCString { helper in
            rootCache.withCString { cache in
                (rootCache + "/Logs/chromium.log").withCString { log in
                    switches.withCString { switches in
                        profile.withCString { profilePath in
                            arguments.locale.withCString { locale in
                                arguments.acceptLanguages.withCString { languages in
                                    var configuration = YardletCEFConfiguration(
                                        frameworkDirectory: framework, mainBundlePath: bundle,
                                        helperExecutablePath: helper, rootCachePath: cache,
                                        profilePath: profilePath, locale: locale, acceptLanguages: languages,
                                        logFile: log, noSandbox: 0, extraSwitches: switches
                                    )
                                    return yardlet_cef_initialize(&configuration, &callbacks)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
guard initialized == 1 else { fail("cef_initialize returned \(initialized)") }
#if DEBUG
if arguments.browserLimit > 0 { yardlet_cef_set_browser_limit(arguments.browserLimit) }
#endif

CommandReader.start(
    onCommand: { data in
        DispatchQueue.main.async { MainActor.assumeIsolated { BrowserHost.shared.receive(data) } }
    },
    onEnd: {
        DispatchQueue.main.async { MainActor.assumeIsolated { BrowserHost.shared.shutdown() } }
    }
)
// SIGTERM (logout, `kill`) ends the host in the same order as the end of input. CEF's signal handlers
// stay off (disable_signal_handlers), so without this it would end the host at once, before its
// browsers close and CefShutdown runs. A handler rather than SIG_IGN: Chromium's processes inherit
// an ignored signal, and Chromium ends them with SIGTERM; a caught one returns to its default there.
signal(SIGTERM) { _ in }
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSignal.setEventHandler { MainActor.assumeIsolated { BrowserHost.shared.shutdown() } }
terminationSignal.resume()

yardlet_cef_run_message_loop()
yardlet_cef_shutdown()
let statistics = MainActor.assumeIsolated { BrowserHost.shared.statistics() }
HostLog.write("Yardlet Browser Host statistics: \(statistics)")
if arguments.rootCachePath.isEmpty { try? FileManager.default.removeItem(atPath: rootCache) }
exit(0)
