import Foundation
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
            let model = AppModel.live()
            let window = MainWindow(model: model, directory: RemoteHostDirectory.live())
            window.open()
            QAEventLog.shared.write(console)
            QAHarnessCheck.runIfAsked(model: model)
            return window
        }
    }
}
