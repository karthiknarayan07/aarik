#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI
    import UniformTypeIdentifiers

    /// The video tool as the iOS shell hosts it (ADR 0006): the tool owns its tab bar (Overview, Library, Queue and
    /// Search) and everything inside it. The shell lists the tools and pushes `root()`.
    @MainActor
    @Observable
    public final class ConvertIOSScene: IOSToolScene {
        private let model: ConvertModel
        public var isSettingsPresented = false

        /// The tabs of the tool's floating tab bar.
        public enum Tab: String, Hashable, Sendable {
            case overview, library, queue, search
        }

        public var tab = Tab.overview
        /// Which list the Library tab shows (Photos or Files) and which the Queue tab shows (Queue or Completed).
        var library = IOSPage.photos
        var activity = IOSPage.queue
        /// A video the Search tab asked the Library tab to open.
        var pendingOpen: UUID?

        public init(model: ConvertModel) {
            self.model = model
            // The model starts on Local Files, which is the Mac's first page; iOS starts on Overview.
            model.selection = .overview
        }

        public var tool: any Tool { model.tool }

        /// The page the tab bar shows, or nil on Search.
        var currentPage: IOSPage? {
            switch tab {
            case .overview: .overview
            case .library: library
            case .queue: activity
            case .search: nil
            }
        }

        /// Follows a change the model made (an Overview card opening a page, an intent).
        func follow(_ selection: VideoPage?) {
            guard let page = IOSPage(selection), page != currentPage else { return }
            switch page {
            case .overview:
                tab = .overview
            case .photos, .files:
                library = page
                tab = .library
            case .queue, .completed:
                activity = page
                tab = .queue
            }
        }

        /// Tells the model which page the tabs show, so its selection and queueing follow what's on screen.
        func publish(to model: ConvertModel) {
            guard let page = currentPage, IOSPage(model.selection) != page else { return }
            model.selection = page.videoPage
        }

        @ViewBuilder public func root() -> some View {
            let model = model
            ForegroundObserver(model: model) {
                IOSConvertTabs(scene: self, model: model)
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

    /// The iOS scene's importers, sheets and alerts, kept around the whole root so a tab change never dismisses them.
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
