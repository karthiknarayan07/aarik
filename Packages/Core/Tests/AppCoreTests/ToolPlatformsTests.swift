import SwiftUI
import Testing

@testable import AppCore

@MainActor
private final class PlatformModule: ToolModule {
    enum Page: Hashable, Sendable { case only }

    let id: String
    let title = "Fake"
    let systemImage = "star"
    let platforms: ToolPlatforms
    var selection: Page? = .only
    var isInspectorPresented = false
    var sidebar: [ToolSidebarSection<Page>] { [] }

    init(id: String, platforms: ToolPlatforms) {
        self.id = id
        self.platforms = platforms
    }

    func detail(for destination: Page?) -> some View { Text("detail") }
    func toolbar(for destination: Page?) -> some ToolbarContent { ToolbarItem { Text("item") } }
    func hasInspector(for destination: Page?) -> Bool { false }
    func inspector(for destination: Page?) -> some View { Text("inspector") }
}

@MainActor
@Suite struct ToolPlatformsTests {
    @Test func theMacRegistryKeepsOnlyModulesThatIncludeMacOS() {
        let both = PlatformModule(id: "both", platforms: [.macOS, .iOS])
        let mac = PlatformModule(id: "mac", platforms: .macOS)
        let phone = PlatformModule(id: "phone", platforms: .iOS)
        let shown = ToolRegistry.modules(for: .macOS, from: [both, phone, mac])
        #expect(shown.map(\.id) == ["both", "mac"])
        #expect(ToolRegistry.modules(for: .iOS, from: [both, phone, mac]).map(\.id) == ["both", "phone"])
    }

    @Test func aModuleForIOSOnlyIsNotOfferedOnTheMac() {
        let phone = PlatformModule(id: "phone", platforms: .iOS)
        #expect(ToolRegistry.modules(for: .macOS, from: [phone]).isEmpty)
    }

    @Test func allCoversBothPlatforms() {
        #expect(ToolPlatforms.all == [.macOS, .iOS])
    }
}
