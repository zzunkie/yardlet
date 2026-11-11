import Foundation
import WinSDK

/// Windows' own folder dialog (the common item dialog with `FOS_PICKFOLDERS`), as File Explorer and the harnesses'
/// own apps show it, for choosing a project's folder. The Windows App SDK this app is on (1.7) has no folder picker of
/// its own, and WinRT's `FolderPicker` needs the window handed to it through a COM interface in an unpackaged app, so
/// the dialog is made directly. It runs modally on the window's thread, as the dialog always does.
enum WindowsFolderPicker {
    /// The folder the person picks, its dialog owned by `window` (an `HWND`'s value); nil when they cancel.
    @MainActor
    static func chooseFolder(window: UInt64, title: String) -> URL? {
        // CLSID_FileOpenDialog and IID_IFileOpenDialog, written out so nothing links uuid.lib for them.
        var classID = GUID(Data1: 0xDC1C_5A9C, Data2: 0xE88A, Data3: 0x4DDE,
                           Data4: (0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7))
        var interfaceID = GUID(Data1: 0xD57C_7288, Data2: 0xD4AD, Data3: 0x4768,
                               Data4: (0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60))
        var created: UnsafeMutableRawPointer?
        guard CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &interfaceID, &created) >= 0,
              let dialog = created?.assumingMemoryBound(to: IFileOpenDialog.self) else { return nil }
        let calls = dialog.pointee.lpVtbl.pointee
        defer { _ = calls.Release(dialog) }

        var options: FILEOPENDIALOGOPTIONS = 0
        _ = calls.GetOptions(dialog, &options)
        _ = calls.SetOptions(dialog, options | FILEOPENDIALOGOPTIONS(FOS_PICKFOLDERS.rawValue)
            | FILEOPENDIALOGOPTIONS(FOS_FORCEFILESYSTEM.rawValue))
        title.withCString(encodedAs: UTF16.self) { _ = calls.SetTitle(dialog, $0) }
        // Cancel answers with an error, as every dialog that was not completed does.
        guard calls.Show(dialog, HWND(bitPattern: UInt(window))) >= 0 else { return nil }

        var chosen: UnsafeMutablePointer<IShellItem>?
        guard calls.GetResult(dialog, &chosen) >= 0, let chosen else { return nil }
        defer { _ = chosen.pointee.lpVtbl.pointee.Release(chosen) }
        var path: PWSTR?
        guard chosen.pointee.lpVtbl.pointee.GetDisplayName(chosen, SIGDN_FILESYSPATH, &path) >= 0, let path else {
            return nil
        }
        defer { CoTaskMemFree(path) }
        return URL(filePath: String(decodingCString: path, as: UTF16.self), directoryHint: .isDirectory)
    }
}
