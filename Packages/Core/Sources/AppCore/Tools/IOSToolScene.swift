#if os(iOS)
    import SwiftUI

    /// What a tool's UI gives the iOS shell: its root navigation (adaptive for iPhone, iPad and Duo), its detail, its
    /// toolbar, its sheets, and where the intent and share hand-off lands (ADR 0006). The protocol only; each tool's UI
    /// package supplies the adapter. The tool's identity, platforms and runners are the `Tool`'s.
    @MainActor
    public protocol IOSToolScene: AnyObject {
        /// What the root navigation selects: one value per page of the tool.
        associatedtype Destination: Hashable & Sendable
        /// The root navigation. It adapts to the size class and posture, and keeps its selection when they change.
        associatedtype Root: View
        associatedtype Detail: View
        associatedtype Toolbar: ToolbarContent
        /// Sheets, alerts and importers the tool needs, applied around the whole root.
        associatedtype Sheets: ViewModifier = EmptyModifier

        /// The tool this scene presents.
        var tool: any Tool { get }

        /// The page showing, kept by the scene so a size class or posture change doesn't lose it.
        var selection: Destination? { get set }

        @ViewBuilder func root() -> Root
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
#endif
