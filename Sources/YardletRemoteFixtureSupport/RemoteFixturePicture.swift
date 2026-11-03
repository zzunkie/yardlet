import Foundation

/// A small drawing of flat colors and bitmap text, written as PNG without any image library, so the fixture's browser
/// tab (§15.25) draws the same on every platform. Each row is filtered against the one above and runs are deflated as
/// matches one byte back, so a page of flat colors is a few kilobytes.
struct RemoteFixturePicture {
    let width: Int
    let height: Int
    /// Palette indexes, row by row.
    private(set) var pixels: [UInt8]
    let palette: [(UInt8, UInt8, UInt8)]

    init(width: Int, height: Int, palette: [(UInt8, UInt8, UInt8)], background: UInt8 = 0) {
        self.width = width
        self.height = height
        self.palette = palette
        pixels = Array(repeating: background, count: width * height)
    }

    mutating func fill(x: Int, y: Int, width: Int, height: Int, color: UInt8) {
        let left = max(0, x), right = min(self.width, x + width)
        let top = max(0, y), bottom = min(self.height, y + height)
        guard left < right, top < bottom else { return }
        for row in top..<bottom {
            for column in left..<right { pixels[row * self.width + column] = color }
        }
    }

    /// A rectangle's outline, `thickness` pixels wide.
    mutating func frame(x: Int, y: Int, width: Int, height: Int, color: UInt8, thickness: Int = 1) {
        fill(x: x, y: y, width: width, height: thickness, color: color)
        fill(x: x, y: y + height - thickness, width: width, height: thickness, color: color)
        fill(x: x, y: y, width: thickness, height: height, color: color)
        fill(x: x + width - thickness, y: y, width: thickness, height: height, color: color)
    }

    /// The width `text` takes at `scale`.
    static func width(of text: String, scale: Int) -> Int {
        text.count * 6 * scale - scale
    }

    /// ASCII text in a 5×8 font, each dot `scale` pixels; a character outside it draws as a box.
    mutating func text(_ text: String, x: Int, y: Int, scale: Int, color: UInt8) {
        var left = x
        for character in text {
            let columns = Self.glyph(character)
            for (column, bits) in columns.enumerated() {
                for row in 0..<8 where bits & (1 << row) != 0 {
                    fill(x: left + column * scale, y: y + row * scale, width: scale, height: scale, color: color)
                }
            }
            left += 6 * scale
        }
    }

    mutating func centeredText(_ text: String, y: Int, scale: Int, color: UInt8) {
        self.text(text, x: (width - Self.width(of: text, scale: scale)) / 2, y: y, scale: scale, color: color)
    }

    /// The picture shrunk by `factor` (≤ 1), each pixel the one under its center.
    func scaled(by factor: Double) -> RemoteFixturePicture {
        guard factor < 1 else { return self }
        let scaledWidth = max(1, Int((Double(width) * factor).rounded()))
        let scaledHeight = max(1, Int((Double(height) * factor).rounded()))
        var scaled = RemoteFixturePicture(width: scaledWidth, height: scaledHeight, palette: palette)
        for row in 0..<scaledHeight {
            let source = min(height - 1, Int((Double(row) + 0.5) / factor))
            for column in 0..<scaledWidth {
                scaled.pixels[row * scaledWidth + column] = pixels[source * width + min(width - 1, Int((Double(column) + 0.5) / factor))]
            }
        }
        return scaled
    }

    // MARK: - PNG

