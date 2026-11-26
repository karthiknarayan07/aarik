#if os(macOS)
    import AppCore
    import SwiftUI

    /// The main window's content. It hosts one tool module (its sidebar, pages, toolbar, inspector and dialogs) and knows
    /// nothing else of the tool; the sidebar's visibility is the window's own.
    public struct MacRootView<Module: MacToolScene>: View {
        let module: Module
        @Binding var sidebarVisibility: NavigationSplitViewVisibility

        public init(module: Module, sidebarVisibility: Binding<NavigationSplitViewVisibility>) {
            self.module = module
            self._sidebarVisibility = sidebarVisibility
        }

        private var inspectorShown: Binding<Bool> {
            Binding {
                module.hasInspector(for: module.selection) && module.isInspectorPresented
            } set: {
                if module.hasInspector(for: module.selection) { module.isInspectorPresented = $0 }
            }
        }

        public var body: some View {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                MacSidebarView(module: module)
            } detail: {
                module.detail(for: module.selection)
                    .inspector(isPresented: inspectorShown) {
                        module.inspector(for: module.selection)
                    }
                    .toolbar { module.toolbar(for: module.selection) }
            }
            .modifier(module.dialogs)
        }
    }
#endif
