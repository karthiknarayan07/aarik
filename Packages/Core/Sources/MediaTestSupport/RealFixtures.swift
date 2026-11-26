import Foundation

public enum RealFixture: String, CaseIterable, Sendable {
    case dolbyVision4K60 = "dv-4k60.mov"
    case dolbyVision4K30 = "dv-4k30.mov"
    case cinematic = "cinematic.mov"
    case spatialAudio = "spatial-audio.mov"
    case sloMo = "slomo.mov"
    case livePhoto = "live-photo.mov"
    case sdr = "sdr.mov"
    case spatialVideo = "spatial-video.mov"
}

public enum RealFixtures {
    /// `<repo>/Fixtures/iphone/<name>` resolved from `#filePath`, or nil if absent.
    public static func url(_ fixture: RealFixture, filePath: String = #filePath) -> URL? {
        var dir = URL(filePath: filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "Packages").path) {
                let candidate = dir.appending(path: "Fixtures/iphone/\(fixture.rawValue)")
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
