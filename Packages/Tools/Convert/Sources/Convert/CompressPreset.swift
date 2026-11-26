import AppCore
import Foundation
import MediaEngine

/// How hard to compress a video while keeping its resolution, frame rate, HDR, Dolby Vision, and metadata (ADR 0005).
///
/// Each preset targets a fraction of the source's video bit rate, clamped above a 0.04 bits-per-pixel-per-frame floor
/// so low-bit-rate sources aren't crushed (and instead stay untouched as "Already small").
public enum CompressPreset: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case smaller
    case balanced
    case bestQuality

    /// Minimum bits per pixel per frame so a low-bit-rate source is never crushed (ADR 0005).
    static let minimumBitsPerPixel = 0.04
    /// Hard minimum bit rate when dimensions are known (e.g. 720p30 at 0.04 bpp is ~1.1 Mbps).
    static let absoluteMinimumBitRate = 1_000_000

    public var id: Self { self }

    /// Target video bit rate as a fraction of the source's video bit rate.
    public var bitRateRatio: Double {
        switch self {
        case .smaller: 0.25
        case .balanced: 0.40
        case .bestQuality: 0.60
        }
    }

    /// Title Case name for controls.
    public var displayName: String {
        switch self {
        case .smaller: "Smaller"
        case .balanced: "Balanced"
        case .bestQuality: "Best Quality"
        }
    }

    /// Sentence case description for pickers and accessibility.
    public var detail: String {
        switch self {
        case .smaller: "Largest saving. Fine detail may soften."
        case .balanced: "Visually close to the original."
        case .bestQuality: "Hard to tell from the source."
        }
    }

    /// Approximate saving headline when exact source metadata isn't available yet (e.g. Photos before download).
    public var approximateSavingText: String {
        let percent = Int(((1 - bitRateRatio) * 100).rounded())
        return "About \(percent)% smaller"
    }

    public func spec(for inventory: MetadataInventory, byteSize: Int64) -> DownscaleSpec {
        spec(for: SourceProfile(inventory: inventory, byteSize: byteSize))
    }

    /// The spec for an already-read source profile, so a planner call reads the inventory once.
    func spec(for source: SourceProfile) -> DownscaleSpec {
        let floor = Self.floorBitRate(for: source)
        let rawTarget = Int((source.videoBitRate * bitRateRatio).rounded())
        let target = max(rawTarget, floor)
        return DownscaleSpec(
            targetShortSide: nil, averageBitRate: target, maxFrameRate: nil, codec: .hevcKeepHDR,
            maxBitRate: target * 2)
    }

    static func floorBitRate(for source: SourceProfile) -> Int {
        guard source.width > 0, source.height > 0 else { return Preset.minimumBitRate }
        // Above 30 fps, inter-frame prediction keeps additional frames cheaper, so 60 fps scales at 1.5x (45) rather
        // than 2x (60), keeping 4K30 at ~10 Mbps, 1080p30 at ~2.5 Mbps, and 4K60 at ~15 Mbps.
        let fps = source.frameRate
        let effectiveFPS = fps > 30 ? 30 + (min(fps, 60) - 30) * 0.5 : fps
        let pixelRate = Double(source.width) * Double(source.height) * effectiveFPS
        return max(Int((minimumBitsPerPixel * pixelRate).rounded()), absoluteMinimumBitRate)
    }
}

/// Which operation a Convert job performs.
///
/// Encoded inside `ConvertJobSettings` (`Job.settings`) rather than as separate `JobQueue` tool IDs, so adding new
/// Convert kinds never touches `JobQueue`, `JobStore`, or the app shells.
public enum ConvertJobKind: Sendable, Equatable, Hashable {
    case shrink
    case compress(CompressPreset)
}

extension ConvertJobKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case preset
    }

    private enum KindType: String, Codable {
        case shrink
        case compress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(KindType.self, forKey: .type)
        switch type {
        case .shrink:
            self = .shrink
        case .compress:
            self = .compress(try container.decode(CompressPreset.self, forKey: .preset))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shrink:
            try container.encode(KindType.shrink, forKey: .type)
        case .compress(let preset):
            try container.encode(KindType.compress, forKey: .type)
            try container.encode(preset, forKey: .preset)
        }
    }
}
