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
        mainWindow = MainActor.assumeIsolated {
            let window = MainWindow(model: AppModel.live())
            window.open()
            return window
        }
    }
}
