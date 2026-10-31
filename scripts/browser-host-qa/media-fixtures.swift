// Writes one-second H.264 and AAC files for the browser panel's media check (form-server.py, /media):
// h264-aac.mp4 (both tracks, as a phone or screen recording has), h264.mp4 (video only), aac.m4a
// (audio only) and h264-aac-fragmented.mp4 (both tracks as fragmented MP4, which Media Source Extensions
// take as sites stream video). AVFoundation encodes them, so the check needs no encoder of its own.
// usage: media-fixtures <output directory>
import AVFoundation
import CoreVideo
import Foundation
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: media-fixtures <output directory>\n".data(using: .utf8)!)
    exit(2)
}
let directory = URL(filePath: arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let width = 320, height = 180, frames = 30, sampleRate = 44_100, chunk = 1_024

/// A frame of one color, a little brighter each frame.
func pixelBuffer(_ index: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = base + y * row + x * 4
            pixel[0] = 200; pixel[1] = UInt8(index * 8); pixel[2] = 40; pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    return pixels
}

/// `chunk` samples of a 440 Hz tone, 16-bit mono, starting at sample `start`.
func toneBuffer(start: Int) -> CMSampleBuffer {
    var format = AudioStreamBasicDescription(
        mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
        mReserved: 0)
    var description: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    // In two steps, which older compilers type-check in time.
    let samples = (0..<chunk).map { index -> Int16 in
        let seconds = Double(start + index) / Double(sampleRate)
        return Int16(sin(seconds * 2 * .pi * 440) * 6_000)
    }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: chunk * 2, flags: 0,
                                       blockBufferOut: &block)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                                                offsetIntoDestination: 0, dataLength: chunk * 2) }
    var buffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: chunk,
        presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &buffer)
    return buffer!
}

/// Collects a fragmented writer's initialization segment and fragments, in order, into one file's bytes.
final class Segments: NSObject, AVAssetWriterDelegate {
    var data = Data()

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        data.append(segmentData)
    }
}

func write(_ name: String, type: AVFileType, video: Bool, audio: Bool, fragmented: Bool = false) async throws {
    let url = directory.appending(path: name)
    try? FileManager.default.removeItem(at: url)
    let segments = Segments()
    let writer: AVAssetWriter
    if fragmented {
        writer = AVAssetWriter(contentType: UTType(type.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(value: 1, timescale: 2)
        writer.initialSegmentStartTime = .zero
        writer.delegate = segments
    } else {
        writer = try AVAssetWriter(outputURL: url, fileType: type)
    }
    var videoInput: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor?, audioInput: AVAssetWriterInput?
    if video {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: frames / 2]
        ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        videoInput = input
    }
    if audio {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        writer.add(input)
        audioInput = input
    }
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    // The writer interleaves the tracks and may hold one back until the other catches up, so they are fed in
    // time order.
    var frame = video ? 0 : frames, sample = audio ? 0 : sampleRate
    while frame < frames || sample < sampleRate {
        let videoNext = frame < frames ? Double(frame) / 30 : .infinity
        let audioNext = sample < sampleRate ? Double(sample) / Double(sampleRate) : .infinity
        if videoNext <= audioNext, let videoInput, let adaptor {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(pixelBuffer(frame), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            frame += 1
        } else if let audioInput {
            while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            audioInput.append(toneBuffer(start: sample))
            sample += chunk
        }
    }
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    if fragmented { try segments.data.write(to: url) }
}

try await write("h264-aac.mp4", type: .mp4, video: true, audio: true)
try await write("h264.mp4", type: .mp4, video: true, audio: false)
try await write("aac.m4a", type: .m4a, video: false, audio: true)
try await write("h264-aac-fragmented.mp4", type: .mp4, video: true, audio: true, fragmented: true)
