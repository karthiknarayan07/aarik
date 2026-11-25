import AppCore
import Foundation
import MediaEngine

public enum Estimator {
    /// Output size for a preset: video bit rate x duration / 8, plus the source's audio carried over as-is
    /// (source bytes minus the estimated source video bytes, never negative), plus 1%.
    public static func estimatedBytes(inventory: MetadataInventory, byteSize: Int64, preset: Preset) -> Int64 {
        estimatedBytes(
            inventory: inventory, byteSize: byteSize, spec: preset.spec(for: inventory, byteSize: byteSize))
    }

    static func estimatedBytes(inventory: MetadataInventory, byteSize: Int64, spec: DownscaleSpec) -> Int64 {
        let source = SourceProfile(inventory: inventory, byteSize: byteSize)
        guard source.durationSeconds > 0 else { return byteSize }
        let videoBytes = Double(spec.averageBitRate) * source.durationSeconds / 8
        let sourceVideoBytes = source.videoBitRate * source.durationSeconds / 8
        let audioBytes = max(0, Double(byteSize) - sourceVideoBytes)
        return Int64(((videoBytes + audioBytes) * 1.01).rounded())
    }
}
