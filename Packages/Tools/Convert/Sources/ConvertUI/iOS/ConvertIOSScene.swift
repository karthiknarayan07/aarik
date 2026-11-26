#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI
    import UniformTypeIdentifiers

    /// The video tool as the iOS shell hosts it: adaptive `NavigationSplitView` across iPhone, iPad and Duo,
    /// adaptive inspector, toolbar, sheets and input hand-off (ADR 0006).
    @MainActor
    @Observable
    public final class ConvertIOSScene: IOSToolScene {
        private let model: ConvertModel
        public var columnVisibility = NavigationSplitViewVisibility.automatic
        public var isSettingsPresented = false
        /// On compact widths (iPhone, folded Duo) the inspector opens on demand as a sheet rather than popping up empty.
        public var isCompactInspectorPresented = false

        public init(model: ConvertModel) {
            self.model = model
        }

        public var tool: any Tool { model.tool }

        public var selection: VideoPage? {
            get { model.selection }
            set { model.selection = newValue }
        }

        public func hasInspector(for destination: VideoPage?) -> Bool {
            destination?.showsLibrary == true || destination == .photosVideos
        }

        @ViewBuilder public func root() -> some View {
            IOSRootView(scene: self, model: model)
        }

        @ViewBuilder public func detail(for destination: VideoPage?) -> some View {
            IOSVideoDetail(model: model, destination: destination)
        }

        @ToolbarContentBuilder public func toolbar(for destination: VideoPage?) -> some ToolbarContent {
            let model = model
            if hasInspector(for: destination) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.requestAddSelectionToQueue()
                    } label: {
                        Label(model.toolbarAddToQueueTitle, systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canAddSelectionToQueue)
                    .accessibilityLabel(model.toolbarAddToQueueTitle)
                }
                ToolbarItem(placement: .primaryAction) {
                    IOSInspectorToggle(scene: self, model: model)
                }
            }
        }

        public var sheets: VideoIOSSheets {
            VideoIOSSheets(scene: self, model: model)
        }

        public func receive(_ inputs: [MediaInput]) {
            let files = inputs.compactMap { input -> URL? in
                if case .file(let url) = input { return url }
                return nil
            }
            if !files.isEmpty {
                model.addFiles(files)
            } else if inputs.contains(where: {
                if case .photosAsset = $0 { return true }
                return false
            }) {
                model.selection = .photosVideos
            }
        }
    }

    private struct IOSRootView: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        private var isCompact: Bool { horizontalSizeClass == .compact }

        private var inspectorShown: Binding<Bool> {
            Binding {
                guard scene.hasInspector(for: model.selection) else { return false }
                return isCompact ? scene.isCompactInspectorPresented : model.isInspectorPresented
            } set: { isPresented in
                guard scene.hasInspector(for: model.selection) else { return }
                if isCompact {
                    scene.isCompactInspectorPresented = isPresented
                } else {
                    model.isInspectorPresented = isPresented
                }
            }
        }

        var body: some View {
            NavigationSplitView(columnVisibility: $scene.columnVisibility) {
                IOSSidebarView(model: model, isSettingsPresented: $scene.isSettingsPresented)
            } detail: {
                scene.detail(for: model.selection)
                    .inspector(isPresented: inspectorShown) {
                        IOSLibraryInspector(
                            model: model,
                            isCompact: isCompact,
                            dismiss: {
                                if isCompact {
                                    scene.isCompactInspectorPresented = false
                                } else {
                                    model.isInspectorPresented = false
                                }
                            }
                        )
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                    }
                    .toolbar { scene.toolbar(for: model.selection) }
            }
            .modifier(scene.sheets)
        }
    }

    private struct IOSVideoDetail: View {
        @Bindable var model: ConvertModel
        let destination: VideoPage?

        var body: some View {
            Group {
                switch destination {
                case .localFiles, .mediaType: IOSLocalFilesView(model: model)
                case .photosVideos: IOSPhotosView(model: model)
                case .queue: IOSQueueView(model: model)
                case .completed: IOSCompletedView(model: model)
                case .keptAsIs: IOSKeptAsIsView(model: model)
                case .failed: IOSFailedView(model: model)
                case .overview: IOSOverviewView(model: model)
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

    private struct IOSInspectorToggle: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        private var isCompact: Bool { horizontalSizeClass == .compact }

        private var isPresented: Bool {
            isCompact ? scene.isCompactInspectorPresented : model.isInspectorPresented
        }

        var body: some View {
            Button {
                if isCompact {
                    scene.isCompactInspectorPresented.toggle()
                } else {
                    model.isInspectorPresented.toggle()
                }
            } label: {
                Label(
                    isCompact ? "Options…" : "Inspector",
                    systemImage: isCompact ? "slider.horizontal.3" : "sidebar.trailing")
            }
            .accessibilityLabel(isPresented ? "Hide Inspector" : "Show Inspector")
        }
    }

    /// The iOS scene's importers, sheets and alerts, kept around the whole root so posture or size-class changes
    /// never dismiss them.
    public struct VideoIOSSheets: ViewModifier {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel

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
                .alert("Replace the Original?", isPresented: $model.isConfirmingReplace) {
                    Button("Cancel", role: .cancel) {}
                    Button("Replace") { model.confirmReplace() }
                } message: {
                    Text(
                        "The smaller copy is saved to Photos and verified first. Then Photos asks you to move the "
                            + "originals to Recently Deleted.")
                }
                .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { _ in
                    Button("OK") {}
                } message: { alert in
                    Text(alert.message)
                }
                .sheet(isPresented: lossReviewShown) {
                    if let review = model.lossReview {
                        IOSLossConfirmationSheet(
                            review: Binding {
                                model.lossReview ?? review
                            } set: {
                                model.lossReview = $0
                            },
                            cancel: model.cancelLossReview, convert: model.confirmLossReview)
                    }
                }
                .sheet(isPresented: $scene.isSettingsPresented) {
                    IOSSettingsView(model: model)
                }
        }
    }
#endif
