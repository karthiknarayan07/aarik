#if os(macOS)
    import AppCore
    import AppServices
    import SwiftUI

    /// The main window's content. The shell owns the sidebar's app items (Home, Ask) and the Tools section, and hosts one
    /// tool scene that supplies its pages, Home summary, toolbar items, inspector and dialogs. The sidebar's visibility is
    /// the window's own.
    public struct MacRootView<Module: MacToolScene>: View {
        let module: Module
        let services: AppServices
        @Binding var sidebarVisibility: NavigationSplitViewVisibility

        public init(
            module: Module, services: AppServices, sidebarVisibility: Binding<NavigationSplitViewVisibility>
        ) {
            self.module = module
            self.services = services
            self._sidebarVisibility = sidebarVisibility
        }

        private var showsAsk: Bool { services.assistantAvailability.isAvailable }

        private var inspectorShown: Binding<Bool> {
            Binding {
                module.hasInspector(on: module.selection) && module.isInspectorPresented
            } set: {
                if module.hasInspector(on: module.selection) { module.isInspectorPresented = $0 }
            }
        }

        public var body: some View {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                MacSidebarView(module: module, showsAsk: showsAsk)
            } detail: {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaBar(edge: .bottom) { module.bottomBar() }
                    .inspector(isPresented: inspectorShown) {
                        inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                    }
                    .toolbar { toolbar }
            }
            .modifier(module.dialogs)
        }

        @ViewBuilder private var page: some View {
            switch module.selection {
            case .home: module.homeSummary()
            case .ask: MacAskView(chat: services.assistantChat)
            case .page(let destination): module.detail(for: destination)
            case nil: module.detail(for: nil)
            }
        }

        @ViewBuilder private var inspector: some View {
            switch module.selection {
            case .home:
                EmptyState(
                    "No Selection", systemImage: "sidebar.trailing", message: "Select an item to see its details here.")
            case .ask: MacChatHistoryView(chat: services.assistantChat)
            case .page(let destination): module.inspector(for: destination)
            case nil: module.inspector(for: nil)
            }
        }

        /// The same items on every page, disabled where they don't apply: a toolbar that appears or disappears with the
        /// page changes the title bar's height, and with it the window's frame.
        @ToolbarContentBuilder private var toolbar: some ToolbarContent {
            let destination = module.selection?.destination
            module.toolbar(for: destination)
            if showsAsk {
                // ⌘N belongs to File → New Chat.
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chat", systemImage: "square.and.pencil") { services.assistantChat.newChat() }
                        .disabled(module.selection != .ask)
                        .help("Start a new chat (⌘N)")
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                InspectorToggle(
                    isPresented: Binding(
                        get: { module.isInspectorPresented }, set: { module.isInspectorPresented = $0 }))
            }
        }
    }

    private struct InspectorToggle: View {
        @Binding var isPresented: Bool

        var body: some View {
            Button {
                isPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(isPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            .accessibilityLabel(isPresented ? "Hide Inspector" : "Show Inspector")
        }
    }
#endif
