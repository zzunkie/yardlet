import Foundation
import WinSDK

/// The count of tasks that need the person on the main window's taskbar button, as the Mac's Dock badge shows it
/// (`DockAttention`): Windows' overlay icon (`ITaskbarList3::SetOverlayIcon`), which Windows draws over the corner of
/// the app's button, as mail and chat apps show their counts. The number is drawn into a small icon, white on a red
/// disc, at the size Windows gives overlays at the window's scale, and the count goes with it as the words a screen
/// reader says. Whether overlays show at all is the person's switch in Settings › Personalization › Taskbar.
@MainActor
final class WindowsTaskbarBadge {
    private var taskbar: UnsafeMutablePointer<ITaskbarList3>?
    private var icon: HICON?

    /// Shows `label` over `window`'s taskbar button, or takes the overlay away for nil. False when Windows did not
    /// take it, such as before the window's button exists.
    @discardableResult
    func show(_ label: String?, on window: HWND) -> Bool {
        guard let taskbar = taskbarList() else { return false }
        let calls = taskbar.pointee.lpVtbl.pointee
        guard let label, !label.isEmpty else {
            let cleared = calls.SetOverlayIcon(taskbar, window, nil, nil) >= 0
            replaceIcon(with: nil)
            return cleared
        }
        let size = Int(GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForWindow(window)))
        guard let drawn = Self.icon(label, size: max(size, 16)) else { return false }
        let count = Int(label) ?? 0
        let description = L10n.format("Tasks that need your attention: %lld", count)
        let shown = description.withCString(encodedAs: UTF16.self) { words in
            calls.SetOverlayIcon(taskbar, window, drawn, words) >= 0
        }
        // Windows keeps its own copy of the icon once it took it.
        replaceIcon(with: drawn)
        return shown
    }

    private func replaceIcon(with drawn: HICON?) {
        if let icon { DestroyIcon(icon) }
        icon = drawn
    }

    /// Windows' taskbar list, made once on the window's thread, where WinUI has started COM.
    private func taskbarList() -> UnsafeMutablePointer<ITaskbarList3>? {
        if let taskbar { return taskbar }
        // CLSID_TaskbarList and IID_ITaskbarList3, written out so nothing links uuid.lib for them.
        var classID = GUID(Data1: 0x56FD_F344, Data2: 0xFD6D, Data3: 0x11D0,
                           Data4: (0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90))
        var interfaceID = GUID(Data1: 0xEA1A_FB91, Data2: 0x9E28, Data3: 0x4B86,
                               Data4: (0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF))
        var created: UnsafeMutableRawPointer?
        guard CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &interfaceID, &created) >= 0,
              let list = created?.assumingMemoryBound(to: ITaskbarList3.self) else { return nil }
        guard list.pointee.lpVtbl.pointee.HrInit(list) >= 0 else {
            _ = list.pointee.lpVtbl.pointee.Release(list)
            return nil
        }
        taskbar = list
        return list
    }

    // MARK: Drawing

    /// The badge's red, Windows' own for what needs attention (its critical status color).
    private static let disc = (red: 0xC4, green: 0x2B, blue: 0x1C)

    /// `label` in white on a red disc, `size` pixels square: the disc drawn here with soft edges, the number drawn by
    /// Windows' text renderer in grays onto a page of its own and laid over the disc as its coverage, so the icon
    /// holds a true alpha channel that GDI's text alone would not write.
    private static func icon(_ label: String, size: Int) -> HICON? {
        let pixels = size * size
        guard let text = textCoverage(label, size: size) else { return nil }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(size)
        info.bmiHeader.biHeight = -LONG(size)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let color = CreateDIBSection(nil, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else { return nil }
        defer { DeleteObject(UnsafeMutableRawPointer(color)) }
        let center = Double(size) / 2
        let radius = center
        let page = bits.bindMemory(to: UInt8.self, capacity: pixels * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - center, dy = Double(y) + 0.5 - center
                let edge = min(max(radius - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
                let ink = text[y * size + x]
                let index = (y * size + x) * 4
                // Blue, green, red, alpha; the color straight, not multiplied by its alpha, as an icon's is.
                page[index] = blend(UInt8(disc.blue), 255, ink)
                page[index + 1] = blend(UInt8(disc.green), 255, ink)
                page[index + 2] = blend(UInt8(disc.red), 255, ink)
                page[index + 3] = UInt8((edge * 255).rounded())
            }
        }
        // A 32-bit color image's alpha decides what shows; the mask beside it is all zeros.
        let maskBytes = [UInt8](repeating: 0, count: ((size + 15) / 16) * 2 * size)
        guard let mask = maskBytes.withUnsafeBytes({ CreateBitmap(Int32(size), Int32(size), 1, 1, $0.baseAddress) })
        else { return nil }
        defer { DeleteObject(UnsafeMutableRawPointer(mask)) }
        var iconInfo = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
        return CreateIconIndirect(&iconInfo)
    }

    private static func blend(_ base: UInt8, _ top: UInt8, _ coverage: Double) -> UInt8 {
        UInt8((Double(base) * (1 - coverage) + Double(top) * coverage).rounded())
    }

    /// How much of each pixel `label`'s glyphs cover, from 0 to 1, centered in a `size` square: Windows draws the
    /// text antialiased in gray (not ClearType, whose colored fringes would show on the red).
    private static func textCoverage(_ label: String, size: Int) -> [Double]? {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(size)
        info.bmiHeader.biHeight = -LONG(size)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let context = CreateCompatibleDC(nil) else { return nil }
        defer { DeleteDC(context) }
        guard let page = CreateDIBSection(context, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            return nil
        }
        defer { DeleteObject(UnsafeMutableRawPointer(page)) }
        let previousPage = SelectObject(context, UnsafeMutableRawPointer(page))
        defer { SelectObject(context, previousPage) }
        // A wider count takes a smaller face, so "99+" still fits the disc.
        let share = label.count <= 1 ? 0.78 : label.count == 2 ? 0.64 : 0.5
        let height = Int32((Double(size) * share).rounded())
        let font = "Segoe UI".withCString(encodedAs: UTF16.self) { face in
            CreateFontW(-height, 0, 0, 0, Int32(FW_BOLD), 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(ANTIALIASED_QUALITY), DWORD(DEFAULT_PITCH), face)
        }
        guard let font else { return nil }
        defer { DeleteObject(UnsafeMutableRawPointer(font)) }
        let previousFont = SelectObject(context, UnsafeMutableRawPointer(font))
        defer { SelectObject(context, previousFont) }
        SetTextColor(context, 0x00FF_FFFF)
        SetBkMode(context, Int32(TRANSPARENT))
        var area = RECT(left: 0, top: 0, right: LONG(size), bottom: LONG(size))
        _ = label.withCString(encodedAs: UTF16.self) { words in
            DrawTextW(context, words, -1, &area, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
        }
        GdiFlush()
        let drawn = bits.bindMemory(to: UInt8.self, capacity: size * size * 4)
        return (0..<(size * size)).map { pixel in
            let index = pixel * 4
            return Double(max(drawn[index], drawn[index + 1], drawn[index + 2])) / 255
        }
    }
}
