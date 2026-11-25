import AppUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var model: AppModel

    private var queueErrorShown: Binding<Bool> {
        Binding {
            model.queueError != nil
        } set: {
            if !$0 { model.queueError = nil }
        }
    }

    /// The inspector belongs to the library grid; the Activity lists don't show it.
    private var showsLibrary: Bool { model.selection?.showsLibrary == true }

    private var inspectorShown: Binding<Bool> {
        Binding {
            showsLibrary && model.isInspectorPresented
        } set: {
            if showsLibrary { model.isInspectorPresented = $0 }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            DetailView(model: model)
                .fileImporter(
                    isPresented: $model.isImporterPresented, allowedContentTypes: [.movie, .folder],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result { model.addFiles(urls) }
                }
                .inspector(isPresented: inspectorShown) {
                    LibraryInspector(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
                .toolbar {
                    if showsLibrary {
                        ToolbarItem(placement: .primaryAction) {
                            InspectorToggle(isPresented: $model.isInspectorPresented)
                        }
                    }
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        }
        .alert("Replace the original?", isPresented: $model.isConfirmingReplace) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { model.confirmReplace() }
        } message: {
            Text("The original goes to the Trash after the smaller copy is verified.")
        }
        .alert("Couldn't add to the queue", isPresented: queueErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.queueError ?? "")
        }
    }
}

private struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.selection {
            case .localFiles, .mediaType: LocalFilesView(model: model)
            case .queue: QueueView(model: model)
            case .completed: CompletedView(model: model)
            case .keptAsIs: KeptAsIsView(model: model)
            case .failed: FailedView(model: model)
            case .some(let destination):
                destination.emptyState
                    .navigationTitle(destination.title)
            case nil:
                EmptyState("Nothing selected", systemImage: "sidebar.left", message: "Choose a section in the sidebar.")
                    .navigationTitle(AppModel.displayName)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .help(isPresented ? "Hide inspector" : "Show inspector")
        .accessibilityLabel(isPresented ? "Hide inspector" : "Show inspector")
    }
}
