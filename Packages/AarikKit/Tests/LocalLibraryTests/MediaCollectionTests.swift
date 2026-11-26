import AarikCore
import CoreGraphics
import Foundation
import Observation
import Testing

@testable import LocalLibrary

/// A collection that isn't the local library, standing in for Photos.
@MainActor
@Observable
final class FakeCollection: MediaCollection {
    var items: [LibraryItem] = [] {
        didSet { revision += 1 }
    }
    private(set) var revision = 0
    var isScanning = false
}

@MainActor
@Suite struct MediaCollectionTests {
    private func photo(_ identifier: String, name: String, bytes: Int64, date: Double) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos(identifier), name: name, byteSize: bytes, duration: 5,
            pixelSize: CGSize(width: 3840, height: 2160), frameRate: 30,
            captureDate: Date(timeIntervalSince1970: date), badges: [.k4], isAvailable: true,
            inventory: MetadataInventory())
    }

    private func file(_ name: String, bytes: Int64) -> LibraryItem {
        LibraryItem(
            id: UUID(), url: URL(filePath: "/nonexistent/\(name)"), byteSize: bytes, duration: 5,
            pixelSize: CGSize(width: 1920, height: 1080), frameRate: 30, captureDate: nil, badges: [.sdr],
            isAvailable: true, inventory: MetadataInventory())
    }

    @Test func sourceDecidesTheFileLocation() {
        let local = file("a.mov", bytes: 1)
        #expect(local.fileURL == URL(filePath: "/nonexistent/a.mov"))
        #expect(local.photosIdentifier == nil)
        #expect(local.name == "a.mov")
        let cloud = photo("ABC/L0/001", name: "IMG_1.MOV", bytes: 1, date: 0)
        #expect(cloud.fileURL == nil)
        #expect(cloud.photosIdentifier == "ABC/L0/001")
    }

    @Test func browserReadsAnyCollection() {
        let collection = FakeCollection()
        collection.items = [
            photo("A", name: "IMG_1.MOV", bytes: 300, date: 100), photo("B", name: "IMG_2.MOV", bytes: 100, date: 200),
            photo("C", name: "Holiday.MOV", bytes: 200, date: 300),
        ]
        let browser = LibraryBrowser(collection: collection)
        #expect(browser.snapshot.items.map(\.name) == ["IMG_1.MOV", "Holiday.MOV", "IMG_2.MOV"])
        #expect(browser.snapshot.totalBytes == 600)

        browser.sort = .newestFirst
        #expect(browser.snapshot.items.map(\.name) == ["Holiday.MOV", "IMG_2.MOV", "IMG_1.MOV"])
        // Search matches the item's name, which a Photos item has without a file.
        browser.search = "holiday"
        #expect(browser.snapshot.items.map(\.name) == ["Holiday.MOV"])
    }

    @Test func browserRebuildsWhenTheCollectionChanges() {
        let collection = FakeCollection()
        collection.items = [photo("A", name: "IMG_1.MOV", bytes: 100, date: 1)]
        let browser = LibraryBrowser(collection: collection)
        #expect(browser.snapshot.items.count == 1)
        _ = browser.snapshot
        #expect(browser.snapshotBuilds == 1)

        collection.items.append(photo("B", name: "IMG_2.MOV", bytes: 50, date: 2))
        #expect(browser.snapshot.items.count == 2)
        #expect(browser.snapshotBuilds == 2)
    }

    @Test func itemsWithEqualSizesKeepAStableOrder() {
        let collection = FakeCollection()
        collection.items = (0..<5).map { photo("id\($0)", name: "same.MOV", bytes: 10, date: 1) }
        let browser = LibraryBrowser(collection: collection)
        let first = browser.snapshot.items.map(\.id)
        collection.items.reverse()
        #expect(browser.snapshot.items.map(\.id) == first)
    }

    @Test func selectionIsPerItemIDAcrossSources() {
        let collection = FakeCollection()
        let video = photo("A", name: "IMG_1.MOV", bytes: 100, date: 1)
        collection.items = [video, photo("B", name: "IMG_2.MOV", bytes: 50, date: 2)]
        let browser = LibraryBrowser(collection: collection)
        browser.selection = [video.id]
        #expect(browser.selectedItems == [video])
        browser.search = "IMG_2"
        #expect(browser.selectedItems.isEmpty)
    }
}
