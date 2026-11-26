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
            Text(model.tool.title)
        }

        @ViewBuilder public func detail(for destination: VideoPage?) -> some View {
            Text(destination?.title ?? model.tool.title)
        }

        @ToolbarContentBuilder public func toolbar(for destination: VideoPage?) -> some ToolbarContent {
            ToolbarItemGroup {}
        }
    }
#endif
