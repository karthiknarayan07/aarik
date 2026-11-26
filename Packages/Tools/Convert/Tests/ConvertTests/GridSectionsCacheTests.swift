import AppCore
import AppServices
import Foundation
import PhotosLibrary
import Testing

@testable import Convert
@testable import LocalLibrary

/// The grids read `photoSections` and `sections` in every body pass, so they must be cheap: the sort, group and
/// filter over every item run only when the items or the query change, never for anything else.
@MainActor
@Suite struct GridSectionsCacheTests {
    private func makeModel(photoCount: Int) async throws -> (ConvertModel, URL) {
        let directory = URL.temporaryDirectory.appending(
            path: "grid-sections-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let assets = (0..<photoCount).map { index in
            PhotoAsset(
                id: "asset-\(index)", creationDate: start.addingTimeInterval(-Double(index) * 3600),
                pixelSize: CGSize(width: 3840, height: 2160), duration: 10, originalFileName: "IMG_\(index).MOV",
                originalByteSize: Int64(1_000_000 + index), modificationDate: start)
        }
        let suite = UserDefaults(suiteName: "GridSectionsCacheTests-\(UUID().uuidString)")!
        let services = AppServices(
            directory: directory, defaults: suite, photoStore: FakePhotoStore(assets: assets))
        let model = ConvertModel(services: services)
        await model.photos.start()
        return (model, directory)
    }

    @Test func photoSectionsAreNotRebuiltWhenSomethingUnrelatedChanges() async throws {
        let (model, directory) = try await makeModel(photoCount: 2_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = model.photosBrowser
        #expect(model.photoSections.map(\.items.count).reduce(0, +) == 2_000)
        let builds = (browser.snapshotBuilds, browser.derivedBuilds)

        // Things a body pass sees change while scrolling or working: the preset, the selection, the page, the
        // thumbnail source being read, and the same call again and again.
        model.preset = .smaller
        browser.selection = [browser.snapshot.items[0].id]
        browser.selection = []
        _ = model.thumbnailSource
        for _ in 0..<1_000 { _ = model.photoSections }

        #expect(browser.snapshotBuilds == builds.0)
        #expect(browser.derivedBuilds == builds.1)
    }

    @Test func photoSectionsAreRebuiltWhenTheQueryOrTheItemsChange() async throws {
        let (model, directory) = try await makeModel(photoCount: 50)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = model.photosBrowser
        _ = model.photoSections
        let builds = browser.snapshotBuilds
        browser.search = "IMG_1"
        #expect(model.photoSections.flatMap(\.items).count == 11)
        #expect(browser.snapshotBuilds == builds + 1)
        browser.grouping = .none
        _ = model.photoSections
        #expect(browser.snapshotBuilds == builds + 2)
    }
}
