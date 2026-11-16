import Foundation

/// A picture as Windows' clipboard holds one when the app that copied it offered no PNG (`CF_DIB`: a
/// `BITMAPINFOHEADER` and its pixels), written as a PNG, which every harness that takes images reads. Pasted into a
/// composer it joins the message as the Mac's pasted picture does (`ComposerAttachmentIntake.storePastedImage`). The
/// PNG keeps the picture's colors without its alpha, which a copied picture rarely fills in. Its rows are compressed
/// here, as nothing on every platform this builds on offers deflate: a screenshot's repeated rows and runs of one
/// color shrink to references back, so a pasted screen stays small enough for a harness to take.
enum DeviceIndependentBitmap {
    /// The PNG of a 24- or 32-bit uncompressed bitmap, or nil for any other.
    static func png(from dib: Data) -> Data? {
        let bytes = [UInt8](dib)
        guard bytes.count >= 40 else { return nil }
        let headerSize = Int(le32(bytes, 0))
        let width = Int(Int32(bitPattern: le32(bytes, 4)))
        let rawHeight = Int(Int32(bitPattern: le32(bytes, 8)))
        let bitCount = Int(le16(bytes, 14))
        let compression = le32(bytes, 16)
        let colorsUsed = Int(le32(bytes, 32))
        // BI_RGB, or BI_BITFIELDS for 32 bits, whose masks follow a 40-byte header.
        guard headerSize >= 40, width > 0, rawHeight != 0, bitCount == 24 || bitCount == 32,
              compression == 0 || (compression == 3 && bitCount == 32) else { return nil }
        let height = abs(rawHeight)
        let masks = compression == 3 && headerSize == 40 ? 12 : 0
        let start = headerSize + masks + colorsUsed * 4
        let stride = (width * bitCount + 31) / 32 * 4
        guard width <= 32_768, height <= 32_768, start + stride * height <= bytes.count else { return nil }

        // Each PNG row is a filter byte (none) and the row's red, green and blue.
        let bytesPerPixel = bitCount / 8
        var raw = [UInt8]()
        raw.reserveCapacity(height * (1 + width * 3))
        for row in 0..<height {
            // A positive height is a bottom-up bitmap.
            let source = start + (rawHeight > 0 ? height - 1 - row : row) * stride
            raw.append(0)
            for column in 0..<width {
                let pixel = source + column * bytesPerPixel
                raw.append(bytes[pixel + 2])
                raw.append(bytes[pixel + 1])
                raw.append(bytes[pixel])
            }
        }

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var header = be32(UInt32(width)) + be32(UInt32(height))
        header += [8, 2, 0, 0, 0] // 8 bits per channel, RGB, deflate, no filter, not interlaced
        chunk("IHDR", header, into: &png)
        chunk("IDAT", zlib(raw), into: &png)
        chunk("IEND", [], into: &png)
        return Data(png)
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func chunk(_ type: String, _ data: [UInt8], into png: inout [UInt8]) {
        let typed = Array(type.utf8) + data
        png += be32(UInt32(data.count)) + typed + be32(crc32(typed))
    }

    /// The rows as a zlib stream of one block in deflate's fixed codes. Each run of at least three bytes that
    /// repeats bytes at most 32 KB back (a row like the one above it, a span of one color) is written as a reference
    /// to them, found through the last place each three bytes were seen.
    private static func zlib(_ data: [UInt8]) -> [UInt8] {
        var bits = BitWriter()
        bits.bytes.reserveCapacity(data.count / 4 + 64)
        bits.write(1, 1) // the last block
        bits.write(1, 2) // fixed codes
        var lastSeen = [Int32](repeating: -1, count: 1 << 16)
        func hash(_ at: Int) -> Int {
            ((Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16) &* 2_654_435_761) >> 16 & 0xFFFF
        }
        var index = 0
        while index < data.count {
            var length = 0
            var distance = 0
            if index + 2 < data.count {
                let key = hash(index)
                let earlier = Int(lastSeen[key])
                lastSeen[key] = Int32(index)
                if earlier >= 0, index - earlier <= 32_768 {
                    let limit = min(258, data.count - index)
                    var matched = 0
                    while matched < limit, data[earlier + matched] == data[index + matched] { matched += 1 }
                    if matched >= 3 { (length, distance) = (matched, index - earlier) }
                }
            }
            guard length > 0 else {
                bits.symbol(Int(data[index]))
                index += 1
                continue
            }
            let lengthCode = lengthBase.lastIndex { $0 <= length } ?? 0
            bits.symbol(257 + lengthCode)
            bits.write(length - lengthBase[lengthCode], lengthExtra[lengthCode])
            let distanceCode = distanceBase.lastIndex { $0 <= distance } ?? 0
            bits.code(distanceCode, 5)
            bits.write(distance - distanceBase[distanceCode], distanceExtra[distanceCode])
            // The bytes inside the run are found again too, so the next row can refer back to them.
            var position = index + 1
            while position < min(index + length, data.count - 2) {
                lastSeen[hash(position)] = Int32(position)
                position += 1
            }
            index += length
        }
        bits.symbol(256) // the end of the block
        bits.flush()
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return [0x78, 0x01] + bits.bytes + be32(b << 16 | a)
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                     115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
                                       1537, 2049, 3073, 4097, 6145, 8193, 12_289, 16_385, 24_577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12,
                                        12, 13, 13]

    /// Deflate's bits, packed from each byte's lowest bit; a Huffman code goes in from its highest.
    private struct BitWriter {
        var bytes: [UInt8] = []
        private var buffer: UInt64 = 0
        private var count: UInt64 = 0

        mutating func write(_ value: Int, _ length: Int) {
            buffer |= UInt64(value) << count
            count += UInt64(length)
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        mutating func code(_ code: Int, _ length: Int) {
            var reversed = 0
            for bit in 0..<length { reversed |= (code >> bit & 1) << (length - 1 - bit) }
            write(reversed, length)
        }

        /// A literal byte, a length's code or the block's end, in the fixed literal/length codes.
        mutating func symbol(_ symbol: Int) {
            switch symbol {
            case 0...143: code(0x30 + symbol, 8)
            case 144...255: code(0x190 + symbol - 144, 9)
            case 256...279: code(symbol - 256, 7)
            default: code(0xC0 + symbol - 280, 8)
            }
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
