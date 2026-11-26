import AarikCore
import SharedUI
import Convert
import SwiftUI
import UniformTypeIdentifiers

/// The video tool as the shell hosts it: its sidebar, pages, toolbar, inspector, dialogs, drops and menu commands.
@MainActor
final class ConvertModule: ToolModule {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var id: String { ConvertTool.descriptor.id }
    var title: String { ConvertTool.descriptor.name }
    var systemImage: String { ConvertTool.descriptor.symbol }

    var selection: VideoPage? {
        get { model.selection }
        set { model.selection = newValue }
    }

    var isInspectorPresented: Bool {
        get { model.isInspectorPresented }
        set { model.isInspectorPresented = newValue }
    }

    var sidebar: [ToolSidebarSection<VideoPage>] {
        VideoSidebar.sections(
            VideoSidebarState(
                photosCount: model.photos.hasLoaded ? model.photos.items.count : nil,
                localCount: model.library.items.count, badgeCounts: model.library.badgeCounts,
                activity: model.activity))
    }

    @ViewBuilder func detail(for destination: VideoPage?) -> some View {
        VideoDetail(model: model, destination: destination)
    }

    @ToolbarContentBuilder func toolbar(for destination: VideoPage?) -> some ToolbarContent {
        let model = model
        if hasInspector(for: destination) {
            // The inspector's main action sits in the toolbar, as Xcode and Photos put theirs. ⌘⏎ belongs to the
            // Queue menu's item of the same name.
            ToolbarItem(placement: .primaryAction) {
                Button(model.toolbarAddToQueueTitle, systemImage: "plus") {
                    model.requestAddSelectionToQueue()
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.canAddSelectionToQueue)
                .help("Add the selected videos to the queue (⌘⏎)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                InspectorToggle(isPresented: Bindable(model).isInspectorPresented)
            }
        }
    }

    func hasInspector(for destination: VideoPage?) -> Bool {
        destination?.showsLibrary == true || destination == .photosVideos
    }

    @ViewBuilder func inspector(for destination: VideoPage?) -> some View {
        LibraryInspector(model: model)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }

    var dialogs: VideoDialogs { VideoDialogs(model: model) }

    var commands: VideoCommands { VideoCommands(model: model) }

    // MARK: Sidebar rows

    func hasContextMenu(for destination: VideoPage) -> Bool {
        switch destination {
        case .localFiles, .queue, .failed: true
        default: false
        }
    }

    @ViewBuilder func contextMenu(for destination: VideoPage) -> some View {
        let model = model
        switch destination {
        case .localFiles:
            Button("Add Videos…") { model.perform(.addVideos) }
        case .queue:
            Button(model.isQueuePaused ? "Resume Queue" : "Pause Queue") { model.perform(.pauseOrResumeQueue) }
        case .failed:
            Button("Retry All Failed") { model.perform(.retryAllFailed) }
                .disabled(model.activity.failed == 0)
        default:
            EmptyView()
        }
    }

    /// Dropping videos on Local Files adds them, with the row as the target.
    func acceptsFileDrop(on destination: VideoPage) -> Bool { destination == .localFiles }

    func dropFiles(_ urls: [URL], on destination: VideoPage) -> Bool {
        model.addFiles(urls)
        return !urls.isEmpty
    }
}

/// A page of the video tool, with the bar for originals waiting to move to Recently Deleted on every page.
private struct VideoDetail: View {
    @Bindable var model: AppModel
    let destination: VideoPage?

    var body: some View {
        Group {
            switch destination {
            case .localFiles, .mediaType: LocalFilesView(model: model)
            case .photosVideos: PhotosView(model: model)
            case .queue: QueueView(model: model)
            case .completed: CompletedView(model: model)
            case .keptAsIs: KeptAsIsView(model: model)
            case .failed: FailedView(model: model)
            case .overview: OverviewView(model: model)
            case .some(let page):
                page.emptyState
                    .navigationTitle(page.title)
            case nil:
                EmptyState("Nothing Selected", systemImage: "sidebar.left", message: "Choose a section in the sidebar.")
                    .navigationTitle(AppModel.displayName)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom) {
            if let content = model.pendingDeletionBar {
                PendingDeletionBar(
                    content: content, perform: model.performPendingDeletionAction,
                    removeKept: model.removeKeptOriginalsFromList, openSettings: model.openPhotosAccessSettings)
            }
        }
    }
}

/// The video tool's window-wide dialogs: the file importer, dropped files, the Replace confirmation, messages and the
/// loss review.
struct VideoDialogs: ViewModifier {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

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

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $model.isImporterPresented, allowedContentTypes: [.movie, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { model.addFiles(urls) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // A video dragged out of the grid and dropped back on the window is not an import.
                let urls = ImportDropGuard.importable(urls, isInternalDragActive: InternalDrag.isActive)
                model.addFiles(urls)
                return !urls.isEmpty
            } isTargeted: {
                isDropTargeted = $0
            }
            .overlay {
                // The system's drop feedback: the window's edge in the accent colour.
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.tint, lineWidth: 3)
                        .padding(3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .alert("Replace the Original?", isPresented: $model.isConfirmingReplace) {
                Button("Cancel", role: .cancel) {}
                // Not destructive: the original goes to the Trash (or Recently Deleted), where it can be restored.
                Button("Replace") { model.confirmReplace() }
            } message: {
                if model.isPhotosPage {
                    Text(
                        "The smaller copy is saved to Photos and verified first. Then Photos asks you to move the "
                            + "originals to Recently Deleted.")
                } else {
                    Text("The original moves to the Trash after the smaller copy is verified.")
                }
            }
            .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { _ in
                Button("OK") {}
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
