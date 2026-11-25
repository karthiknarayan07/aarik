import Foundation
import MediaEngine
import AppCore

/// How hard to shrink a video.
///
/// Bit rate table (spec 8.2). Every result is clamped to at least 2 Mbps.
///
/// | Preset   | Short side | Video bit rate                                                         |
/// |----------|------------|------------------------------------------------------------------------|
/// | high     | kept       | 50% of the source video bit rate, never below the balanced rate at the source size |
/// | balanced | 1080 (kept when the source is 1080 or smaller) | `0.145 x outputWidth x outputHeight x min(fps, 60)` (1920x1080 at 30 fps is about 9.0 Mbps) |
/// | smaller  | 1080 (kept when the source is 1080 or smaller) | 60% of balanced                                                        |
///
/// The source video bit rate is the whole file's bit rate (`byteSize x 8 / duration`) minus an assumed
/// 256 kbps per audio track, since the inventory carries no per-track bit rates.
public enum Preset: String, Codable, CaseIterable, Sendable {
    case high, balanced, smaller

    /// The lowest bit rate any preset produces.
    static let minimumBitRate = 2_000_000
    /// Bits per pixel per frame behind the balanced rate.
    static let bitsPerPixel = 0.145
    /// Assumed rate of each audio track, used to split the file's rate into video and audio.
    static let assumedAudioBitRate = 256_000

    public func spec(for inventory: MetadataInventory, byteSize: Int64) -> DownscaleSpec {
        let source = SourceProfile(inventory: inventory, byteSize: byteSize)
        switch self {
        case .high:
            let floor = Self.balancedBitRate(source: source, shortSide: nil)
            let rate = max(Int(source.videoBitRate * 0.5), floor)
            return DownscaleSpec(targetShortSide: nil, averageBitRate: rate)
        case .balanced:
            return DownscaleSpec(
                targetShortSide: source.downscaleTarget, averageBitRate: Self.balancedBitRate(source: source))
        case .smaller:
            let rate = Int(Double(Self.balancedBitRate(source: source)) * 0.6)
            return DownscaleSpec(
                targetShortSide: source.downscaleTarget, averageBitRate: max(rate, Self.minimumBitRate))
        }
    }

    /// The name shown to the user, also the output label when a preset keeps the resolution.
    public var displayName: String {
        switch self {
        case .high: "High"
        case .balanced: "Balanced"
        case .smaller: "Smaller"
        }
    }

    /// The balanced rate for the size the source has after scaling its short side to `shortSide` (never upscaled).
    private static func balancedBitRate(source: SourceProfile, shortSide: Int? = 1080) -> Int {
        let size = source.outputSize(shortSide: shortSide)
        let pixelRate = Double(size.width) * Double(size.height) * min(source.frameRate, 60)
        return max(Int(bitsPerPixel * pixelRate), minimumBitRate)
    }
}

/// What the presets and the estimator need to know about a source, read from its inventory.
struct SourceProfile {
    var width = 0
    var height = 0
    /// 30 when the inventory does not say.
    var frameRate = 30.0
    var durationSeconds = 0.0
    var audioTrackCount = 0
    var byteSize: Int64

    init(inventory: MetadataInventory, byteSize: Int64) {
        self.byteSize = byteSize
        let parts = inventory["video.dimensions"]?.value.split(separator: "x").compactMap { Int($0) } ?? []
        if parts.count == 2 { (width, height) = (parts[0], parts[1]) }
        if let fps = inventory["video.frameRate"].flatMap({ Double($0.value) }), fps > 0 { frameRate = fps }
        durationSeconds = (inventory["video.duration"].flatMap { Double($0.value) } ?? 0) / 1000
        let audioKeys = inventory.items.compactMap { item -> String? in
            let parts = item.key.split(separator: ".")
            return parts.count == 3 && parts[0] == "audio" && parts[2] == "format" ? String(parts[1]) : nil
        }
        audioTrackCount = Set(audioKeys).count
    }

    var shortSide: Int { min(width, height) }

    /// 1080 for a source taller than that; nil (keep the resolution) when the source is already 1080 or smaller,
    /// so the 1080 presets still compress it, at the bit rate formula for the source's own size.
    var downscaleTarget: Int? { shortSide > 1080 ? 1080 : nil }

    /// The source's video bit rate in bits per second: the file's rate minus the assumed audio; 0 when unknown.
    var videoBitRate: Double {
        guard durationSeconds > 0 else { return 0 }
        let total = Double(byteSize) * 8 / durationSeconds
        return max(0, total - Double(audioTrackCount * Preset.assumedAudioBitRate))
    }

    /// Encoded size when the short side is scaled to `shortSide` (nil keeps it). Never upscales.
    func outputSize(shortSide target: Int?) -> (width: Int, height: Int) {
        guard let target, shortSide > target else { return (width, height) }
        let size = DownscaleSpec(targetShortSide: target).outputSize(
            forNaturalSize: CGSize(width: width, height: height))
        return (Int(size.width), Int(size.height))
    }
}
