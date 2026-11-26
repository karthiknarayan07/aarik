import AarikCore
import Foundation
import MediaEngine
import Testing

@testable import Convert

/// Spec 8.2: the header's preset is the default; the inspector overrides it per video.
@Suite struct PresetOverridesTests {
    private func inventory(size: String) -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(items: [
            item("video.dimensions", size), item("video.frameRate", "30.00"), item("video.duration", "60000"),
        ])
    }

    private var big: SavingsCalculator.Source {
        (byteSize: Int64(100_000_000 * 60 / 8), inventory: inventory(size: "3840x2160"))
    }

    @Test func withoutAnOverrideAVideoUsesTheDefault() {
        let overrides = PresetOverrides<Int>()
        #expect(overrides.isEmpty)
        #expect(overrides.preset(for: 1, default: .balanced) == .balanced)
        #expect(overrides.preset(for: 1, default: .high) == .high)
        #expect(overrides.shownOverride(for: 1, default: .balanced) == nil)
    }

    @Test func anOverrideOutlivesAChangeOfTheDefault() {
        var overrides = PresetOverrides<Int>()
        overrides.set(.smaller, for: [1, 2], default: .balanced)

        #expect(overrides.preset(for: 1, default: .balanced) == .smaller)
        #expect(overrides.preset(for: 2, default: .balanced) == .smaller)
        #expect(overrides.preset(for: 3, default: .balanced) == .balanced)
        // The header changes: videos with an override keep it, the others follow.
        #expect(overrides.preset(for: 1, default: .high) == .smaller)
        #expect(overrides.preset(for: 3, default: .high) == .high)
        #expect(overrides.shownOverride(for: 1, default: .high) == .smaller)
        // While the header shows the same preset, the tile needs no indicator.
        #expect(overrides.shownOverride(for: 1, default: .smaller) == nil)
    }

    @Test func choosingTheDefaultDropsTheOverride() {
        var overrides = PresetOverrides<Int>()
        overrides.set(.smaller, for: [1], default: .balanced)
        overrides.set(.balanced, for: [1], default: .balanced)

        #expect(overrides.isEmpty)
        // It follows the header again.
        #expect(overrides.preset(for: 1, default: .high) == .high)
    }

    @Test func aSelectionSharesAPresetOrIsMixed() {
        var overrides = PresetOverrides<Int>()
        overrides.set(.smaller, for: [1], default: .balanced)

        #expect(overrides.selectionPreset(for: [2, 3], default: .balanced) == .balanced)
        #expect(overrides.selectionPreset(for: [1], default: .balanced) == .smaller)
        #expect(overrides.selectionPreset(for: [1, 2], default: .balanced) == nil)
        #expect(overrides.selectionPreset(for: [], default: .balanced) == .balanced)

        // Choosing a row for a mixed selection applies to all of it.
        overrides.set(.high, for: [1, 2], default: .balanced)
        #expect(overrides.selectionPreset(for: [1, 2], default: .balanced) == .high)
    }

    @Test func removedVideosLoseTheirOverrides() {
        var overrides = PresetOverrides<Int>()
        overrides.set(.smaller, for: [1, 2], default: .balanced)
        overrides.remove([1])

        #expect(overrides.preset(for: 1, default: .balanced) == .balanced)
        #expect(overrides.preset(for: 2, default: .balanced) == .smaller)
    }

    @Test func savingsUseEachVideosEffectivePreset() {
        var overrides = PresetOverrides<Int>()
        overrides.set(.smaller, for: [2], default: .balanced)
        let sources = [(id: 1, source: big), (id: 2, source: big)]

        let freed = overrides.couldFreeBytes(for: sources, default: .balanced)

        let balanced = SavingsCalculator.couldFreeBytes(for: [big], preset: .balanced)
        let smaller = SavingsCalculator.couldFreeBytes(for: [big], preset: .smaller)
        #expect(smaller > balanced)
        #expect(freed == balanced + smaller)
        // A custom spec applies to every video, whatever its preset.
        let custom = DownscaleSpec(targetShortSide: 720, averageBitRate: 4_000_000)
        #expect(
            overrides.couldFreeBytes(for: sources, default: .balanced, custom: custom)
                == SavingsCalculator.couldFreeBytes(for: [big, big], preset: .balanced, custom: custom))
    }

    @Test func savingsForPerVideoPresetsSumEachVideo() {
        let freed = SavingsCalculator.couldFreeBytes(for: [
            (source: big, preset: .high), (source: big, preset: .smaller),
        ])
        #expect(
            freed
                == SavingsCalculator.couldFreeBytes(for: [big], preset: .high)
                + SavingsCalculator.couldFreeBytes(for: [big], preset: .smaller))
    }

    @Test func lossesUseEachVideosPreset() {
        let lossy = MetadataInventory(
            items: inventory(size: "3840x2160").items + [
                MetadataItem(key: "qt.uiso/loci", category: .location, displayName: "Location", value: "+1+2/")
            ])
        let source = (byteSize: big.byteSize, inventory: lossy)

        let losses = LossCheck.losses(
            for: [(id: 1, source: source, preset: .high), (id: 2, source: source, preset: .smaller)],
            quickTimeFallbacks: [2])

        #expect(losses == [PredictedLoss(id: 2, lost: ["Location"], keys: ["qt.uiso/loci"])])
    }

    @Test func jobsCarryEachVideosPreset() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "overrides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try (1...2).map { index in
            let url = folder.appending(path: "clip-\(index).mov")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .replace)

        let batch = JobFactory.makeJobs(
            for: [(url: urls[0], preset: .high), (url: urls[1], preset: .smaller)], settings: settings,
            losses: [urls[1]: PredictedLoss(id: UUID(), lost: ["Location"], keys: ["qt.uiso/loci"])])

        let decoded = try batch.jobs.map { try JSONDecoder().decode(ConvertJobSettings.self, from: $0.settings) }
        #expect(batch.jobs.map(\.source) == urls)
        #expect(decoded.map(\.preset) == [.high, .smaller])
        #expect(decoded.map(\.saveTo) == [.replace, .replace])
        #expect(decoded.map(\.predictedLost) == [[], ["Location"]])
        #expect(decoded.map(\.predictedLostKeys) == [[], ["qt.uiso/loci"]])
    }
}
