import Foundation
import WinSDK

/// `ApplicationAttention` for the Windows app, as `MacApplicationAttention` is the Dock's: whether a Yardlet window
/// is in front, the main window's taskbar button flashing for a new approval while Yardlet is behind other apps
/// (until the window comes forward, as Windows apps ask for attention), and the main window brought forward for a
/// notification's click. A taskbar badge needs a package identity, which an app without a package does not have,
/// so the count of tasks that need the person shows nowhere.
@MainActor
final class WindowsApplicationAttention: ApplicationAttention {
    /// The main window's handle, once it is open.
    var mainWindow: HWND?
    /// Shows the task the click chose, once the window is forward.
    var onBringForward: (() -> Void)?

    var isActive: Bool { WindowsForeground.isYardlet }

    func setDockBadge(_ label: String?) {}

    func requestAttention() {
        guard let window = ownWindow else { return }
        var flash = FLASHWINFO()
        flash.cbSize = UINT(MemoryLayout<FLASHWINFO>.size)
        flash.hwnd = window
        flash.dwFlags = DWORD(FLASHW_TRAY | FLASHW_TIMERNOFG)
        _ = FlashWindowEx(&flash)
    }

    func bringForward() {
        if let window = ownWindow {
            if IsIconic(window) { _ = ShowWindow(window, SW_RESTORE) }
            _ = SetForegroundWindow(window)
        }
        onBringForward?()
    }

    /// The main window, while it is a window of this process.
    private var ownWindow: HWND? {
        guard let mainWindow, IsWindow(mainWindow) else { return nil }
        var process: DWORD = 0
        _ = GetWindowThreadProcessId(mainWindow, &process)
        return process == GetCurrentProcessId() ? mainWindow : nil
    }
}
