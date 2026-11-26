#if os(iOS)
    import AppUI
    import Convert
    import SwiftUI

    /// The foreground-only iOS bottom bar that shows originals waiting to move to Recently Deleted and asks Photos to
    /// move them in one confirmed batch. Never shown or triggered while the app is out of the foreground.
    public struct IOSPendingDeletionBar: View {
        let model: ConvertModel
        @Environment(\.scenePhase) private var scenePhase

        public init(model: ConvertModel) {
            self.model = model
        }

        public var body: some View {
            Group {
                if scenePhase == .active, let content = model.pendingDeletionBar {
                    IOSPendingDeletionBarContent(
                        content: content,
                        perform: model.performPendingDeletionAction,
                        removeKept: model.removeKeptOriginalsFromList,
                        openSettings: model.openPhotosAccessSettings)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.isForeground = (phase == .active)
            }
        }
    }

    /// Layout for `IOSPendingDeletionBar`, separated from `ConvertModel` so previews and tests can exercise every state.
    struct IOSPendingDeletionBarContent: View {
        let content: PendingDeletionBarContent
        let perform: () -> Void
        var removeKept: () -> Void = {}
        var openSettings: () -> Void = {}

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.title)
                            .font(.headline)
                        if !content.detail.isEmpty {
                            Text(content.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    if content.isWorking {
                        ProgressView()
                            .accessibilityLabel("Waiting for Photos")
                    }
                }
                if content.offersSettings || content.offersRemove {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { secondaryButtons }
                        VStack(alignment: .leading, spacing: 8) { secondaryButtons }
                    }
                }
                if let title = content.countedActionTitle {
                    Button(role: content.isDestructiveAction ? .destructive : nil, action: perform) {
                        Text(title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(
                        content.isDestructiveAction ? "Photos asks you to confirm before anything is moved" : "")
                }
            }
            .padding()
        }

        @ViewBuilder private var secondaryButtons: some View {
            if content.offersSettings {
                Button("Open Settings…", action: openSettings)
                    .buttonStyle(.bordered)
            }
            if content.offersRemove {
                Button(PendingDeletionBarContent.removeTitle, action: removeKept)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Takes the kept originals off this list. Nothing is deleted.")
            }
        }
    }

    #Preview("Ready (Multiple)") {
        IOSPendingDeletionBarContent(content: PendingDeletionBarContent(count: 12, status: .ready), perform: {})
    }

    #Preview("Ready (Single)") {
        IOSPendingDeletionBarContent(content: PendingDeletionBarContent(count: 1, status: .ready), perform: {})
    }
#endif
