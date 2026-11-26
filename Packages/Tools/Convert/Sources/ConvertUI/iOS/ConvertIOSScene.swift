#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI
    import UniformTypeIdentifiers

    /// The video tool as the iOS shell hosts it (ADR 0006): the tool owns its pages (Overview, Photos, Files, Queue,
    /// Completed) and the detail of each. The shell lists the tools and hosts the columns, so the same scene serves
    /// a stack on iPhone and a folded Duo and three columns on iPad and an open Duo.
    @MainActor
    @Observable
    public final class ConvertIOSScene: IOSToolScene {
        private let model: ConvertModel
        private let stats: any SavingsStatsSource = InMemorySavingsStats()
        public var isSettingsPresented = false
        /// Whether a page was tapped in the page list; only a collapsed stack needs it (see `IOSPagesView`).
        var hasOpenedPage = false
        /// On compact widths (iPhone, folded Duo) the inspector opens on demand as a sheet rather than popping up empty.
        public var isCompactInspectorPresented = false

        public init(model: ConvertModel) {
            self.model = model
            // The model starts on Local Files, which is the Mac's first page; iOS starts on Overview.
            model.selection = .overview
        }

        public var tool: any Tool { model.tool }

        public var selection: IOSPage? {
            get { IOSPage(model.selection) }
            set {
                // A pop in a collapsed stack clears the list's selection; the page itself stays where it was.
                guard let newValue else { return }
                if IOSPage(model.selection) != newValue { model.selection = newValue.videoPage }
            }
        }

        public func hasInspector(for destination: IOSPage?) -> Bool {
            destination == .files || destination == .photos
        }

        @ViewBuilder public func pages() -> some View {
            let model = model
            ForegroundObserver(model: model) {
                IOSPagesView(scene: self, model: model)
            }
        }

        @ViewBuilder public func detail(for destination: IOSPage?) -> some View {
            IOSVideoDetail(scene: self, model: model, stats: stats, destination: destination)
        }

        @ToolbarContentBuilder public func toolbar(for destination: IOSPage?) -> some ToolbarContent {
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
                    .accessibilityIdentifier("addToQueue")
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

    /// The detail column's content for a page, with the inspector, which is a sheet on compact widths.
    private struct IOSVideoDetail: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel
        let stats: any SavingsStatsSource
        let destination: IOSPage?
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        private var isCompact: Bool { horizontalSizeClass == .compact }

        private var inspectorShown: Binding<Bool> {
            Binding {
                guard scene.hasInspector(for: destination) else { return false }
                return isCompact ? scene.isCompactInspectorPresented : model.isInspectorPresented
            } set: { isPresented in
                guard scene.hasInspector(for: destination) else { return }
                if isCompact {
                    scene.isCompactInspectorPresented = isPresented
                } else {
                    model.isInspectorPresented = isPresented
                }
            }
        }

        private var inspector: some View {
            IOSLibraryInspector(
                model: model, isCompact: isCompact,
                dismiss: {
                    if isCompact {
                        scene.isCompactInspectorPresented = false
                    } else {
                        model.isInspectorPresented = false
                    }
                })
        }

        var body: some View {
            let content =
                page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .bottom) {
                    IOSPendingDeletionBar(model: model)
                }
            // A sheet with detents on compact widths, a trailing column on regular ones.
            if isCompact {
                content.sheet(isPresented: inspectorShown) {
                    inspector.presentationDetents([.medium, .large])
                }
            } else {
                content.inspector(isPresented: inspectorShown) {
                    inspector.inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                }
            }
        }

        @ViewBuilder private var page: some View {
            switch destination {
            case .overview: IOSOverviewView(model: model, stats: stats)
            case .photos: IOSPhotosView(model: model)
            case .files: IOSLocalFilesView(model: model)
            case .queue: IOSQueueView(model: model)
            case .completed: IOSCompletedView(model: model)
            case nil:
                ContentUnavailableView(
                    "Choose a Page", systemImage: "sidebar.left",
                    description: Text("Pick Overview, Photos, Files, Queue or Completed."))
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
            .accessibilityIdentifier("inspectorToggle")
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
                        .presentationDetents([.medium, .large])
                }
        }
    }

    private struct ForegroundObserver<Content: View>: View {
        let model: ConvertModel
        @ViewBuilder let content: () -> Content
        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            content()
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.isForeground = (phase == .active)
                }
        }
    }
#endif
