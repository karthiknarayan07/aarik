import Foundation
import LocalLibrary
import PhotosLibrary
import Testing

@testable import AppCore
@testable import Convert

/// The identifiers that outlive a build: what an existing user's saved queue, settings, library, Shortcuts and
/// Application Support folders are found by. Renaming code must never change them, so each is pinned here to the
/// literal it had before the rename. Values the app shell owns (settings keys, the intent) are checked in its source,
/// because the shell has no unit test target.
@Suite struct PersistedIdentifiersTests {
    private static let root: URL = {
        var url = URL(filePath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "Apps/macOS/Sources").path) { return url }
        }
        return url
    }()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    @Test func persistedIdentifiersUnchanged() throws {
        // Tool ids are stored in every saved job.
        #expect(ConvertTool.toolID == "downscale-video")
        #expect(ConvertTool.photosToolID == "downscale-video-photos")

        // File names in the Application Support folder.
        let directory = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        #expect(JobStore(directory: directory).fileURL.lastPathComponent == "jobs.json")
        #expect(BookmarkStore(directory: directory).fileURL.lastPathComponent == "library.json")
        let work = WorkFolder.standard(bundleIdentifier: "id.example").root.pathComponents
        #expect(work.suffix(2) == ["id.example", "Work"])
        #expect(
            try source("Packages/Core/Sources/PhotosLibrary/PendingDeletions.swift").contains(
                "\"pending-deletions.json\""))
        let model = try source("Apps/macOS/Sources/AppModel.swift")
        #expect(model.contains("\"quick-runs.json\""))
        #expect(model.contains("\"Staging\""))
        // Application Support/<bundle id>.
        #expect(model.contains("URL.applicationSupportDirectory.appending(path: id, directoryHint: .isDirectory)"))
        #expect(model.contains("window.inspectorPresented"))

        // UserDefaults keys, shared by the Settings views (@AppStorage) and the runners.
        let settings = try source("Apps/macOS/Sources/AppSettings.swift")
        for line in [
            "static let preset = \"downscale.preset\"",
            "static let autoStartQueue = \"queue.autoStart\"",
            "static let speed = \"performance.speed\"",
            "static let defaultSaveTo = \"output.defaultSaveTo\"",
            "static let defaultSaveFolder = \"output.defaultSaveFolder\"",
            "static let keepOriginals = \"output.keepOriginals\"",
            "static let originalsFolder = \"output.originalsFolder\"",
        ] {
            #expect(settings.contains(line), "missing \(line)")
        }

        // The App Intent is identified by its type name: a Shortcut built on it breaks if it changes.
        #expect(
            try source("Apps/macOS/Sources/ShrinkVideosIntent.swift").contains("struct ShrinkVideosIntent: AppIntent"))

        // The Mac bundle id is derived from the brand prefix.
        #expect(
            try source("Config/macOS.xcconfig").contains("PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID_PREFIX).app\n"))
    }
}
