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
                .inspector(isPresented: $model.isInspectorPresented) {
                    LibraryInspector(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        InspectorToggle(isPresented: $model.isInspectorPresented)
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
            if let destination = model.selection {
                if destination.showsLibrary {
                    LocalFilesView(model: model)
                } else {
                    destination.emptyState
                        .navigationTitle(destination.title)
                }
            } else {
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
