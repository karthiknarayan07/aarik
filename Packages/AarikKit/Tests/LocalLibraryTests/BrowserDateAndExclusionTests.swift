import AarikCore
import CoreGraphics
import Foundation
import Testing

@testable import LocalLibrary

@MainActor
@Suite struct BrowserDateAndExclusionTests {
    private func item(_ name: String, date: Double?) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos(name), name: name, byteSize: 10, duration: 5,
            pixelSize: CGSize(width: 3840, height: 2160), frameRate: 30,
            captureDate: date.map { Date(timeIntervalSince1970: $0) }, badges: [.k4], isAvailable: true,
            inventory: MetadataInventory())
    }

    @Test func captureRangeKeepsOnlyDatedItemsInsideIt() {
        let collection = FakeCollection()
        collection.items = [
            item("early", date: 100), item("inside", date: 500), item("late", date: 900), item("none", date: nil),
        ]
        let browser = LibraryBrowser(collection: collection)
        browser.captureRange = Date(timeIntervalSince1970: 200)...Date(timeIntervalSince1970: 600)
        #expect(browser.snapshot.items.map(\.name) == ["inside"])
        browser.captureRange = nil
        #expect(browser.snapshot.items.count == 4)
    }

    @Test func excludedItemsAreHidden() {
        let collection = FakeCollection()
        collection.items = [item("a", date: 1), item("b", date: 2)]
        let browser = LibraryBrowser(collection: collection)
        browser.excluded = [collection.items[0].id]
        #expect(browser.snapshot.items.map(\.name) == ["b"])
    }
}
