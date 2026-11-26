import SwiftUI
import Testing

@testable import AppCore

@MainActor
private final class FakeModule: ToolModule {
    enum Page: Hashable, Sendable { case first, second, third }

    let id = "fake"
    let title = "Fake"
    let systemImage = "star"
    var selection: Page? = .first

    var sidebar: [ToolSidebarSection<Page>] {
        [
            ToolSidebarSection(
                title: "One",
                items: [
                    ToolSidebarItem(id: "first", destination: .first, title: "First", systemImage: "1.circle"),
                    ToolSidebarItem(
                        id: "second", destination: .second, title: "Second", systemImage: "2.circle", count: 4),
                ]),
            ToolSidebarSection(
                title: "Two",
                items: [
                    ToolSidebarItem(
                        id: "later", destination: nil, title: "Later", systemImage: "clock",
                        availability: .comingSoon),
                    ToolSidebarItem(
                        id: "third", destination: .third, title: "Third", systemImage: "3.circle", progress: 0.5),
                ]),
        ]
    }

    func detail(for destination: Page?) -> some View { Text("detail") }
    func toolbar(for destination: Page?) -> some ToolbarContent {
        ToolbarItem { Text("item") }
    }
    func hasInspector(for destination: Page?) -> Bool { destination == .first }
    func inspector(for destination: Page?) -> some View { Text("inspector") }
}

@MainActor
@Suite struct ToolModuleTests {
    @Test func shellSeesTheModulesItemsInOrder() {
        let module = FakeModule()
        #expect(module.sidebar.map(\.title) == ["One", "Two"])
        #expect(module.sidebar.flatMap(\.items).map(\.title) == ["First", "Second", "Later", "Third"])
    }

    @Test func comingSoonRowsCannotBeSelected() {
        #expect(FakeModule().selectableDestinations == [.first, .second, .third])
    }

    @Test func rowsSpeakTheirCountsProgressAndAvailability() {
        let items = FakeModule().sidebar.flatMap(\.items)
        #expect(
            items.map(\.accessibilityText) == ["First", "Second, 4", "Later, coming soon", "Third, converting 50%"])
    }

    @Test func inspectorAvailabilityIsTheModulesCall() {
        let module = FakeModule()
        #expect(module.hasInspector(for: .first))
        #expect(!module.hasInspector(for: .second))
        #expect(!module.hasInspector(for: nil))
    }

    @Test func aModuleWithoutCommandsGetsTheEmptyDefault() {
        let module = FakeModule()
        _ = module.commands
        #expect(module.id == "fake")
    }
}
