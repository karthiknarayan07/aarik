import AppCore

/// The metadata changes a downscale is expected to make. Anything else that changed means the output is not a
/// faithful copy of the source.
public enum ExpectedChanges {
    /// What an H.264 encode changes on top: it is 8-bit BT.709 SDR whatever the source was. (The `hdr.*` items it
    /// drops are lost, not changed; the planner predicts those.)
    public static let h264SDRKeys: Set<String> = [
        "video.transferFunction", "video.colorPrimaries", "video.matrix", "video.bitDepth",
    ]

    /// The changed items that are not expected: `video.dimensions`, `video.codec`, the Dolby Vision level (profile
    /// and compatibility equal), `video.frameRate` only when the spec caps the frame rate, and for H.264 the
    /// `h264SDRKeys`.
    public static func unexpected(in report: MetadataReport, spec: DownscaleSpec) -> [MetadataChange] {
        report.changed.filter { change in
            switch change.key {
            case "video.dimensions", "video.codec": false
            case "video.frameRate": spec.maxFrameRate == nil
            case _ where h264SDRKeys.contains(change.key): spec.codec != .h264Compatible
            case "hdr.dolbyVision": !onlyLevelDiffers(change.from, change.to)
            default: true
            }
        }
    }

    /// `"profile 8, level 9, compat 4"` → (8, 9, 4).
    static func dolbyVisionParts(_ value: String) -> (profile: Int, level: Int, compat: Int)? {
        let numbers = value.split(separator: ",").compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
        return numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : nil
    }

    private static func onlyLevelDiffers(_ from: String, _ to: String) -> Bool {
        guard let from = dolbyVisionParts(from), let to = dolbyVisionParts(to) else { return false }
        return from.profile == to.profile && from.compat == to.compat
    }
}
