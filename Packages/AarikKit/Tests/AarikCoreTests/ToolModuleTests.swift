import SwiftUI
import Testing

@testable import AarikCore

@MainActor
private final class FakeModule: ToolModule {
    enum Page: Hashable, Sendable { case first, second, third }

    let id = "fake"
    let title = "Fake"
    let systemImage = "star"
    var selection: Page? = .first
    var isInspectorPresented = true

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
    /// What the shell's sidebar draws for a module: `SidebarView` iterates exactly these sections and rows.
    private func shellModel(_ module: FakeModule) -> ToolSidebarModel<FakeModule.Page> {
        ToolSidebarModel(module.sidebar)
    }

    @Test func shellRendersTheModulesSectionsAndRowsInOrder() {
        let shell = shellModel(FakeModule())
        #expect(shell.sections.map(\.title) == ["One", "Two"])
        #expect(shell.sections.flatMap(\.rows).map(\.item.title) == ["First", "Second", "Later", "Third"])
    }

    @Test func shellOffersOnlyEnabledRowsForSelection() {
        let module = FakeModule()
        let shell = shellModel(module)
        #expect(shell.sections.flatMap(\.rows).map(\.isSelectable) == [true, true, false, true])
        #expect(shell.selectableDestinations == [.first, .second, .third])
        // The module's own list is the shell's.
        #expect(module.selectableDestinations == shell.selectableDestinations)
    }

    @Test func shellRefusesASelectionTheSidebarDoesNotOffer() {
        let item = ToolSidebarItem(
            id: "first", destination: FakeModule.Page.first, title: "First", systemImage: "1.circle")
        let shell = ToolSidebarModel([ToolSidebarSection(title: "One", items: [item])])
        #expect(shell.accepts(.first))
        #expect(shell.accepts(nil))
        #expect(!shell.accepts(.third))
    }

    @Test func rowsSpeakTheirTitleAsLabelAndTheirCountProgressAndAvailabilityAsValue() {
        let items = FakeModule().sidebar.flatMap(\.items)
        #expect(items.map(\.accessibilityLabel) == ["First", "Second", "Later", "Third"])
        #expect(items.map(\.accessibilityValue) == ["", "4", "coming soon", "converting 50%"])
    }

    @Test func inspectorAvailabilityIsTheModulesCall() {
        let module = FakeModule()
        #expect(module.hasInspector(for: .first))
        #expect(!module.hasInspector(for: .second))
        #expect(!module.hasInspector(for: nil))
    }

    @Test func aModuleWithoutDialogsMenusOrDropsGetsTheDefaults() {
        let module = FakeModule()
        #expect(!module.hasContextMenu(for: .first))
        #expect(!module.acceptsFileDrop(on: .first))
        #expect(!module.dropFiles([], on: .first))
    }

    @Test func aModuleWithoutCommandsGetsTheEmptyDefault() {
        let module = FakeModule()
        _ = module.commands
        #expect(module.id == "fake")
    }
}
