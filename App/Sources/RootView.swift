import AppUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var model: AppModel

    private var alertShown: Binding<Bool> {
        Binding {
            model.alert != nil
        } set: {
            if !$0 { model.alert = nil }
        }
    }

    private var lossReviewShown: Binding<Bool> {
        Binding {
            model.lossReview != nil
        } set: {
            if !$0 { model.cancelLossReview() }
        }
    }

    /// The inspector belongs to the library grids; the Activity lists don't show it.
    private var showsLibrary: Bool { model.selection?.showsLibrary == true || model.isPhotosPage }

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
            if model.isPhotosPage {
                Text(
                    "The smaller copy is saved to Photos and verified first. Then Photos asks you to move the "
                        + "originals to Recently Deleted.")
            } else {
                Text("The original goes to the Trash after the smaller copy is verified.")
            }
        }
        .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .sheet(isPresented: lossReviewShown) {
            if let review = model.lossReview {
                LossConfirmationSheet(
                    review: Binding {
                        model.lossReview ?? review
                    } set: {
                        model.lossReview = $0
                    },
                    cancel: model.cancelLossReview, convert: model.confirmLossReview)
            }
        }
    }
}

private struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.selection {
            case .localFiles, .mediaType: LocalFilesView(model: model)
            case .photosVideos: PhotosView(model: model)
            case .queue: QueueView(model: model)
            case .completed: CompletedView(model: model)
            case .keptAsIs: KeptAsIsView(model: model)
            case .failed: FailedView(model: model)
            case .overview: OverviewView(model: model)
            case .some(let destination):
                destination.emptyState
                    .navigationTitle(destination.title)
            case nil:
                EmptyState("Nothing selected", systemImage: "sidebar.left", message: "Choose a section in the sidebar.")
                    .navigationTitle(AppModel.displayName)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Originals waiting to move to Recently Deleted, on every page, in the system's bottom bar.
        .safeAreaBar(edge: .bottom) {
            if let content = model.pendingDeletionBar {
                PendingDeletionBar(
                    content: content, perform: model.performPendingDeletionAction,
                    removeKept: model.removeKeptOriginalsFromList, openSettings: model.openPhotosAccessSettings)
            }
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
        .help(isPresented ? "Hide inspector" : "Show inspector")
        .accessibilityLabel(isPresented ? "Hide inspector" : "Show inspector")
    }
}
