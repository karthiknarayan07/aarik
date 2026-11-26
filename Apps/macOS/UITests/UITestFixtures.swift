import AppCore
import Foundation
import MediaTestSupport

/// Generated media and history for the Mac UI tests: a Local Files library of small clips that are 4K or 1080p with
/// capture dates over several months, and a queue history spread over a week, so every chart has several points.
/// Nothing here is anyone's own media.
enum UITestFixtures {
    /// The moment the app's clock is pinned to (`-uiTestingNow`): noon, local time, on a fixed day.
    static let now: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 26
        parts.hour = 12
        return Calendar.current.date(from: parts)!
    }()

    private struct Clip {
        let name: String
        let width: Int
        let height: Int
        let fps: Int
        let hdr: FixtureHDR
        let created: String
    }

    private static let clips = [
        Clip(name: "Beach Day.mov", width: 3840, height: 2160, fps: 60, hdr: .hlg, created: "2025-07-12T10:15:00+0000"),
        Clip(
            name: "Birthday Dinner.mov", width: 3840, height: 2160, fps: 30, hdr: .hlg,
            created: "2025-07-19T18:40:00+0000"),
        Clip(
            name: "Hike Summit.mov", width: 3840, height: 2160, fps: 30, hdr: .sdr, created: "2025-09-03T08:05:00+0000"),
        Clip(name: "Fireworks.mov", width: 3840, height: 2160, fps: 60, hdr: .hlg, created: "2025-11-05T19:30:00+0000"),
        Clip(name: "Garden.mov", width: 1920, height: 1080, fps: 30, hdr: .sdr, created: "2024-05-20T14:00:00+0000"),
    ]

    /// The folder the clips are written to once for the whole test run.
    private static let filesFolder = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        .appending(path: "ui-fixtures-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)

    /// Writes the clips (once per run) and returns their folder, for `-uiTestingFiles`.
    static func library() async throws -> URL {
        if FileManager.default.fileExists(atPath: filesFolder.appending(path: clips[0].name).path) {
            return filesFolder
        }
        try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        for clip in clips {
            var options = ClipOptions()
            options.width = clip.width
            options.height = clip.height
            options.fps = clip.fps
            options.hdr = clip.hdr
            options.seconds = 1
            options.includeAudio = false
            options.quickTimeMetadata = [
                "com.apple.quicktime.make": "TestMake", "com.apple.quicktime.model": "TestModel",
                "com.apple.quicktime.creationdate": clip.created,
            ]
            let made = try await FixtureFactory.makeClip(options)
            try FileManager.default.moveItem(at: made, to: filesFolder.appending(path: clip.name))
        }
        return filesFolder
    }

    /// Writes a queue history into `support` (`jobs.json`): finished conversions on six of the last seven days (so the
    /// charts' axes have several points), two videos kept as they are and one failure.
    static func writeHistory(into support: URL) throws {
        let calendar = Calendar.current
        let converted = filesFolder.appending(path: "Converted", directoryHint: .isDirectory)
        // (days ago, original name, bytes before, bytes after)
        let finished: [(Int, String, Int64, Int64)] = [
            (6, "Camping Trip", 1_900_000_000, 640_000_000), (6, "Campfire", 800_000_000, 290_000_000),
            (6, "Lake Swim", 1_200_000_000, 410_000_000), (4, "Market Walk", 1_500_000_000, 520_000_000),
            (3, "Sunset Drive", 2_100_000_000, 700_000_000), (3, "Night Skyline", 1_700_000_000, 600_000_000),
            (1, "Road Trip Day 1", 2_400_000_000, 800_000_000), (1, "Road Trip Day 2", 2_200_000_000, 760_000_000),
            (1, "Diner Stop", 600_000_000, 230_000_000), (1, "Canyon Overlook", 1_800_000_000, 620_000_000),
            (0, "Morning Run", 900_000_000, 330_000_000), (0, "Park Picnic", 1_300_000_000, 450_000_000),
        ]
        var jobs: [Job] = []
        for (index, row) in finished.enumerated() {
            let (daysAgo, name, before, after) = row
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let outcome = JobOutcome(
                output: converted.appending(path: "\(name) (smaller).mov"), bytesBefore: before, bytesAfter: after,
                report: MetadataReport(), replacedOriginal: false)
            jobs.append(
                job(
                    named: "\(name).mov", state: .completed(outcome),
                    at: day.addingTimeInterval(Double(index) * 60), in: converted))
        }
        let keptDay = calendar.date(byAdding: .day, value: -2, to: now)!
        jobs.append(
            job(
                named: "Clip A.mov",
                state: .keptAsIs(reason: "It is already small, so a copy wouldn't save space.", code: .other),
                at: keptDay, in: converted))
        jobs.append(
            job(
                named: "Clip B.mov",
                state: .keptAsIs(reason: "It is already small, so a copy wouldn't save space.", code: .other),
                at: keptDay.addingTimeInterval(60), in: converted))
        jobs.append(
            job(
                named: "Broken.mov", state: .failed(reason: "The file couldn't be read.", code: .other),
                at: calendar.date(byAdding: .day, value: -1, to: now)!, in: converted))
        try JobStore(directory: support).save(jobs)
    }

    private static func job(named name: String, state: JobState, at date: Date, in folder: URL) -> Job {
        Job(
            toolID: "downscale-video", source: folder.appending(path: name), sourceBookmark: Data(), settings: Data(),
            state: state, createdAt: date)
    }
}
