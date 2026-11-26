import AppCore
import Convert
import SwiftUI

/// The iOS root: one native tab bar (Liquid Glass) with Home, Browse, Ask and Search. The tab bar folds away as a
/// list scrolls, and an accessory over it shows the job converting now. The shell knows only `Tool` and
/// `IOSToolScene` (ADR 0006): a tool fills Home with its numbers, is opened from a card in Browse (pushed on the
/// Browse tab's stack, with no tab bar of its own) and answers Search. The tab and the open tool are kept in
/// `SceneStorage`, so a relaunch lands in the same place, and a first launch shows the short onboarding once.
struct IOSRootView: View {
    let shell: IOSShell
    @SceneStorage("rootTab") private var storedTab = ""
    @SceneStorage("openTool") private var storedTool = ""
    @AppStorage(IOSOnboarding.completedKey) private var hasOnboarded = false
    @State private var tab = IOSTab.home
    @State private var toolsPath: [ToolRoute] = []
    @State private var hasRestored = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: IOSTab.home) {
                NavigationStack {
                    if let scene = shell.scenes.first {
                        scene.summary()
                    } else {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "house")
                    }
                }
            }
            Tab("Browse", systemImage: "square.grid.2x2.fill", value: IOSTab.browse) {
                NavigationStack(path: $toolsPath) {
                    IOSToolsGrid(scenes: shell.scenes)
                        .routeDestinations(shell.scenes)
                }
            }
            // Without Apple Intelligence there is no Ask tab at all; it comes back when the model becomes available.
            if shell.convert.assistant.isAvailable {
                Tab("Ask", systemImage: "sparkles", value: IOSTab.ask) {
                    AssistantTabRoot()
                }
            }
            Tab(value: IOSTab.search, role: .search) {
                IOSSearchTab(scenes: shell.scenes)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(
            IOSJobAccessoryModifier(model: shell.convert) {
                open(ToolRoute(toolID: shell.convert.tool.id, page: IOSPage.queue.rawValue))
            }
        )
        .environment(\.openToolRoute) { open($0) }
        .sensoryFeedback(.success, trigger: shell.convert.activity.completed)
        .sensoryFeedback(trigger: shell.convert.queuePause.automatic) { old, new in
            new != nil && old != new ? .warning : nil
        }
        .modifier(SheetsModifier(scenes: shell.scenes))
        .fullScreenCover(isPresented: onboardingShown) {
            IOSOnboardingView(requestPhotosAccess: { await shell.requestPhotosAccess() }) {
                hasOnboarded = true
            }
        }
        .task { restore() }
        .onChange(of: tab) { storedTab = tab.rawValue }
        .onChange(of: shell.convert.assistant.isAvailable) {
            // The selection moves only when the tab it is on disappears.
            if tab == .ask && !shell.convert.assistant.isAvailable { tab = .home }
        }
        .onChange(of: toolsPath) { storedTool = toolsPath.first?.toolID ?? "" }
    }

    /// Shows a tool's home or page in the Browse tab, whichever tab asked.
    private func open(_ route: ToolRoute) {
        let home = ToolRoute(toolID: route.toolID)
        toolsPath = route.page == nil ? [home] : [home, route]
        tab = .browse
    }

    private var onboardingShown: Binding<Bool> {
        Binding {
            !hasOnboarded
        } set: {
            if !$0 { hasOnboarded = true }
        }
    }

    private func restore() {
        guard !hasRestored else { return }
        hasRestored = true
        if let restored = IOSTab(rawValue: storedTab), restored != .ask || shell.convert.assistant.isAvailable {
            tab = restored
        }
        if shell.scenes.contains(where: { $0.id == storedTool }) { toolsPath = [ToolRoute(toolID: storedTool)] }
    }
}

enum IOSTab: String, Hashable {
    case home, browse, ask, search
}

/// The Browse tab: a grid of large rounded cards, one per tool (like Health's Browse), each with a colourful symbol.
private struct IOSToolsGrid: View {
    let scenes: [AnyIOSToolScene]
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 34

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(scenes) { scene in
                    NavigationLink(value: ToolRoute(toolID: scene.id)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: scene.tool.systemImage)
                                .font(.system(size: symbolSize))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, IOSTint.color(for: scene.id))
                                .accessibilityHidden(true)
                            Text(scene.tool.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                        .padding(16)
                        .background(IOSTint.color(for: scene.id).opacity(0.14), in: .rect(cornerRadius: 24))
                        .contentShape(.rect(cornerRadius: 24))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tool.\(scene.id)")
                    .accessibilityLabel(scene.tool.title)
                }
            }
            .padding()
        }
        .navigationTitle("Browse")
    }
}

/// A system color per tool, stable across launches (the id's bytes, not `hashValue`).
private enum IOSTint {
    static func color(for id: String) -> Color {
        let palette: [Color] = [.blue, .pink, .orange, .green, .purple, .teal, .indigo]
        return palette[id.utf8.reduce(0) { ($0 &+ Int($1)) % palette.count }]
    }
}

/// Search across every tool; a result pushes in the Search tab's own stack.
private struct IOSSearchTab: View {
    let scenes: [AnyIOSToolScene]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            // One tool offers search today; its results are a list of their own.
            Group {
                if let scene = scenes.first {
                    scene.search(query: query)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Videos in Photos and Files")
            .routeDestinations(scenes)
        }
    }
}

extension View {
    /// Pushes a tool's home or page for a `ToolRoute`.
    fileprivate func routeDestinations(_ scenes: [AnyIOSToolScene]) -> some View {
        navigationDestination(for: ToolRoute.self) { route in
            if let scene = scenes.first(where: { $0.id == route.toolID }) {
                scene.destination(page: route.page)
            }
        }
    }
}

/// Every tool's sheets, importers and alerts, around the whole root, so none is dismissed by choosing another tab.
private struct SheetsModifier: ViewModifier {
    let scenes: [AnyIOSToolScene]

    func body(content: Content) -> some View {
        scenes.reduce(AnyView(content)) { $1.sheets(around: $0) }
    }
}
