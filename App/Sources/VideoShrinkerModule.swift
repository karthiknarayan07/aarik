import AppCore
import AppUI
import DownscaleVideo
import SwiftUI

/// The video tool as the shell hosts it: today's sidebar sections, pages, toolbar and inspector.
@MainActor
final class VideoShrinkerModule: ToolModule {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var id: String { DownscaleTool.descriptor.id }
    var title: String { DownscaleTool.descriptor.name }
    var systemImage: String { DownscaleTool.descriptor.symbol }

    var selection: VideoPage? {
        get { model.selection }
        set { model.selection = newValue }
    }

    var sidebar: [ToolSidebarSection<VideoPage>] {
        VideoSidebar.sections(
            VideoSidebarState(
                photosCount: model.photos.hasLoaded ? model.photos.items.count : nil,
                localCount: model.library.items.count, badgeCounts: model.library.badgeCounts,
                activity: model.activity))
    }

    @ViewBuilder func detail(for destination: VideoPage?) -> some View {
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
            EmptyState("Nothing selected", systemImage: "sidebar.left", message: "Choose a section in the sidebar.")
                .navigationTitle(AppModel.displayName)
        }
    }

    @ToolbarContentBuilder func toolbar(for destination: VideoPage?) -> some ToolbarContent {
        if hasInspector(for: destination) {
            // The inspector button is its own group, apart from the page's own buttons.
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
}

private struct InspectorToggle: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(isPresented ? "Hide inspector" : "Show inspector")
        .accessibilityLabel(isPresented ? "Hide inspector" : "Show inspector")
    }
}
