import AppCore
import AppUI
import SwiftUI
import UniformTypeIdentifiers

/// The main window's content: hosts one tool module (its sidebar, pages, toolbar and inspector) and owns what every
/// tool shares: the file importer, drops, the alerts, the loss review and the pending-deletion bar.
struct RootView<Module: ToolModule>: View {
    @Bindable var model: AppModel
    let module: Module

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

    private var inspectorShown: Binding<Bool> {
        Binding {
            module.hasInspector(for: module.selection) && model.isInspectorPresented
        } set: {
            if module.hasInspector(for: module.selection) { model.isInspectorPresented = $0 }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarView(module: module)
        } detail: {
            DetailView(model: model, module: module)
                .fileImporter(
                    isPresented: $model.isImporterPresented, allowedContentTypes: [.movie, .folder],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result { model.addFiles(urls) }
                }
                .inspector(isPresented: inspectorShown) {
                    module.inspector(for: module.selection)
                }
                .toolbar { module.toolbar(for: module.selection) }
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

private struct DetailView<Module: ToolModule>: View {
    @Bindable var model: AppModel
    let module: Module

    var body: some View {
        Group { module.detail(for: module.selection) }
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
