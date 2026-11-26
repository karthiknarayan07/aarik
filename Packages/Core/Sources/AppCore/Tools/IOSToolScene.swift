#if os(iOS)
    import SwiftUI

    /// What a tool's UI gives the iOS shell: its whole interface below the Tools list, its sheets, and where the intent
    /// and share hand-off lands (ADR 0006). The shell lists the tools and pushes the chosen one's `root()`; the tool
    /// owns everything inside, such as its own tab bar, and brings its own way back to the Tools list through the
    /// `toolExit` environment action. The protocol only; each tool's UI package supplies the adapter. The tool's
    /// identity, platforms and runners are the `Tool`'s.
    @MainActor
    public protocol IOSToolScene: AnyObject {
        associatedtype Root: View
        /// Sheets, alerts and importers the tool needs, applied around the whole root.
        associatedtype Sheets: ViewModifier = EmptyModifier

        /// The tool this scene presents.
        var tool: any Tool { get }

        /// The tool's interface, pushed from the Tools list.
        @ViewBuilder func root() -> Root
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

    private struct ToolExitKey: EnvironmentKey {
        static let defaultValue: @MainActor () -> Void = {}
    }

    extension EnvironmentValues {
        /// Goes back to the Tools list; set by the shell for the tool it shows.
        public var toolExit: @MainActor () -> Void {
            get { self[ToolExitKey.self] }
            set { self[ToolExitKey.self] = newValue }
        }
    }

    /// An `IOSToolScene` without its associated types, so the shell can hold the scenes of every tool in one list and
    /// still know only `Tool` and the scene protocol.
    @MainActor
    public struct AnyIOSToolScene: Identifiable {
        public let tool: any Tool
        public let id: String

        private let makeRoot: () -> AnyView
        private let wrapSheets: (AnyView) -> AnyView
        private let deliver: ([MediaInput]) -> Void

        public init<Scene: IOSToolScene>(_ scene: Scene) {
            tool = scene.tool
            id = scene.tool.id
            makeRoot = { AnyView(scene.root()) }
            wrapSheets = { AnyView($0.modifier(scene.sheets)) }
            deliver = { scene.receive($0) }
        }

        public func root() -> AnyView { makeRoot() }
        public func sheets(around content: AnyView) -> AnyView { wrapSheets(content) }
        public func receive(_ inputs: [MediaInput]) { deliver(inputs) }
    }
#endif
