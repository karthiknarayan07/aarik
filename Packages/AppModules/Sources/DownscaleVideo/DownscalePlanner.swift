import AppCore
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
    static func decide(inventory: MetadataInventory, byteSize: Int64, spec: DownscaleSpec) -> PlanDecision {
        if inventory["hdr.stereo"] != nil { return .keptAsIs(reason: spatialReason) }
        let source = SourceProfile(inventory: inventory, byteSize: byteSize)
        if let target = spec.targetShortSide {
            if source.shortSide > 0, source.shortSide <= target { return .keptAsIs(reason: "Already small") }
        } else if source.videoBitRate > 0, source.videoBitRate <= Double(spec.averageBitRate) {
            return .keptAsIs(reason: "Already small")
        }
        let estimate = Estimator.estimatedBytes(inventory: inventory, byteSize: byteSize, spec: spec)
        if source.durationSeconds > 0, byteSize > 0, Double(estimate) > Double(byteSize) * 0.9 {
            return .keptAsIs(reason: "Would save less than 10%")
        }
        return .convert(spec, estimatedBytes: estimate, predicted: predicted(inventory: inventory, spec: spec))
    }

    /// What the conversion is expected to change or drop: the dimensions (and the Dolby Vision level) when the
    /// size shrinks, and auxiliary video tracks such as the Cinematic disparity track. All else is kept.
    static func predicted(inventory: MetadataInventory, spec: DownscaleSpec) -> MetadataReport {
        let source = SourceProfile(inventory: inventory, byteSize: 0)
        let size = source.outputSize(shortSide: spec.targetShortSide)
        let resized = (size.width, size.height) != (source.width, source.height)
        var report = MetadataReport()
        var seen = Set<String>()
        for item in inventory.items where seen.insert(item.key).inserted {
            if item.key.hasPrefix("track."), item.key.hasSuffix(".kind"), item.value.contains("auxv") {
                report.lost.append(item)
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
