import Foundation
import WinSDK

/// What Windows' clipboard holds that a composer attaches rather than types, as the Mac's composer takes a paste:
/// files copied in File Explorer (`CF_HDROP`), or a picture, as the PNG an app offered (the `PNG` format browsers,
/// Office and Snipping Tool put there) or else its bitmap (`CF_DIB`). As on the Mac (`ComposerExternalInput.read`),
/// copied files win, and copied text stays text for the field's own paste even when the app also offered a picture of
/// it, as a spreadsheet's cells or a styled snippet come with one.
enum WindowsClipboard {
    enum Attachment: Equatable {
        case files([URL])
        case png(Data)
        /// A `BITMAPINFOHEADER` and its pixels, which `DeviceIndependentBitmap` makes a PNG.
        case bitmap(Data)

        /// The picture's PNG, made where it is called; nil for files.
        var png: (@Sendable () -> Data?)? {
            switch self {
            case .files: nil
            case let .png(data): { data }
            case let .bitmap(data): { DeviceIndependentBitmap.png(from: data) }
            }
        }
    }

    /// The clipboard's files or picture, read while `window` (an `HWND`'s value) holds the clipboard open.
    @MainActor
    static func attachment(window: UInt64) -> Attachment? {
        guard OpenClipboard(HWND(bitPattern: UInt(window))) else { return nil }
        defer { CloseClipboard() }
        if IsClipboardFormatAvailable(UINT(CF_HDROP)), let handle = GetClipboardData(UINT(CF_HDROP)) {
            let drop = HDROP(OpaquePointer(handle))
            let count = DragQueryFileW(drop, 0xFFFF_FFFF, nil, 0)
            var urls: [URL] = []
            for index in 0..<count {
                let length = DragQueryFileW(drop, index, nil, 0)
                var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
                guard DragQueryFileW(drop, index, &buffer, length + 1) > 0 else { continue }
                urls.append(URL(filePath: String(decodingCString: buffer, as: UTF16.self)))
            }
            if !urls.isEmpty { return .files(urls) }
        }
        if IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)) { return nil }
        let pngFormat = "PNG".withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }
        if pngFormat != 0, IsClipboardFormatAvailable(pngFormat), let png = bytes(of: GetClipboardData(pngFormat)) {
            return .png(png)
        }
        if IsClipboardFormatAvailable(UINT(CF_DIB)), let dib = bytes(of: GetClipboardData(UINT(CF_DIB))) {
            return .bitmap(dib)
        }
        return nil
    }

    /// The bytes a clipboard handle holds, copied while it is locked.
    private static func bytes(of handle: HANDLE?) -> Data? {
        guard let handle, let locked = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }
        let size = GlobalSize(handle)
        guard size > 0 else { return nil }
        return Data(bytes: locked, count: Int(size))
    }
}
