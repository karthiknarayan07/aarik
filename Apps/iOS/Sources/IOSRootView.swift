import AppCore
import SwiftUI

/// The iOS root: a Tools list, then the chosen tool's own pages, then the page's detail (ADR 0006). One
/// `NavigationSplitView` serves every size: it collapses to a stack on iPhone and a folded Duo (Tools, then pages, then
/// detail) and shows three columns on iPad and an open Duo. The selection lives here and in the tool's scene, never in a
/// column's view, so a size-class or posture change keeps it, and `SceneStorage` brings it back after a relaunch.
struct IOSRootView: View {
    let shell: IOSShell
    @SceneStorage("navigation") private var stored = ""
    // Chosen up front: a selection that appears later would push the collapsed stack past the Tools list.
    @State private var toolID: String?
    @State private var column = NavigationSplitViewColumn.sidebar
    @State private var hasRestored = false
    @State private var hasOpenedTool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

    init(shell: IOSShell) {
        self.shell = shell
        _toolID = State(initialValue: shell.scenes.first?.id)
    }

    private var selectedScene: AnyIOSToolScene? {
        shell.scenes.first { $0.id == toolID }
    }

    /// In a collapsed stack nothing is selected until the person taps a row (a selection would push past the Tools
    /// list at launch), and popping clears it again; the tool stays chosen either way. Side by side, the chosen tool
    /// is always selected.
    private var toolSelection: Binding<String?> {
        Binding {
            isCompact && !hasOpenedTool ? nil : toolID
        } set: { newValue in
            if let newValue {
                toolID = newValue
                hasOpenedTool = true
            } else if isCompact {
                hasOpenedTool = false
            }
        }
    }

    var body: some View {
        split
            .modifier(SheetsModifier(scenes: shell.scenes))
            .task { restore() }
            .onChange(of: toolID) { save() }
            .onChange(of: column) { save() }
            .onChange(of: selectedScene?.page) { save() }
    }

    private var split: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            List(shell.scenes, selection: toolSelection) { scene in
                NavigationLink(value: scene.id) {
                    Label {
                        Text(scene.tool.title)
                    } icon: {
                        Image(systemName: scene.tool.systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Self.tint(for: scene.id))
                    }
                }
                .accessibilityIdentifier("tool.\(scene.id)")
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tools")
        } content: {
            if let selectedScene {
                selectedScene.pages()
            } else {
                ContentUnavailableView("Choose a Tool", systemImage: "wrench.and.screwdriver")
            }
        } detail: {
            NavigationStack {
                if let selectedScene {
                    selectedScene.detail()
                } else {
                    ContentUnavailableView("Choose a Tool", systemImage: "wrench.and.screwdriver")
                }
            }
        }
    }

    /// A system color per tool, stable across launches (the id's bytes, not `hashValue`).
    private static func tint(for id: String) -> Color {
        let palette: [Color] = [.blue, .pink, .orange, .green, .purple, .teal, .indigo]
        return palette[id.utf8.reduce(0) { ($0 &+ Int($1)) % palette.count }]
    }

    private func restore() {
        guard !hasRestored else { return }
        hasRestored = true
        let ids = shell.scenes.map(\.id)
        let state = ToolNavigationState(stored: stored).restricted(to: ids)
        if let restored = state.toolID, restored != toolID { toolID = restored }
        if let page = state.page { selectedScene?.page = page }
        hasOpenedTool = state.column != .tools
        column =
            switch state.column {
            case .tools: .sidebar
            case .pages: .content
            case .detail: .detail
            }
    }

    private func save() {
        guard hasRestored else { return }
        let state = ToolNavigationState(
            toolID: toolID, page: selectedScene?.page,
            column: column == .detail ? .detail : column == .content ? .pages : .tools)
        stored = state.stored
    }
}

/// Every tool's sheets, importers and alerts, around the whole root, so none is dismissed by a size-class or posture
/// change or by choosing another tool.
private struct SheetsModifier: ViewModifier {
    let scenes: [AnyIOSToolScene]

    func body(content: Content) -> some View {
        scenes.reduce(AnyView(content)) { $1.sheets(around: $0) }
    }
}
