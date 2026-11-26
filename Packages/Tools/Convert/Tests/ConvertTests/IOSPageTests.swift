import Testing

@testable import Convert

@Suite struct IOSPageTests {
    @Test func everyPageRoundTripsThroughItsModelPage() {
        for page in IOSPage.allCases {
            #expect(IOSPage(page.videoPage) == page)
        }
    }

    @Test func activityAndFilterPagesFoldIntoTheirParents() {
        #expect(IOSPage(.keptAsIs) == .completed)
        #expect(IOSPage(.failed) == .completed)
        #expect(IOSPage(.mediaType(.hdr)) == .files)
    }

    @Test func aPageIOSDoesNotListHasNoMatch() {
        #expect(IOSPage(.tool("x")) == nil)
        #expect(IOSPage(nil) == nil)
    }

    @Test func rawValuesAreStableForRestoration() {
        #expect(IOSPage.allCases.map(\.rawValue) == ["overview", "photos", "files", "queue", "completed"])
    }

    @Test func titlesAreTitleCase() {
        #expect(IOSPage.allCases.map(\.title) == ["Overview", "Photos", "Files", "Queue", "Completed"])
    }
}
