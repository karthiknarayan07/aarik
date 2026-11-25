import AppCore
import CoreMedia
import Foundation
import MediaEngine

public enum PlanDecision: Sendable, Equatable {
    case convert(DownscaleSpec, estimatedBytes: Int64, predicted: MetadataReport)
    case keptAsIs(reason: String)
}

public enum DownscalePlanner {
    static let spatialReason = "Spatial video isn't supported yet — it would lose one eye"

    public static func decide(source: URL, inventory: MetadataInventory, byteSize: Int64, preset: Preset)
        -> PlanDecision
    {
        decide(
            inventory: inventory, byteSize: byteSize, spec: preset.spec(for: inventory, byteSize: byteSize))
    }

    /// Decides for an explicit spec (a preset's or a custom one).
    public static func decide(inventory: MetadataInventory, byteSize: Int64, spec: DownscaleSpec) -> PlanDecision {
        decide(source: SourceProfile(inventory: inventory, byteSize: byteSize), inventory: inventory, spec: spec)
    }

    /// Decides with an already-read source profile, so the inventory is parsed once per decision.
    static func decide(source: SourceProfile, inventory: MetadataInventory, spec: DownscaleSpec) -> PlanDecision {
        let byteSize = source.byteSize
        if inventory["hdr.stereo"] != nil { return .keptAsIs(reason: spatialReason) }
        guard source.durationSeconds > 0 else { return .keptAsIs(reason: "Couldn't read the video's length") }
        if let target = spec.targetShortSide {
            if source.shortSide > 0, source.shortSide <= target { return .keptAsIs(reason: "Already small") }
        } else if source.videoBitRate > 0, source.videoBitRate <= Double(spec.averageBitRate) {
            return .keptAsIs(reason: "Already small")
        }
        let estimate = Estimator.estimatedBytes(source: source, spec: spec)
        if Double(estimate) > Double(byteSize) * 0.9 {
            return .keptAsIs(reason: "Would save less than 10%")
        }
        let report = predicted(inventory: inventory, source: source, spec: spec)
        return .convert(spec, estimatedBytes: estimate, predicted: report)
    }

    /// The `hdr.*` items an H.264 (SDR) output drops.
    static let h264LostKeys: Set<String> = [
        "hdr.dolbyVision", "hdr.masteringDisplay", "hdr.contentLightLevel", "hdr.ambientViewingEnvironment",
    ]

    /// What an H.264 output's format items become: H.264 8-bit BT.709 SDR. The values are the inventory's.
    static let h264Values: [String: String] = [
        "video.codec": "avc1",
        "video.colorPrimaries": kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
        "video.transferFunction": kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
        "video.matrix": kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
        "video.bitDepth": "8",
    ]

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
