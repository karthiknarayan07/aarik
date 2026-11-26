import AppCore
import SwiftUI

/// The iOS root: a Tools list, and the chosen tool's own interface pushed from it (ADR 0006). The shell knows only
/// `Tool` and `IOSToolScene`; a tool brings its own tab bar and its own way back (`toolExit`). The open tool is kept
/// in `SceneStorage`, so a relaunch lands in the same place, and a first launch shows the short onboarding once.
struct IOSRootView: View {
    let shell: IOSShell
    @SceneStorage("openTool") private var storedTool = ""
    @AppStorage(IOSOnboarding.completedKey) private var hasOnboarded = false
    @State private var path: [String] = []
    @State private var hasRestored = false

    var body: some View {
        NavigationStack(path: $path) {
            List(shell.scenes) { scene in
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
            .navigationDestination(for: String.self) { id in
                if let scene = shell.scenes.first(where: { $0.id == id }) {
                    ToolHost(scene: scene) { path.removeAll() }
                }
            }
        }
        .modifier(SheetsModifier(scenes: shell.scenes))
        .fullScreenCover(isPresented: onboardingShown) {
            IOSOnboardingView(requestPhotosAccess: { await shell.requestPhotosAccess() }) {
                hasOnboarded = true
            }
        }
        .task { restore() }
        .onChange(of: path) { storedTool = path.first ?? "" }
    }

    private var onboardingShown: Binding<Bool> {
        Binding {
            !hasOnboarded
        } set: {
            if !$0 { hasOnboarded = true }
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
        if shell.scenes.contains(where: { $0.id == storedTool }) { path = [storedTool] }
    }
}

/// One tool's interface, with the action that goes back to the Tools list.
private struct ToolHost: View {
    let scene: AnyIOSToolScene
    let exit: @MainActor () -> Void

    var body: some View {
        scene.root()
            .environment(\.toolExit, exit)
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Every tool's sheets, importers and alerts, around the whole root, so none is dismissed by choosing another tool.
private struct SheetsModifier: ViewModifier {
    let scenes: [AnyIOSToolScene]

    func body(content: Content) -> some View {
        scenes.reduce(AnyView(content)) { $1.sheets(around: $0) }
    }
}
