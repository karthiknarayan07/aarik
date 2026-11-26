#if os(iOS)
    import AppCore
    import Convert
    import SwiftUI

    /// The adaptive sidebar for iOS: renders `VideoSidebar` sections with `NavigationLink(value:)` so it works as
    /// a push list in compact width (iPhone, folded Duo) and a split-view sidebar in regular width (iPad, unfolded Duo).
    struct IOSSidebarView: View {
        @Bindable var model: ConvertModel
        @Binding var isSettingsPresented: Bool

        private var sidebar: ToolSidebarModel<VideoPage> {
            ToolSidebarModel(
                VideoSidebar.sections(
                    VideoSidebarState(
                        photosCount: model.photos.hasLoaded ? model.photos.items.count : nil,
                        localCount: model.library.items.count, badgeCounts: model.library.badgeCounts,
                        activity: model.activity)))
        }

        private var selection: Binding<VideoPage?> {
            Binding {
                model.selection
            } set: { newValue in
                if sidebar.accepts(newValue) { model.selection = newValue }
            }
        }

        var body: some View {
            List(selection: selection) {
                ForEach(sidebar.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            IOSSidebarRow(model: model, row: row)
                        }
                    }
                }
            }
            .navigationTitle(AppInfo.displayName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                }
            }
        }
    }

    private struct IOSSidebarRow: View {
        let model: ConvertModel
        let row: ToolSidebarModel<VideoPage>.Row

        var body: some View {
            if row.isSelectable, let destination = row.item.destination {
                available(destination)
            } else {
                unavailable
            }
        }

        private func available(_ destination: VideoPage) -> some View {
            let item = row.item
            return NavigationLink(value: destination) {
                HStack {
                    Label(item.title, systemImage: item.systemImage)
                    if let progress = item.progress {
                        Spacer()
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                    }
                }
            }
            .badge(item.count ?? 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityValue(item.accessibilityValue)
            .contextMenu { contextMenu(for: destination) }
        }

        @ViewBuilder private func contextMenu(for destination: VideoPage) -> some View {
            switch destination {
            case .localFiles:
                Button("Add Files…", systemImage: "plus") { model.perform(.addVideos) }
            case .queue:
                Button(model.isQueuePaused ? "Resume Queue" : "Pause Queue") {
                    model.perform(.pauseOrResumeQueue)
                }
            case .failed:
                Button("Retry All Failed", systemImage: "arrow.clockwise") {
                    model.perform(.retryAllFailed)
                }
                .disabled(model.activity.failed == 0)
            default:
                EmptyView()
            }
        }

        private var unavailable: some View {
            let item = row.item
            return HStack {
                Label(item.title, systemImage: item.systemImage)
                Spacer()
                Text("Soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .selectionDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityValue(item.accessibilityValue)
        }
    }
#endif
