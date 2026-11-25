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
    static func source(name: String = "x.mov") async throws -> URL {
        var options = ClipOptions()
        options.width = 2560
        options.height = 1440
        options.fps = 10
        options.hdr = .sdr
        // A bit rate well above the 2 Mbps the tests encode at, so the planner sees a saving over 10%.
        options.videoBitRate = 20_000_000
        return try await renamed(FixtureFactory.makeClip(options), to: name)
    }

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
