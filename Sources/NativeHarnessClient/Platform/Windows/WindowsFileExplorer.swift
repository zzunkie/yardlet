import Foundation
import WinSDK

/// File Explorer, where the Mac's "Show in Finder" shows a task's or a project's folder: a window on the folder that
/// holds it, with it selected, as Finder shows it.
enum WindowsFileExplorer {
    /// False when Windows did not open File Explorer.
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        let selection = "/select,\"\(url.nativePath)\""
        let result = "open".withCString(encodedAs: UTF16.self) { verb in
            "explorer.exe".withCString(encodedAs: UTF16.self) { program in
                selection.withCString(encodedAs: UTF16.self) { parameters in
                    ShellExecuteW(nil, verb, program, parameters, nil, SW_SHOWNORMAL)
                }
            }
        }
        // ShellExecuteW reports success as a value above 32.
        return Int(bitPattern: result) > 32
    }
}
