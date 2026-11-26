import AppCore
import CoreGraphics
import Foundation
import Testing

@testable import LocalLibrary

@Suite struct BrowserMenuOptionsTests {
    private func item(_ path: String) -> LibraryItem {
        LibraryItem(
            id: UUID(), url: URL(filePath: path), byteSize: 1, duration: 1, pixelSize: CGSize(width: 1, height: 1),
            frameRate: 30, captureDate: nil, badges: [], isAvailable: true, inventory: MetadataInventory(items: []))
    }

    @Test func everyGroupingAndSortIsInTheMenuOnceWithTitleCaseNames() {
        #expect(Set(Grouping.menuOrder) == Set(Grouping.allCases))
        #expect(Grouping.menuOrder.count == Grouping.allCases.count)
        #expect(Grouping.menuOrder.map(\.menuTitle) == ["None", "Year", "Month"])
        #expect(Set(Sort.menuOrder) == Set(Sort.allCases))
        #expect(Sort.menuOrder.map(\.menuTitle) == ["Biggest First", "Newest First"])
    }

    @Test func aRemovalKeepsTheFilesToPutBack() {
        let items = [item("/videos/a.mov"), item("/videos/b.mov")]
        let removal = LibraryRemoval(items: items)

        #expect(removal.urls == [URL(filePath: "/videos/a.mov"), URL(filePath: "/videos/b.mov")])
        #expect(!removal.isEmpty)
        #expect(LibraryRemoval.actionName == "Remove from Library")
        #expect(LibraryRemoval(items: []).isEmpty)
    }

    @Test func redoFindsTheItemsThatCameBackUnderNewIDs() {
        let removed = [item("/videos/a.mov"), item("/videos/b.mov")]
        let removal = LibraryRemoval(items: removed)
        let readded = item("/videos/a.mov")
        let other = item("/videos/c.mov")

        #expect(removal.ids(in: [readded, other]) == [readded.id])
        #expect(removal.ids(in: [other]).isEmpty)
    }
}
