// Writes a short, deliberately heavy test clip for the iOS UI tests: 1080p H.264 at a high bit rate over noisy frames, so
// converting it saves far more than the 10 % the planner requires even with the Simulator's software encoder. Generated,
// never personal media, with the camera-style metadata the app keeps.
//
//   swift scripts/make-ui-fixture.swift <out.mov> [seconds] [mbps]
import AVFoundation
import CoreVideo
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-ui-fixture.swift <out.mov> [seconds] [mbps]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 6 : 6
let mbps = arguments.count > 3 ? Int(arguments[3]) ?? 40 : 40
let width = 1920
let height = 1080
let fps = 30
if FileManager.default.fileExists(atPath: output.path) {
    FileHandle.standardError.write(Data("refusing to overwrite \(output.path)\n".utf8))
    exit(1)
}

let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: mbps * 1_000_000, AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
writer.add(input)

func item(_ key: String, _ value: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}
writer.metadata = [
    item("com.apple.quicktime.make", "TestMake"), item("com.apple.quicktime.model", "TestModel"),
    item("com.apple.quicktime.software", "1.0"),
    item("com.apple.quicktime.creationdate", "2020-01-02T03:04:05+0000"),
    item("com.apple.quicktime.location.ISO6709", "+10.0000+20.0000+5.000/"),
]

guard writer.startWriting() else { fatalError("writer failed: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

let padSize = width * height * 4 * 3
var pad = Data(count: padSize)
pad.withUnsafeMutableBytes { raw in
    _ = SecRandomCopyBytes(kSecRandomDefault, padSize, raw.baseAddress!)
}
let frames = Int(seconds * Double(fps))
for frame in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytes = CVPixelBufferGetBytesPerRow(buffer) * height
    // A different slice of a random pad per frame: nothing for the encoder to predict, so the file really is large.
    pad.withUnsafeBytes { source in
        let start = (frame * 7919 * 4) % (padSize - bytes)
        memcpy(base, source.baseAddress! + start, bytes)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("finish failed: \(String(describing: writer.error))") }
print("Wrote \(output.path)")
