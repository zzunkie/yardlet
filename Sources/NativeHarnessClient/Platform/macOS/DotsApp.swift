import AppKit

/// The provider's app that Dots run in: found by its identifier wherever it is installed, and taken only
/// when its bundle says so and claims the scheme of the Dots home. Looking it up launches nothing; the
/// Dots home opens in that app, not in whatever else handles the scheme, only when the person asks. A
/// QA run opens nothing.
@MainActor
enum DotsApp {
    static func location() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DotsLinks.appBundleIdentifier),
              let bundle = Bundle(url: app), bundle.bundleIdentifier == DotsLinks.appBundleIdentifier,
              let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(DotsLinks.appHome.scheme ?? "") == true })
        else { return nil }
        return app
    }

    /// Hands the Dots home to the app. Success means the app took the address, not that it shows any
    /// particular dot or account.
    static func openHome(in app: URL, done: @escaping @MainActor (Bool) -> Void) {
        guard !QABackground.isOn else {
            NSLog("Yardlet QA: not opening the Dots app")
            return done(false)
        }
        NSWorkspace.shared.open([DotsLinks.appHome], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in done(error == nil) }
        }
    }

    /// The dot's page, as a link in a conversation opens: in the Mac's default browser, which may be
    /// Yardlet's own.
    static func openWeb(_ url: URL) -> Bool {
        guard !QABackground.isOn else {
            NSLog("Yardlet QA: not opening a dot's page")
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
