import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Testing

@testable import DownscaleVideo

@Suite struct PlannerTests {
    private func inventory(
        size: String, fps: String = "30.00", durationMs: Int = 60_000, extra: [MetadataItem] = []
    ) -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(
            items: [
                item("video.dimensions", size), item("video.frameRate", fps),
                item("video.duration", String(durationMs)), item("audio.0.format", "aac "),
            ] + extra)
    }

    /// A file of `megabits` per second for 60 s.
    private func bytes(mbps: Double) -> Int64 { Int64(mbps * 1_000_000 * 60 / 8) }

    @Test func presetBitratesScaleWithPixelRate() {
        let hd = inventory(size: "1920x1080")
        let balanced = Preset.balanced.spec(for: hd, byteSize: bytes(mbps: 40))
        #expect((8_000_000...10_000_000).contains(balanced.averageBitRate))
        // A 1080p source keeps its resolution; the 1080 target applies to larger ones.
        #expect(balanced.targetShortSide == nil)
        let smaller = Preset.smaller.spec(for: hd, byteSize: bytes(mbps: 40))
        #expect(smaller.averageBitRate == Int(Double(balanced.averageBitRate) * 0.6))

        let uhd = inventory(size: "3840x2160")
        let high = Preset.high.spec(for: uhd, byteSize: bytes(mbps: 60))
        let balanced4K = Preset.balanced.spec(for: uhd, byteSize: bytes(mbps: 60))
        #expect(high.targetShortSide == nil)
        #expect(balanced4K.targetShortSide == 1080)
        #expect(high.averageBitRate > balanced4K.averageBitRate)
        // Floor is the balanced formula at the source resolution: 0.145 x 3840 x 2160 x 30.
        #expect(high.averageBitRate == Int(0.145 * 3840 * 2160 * 30))
    }

    @Test func highIsHalfTheSourceVideoBitrateAboveTheFloor() {
        let uhd = inventory(size: "3840x2160")
        // 100 Mbps total, minus one 256 kbps audio track, halved.
        let high = Preset.high.spec(for: uhd, byteSize: bytes(mbps: 100))
        #expect(abs(high.averageBitRate - Int((100_000_000.0 - 256_000) * 0.5)) < 1000)
    }

    @Test func everyPresetClampsToTwoMegabits() {
        let tiny = inventory(size: "3840x2160", durationMs: 0)
        for preset in Preset.allCases {
            #expect(preset.spec(for: tiny, byteSize: 1000).averageBitRate >= 2_000_000)
        }
    }

    @Test func smallLowBitrateSourceIsKeptAsIs() {
        // 720p30 balanced is ~4 Mbps; a 3 Mbps source is already below it.
        let source = inventory(size: "1280x720")
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: bytes(mbps: 3), preset: .balanced)
        #expect(decision == .keptAsIs(reason: "Already small"))
    }

    @Test func highBitrate1080pBalancedKeepsResolutionAndConverts() {
        let source = inventory(size: "1920x1080")
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: bytes(mbps: 40), preset: .balanced)
        guard case .convert(let spec, _, _) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        #expect(spec.targetShortSide == nil)
        #expect((8_000_000...10_000_000).contains(spec.averageBitRate))
    }

    @Test func unknownDurationIsKeptAsIs() {
        let source = inventory(size: "3840x2160", durationMs: 0)
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: 1_000_000, preset: .balanced)
        #expect(decision == .keptAsIs(reason: "Couldn't read the video's length"))
    }

    @Test func customSpecUsesTheSameRules() {
        let source = inventory(size: "2560x1440")
        let spec = DownscaleSpec(targetShortSide: 1080, averageBitRate: 9_000_000)
        let decision = DownscalePlanner.decide(inventory: source, byteSize: bytes(mbps: 10), spec: spec)
        #expect(decision == .keptAsIs(reason: "Would save less than 10%"))
    }

    @Test func lowBitrateKeepResolutionIsKeptAsIs() {
        let source = inventory(size: "3840x2160")
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: bytes(mbps: 5), preset: .high)
        #expect(decision == .keptAsIs(reason: "Already small"))
    }

    @Test func smallSavingIsKeptAsIs() {
        // 1440p at 10 Mbps: balanced 1080p is ~9 Mbps, saving under 10%.
        let source = inventory(size: "2560x1440")
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: bytes(mbps: 10), preset: .balanced)
        #expect(decision == .keptAsIs(reason: "Would save less than 10%"))
    }

    @Test func spatialIsKeptAsIs() {
        let stereo = MetadataItem(
            key: "hdr.stereo", category: .hdr, displayName: "Stereo views", value: "left+right")
        let source = inventory(size: "3840x2160", extra: [stereo])
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: bytes(mbps: 60), preset: .balanced)
        #expect(decision == .keptAsIs(reason: "Spatial video isn't supported yet — it would lose one eye"))
    }

    @Test func cinematicPredictsAuxLoss() throws {
        let aux = MetadataItem(
            key: "track.1.kind", category: .track, displayName: "Track 2 kind", value: "auxv/dish")
        let meta = MetadataItem(
            key: "trackmeta.1.com.apple.quicktime.x", category: .track, displayName: "x", value: "1")
        let source = inventory(size: "3840x2160", extra: [aux, meta])
        let decision = DownscalePlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: source, byteSize: bytes(mbps: 60), preset: .balanced)
        guard case .convert(_, _, let predicted) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        #expect(predicted.lost.map(\.key) == ["track.1.kind", "trackmeta.1.com.apple.quicktime.x"])
        #expect(predicted.changed.map(\.key).contains("video.dimensions"))
        #expect(predicted.changed.first { $0.key == "video.dimensions" }?.to == "1920x1080")
    }

    @Test(.timeLimit(.minutes(2))) func estimateWithinRange() async throws {
        var options = ClipOptions()
        options.seconds = 2
        let source = try await FixtureFactory.makeClip(options)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let inventory = try await MediaInspector().inventory(of: source)
        let byteSize = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64)

        let spec = Preset.balanced.spec(for: inventory, byteSize: byteSize)
        let estimate = Estimator.estimatedBytes(inventory: inventory, byteSize: byteSize, preset: .balanced)

        // R7: the estimate is the bit rate x duration math (plus audio and 1%), within 1%.
        let duration = (Double(try #require(inventory["video.duration"]).value) ?? 0) / 1000
        let source8 = SourceProfile(inventory: inventory, byteSize: byteSize)
        let audio = max(0, Double(byteSize) - source8.videoBitRate * duration / 8)
        let math = (Double(spec.averageBitRate) * duration / 8 + audio) * 1.01
        #expect(abs(Double(estimate) - math) <= math * 0.01)

        // The real output is at most 35% over the estimate. No lower bound: synthetic content undershoots.
        let output = source.deletingLastPathComponent().appending(path: "out.mov")
        try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }
        let actual = try #require(FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64)
        #expect(Double(actual) <= Double(estimate) * 1.35)
    }
}
