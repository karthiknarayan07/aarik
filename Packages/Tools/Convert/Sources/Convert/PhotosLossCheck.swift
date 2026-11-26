import AarikCore
import MediaEngine

/// What converting a Photos video is predicted to lose, from what Photos says about it. Nothing is downloaded
/// to find out, so only what its subtypes and dynamic range show can be named; the run reads the real file and
/// keeps the original as is when it would lose something that was not named here.
public enum PhotosLossCheck {
    /// Stands for the Dolby Vision and HDR items an H.264 copy drops.
    public static let hdrDetails = "HDR details"

    /// The names to show before a Photos video is added to the queue; empty for nothing.
    public static func lostNames(isCinematic: Bool, isHDR: Bool, custom: DownscaleSpec?) -> [String] {
        var names: [String] = []
        if isCinematic { names.append(MetadataNames.cinematicDepth) }
        if isHDR, custom?.codec == .h264Compatible { names.append(hdrDetails) }
        return names
    }
}
