import Foundation
import LocalLibrary
import PhotosLibrary
import QuickRunService
import Testing

@testable import AppCore
@testable import AppServices
@testable import Convert

/// The identifiers that outlive a build: what an existing user's saved queue, settings, library, Shortcuts and
/// Application Support folders are found by. Renaming code must never change them, so each is pinned here to the
/// literal it had before the rename.
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

        // File names and folders in Application Support.
        let directory = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        #expect(JobStore(directory: directory).fileURL.lastPathComponent == "jobs.json")
        #expect(BookmarkStore(directory: directory).fileURL.lastPathComponent == "library.json")
        let work = WorkFolder.standard(bundleIdentifier: "id.example").root.pathComponents
        #expect(work.suffix(2) == ["id.example", "Work"])
        #expect(PendingDeletions(directory: directory).fileURL.lastPathComponent == "pending-deletions.json")
        #expect(QuickRunStore(directory: directory).fileURL.lastPathComponent == "quick-runs.json")
        #expect(AppServices.stagingFolderName == "Staging")
        #expect(
            AppServices.supportDirectory(bundleIdentifier: "id.example")
                == URL.applicationSupportDirectory.appending(path: "id.example", directoryHint: .isDirectory))
        #expect(ConvertModel.Keys.inspector == "window.inspectorPresented")

        // UserDefaults keys, shared by the Settings views (@AppStorage), SettingsStore and the runners.
        #expect(AppSettings.Keys.preset == "downscale.preset")
        #expect(AppSettings.Keys.autoStartQueue == "queue.autoStart")
        #expect(SettingsStore.Keys.autoStartQueue == "queue.autoStart")
        #expect(AppSettings.Keys.speed == "performance.speed")
        #expect(SettingsStore.Keys.speed == "performance.speed")
        #expect(AppSettings.Keys.defaultSaveTo == "output.defaultSaveTo")
        #expect(AppSettings.Keys.defaultSaveFolder == "output.defaultSaveFolder")
        #expect(AppSettings.Keys.keepOriginals == "output.keepOriginals")
        #expect(AppSettings.Keys.originalsFolder == "output.originalsFolder")

        // The App Intent is identified by its type name: a Shortcut built on it breaks if it changes.
        #expect(
            try source("Apps/macOS/Sources/ShrinkVideosIntent.swift").contains("struct ShrinkVideosIntent: AppIntent"))

        // The Mac bundle id is derived from the brand prefix.
        #expect(
            try source("Config/macOS.xcconfig").contains("PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID_PREFIX).app\n"))
    }
}
