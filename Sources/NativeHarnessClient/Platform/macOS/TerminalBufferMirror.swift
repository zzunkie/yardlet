import AppKit
@preconcurrency import SwiftTerm

/// The headless session's emulator. A later view adopts this exact state, including alternate
/// screen, parser state and scrollback. The host remains the only terminal-query responder.
@MainActor
final class TerminalBufferMirror: @MainActor TerminalDelegate {
    weak var display: TerminalView?
    var sendBytes: ((ArraySlice<UInt8>) -> Void)?
    lazy var terminal: Terminal = {
        var options = TerminalOptions.default
        options.scrollback = 5_000
        return Terminal(delegate: self, options: options)
    }()

    func send(source: Terminal, data: ArraySlice<UInt8>) { sendBytes?(data) }
    func showCursor(source: Terminal) { display?.showCursor(source: source) }
    func hideCursor(source: Terminal) { display?.hideCursor(source: source) }
    func setTerminalTitle(source: Terminal, title: String) { display?.setTerminalTitle(source: source, title: title) }
    func setTerminalIconTitle(source: Terminal, title: String) { display?.setTerminalIconTitle(source: source, title: title) }
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { display?.windowCommand(source: source, command: command) }
    func sizeChanged(source: Terminal) { display?.sizeChanged(source: source) }
    func scrolled(source: Terminal, yDisp: Int) { display?.scrolled(source: source, yDisp: yDisp) }
    func linefeed(source: Terminal) { display?.linefeed(source: source) }
    func bufferActivated(source: Terminal) { display?.bufferActivated(source: source) }
    func synchronizedOutputChanged(source: Terminal, active: Bool) { display?.synchronizedOutputChanged(source: source, active: active) }
    func bell(source: Terminal) { display?.bell(source: source) }
    func selectionChanged(source: Terminal) { display?.selectionChanged(source: source) }
    func isProcessTrusted(source: Terminal) -> Bool { display?.isProcessTrusted(source: source) ?? true }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { display?.cellSizeInPixels(source: source) }
    func mouseModeChanged(source: Terminal) { display?.mouseModeChanged(source: source) }
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) { display?.cursorStyleChanged(source: source, newStyle: newStyle) }
    func hostCurrentDirectoryUpdated(source: Terminal) { display?.hostCurrentDirectoryUpdated(source: source) }
    func hostCurrentDocumentUpdated(source: Terminal) { display?.hostCurrentDocumentUpdated(source: source) }
    func colorChanged(source: Terminal, idx: Int?) { display?.colorChanged(source: source, idx: idx) }
    func setForegroundColor(source: Terminal, color: SwiftTerm.Color) {
        if let display { display.setForegroundColor(source: source, color: color) } else { source.foregroundColor = color }
    }
    func setBackgroundColor(source: Terminal, color: SwiftTerm.Color) {
        if let display { display.setBackgroundColor(source: source, color: color) } else { source.backgroundColor = color }
    }
    func setCursorColor(source: Terminal, color: SwiftTerm.Color?) { display?.setCursorColor(source: source, color: color) }
    func getColors(source: Terminal) -> (foreground: SwiftTerm.Color, background: SwiftTerm.Color) {
        display?.getColors(source: source) ?? (source.foregroundColor, source.backgroundColor)
    }
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) { display?.iTermContent(source: source, content: content) }
    func clipboardCopy(source: Terminal, content: Data) { display?.clipboardCopy(source: source, content: content) }
    func clipboardRead(source: Terminal) -> Data? { display?.clipboardRead(source: source) }
    func notify(source: Terminal, title: String, body: String) { display?.notify(source: source, title: title, body: body) }
    func progressReport(source: Terminal, report: Terminal.ProgressReport) { display?.progressReport(source: source, report: report) }
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        display?.createImageFromBitmap(source: source, bytes: &bytes, width: width, height: height)
    }
    func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {
        display?.createImage(source: source, data: data, width: width, height: height, preserveAspectRatio: preserveAspectRatio)
    }
}
