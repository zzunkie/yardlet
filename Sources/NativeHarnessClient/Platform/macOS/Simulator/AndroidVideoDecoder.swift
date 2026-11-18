import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// H.264 as scrcpy sends it, an Annex B byte stream: each NAL unit after a start code (00 00 01 or 00 00 00 01).
enum H264AnnexB {
    static let sequenceParameterSet: UInt8 = 7
    static let pictureParameterSet: UInt8 = 8

    static func type(of unit: Data) -> UInt8 { (unit.first ?? 0) & 0x1F }

    static func isParameterSet(_ unit: Data) -> Bool {
        let type = type(of: unit)
        return type == sequenceParameterSet || type == pictureParameterSet
    }

    /// The NAL units in `data`, without their start codes or the zero bytes that may come before the next one.
    static func nalUnits(in data: Data) -> [Data] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Data] in
            guard let base = bytes.baseAddress else { return [] }
            let count = bytes.count
            var starts: [(code: Int, payload: Int)] = []
            var index = 0
            // A start code ends in 01 after two zeros, so a byte above 1 rules out the three places it could begin.
            while index + 2 < count {
                if bytes[index + 2] > 1 {
                    index += 3
                } else if bytes[index + 1] != 0 {
                    index += 2
                } else if bytes[index] != 0 || bytes[index + 2] != 1 {
                    index += 1
                } else {
                    starts.append((index, index + 3))
                    index += 3
                }
            }
            var units: [Data] = []
            for (number, start) in starts.enumerated() {
                var end = number + 1 < starts.count ? starts[number + 1].code : count
                while end > start.payload, bytes[end - 1] == 0 { end -= 1 }
                if end > start.payload { units.append(Data(bytes: base + start.payload, count: end - start.payload)) }
            }
            return units
        }
    }

    /// The units in the form VideoToolbox decodes (AVCC): each after its length in four big-endian bytes.
    static func avcc(_ units: [Data]) -> Data {
        var data = Data(capacity: units.reduce(0) { $0 + 4 + $1.count })
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(unit)
        }
        return data
    }
}

