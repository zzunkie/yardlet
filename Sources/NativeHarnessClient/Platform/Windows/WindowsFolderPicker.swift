import Foundation
import WinSDK

/// Windows' own file and folder dialog (the common item dialog, with `FOS_PICKFOLDERS` for folders), as File Explorer
/// and the harnesses' own apps show it, for choosing a project's folder and the files a message carries. The Windows
/// App SDK this app is on (1.7) has no folder picker of its own, and WinRT's pickers need the window handed to them
/// through a COM interface in an unpackaged app, so the dialog is made directly. It runs modally on the window's
/// thread, as the dialog always does.
enum WindowsFolderPicker {
    /// The folder the person picks, its dialog owned by `window` (an `HWND`'s value); nil when they cancel.
    @MainActor
    static func chooseFolder(window: UInt64, title: String) -> URL? {
        choose(window: window, title: title, folders: true, multiple: false)?.first
    }

    /// The files or folders the person picks, several at once, as the composer's "+" menu adds them; nil when they
    /// cancel.
    @MainActor
    static func chooseItems(window: UInt64, title: String, folders: Bool) -> [URL]? {
        choose(window: window, title: title, folders: folders, multiple: true)
    }

    @MainActor
    private static func choose(window: UInt64, title: String, folders: Bool, multiple: Bool) -> [URL]? {
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
        options |= FILEOPENDIALOGOPTIONS(FOS_FORCEFILESYSTEM.rawValue)
        if folders { options |= FILEOPENDIALOGOPTIONS(FOS_PICKFOLDERS.rawValue) }
        if multiple { options |= FILEOPENDIALOGOPTIONS(FOS_ALLOWMULTISELECT.rawValue) }
        _ = calls.SetOptions(dialog, options)
        title.withCString(encodedAs: UTF16.self) { _ = calls.SetTitle(dialog, $0) }
        // Cancel answers with an error, as every dialog that was not completed does.
        guard calls.Show(dialog, HWND(bitPattern: UInt(window))) >= 0 else { return nil }

        var results: UnsafeMutablePointer<IShellItemArray>?
        guard calls.GetResults(dialog, &results) >= 0, let results else { return nil }
        let list = results.pointee.lpVtbl.pointee
        defer { _ = list.Release(results) }
        var count: DWORD = 0
        guard list.GetCount(results, &count) >= 0 else { return nil }
        var urls: [URL] = []
        for index in 0..<count {
            var item: UnsafeMutablePointer<IShellItem>?
            guard list.GetItemAt(results, index, &item) >= 0, let item else { continue }
            defer { _ = item.pointee.lpVtbl.pointee.Release(item) }
            var path: PWSTR?
            guard item.pointee.lpVtbl.pointee.GetDisplayName(item, SIGDN_FILESYSPATH, &path) >= 0, let path else {
                continue
            }
            defer { CoTaskMemFree(path) }
            urls.append(URL(filePath: String(decodingCString: path, as: UTF16.self),
                            directoryHint: folders ? .isDirectory : .notDirectory))
        }
        return urls
    }
}
