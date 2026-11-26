#if os(iOS)
    import AppCore
    import Convert
    import SwiftUI

    /// The video tool's pages: the list the Tools list opens. A grouped list like Settings and Fitness, with counts
    /// as badges and the running queue's progress on its own row. Selection is the scene's, so it survives size-class
    /// and posture changes.
    struct IOSPagesView: View {
        @Bindable var scene: ConvertIOSScene
        @Bindable var model: ConvertModel

        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        /// In a collapsed stack nothing is selected until a row is tapped (a selection would push the detail at once),
        /// and popping clears it; the page itself stays. Side by side, the page is always selected.
        private var selection: Binding<IOSPage?> {
            let isCompact = horizontalSizeClass == .compact
            return Binding {
                isCompact && !scene.hasOpenedPage ? nil : scene.selection
            } set: { newValue in
                if let newValue {
                    scene.selection = newValue
                    scene.hasOpenedPage = true
                } else if isCompact {
                    scene.hasOpenedPage = false
                }
            }
        }

        var body: some View {
            List(selection: selection) {
                IOSPageRow(page: .overview, model: model)
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
            NavigationLink(value: page) {
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
                    model.isQueuePaused ? "Resume Queue" : "Pause Queue",
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
#endif
