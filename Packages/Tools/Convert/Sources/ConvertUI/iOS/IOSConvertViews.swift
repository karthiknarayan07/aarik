#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import struct LocalLibrary.LibraryItem
    import SwiftUI

    /// What the Tools tab pushes for Convert: its home (the list of pages) or one page.
    struct IOSConvertDestination: View {
        let scene: ConvertIOSScene
        let model: ConvertModel
        let page: String?

        var body: some View {
            if let page, let video = IOSVideoRoute(page) {
                IOSVideoRouteView(model: model, route: video)
            } else if let page, let iosPage = IOSPage(rawValue: page) {
                content(for: iosPage)
                    // The model queues and filters by the page it is on, so it follows what the stack shows.
                    .onAppear { model.selection = iosPage.videoPage }
            } else {
                IOSConvertHome(scene: scene, model: model)
            }
        }

        @ViewBuilder private func content(for page: IOSPage) -> some View {
            switch page {
            case .photos: IOSPhotosView(model: model)
            case .files: IOSLocalFilesView(model: model)
            case .queue: IOSQueueView(model: model)
            case .completed: IOSCompletedView(model: model)
            case .overview: IOSOverviewView(model: model)
            }
        }
    }

    /// A video's own page, reached from Search: which library it is in and which video.
    struct IOSVideoRoute {
        let id: UUID
        let isPhoto: Bool

        static func page(id: UUID, isPhoto: Bool) -> String { "\(isPhoto ? "photo" : "file")/\(id.uuidString)" }

        init?(_ page: String) {
            let parts = page.split(separator: "/")
            guard parts.count == 2, ["photo", "file"].contains(String(parts[0])),
                let id = UUID(uuidString: String(parts[1]))
            else { return nil }
            self.id = id
            isPhoto = parts[0] == "photo"
        }
    }

    private struct IOSVideoRouteView: View {
        @Bindable var model: ConvertModel
        let route: IOSVideoRoute

        var body: some View {
            IOSVideoDetailView(model: model, id: route.id)
                .onAppear {
                    // "Add to Queue" acts on the selection of the library the video is in.
                    model.selection = route.isPhoto ? .photosVideos : .localFiles
                    (route.isPhoto ? model.photosBrowser : model.browser).selection = [route.id]
                }
        }
    }

    /// Convert's home: the pages in a grouped list, with counts as badges and the running queue's progress on its row.
    struct IOSConvertHome: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel

        var body: some View {
            List {
                Section("Library") {
                    IOSPageRow(page: .photos, model: model)
                    IOSPageRow(page: .files, model: model)
                }
                Section("Activity") {
                    IOSPageRow(page: .queue, model: model)
                    IOSPageRow(page: .completed, model: model)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(scene.tool.title)
            .onAppear { model.selection = .overview }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scene.isSettingsPresented = true
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings")
                }
            }
        }
    }

    private struct IOSPageRow: View {
        let page: IOSPage
        let model: ConvertModel

        private var count: Int? {
            switch page {
            case .overview: nil
            case .photos: model.photos.hasLoaded ? model.photos.items.count : nil
            case .files: model.library.items.count
            case .queue: model.activity.queue
            case .completed: model.activity.completed + model.activity.keptAsIs + model.activity.failed
            }
        }

        private var progress: Double? { page == .queue ? model.activity.runningProgress : nil }

        var body: some View {
            NavigationLink(value: model.route(to: page)) {
                HStack {
                    Label {
                        Text(page.title)
                    } icon: {
                        Image(systemName: page.systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(page.tint)
                            .symbolEffect(.bounce, value: page == .completed ? model.activity.completed : 0)
                    }
                    if let progress {
                        Spacer()
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                }
            }
            .badge(count ?? 0)
            .accessibilityIdentifier("page.\(page.rawValue)")
            .accessibilityLabel(page.title)
            .accessibilityValue(value)
            .contextMenu { menu }
        }

        private var value: String {
            guard let count else { return "" }
            var parts = [count == 1 ? "1 item" : "\(count) items"]
            if page == .queue, let progress { parts.append("\(Int((progress * 100).rounded())) percent done") }
            if page == .completed, model.activity.failed > 0 { parts.append("\(model.activity.failed) failed") }
            return parts.joined(separator: ", ")
        }

        @ViewBuilder private var menu: some View {
            switch page {
            case .files:
                Button("Add Files…", systemImage: "plus") { model.perform(.addVideos) }
            case .queue:
                Button(
                    model.isQueuePaused ? (model.waitsForStart ? "Start Queue" : "Resume Queue") : "Pause Queue",
                    systemImage: model.isQueuePaused ? "play.fill" : "pause.fill"
                ) {
                    model.perform(.pauseOrResumeQueue)
                }
            case .completed:
                Button("Retry All Failed", systemImage: "arrow.clockwise") {
                    model.perform(.retryAllFailed)
                }
                .disabled(model.activity.failed == 0)
            default:
                EmptyView()
            }
        }
    }

    /// Search across the videos in Photos and in Files by name; a result opens the video's page.
    struct IOSSearchResults: View {
        let model: ConvertModel
        let query: String

        private func matches(_ items: [LibraryItem]) -> [LibraryItem] {
            guard !query.isEmpty else { return [] }
            return items.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(100).map { $0 }
        }

        var body: some View {
            let photos = matches(model.photos.items)
            let files = matches(model.library.items)
            List {
                if !photos.isEmpty {
                    Section("Photos") {
                        ForEach(photos) { row($0, isPhoto: true) }
                    }
                }
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { row($0, isPhoto: false) }
                    }
                }
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Search Your Videos", systemImage: "magnifyingglass",
                        description: Text("Find a video by name in Photos or Files."))
                } else if photos.isEmpty && files.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .task { await model.photos.start() }
        }

        private func row(_ item: LibraryItem, isPhoto: Bool) -> some View {
            NavigationLink(
                value: ToolRoute(toolID: model.tool.id, page: IOSVideoRoute.page(id: item.id, isPhoto: isPhoto))
            ) {
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.string(item.byteSize)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
#endif
