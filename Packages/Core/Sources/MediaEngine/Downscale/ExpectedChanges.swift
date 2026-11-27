import AppCore
import CoreMedia

/// The metadata changes a downscale is expected to make. Anything else that changed means the output is not a
/// faithful copy of the source.
public enum ExpectedChanges {
    /// What an H.264 encode changes on top, as inventory values: it is 8-bit BT.709 SDR whatever the source was.
    /// (The `hdr.*` items it drops are lost, not changed; the planner predicts those.)
    public static let h264SDRValues: [String: String] = [
        "video.colorPrimaries": kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
        "video.transferFunction": kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
        "video.matrix": kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
        "video.bitDepth": "8",
    ]

    /// How far a track or timed-metadata duration may move, in milliseconds. Re-encoding rounds video and timed
    /// metadata by a millisecond or two, and passthrough AAC can gain the standard 2112-sample priming trim (about
    /// 48 ms) that a source without an edit list lacked; the samples themselves are all still there.
    public static let durationToleranceMilliseconds = 100.0

    /// The changed items that are not expected: `video.dimensions`, `video.codec`, the Dolby Vision level (profile
    /// and compatibility equal), `video.frameRate` only when the spec caps the frame rate, any duration that moved by
    /// less than `durationToleranceMilliseconds`, and for H.264 a change of an `h264SDRValues` item to exactly its
    /// SDR value.
    public static func unexpected(in report: MetadataReport, spec: DownscaleSpec) -> [MetadataChange] {
        report.changed.filter { change in
            switch change.key {
            case "video.dimensions", "video.codec": false
            case "video.frameRate": spec.maxFrameRate == nil
            case _ where h264SDRValues[change.key] != nil:
                spec.codec != .h264Compatible || h264SDRValues[change.key] != change.to
            case "hdr.dolbyVision": !onlyLevelDiffers(change.from, change.to)
            case _ where change.key.hasSuffix("duration"): !withinDurationTolerance(change.from, change.to)
            default: true
            }
        }
    }

    /// `"profile 8, level 9, compat 4"` → (8, 9, 4).
    static func dolbyVisionParts(_ value: String) -> (profile: Int, level: Int, compat: Int)? {
        let numbers = value.split(separator: ",").compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
        return numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : nil
    }

    private static func withinDurationTolerance(_ from: String, _ to: String) -> Bool {
        guard let from = Double(from), let to = Double(to) else { return false }
        return abs(from - to) < durationToleranceMilliseconds
    }

    private static func onlyLevelDiffers(_ from: String, _ to: String) -> Bool {
        guard let from = dolbyVisionParts(from), let to = dolbyVisionParts(to) else { return false }
        return from.profile == to.profile && from.compat == to.compat
    }

    /// Image changes allowed by `spec`: `img.dimensions` (when resized) and `img.uti` (when changing format).
    public static func unexpected(in report: MetadataReport, spec: ImageSpec) -> [MetadataChange] {
        let formatMayChange = spec.format != .keepOriginal
        return report.changed.filter { change in
            switch change.key {
            case "img.dimensions": false
            case "img.uti": !formatMayChange
            case "img.xmp": false
            case "img.apple.contentID": false
            default: true
            }
        }
    }
}
