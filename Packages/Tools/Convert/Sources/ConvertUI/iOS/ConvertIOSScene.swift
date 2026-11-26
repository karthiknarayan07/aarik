#if os(iOS)
    import AppCore
    import Convert
    import SwiftUI

    /// The video tool as the iOS shell hosts it (Task 6 builds its screens).
    @MainActor
    public final class ConvertIOSScene: IOSToolScene {
        private let model: ConvertModel

        public init(model: ConvertModel) {
            self.model = model
        }

        public var tool: any Tool { model.tool }

        public var selection: VideoPage? {
            get { model.selection }
            set { model.selection = newValue }
        }

        @ViewBuilder public func root() -> some View {
            let model = model
            ForegroundObserver(model: model) {
                Text(model.tool.title)
            }
        }

        @ViewBuilder public func detail(for destination: VideoPage?) -> some View {
            let model = model
            Text(destination?.title ?? model.tool.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .bottom) {
                    IOSPendingDeletionBar(model: model)
                }
        }

        @ToolbarContentBuilder public func toolbar(for destination: VideoPage?) -> some ToolbarContent {
            ToolbarItemGroup {}
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
