#if os(iOS)
    import SwiftUI

    /// Where the shell's Tools stack goes: a tool's home (no page) or one of its pages. The page is whatever string the
    /// tool gives it; the shell only carries it back to the tool's `destination(page:)`.
    public struct ToolRoute: Hashable, Sendable {
        public let toolID: String
        public let page: String?

        public init(toolID: String, page: String? = nil) {
            self.toolID = toolID
            self.page = page
        }
    }

    /// What a tool's UI gives the iOS shell: its home and pages (pushed from the Browse tab), its contribution to the
    /// Home and Search tabs, its sheets, and where the intent and share hand-off lands (ADR 0006). The shell owns
    /// the app's tab bar and the stacks; the tool fills them. The protocol only; each tool's UI package supplies the
    /// adapter. The tool's identity, platforms and runners are the `Tool`'s.
    @MainActor
    public protocol IOSToolScene: AnyObject {
        associatedtype Destination: View
        associatedtype Summary: View
        associatedtype Search: View
        /// Sheets, alerts and importers the tool needs, applied around the whole root.
        associatedtype Sheets: ViewModifier = EmptyModifier

        /// The tool this scene presents.
        var tool: any Tool { get }

        /// What the Browse tab pushes: the tool's home when `page` is nil, else one of its pages or details. Never
        /// carries a tab bar of its own.
        @ViewBuilder func destination(page: String?) -> Destination
        /// The tool's part of the Home tab: numbers and charts about what it has done and could do.
        @ViewBuilder func summary() -> Summary
        /// The tool's results for the Search tab's text; rows push `ToolRoute`s.
        @ViewBuilder func search(query: String) -> Search
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

    private struct OpenToolRouteKey: EnvironmentKey {
        static let defaultValue: @MainActor (ToolRoute) -> Void = { _ in }
    }

    extension EnvironmentValues {
        /// Opens a tool's page in the Browse tab, whichever tab asks (Home's cards, the queue accessory); set by
        /// the shell.
        public var openToolRoute: @MainActor (ToolRoute) -> Void {
            get { self[OpenToolRouteKey.self] }
            set { self[OpenToolRouteKey.self] = newValue }
        }
    }

    /// An `IOSToolScene` without its associated types, so the shell can hold the scenes of every tool in one list and
    /// still know only `Tool` and the scene protocol.
    @MainActor
    public struct AnyIOSToolScene: Identifiable {
        public let tool: any Tool
        public let id: String

        private let makeDestination: (String?) -> AnyView
        private let makeSummary: () -> AnyView
        private let makeSearch: (String) -> AnyView
        private let wrapSheets: (AnyView) -> AnyView
        private let deliver: ([MediaInput]) -> Void

        public init<Scene: IOSToolScene>(_ scene: Scene) {
            tool = scene.tool
            id = scene.tool.id
            makeDestination = { AnyView(scene.destination(page: $0)) }
            makeSummary = { AnyView(scene.summary()) }
            makeSearch = { AnyView(scene.search(query: $0)) }
            wrapSheets = { AnyView($0.modifier(scene.sheets)) }
            deliver = { scene.receive($0) }
        }

        public func destination(page: String?) -> AnyView { makeDestination(page) }
        public func summary() -> AnyView { makeSummary() }
        public func search(query: String) -> AnyView { makeSearch(query) }
        public func sheets(around content: AnyView) -> AnyView { wrapSheets(content) }
        public func receive(_ inputs: [MediaInput]) { deliver(inputs) }
    }
#endif
