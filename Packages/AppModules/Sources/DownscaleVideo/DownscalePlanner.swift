import AppCore
import Foundation
import MediaEngine

public enum PlanDecision: Sendable, Equatable {
    case convert(DownscaleSpec, estimatedBytes: Int64, predicted: MetadataReport)
    case keptAsIs(reason: String, code: OutcomeCode = .other)
}

public enum DownscalePlanner {
    static let spatialReason = "Spatial video isn't supported yet — it would lose one eye"
    static let alreadySmallReason = "Already small"
    static let savesLittleReason = "Would save less than 10%"
    static let lengthUnreadableReason = "Couldn't read the video's length"
    /// A clip at this frame rate or above is slo-mo: its frame rate is always kept (spec 8.1).
    public static let sloMoFrameRate = 100.0

    /// True for a slo-mo clip, whose frame rate a conversion never lowers.
    public static func locksFrameRate(_ inventory: MetadataInventory) -> Bool {
        SourceProfile(inventory: inventory, byteSize: 0).isSloMo
    }

    public static func decide(source: URL, inventory: MetadataInventory, byteSize: Int64, preset: Preset)
        -> PlanDecision
    {
        decide(
            inventory: inventory, byteSize: byteSize, spec: preset.spec(for: inventory, byteSize: byteSize))
    }

    /// Decides for an explicit spec (a preset's or a custom one). `fallsBackToQuickTime` says the output leaves
    /// the source's MPEG-4 container for QuickTime (`OutputContainer.decide(for:)`), which the prediction counts.
    public static func decide(
        inventory: MetadataInventory, byteSize: Int64, spec: DownscaleSpec, fallsBackToQuickTime: Bool = false
    ) -> PlanDecision {
        decide(
            source: SourceProfile(inventory: inventory, byteSize: byteSize), inventory: inventory, spec: spec,
            fallsBackToQuickTime: fallsBackToQuickTime)
    }

    /// Decides with an already-read source profile, so the inventory is parsed once per decision. The spec in a
    /// `.convert` decision is the one to encode and verify with: `spec`, minus its frame-rate cap for slo-mo.
    static func decide(
        source: SourceProfile, inventory: MetadataInventory, spec requested: DownscaleSpec,
        fallsBackToQuickTime: Bool = false
    ) -> PlanDecision {
        var spec = requested
        if source.isSloMo { spec.maxFrameRate = nil }
        let byteSize = source.byteSize
        if inventory["hdr.stereo"] != nil { return .keptAsIs(reason: spatialReason, code: .spatialVideo) }
        guard source.durationSeconds > 0 else {
            return .keptAsIs(reason: lengthUnreadableReason, code: .lengthUnreadable)
        }
        if let target = spec.targetShortSide {
            if source.shortSide > 0, source.shortSide <= target {
                return .keptAsIs(reason: alreadySmallReason, code: .alreadySmall)
            }
        } else if source.videoBitRate > 0, source.videoBitRate <= Double(spec.averageBitRate) {
            return .keptAsIs(reason: alreadySmallReason, code: .alreadySmall)
        }
        let estimate = Estimator.estimatedBytes(source: source, spec: spec)
        if Double(estimate) > Double(byteSize) * 0.9 {
            return .keptAsIs(reason: savesLittleReason, code: .savesLittle)
        }
        var report = predicted(inventory: inventory, source: source, spec: spec)
        if fallsBackToQuickTime { report = movingToQuickTime(report, inventory: inventory) }
        return .convert(spec, estimatedBytes: estimate, predicted: report)
    }

    /// Moves what a QuickTime output of an MPEG-4 source loses from kept to lost.
    static func movingToQuickTime(_ report: MetadataReport, inventory: MetadataInventory) -> MetadataReport {
        let dropped = Set(OutputContainer.lostInQuickTimeFallback(inventory).map(\.key))
        guard !dropped.isEmpty else { return report }
        var report = report
        report.lost += report.kept.filter { dropped.contains($0.key) }
        report.kept.removeAll { dropped.contains($0.key) }
        return report
    }

    /// The `hdr.*` items an H.264 (SDR) output drops.
    static let h264LostKeys: Set<String> = [
        "hdr.dolbyVision", "hdr.masteringDisplay", "hdr.contentLightLevel", "hdr.ambientViewingEnvironment",
    ]

    /// What an H.264 output's format items become: `avc1`, and the 8-bit BT.709 SDR values the Replace gate
    /// (`ExpectedChanges`) accepts. The values are the inventory's.
    static let h264Values = ExpectedChanges.h264SDRValues.merging(["video.codec": "avc1"]) { current, _ in current }

    /// What the conversion is expected to change or drop: the dimensions (and the Dolby Vision level) when the
    /// size shrinks, and auxiliary video tracks such as the Cinematic disparity track. For H.264 also the codec,
    /// color and bit depth that differ from 8-bit BT.709, and every HDR item (lost). All else is kept.
    static func predicted(inventory: MetadataInventory, spec: DownscaleSpec) -> MetadataReport {
        predicted(inventory: inventory, source: SourceProfile(inventory: inventory, byteSize: 0), spec: spec)
    }

    static func predicted(inventory: MetadataInventory, source: SourceProfile, spec: DownscaleSpec)
        -> MetadataReport
    {
        let size = source.outputSize(shortSide: spec.targetShortSide)
        let resized = (size.width, size.height) != (source.width, source.height)
        let isH264 = spec.codec == .h264Compatible
        var report = MetadataReport()
        var seen = Set<String>()
        // `track.<n>.kind` = `auxv/<subtype>` marks an auxiliary video track (Cinematic disparity); the downscaler
        // drops it along with its `trackmeta.<n>.*` items.
        let auxPrefixes = inventory.items.compactMap { item -> String? in
            let parts = item.key.split(separator: ".")
            guard parts.count == 3, parts[0] == "track", parts[2] == "kind", item.value.hasPrefix("auxv/") else {
                return nil
            }
            return "trackmeta.\(parts[1])."
        }
        for item in inventory.items where seen.insert(item.key).inserted {
            if item.key.hasPrefix("track."), item.key.hasSuffix(".kind"), item.value.hasPrefix("auxv/") {
                report.lost.append(item)
            } else if auxPrefixes.contains(where: { item.key.hasPrefix($0) }) {
                report.lost.append(item)
            } else if isH264, h264LostKeys.contains(item.key) {
                report.lost.append(item)
            } else if isH264, let value = h264Values[item.key], value != item.value {
                report.changed.append(
                    MetadataChange(key: item.key, displayName: item.displayName, from: item.value, to: value))
            } else if resized, item.key == "video.dimensions" {
                report.changed.append(
                    MetadataChange(
                        key: item.key, displayName: item.displayName, from: item.value,
                        to: "\(size.width)x\(size.height)"))
            } else if resized, item.key == "hdr.dolbyVision" {
                report.changed.append(
                    MetadataChange(
                        key: item.key, displayName: item.displayName, from: item.value, to: "level adjusted"))
            } else {
                report.kept.append(item)
            }
        }
        return report
    }
}
