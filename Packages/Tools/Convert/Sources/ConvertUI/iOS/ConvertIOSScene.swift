#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI
    import UniformTypeIdentifiers

    /// The video tool as the iOS shell hosts it (ADR 0006): its home and pages are pushed from the Tools tab, its charts
    /// are part of the Summary tab and its results part of Search. The tab bar is the shell's.
    @MainActor
    @Observable
    public final class ConvertIOSScene: IOSToolScene {
        private let model: ConvertModel
        public var isSettingsPresented = false

        public init(model: ConvertModel) {
            self.model = model
            // The model starts on Local Files, which is the Mac's first page; iOS starts on the home.
            model.selection = .overview
        }

        public var tool: any Tool { model.tool }

        @ViewBuilder public func destination(page: String?) -> some View {
            let model = model
            ForegroundObserver(model: model) {
                IOSConvertDestination(scene: self, model: model, page: page)
            }
        }

        @ViewBuilder public func summary() -> some View {
            let model = model
            ForegroundObserver(model: model) {
                IOSOverviewView(model: model)
            }
        }

        @ViewBuilder public func search(query: String) -> some View {
            IOSSearchResults(model: model, query: query)
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
                // Shown in Files, and queued: the run starts only from the Queue's Start.
                model.addFiles(files)
                model.queueHandedOff(files)
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
