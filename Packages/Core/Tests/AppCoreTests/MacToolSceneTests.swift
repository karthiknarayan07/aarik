import SwiftUI
import Testing

@testable import AppCore

#if os(macOS)

    @MainActor
    private final class FakeModule: MacToolScene {
        enum Page: Hashable, Sendable { case first, second, third }

        struct FakeTool: Tool {
            var id: String { "fake" }
            var title: String { "Fake" }
            var systemImage: String { "star" }
        }

        let tool: any Tool = FakeTool()
        var selection: MacShellPage<Page>? = .page(.first)
        var sidebarTint: SidebarTint { .indigo }
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
                        ToolSidebarItem(id: "unselectable", destination: nil, title: "Header", systemImage: "clock"),
                        ToolSidebarItem(
                            id: "third", destination: .third, title: "Third", systemImage: "3.circle", progress: 0.5),
                    ]),
            ]
        }

        func homeSummary() -> some View { Text("home") }
        func detail(for destination: Page?) -> some View { Text("detail") }
        func toolbar(for destination: Page?) -> some ToolbarContent {
            ToolbarItem { Text("item") }
        }
        func hasInspector(for destination: Page?) -> Bool { destination == .first }
        func inspector(for destination: Page?) -> some View { Text("inspector") }
    }

    @MainActor
    @Suite struct MacToolSceneTests {
        /// What the shell's sidebar draws for a module: `SidebarView` iterates exactly these sections and rows.
        private func shellModel(_ module: FakeModule) -> ToolSidebarModel<FakeModule.Page> {
            ToolSidebarModel(module.sidebar)
        }

        @Test func shellRendersTheModulesSectionsAndRowsInOrder() {
            let shell = shellModel(FakeModule())
            #expect(shell.sections.map(\.title) == ["One", "Two"])
            #expect(shell.sections.flatMap(\.rows).map(\.item.title) == ["First", "Second", "Header", "Third"])
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

        @Test func theShellListsHomeAskAndTheToolsPagesInOrder() {
            let module = FakeModule()
            let sidebar = MacSidebarModel(showsAsk: true, tool: module.sidebar)
            #expect(sidebar.selectablePages == [.home, .ask, .page(.first), .page(.second), .page(.third)])
            #expect(sidebar.toolRows.map(\.item.title) == ["First", "Second", "Header", "Third"])
            let noAsk = MacSidebarModel(showsAsk: false, tool: module.sidebar)
            #expect(noAsk.selectablePages == [.home, .page(.first), .page(.second), .page(.third)])
        }

        @Test func theShellRefusesAskWhenHiddenAndPagesTheToolDoesNotList() {
            let sidebar = MacSidebarModel(showsAsk: false, tool: FakeModule().sidebar)
            #expect(sidebar.accepts(.home))
            #expect(sidebar.accepts(nil))
            #expect(!sidebar.accepts(.ask))
            #expect(sidebar.accepts(.page(.second)))
            let unlisted = MacSidebarModel<FakeModule.Page>(showsAsk: true, tool: [])
            #expect(!unlisted.accepts(.page(.first)))
            #expect(unlisted.accepts(.ask))
        }

        @Test func homeAndAskAlwaysHaveAnInspectorColumn() {
            let module = FakeModule()
            #expect(!module.hasInspector(on: .home))
            #expect(module.hasInspector(on: .ask))
            #expect(module.hasInspector(on: .page(.first)))
            #expect(!module.hasInspector(on: .page(.second)))
            #expect(MacShellPage<FakeModule.Page>.page(.third).destination == .third)
            #expect(MacShellPage<FakeModule.Page>.home.destination == nil)
        }

        @Test func rowsSpeakTheirTitleAsLabelAndTheirCountAndProgressAsValue() {
            let items = FakeModule().sidebar.flatMap(\.items)
            #expect(items.map(\.accessibilityLabel) == ["First", "Second", "Header", "Third"])
            #expect(items.map(\.accessibilityValue) == ["", "4", "", "converting 50%"])
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
            #expect(module.tool.id == "fake")
        }
    }
#endif
