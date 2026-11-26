import AVFoundation
import AppCore
import CoreMedia
import CoreVideo
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

@Suite struct H264OutputTests {
    private static let bt709 = kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
    private let h264Spec = DownscaleSpec(targetShortSide: 360, averageBitRate: 3_000_000, codec: .h264Compatible)

    private func hlgClip(_ configure: (inout ClipOptions) -> Void = { _ in }) -> ClipOptions {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.hdr = .hlg
        configure(&options)
        return options
    }

    private func downscale(_ source: URL, spec: DownscaleSpec) async throws -> URL {
        let output = source.deletingLastPathComponent().appending(path: "output.mov")
        try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }
        return output
    }

    @Test(.timeLimit(.minutes(5))) func h264FromHLGIsSDR() async throws {
        let source = try await FixtureFactory.makeClip(
            hlgClip {
                $0.masteringDisplay = Data([
                    0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8, 0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40, 0x42,
                    0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
                ])
                $0.contentLightLevel = Data([0x03, 0xE8, 0x01, 0x90])
                $0.ambientViewingEnvironment = Data([0x00, 0x04, 0xCA, 0x80, 0x3D, 0x13, 0x40, 0x42])
            })
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await downscale(source, spec: h264Spec)

        let sourceInventory = try await MediaInspector().inventory(of: source)
        let inventory = try await MediaInspector().inventory(of: output)
        #expect(sourceInventory["hdr.dolbyVision"] != nil, "the HLG fixture should carry Dolby Vision")
        #expect(inventory["video.codec"]?.value == "avc1")
        #expect(inventory["video.transferFunction"]?.value == Self.bt709)
        #expect(inventory["video.colorPrimaries"]?.value == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(inventory["video.matrix"]?.value == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
        #expect(inventory["video.bitDepth"]?.value == "8")
        #expect(inventory["video.dimensions"]?.value == "640x360")
        #expect(inventory["hdr.dolbyVision"] == nil)
        #expect(inventory.items.filter { $0.key.hasPrefix("hdr.") }.isEmpty, "hdr: \(inventory.items)")
        // Audio still passes through.
        #expect(inventory["audio.0.format"] == sourceInventory["audio.0.format"])

        let report = MetadataDiff.report(source: sourceInventory, output: inventory)
        #expect(ExpectedChanges.unexpected(in: report, spec: h264Spec).isEmpty, "changed: \(report.changed)")
        let lost = Set(report.lost.map(\.key))
        #expect(
            lost == [
                "hdr.dolbyVision", "hdr.masteringDisplay", "hdr.contentLightLevel", "hdr.ambientViewingEnvironment",
            ],
            "lost: \(lost)")
    }

    /// Stripes at HLG 50% (mid grey), 75% (reference white, 203 nits) and 100% (peak). A clipping conversion (HLG
    /// light scaled to SDR white and cut off) puts reference white and peak at the same code; keeping the code values
    /// and only relabelling them 709 (washed out) leaves reference white at about 180. Tone mapping keeps the three
    /// apart and mid grey in the SDR mid-tones.
    @Test(.timeLimit(.minutes(5))) func h264ToneMapsHLGInsteadOfClipping() async throws {
        let source = try await FixtureFactory.makeClip(
            hlgClip {
                $0.lumaStripes = [0.5, 0.75, 1.0]
                $0.includeAudio = false
                $0.seconds = 0.5
            })
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await downscale(source, spec: h264Spec)

        let lumas = try await Self.stripeLumas(of: output, count: 3)
        let (grey, white, peak) = (lumas[0], lumas[1], lumas[2])
        // 8-bit video range: 16 black, 235 white.
        #expect((70...170).contains(grey), "mid grey \(grey), all \(lumas)")
        #expect(white > grey + 20, "reference white \(white), all \(lumas)")
        #expect(peak > white + 20, "peak \(peak) not above reference white \(white): clipped")
        #expect(peak <= 240, "peak \(peak)")
        let relabelled = 16 + 0.75 * 219
        #expect(abs(Double(white) - relabelled) > 15, "reference white \(white) looks relabelled, not converted")
    }

    /// Mean 8-bit luma of a 16x16 block in the middle of each of `count` vertical stripes of the first frame.
    private static func stripeLumas(of url: URL, count: Int) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(sample.imageBuffer)
        reader.cancelReading()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        return (0..<count).map { stripe in
            let centerX = (2 * stripe + 1) * width / (2 * count)
            var sum = 0
            for y in (height / 2 - 8)..<(height / 2 + 8) {
                for x in (centerX - 8)..<(centerX + 8) { sum += Int(base[y * stride + x]) }
            }
            return sum / 256
        }
    }
}
