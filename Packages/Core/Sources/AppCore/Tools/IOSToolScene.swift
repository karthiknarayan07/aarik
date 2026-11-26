#if os(iOS)
    import SwiftUI

    /// What a tool's UI gives the iOS shell: its pages, its detail, its toolbar, its sheets, and where the intent and
    /// share hand-off lands (ADR 0006). The tool owns its navigation below the Tools list: the shell lists the tools
    /// and hosts the columns `[Tools] | [pages] | [detail]` (a stack on iPhone and a folded Duo), and the tool fills the
    /// last two. The protocol only; each tool's UI package supplies the adapter. The tool's identity, platforms and
    /// runners are the `Tool`'s.
    @MainActor
    public protocol IOSToolScene: AnyObject where Destination.RawValue == String {
        /// What the page list selects: one value per page of the tool. Its raw value is what state restoration stores.
        associatedtype Destination: Hashable & Sendable & RawRepresentable
        /// The tool's own list of pages (a `List(selection:)` of `NavigationLink(value:)` rows bound to `selection`).
        associatedtype Pages: View
        associatedtype Detail: View
        associatedtype Toolbar: ToolbarContent
        /// Sheets, alerts and importers the tool needs, applied around the whole root.
        associatedtype Sheets: ViewModifier = EmptyModifier

        /// The tool this scene presents.
        var tool: any Tool { get }

        /// The page showing, kept by the scene so a size class or posture change doesn't lose it.
        var selection: Destination? { get set }

        @ViewBuilder func pages() -> Pages
        @ViewBuilder func detail(for destination: Destination?) -> Detail
        @ToolbarContentBuilder func toolbar(for destination: Destination?) -> Toolbar
        var sheets: Sheets { get }

        /// The inputs an App Intent or the share extension handed over, staged by the app. The scene shows what it
        /// needs to; it never encodes in an extension.
        func receive(_ inputs: [MediaInput])
    }

    extension IOSToolScene where Sheets == EmptyModifier {
        public var sheets: EmptyModifier { EmptyModifier() }
    }

    extension IOSToolScene {
        public func receive(_ inputs: [MediaInput]) {}
    }

    /// An `IOSToolScene` without its associated types, so the shell can hold the scenes of every tool in one list and
    /// still know only `Tool` and the scene protocol.
    @MainActor
    public struct AnyIOSToolScene: Identifiable {
        public let tool: any Tool
        public let id: String

        private let makePages: () -> AnyView
        private let makeDetail: () -> AnyView
        private let wrapSheets: (AnyView) -> AnyView
        private let readPage: () -> String?
        private let writePage: (String?) -> Void
        private let deliver: ([MediaInput]) -> Void

        public init<Scene: IOSToolScene>(_ scene: Scene) {
            tool = scene.tool
            id = scene.tool.id
            makePages = { AnyView(scene.pages()) }
            makeDetail = {
                AnyView(
                    scene.detail(for: scene.selection)
                        .toolbar { scene.toolbar(for: scene.selection) })
            }
            wrapSheets = { AnyView($0.modifier(scene.sheets)) }
            readPage = { scene.selection?.rawValue }
            writePage = { scene.selection = $0.flatMap(Scene.Destination.init(rawValue:)) }
            deliver = { scene.receive($0) }
        }

        /// The raw value of the page showing, for state restoration.
        public var page: String? {
            get { readPage() }
            nonmutating set { writePage(newValue) }
        }

        public func pages() -> AnyView { makePages() }
        public func detail() -> AnyView { makeDetail() }
        public func sheets(around content: AnyView) -> AnyView { wrapSheets(content) }
        public func receive(_ inputs: [MediaInput]) { deliver(inputs) }
    }
#endif
