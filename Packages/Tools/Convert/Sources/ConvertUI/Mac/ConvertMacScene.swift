#if os(macOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI
    import UniformTypeIdentifiers

    /// The video tool as the Mac shell hosts it: its sidebar, pages, toolbar, inspector, dialogs, drops and menu commands.
    @MainActor
    public final class ConvertMacScene: MacToolScene {
        private let model: ConvertModel

        public init(model: ConvertModel) {
            self.model = model
        }

        public var tool: any Tool { model.tool }

        public var sidebarTint: SidebarTint { .indigo }

        /// Home and Ask are the shell's pages; the model keeps them beside its own, so they map one to one.
        public var selection: MacShellPage<VideoPage>? {
            get {
                switch model.selection {
                case .overview: .home
                case .ask: .ask
                case .some(let page): .page(page)
                case nil: nil
                }
            }
            set {
                switch newValue {
                case .home: model.selection = .overview
                case .ask: model.selection = .ask
                case .page(let page): model.selection = page
                case nil: model.selection = nil
                }
            }
        }

        public var isInspectorPresented: Bool {
            get { model.isInspectorPresented }
            set { model.isInspectorPresented = newValue }
        }

        public var sidebar: [ToolSidebarSection<VideoPage>] {
            VideoSidebar.sections(
                VideoSidebarState(
                    photosCount: model.photos.hasLoaded ? model.photos.items.count : nil,
                    localCount: model.library.items.count, badgeCounts: model.library.badgeCounts,
                    activity: model.activity))
        }

        /// Today's Overview, the savings summary, is the app's Home.
        @ViewBuilder public func homeSummary() -> some View {
            OverviewView(model: model)
        }

        @ViewBuilder public func detail(for destination: VideoPage?) -> some View {
            VideoDetail(model: model, destination: destination)
        }

        @ViewBuilder public func bottomBar() -> some View {
            if let content = model.pendingDeletionBar {
                PendingDeletionBar(
                    content: content, perform: model.performPendingDeletionAction,
                    removeKept: model.removeKeptOriginalsFromList, openSettings: model.openPhotosAccessSettings)
            }
        }

        /// Only asked for on the tool's own pages; the shell's items keep the title bar's height the same elsewhere.
        @ToolbarContentBuilder public func toolbar(for destination: VideoPage?) -> some ToolbarContent {
            let model = model
            ToolbarItem(placement: .primaryAction) {
                Button("Compress…", systemImage: "rectangle.compress.vertical") {
                    model.presentCompress()
                }
                .disabled(!model.canAddSelectionToQueue)
                .help("Compress the selected videos without changing resolution")
            }
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
        }

        /// Every page has the inspector column, so the detail area keeps its width when the page changes.
        public func hasInspector(for destination: VideoPage?) -> Bool { true }

        @ViewBuilder public func inspector(for destination: VideoPage?) -> some View {
            Group {
                if destination?.showsLibrary == true || destination == .photosVideos {
                    LibraryInspector(model: model)
                } else {
                    EmptyState(
                        "No Selection", systemImage: "sidebar.trailing",
                        message: "Select videos in Photos or Local Files to see their details here.")
                }
            }
        }

        public var dialogs: VideoDialogs { VideoDialogs(model: model) }

        public var commands: VideoCommands { VideoCommands(model: model) }

        // MARK: Sidebar rows

        public func hasContextMenu(for destination: VideoPage) -> Bool {
            switch destination {
            case .localFiles, .queue, .failed: true
            default: false
            }
        }

        @ViewBuilder public func contextMenu(for destination: VideoPage) -> some View {
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
        public func acceptsFileDrop(on destination: VideoPage) -> Bool { destination == .localFiles }

        public func dropFiles(_ urls: [URL], on destination: VideoPage) -> Bool {
            model.addFiles(urls)
            return !urls.isEmpty
        }
    }

    /// A page of the video tool, with the bar for originals waiting to move to Recently Deleted on every page.
    private struct VideoDetail: View {
        @Bindable var model: ConvertModel
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
                case .overview, .ask:
                    // The shell's pages (Home, Ask); never selected through the tool's rows.
                    EmptyView()
                case .some(let page):
                    page.emptyState
                        .navigationTitle(page.title)
                case nil:
                    EmptyState(
                        "Nothing Selected", systemImage: "sidebar.left", message: "Choose a section in the sidebar."
                    )
                    .navigationTitle(AppInfo.displayName)
                }
            }
        }
    }

    /// The video tool's window-wide dialogs: the file importer, dropped files, the Replace confirmation, messages and the
    /// loss review.
    public struct VideoDialogs: ViewModifier {
        @Bindable var model: ConvertModel
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

        public func body(content: Content) -> some View {
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
                .sheet(isPresented: $model.isCompressPresented) {
                    CompressSheet(model: model)
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
#endif