    var png: Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 3, 0, 0, 0])
        Self.chunk("IHDR", header, into: &data)
        Self.chunk("PLTE", Data(palette.flatMap { [$0.0, $0.1, $0.2] }), into: &data)
        // Each row filtered "Up": a row like the one above is all zeros.
        var raw: [UInt8] = []
        raw.reserveCapacity((width + 1) * height)
        for row in 0..<height {
            raw.append(2)
            for column in 0..<width {
                let above = row > 0 ? pixels[(row - 1) * width + column] : 0
                raw.append(pixels[row * width + column] &- above)
            }
        }
        Self.chunk("IDAT", Self.zlib(raw), into: &data)
        Self.chunk("IEND", Data(), into: &data)
        return data
    }

    private static func chunk(_ type: String, _ body: Data, into data: inout Data) {
        data.appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        data.append(typed)
        data.appendBigEndian(crc32(typed))
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// zlib around one deflate block of fixed codes: literals, and runs as matches one byte back (RFC 1950, 1951).
    private static func zlib(_ bytes: [UInt8]) -> Data {
        var bits = BitWriter()
        bits.write(1, count: 1)
        bits.write(1, count: 2)
        var index = 0
        while index < bytes.count {
            var run = 0
            if index > 0 {
                while index + run < bytes.count, bytes[index + run] == bytes[index - 1], run < 258 { run += 1 }
            }
            if run >= 3 {
                bits.writeLength(run)
                bits.write(0, count: 5)
                index += run
            } else {
                bits.writeLiteral(Int(bytes[index]))
                index += 1
            }
        }
        bits.writeLiteral(256)
        var data = Data([0x78, 0x01])
        data.append(contentsOf: bits.finished)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        data.appendBigEndian(b << 16 | a)
        return data
    }

    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var current: UInt32 = 0
        private var filled = 0

        /// Writes `count` bits of `value`, the lowest first (header fields and extra bits).
        mutating func write(_ value: Int, count: Int) {
            for bit in 0..<count {
                current |= UInt32((value >> bit) & 1) << filled
                filled += 1
                if filled == 8 { flush() }
            }
        }

        /// Writes a Huffman code, its highest bit first.
        mutating func writeCode(_ code: Int, count: Int) {
            for bit in stride(from: count - 1, through: 0, by: -1) { write((code >> bit) & 1, count: 1) }
        }

        mutating func writeLiteral(_ value: Int) {
            switch value {
            case 0...143: writeCode(0x30 + value, count: 8)
            case 144...255: writeCode(0x190 + value - 144, count: 9)
            case 256...279: writeCode(value - 256, count: 7)
            default: writeCode(0xC0 + value - 280, count: 8)
            }
        }

        private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                         115, 131, 163, 195, 227, 258]
        private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

        mutating func writeLength(_ length: Int) {
            let index = Self.lengthBase.lastIndex { $0 <= length } ?? 0
            writeLiteral(257 + index)
            write(length - Self.lengthBase[index], count: Self.lengthExtra[index])
        }

        var finished: [UInt8] {
            var copy = self
            if copy.filled > 0 { copy.flush() }
            return copy.bytes
        }

        private mutating func flush() {
            bytes.append(UInt8(current & 0xFF))
            current = 0
            filled = 0
        }
    }

    // MARK: - Font

    /// Columns of the 5×8 font, lowest bit at the top, for ASCII 32 to 126.
    private static func glyph(_ character: Character) -> [UInt8] {
        guard let value = character.asciiValue, (32...126).contains(value) else { return [0x7F, 0x41, 0x41, 0x41, 0x7F] }
        let start = Int(value - 32) * 5
        return Array(font[start..<start + 5])
    }

    private static let font: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5F, 0x00, 0x00, 0x00, 0x07, 0x00, 0x07, 0x00, 0x14, 0x7F, 0x14, 0x7F, 0x14,
        0x24, 0x2A, 0x7F, 0x2A, 0x12, 0x23, 0x13, 0x08, 0x64, 0x62, 0x36, 0x49, 0x56, 0x20, 0x50, 0x00, 0x08, 0x07, 0x03, 0x00,
        0x00, 0x1C, 0x22, 0x41, 0x00, 0x00, 0x41, 0x22, 0x1C, 0x00, 0x2A, 0x1C, 0x7F, 0x1C, 0x2A, 0x08, 0x08, 0x3E, 0x08, 0x08,
        0x00, 0x80, 0x70, 0x30, 0x00, 0x08, 0x08, 0x08, 0x08, 0x08, 0x00, 0x00, 0x60, 0x60, 0x00, 0x20, 0x10, 0x08, 0x04, 0x02,
        0x3E, 0x51, 0x49, 0x45, 0x3E, 0x00, 0x42, 0x7F, 0x40, 0x00, 0x72, 0x49, 0x49, 0x49, 0x46, 0x21, 0x41, 0x49, 0x4D, 0x33,
        0x18, 0x14, 0x12, 0x7F, 0x10, 0x27, 0x45, 0x45, 0x45, 0x39, 0x3C, 0x4A, 0x49, 0x49, 0x31, 0x41, 0x21, 0x11, 0x09, 0x07,
        0x36, 0x49, 0x49, 0x49, 0x36, 0x46, 0x49, 0x49, 0x29, 0x1E, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x40, 0x34, 0x00, 0x00,
        0x00, 0x08, 0x14, 0x22, 0x41, 0x14, 0x14, 0x14, 0x14, 0x14, 0x00, 0x41, 0x22, 0x14, 0x08, 0x02, 0x01, 0x59, 0x09, 0x06,
        0x3E, 0x41, 0x5D, 0x59, 0x4E, 0x7C, 0x12, 0x11, 0x12, 0x7C, 0x7F, 0x49, 0x49, 0x49, 0x36, 0x3E, 0x41, 0x41, 0x41, 0x22,
        0x7F, 0x41, 0x41, 0x41, 0x3E, 0x7F, 0x49, 0x49, 0x49, 0x41, 0x7F, 0x09, 0x09, 0x09, 0x01, 0x3E, 0x41, 0x41, 0x51, 0x73,
        0x7F, 0x08, 0x08, 0x08, 0x7F, 0x00, 0x41, 0x7F, 0x41, 0x00, 0x20, 0x40, 0x41, 0x3F, 0x01, 0x7F, 0x08, 0x14, 0x22, 0x41,
        0x7F, 0x40, 0x40, 0x40, 0x40, 0x7F, 0x02, 0x1C, 0x02, 0x7F, 0x7F, 0x04, 0x08, 0x10, 0x7F, 0x3E, 0x41, 0x41, 0x41, 0x3E,
        0x7F, 0x09, 0x09, 0x09, 0x06, 0x3E, 0x41, 0x51, 0x21, 0x5E, 0x7F, 0x09, 0x19, 0x29, 0x46, 0x26, 0x49, 0x49, 0x49, 0x32,
        0x03, 0x01, 0x7F, 0x01, 0x03, 0x3F, 0x40, 0x40, 0x40, 0x3F, 0x1F, 0x20, 0x40, 0x20, 0x1F, 0x3F, 0x40, 0x38, 0x40, 0x3F,
        0x63, 0x14, 0x08, 0x14, 0x63, 0x03, 0x04, 0x78, 0x04, 0x03, 0x61, 0x59, 0x49, 0x4D, 0x43, 0x00, 0x7F, 0x41, 0x41, 0x41,
        0x02, 0x04, 0x08, 0x10, 0x20, 0x00, 0x41, 0x41, 0x41, 0x7F, 0x04, 0x02, 0x01, 0x02, 0x04, 0x40, 0x40, 0x40, 0x40, 0x40,
        0x00, 0x03, 0x07, 0x08, 0x00, 0x20, 0x54, 0x54, 0x78, 0x40, 0x7F, 0x28, 0x44, 0x44, 0x38, 0x38, 0x44, 0x44, 0x44, 0x28,
        0x38, 0x44, 0x44, 0x28, 0x7F, 0x38, 0x54, 0x54, 0x54, 0x18, 0x00, 0x08, 0x7E, 0x09, 0x02, 0x18, 0xA4, 0xA4, 0x9C, 0x78,
        0x7F, 0x08, 0x04, 0x04, 0x78, 0x00, 0x44, 0x7D, 0x40, 0x00, 0x20, 0x40, 0x40, 0x3D, 0x00, 0x7F, 0x10, 0x28, 0x44, 0x00,
        0x00, 0x41, 0x7F, 0x40, 0x00, 0x7C, 0x04, 0x78, 0x04, 0x78, 0x7C, 0x08, 0x04, 0x04, 0x78, 0x38, 0x44, 0x44, 0x44, 0x38,
        0xFC, 0x18, 0x24, 0x24, 0x18, 0x18, 0x24, 0x24, 0x18, 0xFC, 0x7C, 0x08, 0x04, 0x04, 0x08, 0x48, 0x54, 0x54, 0x54, 0x24,
        0x04, 0x04, 0x3F, 0x44, 0x24, 0x3C, 0x40, 0x40, 0x20, 0x7C, 0x1C, 0x20, 0x40, 0x20, 0x1C, 0x3C, 0x40, 0x30, 0x40, 0x3C,
        0x44, 0x28, 0x10, 0x28, 0x44, 0x4C, 0x90, 0x90, 0x90, 0x7C, 0x44, 0x64, 0x54, 0x4C, 0x44, 0x00, 0x08, 0x36, 0x41, 0x00,
        0x00, 0x00, 0x77, 0x00, 0x00, 0x00, 0x41, 0x36, 0x08, 0x00, 0x02, 0x01, 0x02, 0x04, 0x02
    ]
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
