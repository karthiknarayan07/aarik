import AppCore
import CoreGraphics
import Foundation

/// The video format a downscale writes.
public enum VideoCodec: String, Codable, Sendable, Hashable, CaseIterable {
    /// HEVC at the source bit depth, keeping HDR, its static metadata and Dolby Vision.
    case hevcKeepHDR
    /// H.264 High, 8-bit BT.709 SDR: HDR sources are tone-mapped and lose their HDR metadata.
    case h264Compatible
}

/// What a downscale produces: the short side, the average bit rate, an optional frame-rate cap, the codec and an
/// optional 1-second peak bit-rate cap.
public struct DownscaleSpec: Sendable, Hashable, Codable {
    /// `nil` keeps the source resolution.
    public var targetShortSide: Int? = 1080
    public var averageBitRate: Int = 20_000_000
    /// True to encode at the source video's own bit rate instead of a fixed target.
    public var keepsSourceBitRate: Bool = false
    /// `nil` keeps the source frame rate. A cap never increases the frame rate.
    public var maxFrameRate: Double? = nil
    public var codec: VideoCodec = .hevcKeepHDR
    /// Optional hard bit-rate cap over a 1-second window (`kVTCompressionPropertyKey_DataRateLimits`); `nil` leaves
    /// it uncapped.
    public var maxBitRate: Int? = nil

    public init(
        targetShortSide: Int? = 1080, averageBitRate: Int = 20_000_000, keepsSourceBitRate: Bool = false,
        maxFrameRate: Double? = nil, codec: VideoCodec = .hevcKeepHDR, maxBitRate: Int? = nil
    ) {
        self.targetShortSide = targetShortSide
        self.averageBitRate = averageBitRate
        self.keepsSourceBitRate = keepsSourceBitRate
        self.maxFrameRate = maxFrameRate
        self.codec = codec
        self.maxBitRate = maxBitRate
    }

    /// Job JSON written before `codec`, `maxBitRate`, or `keepsSourceBitRate` existed decodes with safe defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetShortSide = try container.decodeIfPresent(Int.self, forKey: .targetShortSide)
        averageBitRate = try container.decode(Int.self, forKey: .averageBitRate)
        keepsSourceBitRate = try container.decodeIfPresent(Bool.self, forKey: .keepsSourceBitRate) ?? false
        maxFrameRate = try container.decodeIfPresent(Double.self, forKey: .maxFrameRate)
        codec = try container.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? .hevcKeepHDR
        maxBitRate = try container.decodeIfPresent(Int.self, forKey: .maxBitRate)
    }

    /// Encoded (pre-transform) output size: short side = target, aspect kept, both even.
    public func outputSize(forNaturalSize size: CGSize) -> CGSize {
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return .zero }
        let scale = targetShortSide.map { CGFloat($0) / shortSide } ?? 1
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

public enum DownscaleError: Error, Equatable, Sendable {
    case outputExists
    case sourceAlreadySmall
    case unsupportedSource(String)
    case encoderFailed(String)
    /// Nothing moved for too long (`StallLimits`): the writer or encoder stopped responding.
    case stalled
}

extension DownscaleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outputExists: "A file with the new name already exists, so nothing was saved."
        case .sourceAlreadySmall: "The video is already small."
        case .unsupportedSource: "This kind of video can't be converted yet."
        case .encoderFailed: "The video couldn't be converted."
        case .stalled: "The encoder stopped responding."
        }
    }
}

extension DownscaleError: OutcomeCoded {
    public var outcomeCode: OutcomeCode {
        switch self {
        case .outputExists: .outputNameTaken
        case .sourceAlreadySmall: .alreadySmall
        case .unsupportedSource: .unsupportedVideo
        case .encoderFailed, .stalled: .conversionFailed
        }
    }
}
