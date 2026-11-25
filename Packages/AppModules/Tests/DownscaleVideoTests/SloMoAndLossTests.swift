import AppCore
import Foundation
import MediaEngine
import Testing

@testable import DownscaleVideo

/// Slo-mo keeps its frame rate (spec 8.1), and what a conversion would lose is known before it runs (spec 8.4).
@Suite struct SloMoAndLossTests {
    private func item(_ key: String, _ value: String, name: String? = nil) -> MetadataItem {
        MetadataItem(key: key, category: .video, displayName: name ?? key, value: value)
    }

    private func inventory(size: String = "3840x2160", fps: String = "30.00", extra: [MetadataItem] = [])
        -> MetadataInventory
    {
        MetadataInventory(
            items: [
                item("video.dimensions", size), item("video.frameRate", fps), item("video.duration", "60000"),
                item("audio.0.format", "aac "),
            ] + extra)
    }

    /// 60 Mbps for 60 s.
    private let byteSize = Int64(60_000_000 * 60 / 8)

    @Test func sloMoDropsTheFrameRateCap() throws {
        let capped = DownscaleSpec(targetShortSide: 1080, averageBitRate: 8_000_000, maxFrameRate: 30)
        let decision = DownscalePlanner.decide(inventory: inventory(fps: "120.00"), byteSize: byteSize, spec: capped)
        guard case .convert(let spec, _, _) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        #expect(spec.maxFrameRate == nil)
        #expect(spec.targetShortSide == 1080)
        #expect(DownscalePlanner.locksFrameRate(inventory(fps: "120.00")))
        #expect(DownscalePlanner.locksFrameRate(inventory(fps: "240.00")))
    }

    @Test func normalClipKeepsTheFrameRateCap() throws {
        let capped = DownscaleSpec(targetShortSide: 1080, averageBitRate: 8_000_000, maxFrameRate: 30)
        let decision = DownscalePlanner.decide(inventory: inventory(fps: "60.00"), byteSize: byteSize, spec: capped)
        guard case .convert(let spec, _, _) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        #expect(spec.maxFrameRate == 30)
        #expect(!DownscalePlanner.locksFrameRate(inventory(fps: "60.00")))
        #expect(!DownscalePlanner.locksFrameRate(MetadataInventory(items: [])))
    }

    @Test func verificationRejectsAFrameRateChangeOnSloMo() throws {
        let capped = DownscaleSpec(targetShortSide: 1080, averageBitRate: 8_000_000, maxFrameRate: 30)
        let decision = DownscalePlanner.decide(inventory: inventory(fps: "120.00"), byteSize: byteSize, spec: capped)
        guard case .convert(let spec, _, let predicted) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        let report = MetadataReport(
            changed: [MetadataChange(key: "video.frameRate", displayName: "Frame rate", from: "120.00", to: "30.00")])
        #expect(!DownscaleRunner.isVerified(report, predicted: predicted, spec: spec))
        // The cap as asked for would have let the change through; the planner's spec is the one that counts.
        #expect(DownscaleRunner.isVerified(report, predicted: predicted, spec: capped))
    }

    @Test func cinematicLosesItsDepthDataAsOneReadableEntry() {
        let source = inventory(extra: [
            item("track.2.kind", "auxv/dish", name: "Track 3 kind"),
            item("trackmeta.2.com.apple.quicktime.x", "1", name: "Track 3 x"),
        ])
        #expect(
            LossCheck.lostNames(byteSize: byteSize, inventory: source, preset: .balanced) == ["Cinematic depth data"])
    }

    @Test func h264OfAnHDRClipLosesItsHDRMetadata() {
        let source = inventory(extra: [
            item("hdr.dolbyVision", "profile 8, level 9, compat 4", name: "Dolby Vision"),
            item("hdr.masteringDisplay", "ab", name: "Mastering display"),
        ])
        let h264 = DownscaleSpec(targetShortSide: 1080, averageBitRate: 12_000_000, codec: .h264Compatible)
        #expect(
            LossCheck.lostNames(byteSize: byteSize, inventory: source, preset: .balanced, custom: h264)
                == ["Dolby Vision", "Mastering display"])
        #expect(LossCheck.lostNames(byteSize: byteSize, inventory: source, preset: .balanced).isEmpty)
    }

    @Test func keptAsIsLosesNothing() {
        let spatial = inventory(extra: [
            item("hdr.stereo", "left+right"), item("track.2.kind", "auxv/dish"),
        ])
        #expect(LossCheck.lostNames(byteSize: byteSize, inventory: spatial, preset: .balanced).isEmpty)
    }

    @Test func lossesListOnlyTheVideosThatLoseSomething() {
        let plain = inventory()
        let cinematic = inventory(extra: [item("track.2.kind", "auxv/dish")])
        let losses = LossCheck.losses(
            for: [(id: 1, source: (byteSize, plain)), (id: 2, source: (byteSize, cinematic))], preset: .balanced)
        #expect(losses == [PredictedLoss(id: 2, lost: ["Cinematic depth data"])])
    }
}
