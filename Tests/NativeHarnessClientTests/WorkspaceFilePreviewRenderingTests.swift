import AppKit
import AVKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Files panel drawn without a window on screen, light and dark, into `.build/file-preview-qa/`:
/// a small source file with its colors, a 3 MB one without colors or editing and its one line
/// saying so, a 25 MB one shown from its beginning with the file's app and Finder, and, opened from a
/// link as a person clicks one, a file outside the task's folder (read-only), an image, a PDF and a
/// file it cannot show. The files are written into `YARDLET_FILE_PREVIEW_QA_DIR` (a temporary folder
/// without it) and removed.
@MainActor
final class WorkspaceFilePreviewRenderingTests: XCTestCase {
    private static let sample = """
        import Foundation

        /// Reads a file the way the Files panel shows it.
        struct Preview {
            let path: String
            var limit = 2_097_152 // 2 MB

            func title() -> String {
                guard !path.isEmpty else { return "Untitled" }
                return "File: \\(path)"
            }
        }

        """

    private func folder() throws -> URL {
        let base = ProcessInfo.processInfo.environment["YARDLET_FILE_PREVIEW_QA_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: "file-preview-render-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func render(_ file: URL, in root: URL, name: String, minimumInk: Double = 0.01,
                        check: (WorkspaceFilesState) throws -> Void) throws {
        let directory = try WindowlessRender.directory("file-preview-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let state = WorkspaceFilesState()
            let host = WindowlessRender.Host(
                FilesPane(workspaceURL: root, state: state, onClose: {})
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 620, height: 420), appearance: appearance)
            defer { host.close() }
            state.open(file, in: root)
            let deadline = Date().addingTimeInterval(20)
            while state.isLoading, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            // An image is decoded after the panel shows it.
            host.settle(passes: state.media == nil ? 6 : 20)
            try check(state)
            let bitmap = try host.capture().bitmap
            // Text is drawn on the lines below the first too, not only where the view laid out first.
            XCTAssertGreaterThan(ink(in: bitmap, rows: 0.35...0.55), minimumInk, "\(name) \(appearance)")
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
        }
    }

    /// The share of pixels in a band of rows, across the text, that differ from the background.
    private func ink(in bitmap: NSBitmapImageRep, rows: ClosedRange<Double>) -> Double {
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        guard let background = rgb(bitmap.pixelsWide - 4, bitmap.pixelsHigh - 4) else { return 0 }
        var ink = 0, total = 0
        let top = Int(Double(bitmap.pixelsHigh) * rows.lowerBound), bottom = Int(Double(bitmap.pixelsHigh) * rows.upperBound)
        for y in stride(from: top, to: bottom, by: 2) {
            for x in stride(from: bitmap.pixelsWide / 8, to: bitmap.pixelsWide * 3 / 4, by: 2) {
                total += 1
                guard let pixel = rgb(x, y) else { continue }
                if abs(pixel.0 - background.0) + abs(pixel.1 - background.1) + abs(pixel.2 - background.2) > 0.3 { ink += 1 }
            }
        }
        return Double(ink) / Double(max(1, total))
    }

    func testFilesPanelAtEachSize() throws {
        let root = try folder()
        try Data(Self.sample.utf8).write(to: root.appending(path: "Preview.swift"))
        let repeated = String(repeating: Self.sample, count: 3 * 1_048_576 / Self.sample.utf8.count + 1)
        try Data(repeated.utf8).write(to: root.appending(path: "Large.swift"))
        let huge = String(repeating: Self.sample, count: 25 * 1_048_576 / Self.sample.utf8.count + 1)
        try Data(huge.utf8).write(to: root.appending(path: "Huge.swift"))

        try render(root.appending(path: "Preview.swift"), in: root, name: "small-colored") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertFalse(document.tokens.isEmpty)
            XCTAssertTrue(state.canEdit)
        }
        try render(root.appending(path: "Large.swift"), in: root, name: "large-plain") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.tokens.isEmpty)
            XCTAssertFalse(document.isPartial)
            XCTAssertFalse(state.canEdit)
        }
        try render(root.appending(path: "Huge.swift"), in: root, name: "huge-beginning") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.isPartial)
            XCTAssertFalse(state.canEdit)
        }
    }

    /// What a person's click on a conversation's file link shows: a file outside the task's folder,
    /// read-only, through `~/Library/Application Support`'s space; an image and a PDF as themselves;
    /// and a file the panel cannot show, with its app and Finder under the reason.
    func testFilesPanelOpensWhatALinkNames() throws {
        let root = try folder(), outside = try folder()
        let notes = outside.appending(path: "Application Support/notes.swift")
        try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.sample.utf8).write(to: notes)
        try render(URL(filePath: notes.path(percentEncoded: false) + ":3"), in: root, name: "outside-read-only") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.path.hasPrefix("/"))
            XCTAssertFalse(state.canEdit)
        }

        let image = root.appending(path: "screenshot.png")
        try Self.pngData().write(to: image)
        try render(image, in: root, name: "image") { state in
            XCTAssertEqual(state.media?.kind, .image)
            XCTAssertNil(state.fileError)
        }

        let pdf = outside.appending(path: "report.pdf")
        try Self.pdfData().write(to: pdf)
        try render(pdf, in: root, name: "pdf") { state in
            XCTAssertEqual(state.media?.kind, .pdf)
        }

        let brokenMovie = root.appending(path: "broken.mp4")
        try Data("Invalid movie".utf8).write(to: brokenMovie)
        try render(brokenMovie, in: root, name: "unsupported-movie", minimumInk: 0.001) { state in
            XCTAssertEqual(state.media?.kind, .movie)
        }

        let binary = root.appending(path: "app-debug.apk")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0xFF]).write(to: binary)
        try render(binary, in: root, name: "unsupported", minimumInk: 0.001) { state in
            XCTAssertNil(state.media)
            XCTAssertEqual(state.fileError, WorkspaceFileError.unsupported.localizedDescription)
        }
    }


    func testPlayableMediaAndAnimatedImages() async throws {
        let root = try folder()
        let movie = root.appending(path: "sample.mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 {
            for x in 0..<320 {
                let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                bytes[offset] = 255; bytes[offset + 1] = 40
                bytes[offset + 2] = UInt8(x % 256); bytes[offset + 3] = 180
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<10 {
            try await waitUntil { input.isReadyForMoreMediaData }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let audio = root.appending(path: "silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        samples.frameLength = samples.frameCapacity
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: samples)

        let gif = root.appending(path: "animated.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [NSColor.systemRed, NSColor.systemBlue] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            color.setFill()
            NSRect(x: 0, y: 0, width: 640, height: 360).fill()
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoder = ImageFrameDecoder(url: gif)
        let first = await decoder.frame(0), second = await decoder.frame(1)
        XCTAssertEqual(first?.frameCount, 2)
        XCTAssertEqual(second?.duration, 0.5)
        XCTAssertLessThanOrEqual(first?.cgImage.width ?? 0, DecodedImage.longSidePixels)

        let directory = try WindowlessRender.directory("file-preview-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            for (file, name) in [(movie, "movie"), (audio, "audio"), (gif, "animated")] {
                let state = WorkspaceFilesState()
                let host = WindowlessRender.Host(FilesPane(workspaceURL: root, state: state, onClose: {})
                    .environment(\.colorScheme, appearance.colorScheme),
                    size: NSSize(width: 620, height: 420), appearance: appearance)
                state.open(file, in: root)
                await host.settle(until: { !state.isLoading && state.media != nil })
                func playerView(_ view: NSView) -> AVPlayerView? {
                    if let player = view as? AVPlayerView { return player }
                    return view.subviews.lazy.compactMap { playerView($0) }.first
                }
                if name != "animated" {
                    await host.settle(until: { playerView(host.hosting)?.player?.currentItem?.status == .readyToPlay })
                    host.settle(passes: 20)
                    let view = try XCTUnwrap(playerView(host.hosting))
                    let player = try XCTUnwrap(view.player)
                    XCTAssertEqual(player.rate, 0)
                    XCTAssertLessThanOrEqual(view.bounds.width, name == "movie" ? 320 : 588)
                    try WindowlessRender.writePNG(try host.capture().bitmap,
                        to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                    state.showPicker()
                    await host.settle(until: { player.currentItem == nil })
                    XCTAssertEqual(player.rate, 0)
                } else {
                    // Wait for the real animated panel to display each generated color.
                    for (index, red) in [(0, true), (1, false)] {
                        await host.settle(until: {
                            guard let bitmap = try? host.capture().bitmap,
                                  let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
                            else { return false }
                            return red ? color.redComponent > 0.7 && color.blueComponent < 0.5 : color.blueComponent > 0.7 && color.redComponent < 0.3
                        })
                        try WindowlessRender.writePNG(try host.capture().bitmap,
                            to: directory.appending(path: "animated-\(index)-\(appearance.suffix).png"))
                    }
                }
                host.close()
            }
        }
    }


    func testImageSequenceDecodesWithoutKeepingEveryFrame() async throws {
        let root = try folder()
        for (type, ext, dictionary, delay) in [
            (UTType.gif, "gif", kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime),
            (UTType.png, "png", kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime)
        ] {
            let url = root.appending(path: "sequence.\(ext)")
            try autoreleasepool {
                let canvas = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 48, nil))
                for index in 0..<48 {
                    canvas.setFillColor(CGColor(red: CGFloat(index) / 48, green: 0.3, blue: 0.8, alpha: 1))
                    canvas.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
                    CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()),
                        [dictionary: [delay: 0.1]] as CFDictionary)
                }
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            let decoder = ImageFrameDecoder(url: url)
            let warmup = await decoder.frame(0)
            XCTAssertEqual(warmup?.frameCount, 48)
            let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            var ends: [UInt64] = []
            let baseline = Footprint.current()
            let sampler = Footprint.Sampler()
            for _ in 0..<3 {
                for index in 0..<48 {
                    let frame = await decoder.frame(index)
                    XCTAssertEqual(frame?.cgImage.width, 2048)
                    if let frame {
                        context.draw(frame.cgImage, in: CGRect(x: 0, y: 0, width: 2048, height: 1024))
                    }
                    // Playback yields between frames; this checks memory stability over time.
                    try await Task.sleep(for: .milliseconds(20))
                }
                ends.append(Footprint.current())
            }
            let peak = sampler.stop()
            print("Image sequence \(ext): baseline \(baseline), peak \(peak), loop ends \(ends)")
            // Once decoder buffers are warm, subsequent loops must not retain all their frames.
            XCTAssertLessThan(Int64(ends[2]) - Int64(ends[0]), 64 * 1024 * 1024)

        }
    }

    /// A 1,600 by 1,000 pixel picture at 144 dpi: bands of color with dark bars across its middle.
    private static func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_600, pixelsHigh: 1_000, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 800, height: 500)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGradient(starting: .systemBlue, ending: .systemPurple)?.draw(in: NSRect(x: 0, y: 0, width: 800, height: 500), angle: 30)
        NSColor(white: 0.1, alpha: 1).setFill()
        for row in 0..<6 { NSRect(x: 80, y: 120 + row * 44, width: 640 - row * 60, height: 18).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// A one-page US Letter PDF with large lines of text down its page.
    private static func pdfData() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
        for line in 0..<14 { ("Quarterly report line \(line + 1)" as NSString).draw(at: NSPoint(x: 48, y: 720 - line * 50), withAttributes: attributes) }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
