import Foundation
import Testing

@testable import AppUI

@Suite struct HelpMenuTests {
    @Test func linksAreBuiltFromTheProjectAddress() {
        let links = HelpMenu.links(appName: "App", homepage: "https://github.com/owner/repo#readme")

        #expect(links.map(\.title) == ["App Help", "Privacy", "Release Notes", "Report an Issue…"])
        #expect(
            links.map(\.url.absoluteString) == [
                "https://github.com/owner/repo", "https://github.com/owner/repo#privacy",
                "https://github.com/owner/repo/blob/main/CHANGELOG.md", "https://github.com/owner/repo/issues",
            ])
    }

    @Test func aTrailingSlashDoesNotDoubleUp() {
        let links = HelpMenu.links(appName: "App", homepage: "https://github.com/owner/repo/")
        #expect(links.last?.url.absoluteString == "https://github.com/owner/repo/issues")
    }

    @Test func nothingIsShownForAMissingOrInsecureAddress() {
        #expect(HelpMenu.links(appName: "App", homepage: nil).isEmpty)
        #expect(HelpMenu.links(appName: "App", homepage: "").isEmpty)
        #expect(HelpMenu.links(appName: "App", homepage: "http://github.com/owner/repo").isEmpty)
        #expect(HelpMenu.links(appName: "App", homepage: "file:///etc/hosts").isEmpty)
        #expect(HelpMenu.links(appName: "App", homepage: "$(APP_HELP_URL)").isEmpty)
    }
}
