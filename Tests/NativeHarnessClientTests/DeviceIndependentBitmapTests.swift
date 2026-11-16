import AppKit
import XCTest
@testable import NativeHarnessClient

/// A picture pasted into the Windows composer from an app that offers only a bitmap becomes a PNG the harnesses read:
/// the rows in order whichever way the bitmap stores them, padding left out, and a 32-bit bitmap's colors kept.
final class DeviceIndependentBitmapTests: XCTestCase {
    func testABitmapBecomesAPNGWithItsPixels() throws {
        // 3×2, bottom-up, 24 bits: each row is 9 bytes padded to 12. The top row is red, green, blue; the bottom
        // row white, black, gray.
        var dib = header(width: 3, height: 2, bitCount: 24, compression: 0)
        dib += [255, 255, 255, 0, 0, 0, 128, 128, 128, 0, 0, 0]
        dib += [0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0]
        try assertPixels(of: dib, width: 3, height: 2, [
            [(255, 0, 0), (0, 255, 0), (0, 0, 255)],
            [(255, 255, 255), (0, 0, 0), (128, 128, 128)],
        ])

        // 2×1, top-down, 32 bits with the masks after the header (BI_BITFIELDS); the alpha byte is ignored.
        var top = header(width: 2, height: -1, bitCount: 32, compression: 3)
        top += [0, 0, 0xFF, 0, 0, 0xFF, 0, 0, 0xFF, 0, 0, 0]
        top += [10, 20, 30, 0, 40, 50, 60, 0]
        try assertPixels(of: top, width: 2, height: 1, [[(30, 20, 10), (60, 50, 40)]])

        // A screen-like 300×40: bands of one color and rows that repeat, which the PNG stores as references back,
        // with a varied band in the middle that stays as it is.
        let width = 300, height = 40
        var screen = header(width: Int32(width), height: Int32(height), bitCount: 24, compression: 0)
        var expected: [[(Int, Int, Int)]] = []
        for y in 0..<height {
            expected.append((0..<width).map { x in
                y < 10 ? (240, 240, 240) : y < 20 ? ((x * 7) % 256, (x * y) % 256, (x + y) % 256) : (20, 120, 220)
            })
        }
        for row in expected.reversed() {
            for pixel in row { screen += [UInt8(pixel.2), UInt8(pixel.1), UInt8(pixel.0)] }
        }
        let png = try XCTUnwrap(DeviceIndependentBitmap.png(from: Data(screen)))
        XCTAssertLessThan(png.count, width * height, "Repeated rows are compressed")
        try assertPixels(of: screen, width: width, height: height, expected)

        XCTAssertNil(DeviceIndependentBitmap.png(from: Data(header(width: 2, height: 2, bitCount: 8, compression: 0))),
                     "A paletted bitmap is not read")
    }

    private func header(width: Int32, height: Int32, bitCount: UInt16, compression: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 40)
        func put32(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(value >> (8 * UInt32(index)) & 0xFF) }
        }
        put32(40, at: 0)
        put32(UInt32(bitPattern: width), at: 4)
        put32(UInt32(bitPattern: height), at: 8)
        bytes[12] = 1
        bytes[14] = UInt8(bitCount & 0xFF)
        put32(compression, at: 16)
        return bytes
    }

    private func assertPixels(of dib: [UInt8], width: Int, height: Int, _ rows: [[(Int, Int, Int)]],
                              line: UInt = #line) throws {
        let png = try XCTUnwrap(DeviceIndependentBitmap.png(from: Data(dib)), line: line)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png), line: line)
        XCTAssertEqual(image.pixelsWide, width, line: line)
        XCTAssertEqual(image.pixelsHigh, height, line: line)
        for (y, row) in rows.enumerated() {
            for (x, expected) in row.enumerated() {
                var pixel = [Int](repeating: 0, count: 4)
                image.getPixel(&pixel, atX: x, y: y)
                XCTAssertEqual([pixel[0], pixel[1], pixel[2]], [expected.0, expected.1, expected.2],
                               "(\(x), \(y))", line: line)
            }
        }
    }
}
