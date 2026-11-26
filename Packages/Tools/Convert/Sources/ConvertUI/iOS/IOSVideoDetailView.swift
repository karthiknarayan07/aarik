#if os(iOS)
    import AppUI
    import Convert
    import SwiftUI

    /// What a tap on a grid tile opens: the video's own page, reached with a zoom from its tile. It shows the details
    /// and the conversion options for that one video, the same form the inspector shows for a selection.
    struct IOSVideoDetailView: View {
        @Bindable var model: ConvertModel
        let id: UUID

        private var name: String {
            model.photos.items.first { $0.id == id }?.name ?? model.library.items.first { $0.id == id }?.name ?? "Video"
        }

        var body: some View {
            IOSLibraryInspector(model: model, isCompact: false, dismiss: {})
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.requestAddSelectionToQueue()
                        } label: {
                            Label(model.toolbarAddToQueueTitle, systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.canAddSelectionToQueue)
                        .accessibilityIdentifier("detail.addToQueue")
                    }
                }
                .sensoryFeedback(.success, trigger: model.activity.queue)
                .accessibilityIdentifier("videoDetail")
        }
    }
#endif
