import AarikCore
import SwiftUI

/// The main window's content. It hosts one tool module (its sidebar, pages, toolbar, inspector and dialogs) and knows
/// nothing else of the tool; the sidebar's visibility is the window's own.
struct RootView<Module: ToolModule>: View {
    let module: Module
    @Binding var sidebarVisibility: NavigationSplitViewVisibility

    private var inspectorShown: Binding<Bool> {
        Binding {
            module.hasInspector(for: module.selection) && module.isInspectorPresented
        } set: {
            if module.hasInspector(for: module.selection) { module.isInspectorPresented = $0 }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(module: module)
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