/// Decodes one device's scrcpy stream with VideoToolbox into IOSurface-backed BGRA pixel buffers, which a layer
/// shows as they are. It works on a queue of its own: the session hands it packets from its actor, and nothing here
/// touches the main thread. The device sends its parameter sets again with each new capture (the device turned, the
/// stream was reset), and the decoder starts over with them.
final class AndroidVideoDecoder: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let surface: IOSurfaceRef
        let width: Int
        let height: Int
        /// Increases each time the decoder starts over with new parameter sets.
        let format: UInt64
        let sequence: UInt64
        /// When the frame came out of the decoder, in `DispatchTime.uptimeNanoseconds`.
        let decodedAt: UInt64
    }

    /// How many recent frames stay referenced: one on screen, one being placed and one spare, so the decoder's pool
    /// never paints into a surface a layer may still be reading.
    private static let keptFrames = 3

    private let queue = DispatchQueue(label: "Yardlet Android video", qos: .userInteractive)
    private let output: @Sendable (Frame) -> Void
    private let needsKeyFrame: @Sendable () -> Void

    // Used on `queue` only.
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var formatNumber: UInt64 = 0
    private var waitingForKeyFrame = true
    private var askedForKeyFrameAt: UInt64 = 0
    private var closed = false

    // The decoder's output handler may run on another thread.
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var kept: [Frame] = []

    /// `output` gets each decoded frame, on the decoder's thread; `needsKeyFrame` asks the device for a key frame
    /// after the decoder lost its place, at most once a second.
    init(output: @escaping @Sendable (Frame) -> Void, needsKeyFrame: @escaping @Sendable () -> Void) {
        self.output = output
        self.needsKeyFrame = needsKeyFrame
    }

    /// The last frame decoded.
    var latest: Frame? { lock.withLock { kept.last } }

    func handle(_ event: ScrcpyVideoEvent) {
        queue.async { self.decode(event) }
    }

    /// Lets go of the decoder and its frames once the stream ended.
    func close() {
        queue.async {
            self.closed = true
            self.invalidate()
            self.lock.withLock { self.kept = [] }
        }
    }

    /// Waits until the packets handed in so far are decoded.
    func flush() {
        queue.sync {
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        }
    }

    // MARK: - On the queue

    private func decode(_ event: ScrcpyVideoEvent) {
        guard !closed else { return }
        switch event {
        case .session:
            // A new capture: its parameter sets and a key frame come next.
            waitingForKeyFrame = true
        case let .packet(data, presentation, isKeyFrame):
            let units = H264AnnexB.nalUnits(in: data)
            let sets = units.filter(H264AnnexB.isParameterSet)
            if !sets.isEmpty { configure(sets) }
            // A config packet carries no picture.
            guard let presentation, session != nil else { return }
            let pictures = units.filter { !H264AnnexB.isParameterSet($0) }
            guard !pictures.isEmpty else { return }
            if waitingForKeyFrame {
                guard isKeyFrame else { return }
                waitingForKeyFrame = false
            }
            decodePicture(pictures, presentation: presentation)
        }
    }

    private func configure(_ sets: [Data]) {
        let ordered = sets.filter { H264AnnexB.type(of: $0) == H264AnnexB.sequenceParameterSet }
            + sets.filter { H264AnnexB.type(of: $0) == H264AnnexB.pictureParameterSet }
        guard ordered != parameterSets || session == nil else { return }
        guard let format = Self.format(ordered) else {
            askForKeyFrame()
            return
        }
        parameterSets = ordered
        self.format = format
        formatNumber += 1
        startSession()
    }

    private func startSession() {
        invalidate()
        guard let format else { return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { return askForKeyFrame() }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        waitingForKeyFrame = true
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private func decodePicture(_ units: [Data], presentation: UInt64) {
        guard let session, let format, let sample = Self.sample(H264AnnexB.avcc(units), format: format,
                                                                  presentation: presentation) else { return }
        let formatNumber = formatNumber
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback],
                                                       infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr else { return self.queue.async { self.lostPlace(status) } }
            guard let image, let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return }
            self.decoded(image, surface: surface, format: formatNumber)
        }
        if status != noErr { lostPlace(status) }
    }

    private func decoded(_ image: CVPixelBuffer, surface: IOSurfaceRef, format: UInt64) {
        let frame = lock.withLock { () -> Frame in
            sequence += 1
            let frame = Frame(pixelBuffer: image, surface: surface, width: CVPixelBufferGetWidth(image),
                              height: CVPixelBufferGetHeight(image), format: format, sequence: sequence,
                              decodedAt: DispatchTime.now().uptimeNanoseconds)
            kept.append(frame)
            if kept.count > Self.keptFrames { kept.removeFirst(kept.count - Self.keptFrames) }
            return frame
        }
        output(frame)
    }

    /// A packet did not decode: the pictures that follow depend on it, so wait for the next key frame, and start
    /// the decoder again if the system took its session away (sleep, a change of GPU).
    private func lostPlace(_ status: OSStatus) {
        guard !closed else { return }
        if status == kVTInvalidSessionErr { startSession() }
        waitingForKeyFrame = true
        askForKeyFrame()
    }

    private func askForKeyFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - askedForKeyFrameAt >= 1_000_000_000 else { return }
        askedForKeyFrameAt = now
        needsKeyFrame()
    }

    // MARK: - Core Media

    private static func format(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard sets.contains(where: { H264AnnexB.type(of: $0) == H264AnnexB.sequenceParameterSet }),
              sets.contains(where: { H264AnnexB.type(of: $0) == H264AnnexB.pictureParameterSet }) else { return nil }
        // Core Media copies the sets; the pointers only need to live for the call.
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription, presentation: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: Int64(clamping: presentation),
                                                                      timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                               formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                               sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                               sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
