#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import struct LocalLibrary.LibraryItem
    import SwiftUI

    /// The video tool's floating tab bar: Overview, Library (Photos and Files), Queue (with Completed) and Search. It
    /// folds into a small bar while a list scrolls, and a bottom accessory shows the job that is converting. The tabs
    /// are the scene's, so they survive a relaunch (`SceneStorage`) and an Overview card or an intent can switch them.
    struct IOSConvertTabs: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel
        @SceneStorage("convert.tab") private var storedTab = ""
        @State private var hasRestored = false

        var body: some View {
            TabView(selection: $scene.tab) {
                Tab("Overview", systemImage: "chart.pie.fill", value: ConvertIOSScene.Tab.overview) {
                    IOSTabStack(scene: scene) {
                        IOSOverviewView(model: model)
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
                Tab("Library", systemImage: "photo.stack.fill", value: ConvertIOSScene.Tab.library) {
                    IOSTabStack(scene: scene) {
                        IOSLibraryTab(scene: scene, model: model)
                    }
                }
                Tab("Queue", systemImage: "list.bullet", value: ConvertIOSScene.Tab.queue) {
                    IOSTabStack(scene: scene) {
                        IOSActivityTab(scene: scene, model: model)
                    }
                }
                .badge(model.activity.queue)
                Tab(value: ConvertIOSScene.Tab.search, role: .search) {
                    IOSTabStack(scene: scene) {
                        IOSSearchTab(scene: scene, model: model)
                    }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(IOSJobAccessoryModifier(model: model) { scene.tab = .queue })
            .sensoryFeedback(.success, trigger: model.activity.completed)
            .sensoryFeedback(trigger: model.queuePause.automatic) { old, new in
                new != nil && old != new ? .warning : nil
            }
            .task { restore() }
            .onChange(of: scene.tab) {
                storedTab = scene.tab.rawValue
                scene.publish(to: model)
            }
            .onChange(of: scene.library) { scene.publish(to: model) }
            .onChange(of: scene.activity) { scene.publish(to: model) }
            .onChange(of: model.selection) { scene.follow(model.selection) }
        }

        private func restore() {
            guard !hasRestored else { return }
            hasRestored = true
            if let tab = ConvertIOSScene.Tab(rawValue: storedTab), tab != scene.tab { scene.tab = tab }
            scene.publish(to: model)
        }
    }

    /// The accessory over the tab bar, shown only while something is queued (the on and off switch is iOS 26.1).
    private struct IOSJobAccessoryModifier: ViewModifier {
        let model: ConvertModel
        let open: () -> Void

        func body(content: Content) -> some View {
            if #available(iOS 26.1, *) {
                content.tabViewBottomAccessory(isEnabled: model.activity.queue > 0) {
                    IOSJobAccessory(model: model, open: open)
                }
            } else {
                content.tabViewBottomAccessory {
                    IOSJobAccessory(model: model, open: open)
                }
            }
        }
    }

    /// A tab's own navigation stack, with the way back to the Tools list at its leading edge.
    private struct IOSTabStack<Content: View>: View {
        let scene: ConvertIOSScene
        @ViewBuilder let content: () -> Content
        @Environment(\.toolExit) private var exit

        var body: some View {
            NavigationStack {
                content()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                exit()
                            } label: {
                                Label("Tools", systemImage: "chevron.backward")
                            }
                            .accessibilityIdentifier("tools.back")
                        }
                    }
            }
        }
    }

    /// Photos and Files, one segment each, under the tab's bar.
    private struct IOSLibraryTab: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel

        var body: some View {
            Group {
                if scene.library == .files {
                    IOSLocalFilesView(model: model, incoming: $scene.pendingOpen)
                } else {
                    IOSPhotosView(model: model, incoming: $scene.pendingOpen)
                }
            }
            .safeAreaBar(edge: .top) {
                IOSSegments(selection: $scene.library, pages: [.photos, .files], identifier: "library.segments")
            }
        }
    }

    /// Queue and Completed, one segment each.
    private struct IOSActivityTab: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel

        var body: some View {
            Group {
                if scene.activity == .completed {
                    IOSCompletedView(model: model)
                } else {
                    IOSQueueView(model: model)
                }
            }
            .safeAreaBar(edge: .top) {
                IOSSegments(
                    selection: $scene.activity, pages: [.queue, .completed], identifier: "activity.segments")
            }
        }
    }

    private struct IOSSegments: View {
        @Binding var selection: IOSPage
        let pages: [IOSPage]
        let identifier: String

        var body: some View {
            Picker("Show", selection: $selection) {
                ForEach(pages, id: \.self) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .accessibilityIdentifier(identifier)
        }
    }

    /// The tab bar's accessory: the job converting now with its progress, or why the queue waits. Tapping opens the queue.
    private struct IOSJobAccessory: View {
        let model: ConvertModel
        let open: () -> Void
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        private var running: Job? {
            model.queuedJobs.first {
                if case .running = $0.state { return true }
                return false
            }
        }

        private var progress: Double? {
            if let running, case .running(let value) = running.state { return value }
            return nil
        }

        private var title: String { running?.displayName ?? "Queue" }

        private var detail: String {
            if let pause = model.queuePause.statusText { return pause }
            if let progress { return "\(running?.phase ?? "Converting") · \(Int((progress * 100).rounded()))%" }
            let count = model.activity.queue
            return count == 1 ? "1 video waiting" : "\(count) videos waiting"
        }

        var body: some View {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: model.queuePause.isPaused ? "pause.circle.fill" : "clock.fill")
                            .foregroundStyle(model.queuePause.isPaused ? .orange : .secondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if placement != .inline {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(detail)")
            .accessibilityHint("Opens the queue")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("jobAccessory")
        }
    }

    /// Search across the videos in Photos and in Files by name; a result opens on its Library page.
    private struct IOSSearchTab: View {
        @Bindable var scene: ConvertIOSScene
        let model: ConvertModel
        @State private var text = ""

        private func matches(_ items: [LibraryItem]) -> [LibraryItem] {
            guard !text.isEmpty else { return [] }
            return items.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(100).map { $0 }
        }

        var body: some View {
            let photos = matches(model.photos.items)
            let files = matches(model.library.items)
            List {
                if !photos.isEmpty {
                    Section("Photos") {
                        ForEach(photos) { row($0, page: .photos) }
                    }
                }
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { row($0, page: .files) }
                    }
                }
            }
            .overlay {
                if text.isEmpty {
                    ContentUnavailableView(
                        "Search Your Videos", systemImage: "magnifyingglass",
                        description: Text("Find a video by name in Photos or Files."))
                } else if photos.isEmpty && files.isEmpty {
                    ContentUnavailableView.search(text: text)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "Videos in Photos and Files")
            .task { await model.photos.start() }
        }

        private func row(_ item: LibraryItem, page: IOSPage) -> some View {
            Button {
                scene.library = page
                let browser = page == .photos ? model.photosBrowser : model.browser
                browser.selection = [item.id]
                scene.pendingOpen = item.id
                scene.tab = .library
            } label: {
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.string(item.byteSize)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
        }
    }

    /// The bar over a grid while selecting: "Convert 3 Videos · Save 1.2 GB".
    struct IOSSelectionBar: View {
        let model: ConvertModel
        let count: Int
        @Binding var isSelecting: Bool
        let clear: () -> Void

        var body: some View {
            if isSelecting && count > 0 {
                Button {
                    model.requestAddSelectionToQueue()
                    // A conversion that would lose metadata asks first and keeps the selection it asks about.
                    if model.lossReview == nil {
                        clear()
                        isSelecting = false
                    }
                } label: {
                    Text(
                        QueueButtonTitle.selectionTitle(
                            count: count,
                            saved: model.couldFreeSelected > 0 ? ByteFormat.string(model.couldFreeSelected) : nil)
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!model.canAddSelectionToQueue)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("convertSelection")
            }
        }
    }
#endif
