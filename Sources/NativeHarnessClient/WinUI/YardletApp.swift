import Foundation
import WinSDK
import WinUI
import WinUIApplication

/// The Windows app (docs/PLATFORM_PORTABILITY.md, "The Windows app"): the engine's model, made once
/// WinUI has started, and its main window. `XamlApplication` runs Swift's main actor on the window's
/// thread, so the engine's main-actor code runs as on the Mac.
@main
final class YardletApp: XamlApplication {
    private var mainWindow: MainWindow?

    required init() {
        super.init()
    }

    override func launched() {
        let console = WindowsConsole.makeHidden()
        mainWindow = MainActor.assumeIsolated {
            let attention = WindowsApplicationAttention()
            let model = AppModel.live(applicationAttention: attention)
            // Off until the person turns it on in Settings › Remote, as on the Mac; while off it opens nothing.
            let remote = RemoteControlService.live(model: model)
            model.remoteControl = remote
            Task { await remote.start() }
            let window = MainWindow(model: model, directory: RemoteHostDirectory.live())
            window.open()
            attention.mainWindow = HWND(bitPattern: UInt(window.handle))
            // A click chooses its task after bringing the window forward, so the window shows it on its next turn.
            attention.onBringForward = { [weak window] in
                let shown = window
                Task { @MainActor in shown?.showSelectedTask() }
            }
            QAEventLog.shared.write(console)
            QAEventLog.shared.write("language: \(L10n.windowsLanguageNote)")
            QAHarnessCheck.runIfAsked(model: model)
            return window
        }
    }
}
