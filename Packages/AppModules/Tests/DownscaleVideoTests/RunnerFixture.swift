import AVFoundation
import AppCore
import Foundation
import MediaEngine
import MediaTestSupport

@testable import DownscaleVideo

/// Clips and jobs shared by the runner tests.
enum RunnerFixture {
    /// The spec most runner tests encode at: a real downscale at a low bit rate.
    static let spec = DownscaleSpec(targetShortSide: 1080, averageBitRate: 2_000_000)

    /// 2560x1440 so a 1080 short side really shrinks it; small and fast. Lives in its own temporary directory.
    /// `fileType` picks the container (the name's extension is the caller's), `timedMetadata` adds a timed
    /// metadata track, `metadata` file-level QuickTime items (an MPEG-4 writer stores some as ISO user data).
    static func source(
        name: String = "x.mov", fileType: AVFileType = .mov, timedMetadata: Bool = false,
        metadata: [String: String] = [:]
    ) async throws -> URL {
        var options = ClipOptions()
        options.width = 2560
        options.height = 1440
        options.fps = 10
        options.hdr = .sdr
        // A bit rate well above the 2 Mbps the tests encode at, so the planner sees a saving over 10%.
        options.videoBitRate = 20_000_000
        options.fileType = fileType
        options.includeTimedMetadataTrack = timedMetadata
        options.quickTimeMetadata = metadata
        return try await renamed(FixtureFactory.makeClip(options), to: name)
    }

    /// The major brand in a file's `ftyp` box (`qt  ` for QuickTime, `mp42` or `isom` for MPEG-4).
    static func majorBrand(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 12) ?? Data()
        guard head.count == 12, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" else { return "" }
        return String(decoding: head[8..<12], as: UTF8.self)
    }

    /// A location and a creation date, which an MPEG-4 file keeps as ISO user data (`uiso/loci`, `uiso/date`).
    static let locationMetadata = [
        "com.apple.quicktime.location.ISO6709": "+37.3349-122.0090+010.000/",
        "com.apple.quicktime.creationdate": "2026-11-25T10:00:00+0000",
    ]

    /// 640x360 at a low bit rate: below a 1080 short side, so a 1080p downscale finds it already small.
    static func smallSource(name: String = "small.mov") async throws -> URL {
        var options = ClipOptions()
        options.width = 640
        options.height = 360
        options.fps = 10
        options.hdr = .sdr
        options.videoBitRate = 300_000
        return try await renamed(FixtureFactory.makeClip(options), to: name)
    }

    static func job(_ source: URL, _ settings: DownscaleJobSettings) throws -> Job {
        Job(
            toolID: DownscaleTool.toolID, source: source, sourceBookmark: Data(),
            settings: try JSONEncoder().encode(settings))
    }

    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private static func renamed(_ clip: URL, to name: String) throws -> URL {
        let renamed = clip.deletingLastPathComponent().appending(path: name)
        try FileManager.default.moveItem(at: clip, to: renamed)
        return renamed
    }
}
