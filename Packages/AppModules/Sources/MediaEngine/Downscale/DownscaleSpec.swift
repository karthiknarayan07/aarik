import CoreGraphics

/// What a downscale produces: the short side, the average bit rate, and an optional frame-rate cap.
public struct DownscaleSpec: Sendable, Hashable, Codable {
    /// `nil` keeps the source resolution.
    public var targetShortSide: Int? = 1080
    public var averageBitRate: Int = 20_000_000
    /// `nil` keeps the source frame rate. A cap never increases the frame rate.
    public var maxFrameRate: Double? = nil

    public init(targetShortSide: Int? = 1080, averageBitRate: Int = 20_000_000, maxFrameRate: Double? = nil) {
        self.targetShortSide = targetShortSide
        self.averageBitRate = averageBitRate
        self.maxFrameRate = maxFrameRate
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
}
