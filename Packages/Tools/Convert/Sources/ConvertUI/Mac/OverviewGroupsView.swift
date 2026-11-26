#if os(macOS)
    import AppCore
    import AppUI
    import Assistant
    import Convert
    import PhotosLibrary
    import SwiftUI

    /// A titled group: a headline over a grouped box, as in System Settings.
    struct OverviewGroup<Content: View>: View {
        let title: String
        var systemImage: String?
        @ViewBuilder let content: Content

        var body: some View {
            GroupBox {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Group {
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                    } else {
                        Text(title)
                    }
                }
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// Shared description and optional action for Photos permission states shown on Home.
    private struct PhotosPermissionPrompt {
        let message: String
        let buttonTitle: String?
        let action: (() -> Void)?

        @MainActor
        static func make(model: ConvertModel, emptyMessage: String) -> PhotosPermissionPrompt? {
            guard model.photos.isAuthorizationKnown else { return nil }
            switch model.photos.authorization {
            case .notDetermined:
                return PhotosPermissionPrompt(
                    message: "Include the videos in your Photos library.",
                    buttonTitle: "Allow Access to Photos…",
                    action: { model.allowPhotos() })
            case .denied:
                return PhotosPermissionPrompt(
                    message: emptyMessage,
                    buttonTitle: "Open System Settings…",
                    action: { PrivacySettings.open(PrivacySettings.photos) })
            case .restricted:
                return PhotosPermissionPrompt(
                    message: "Access to Photos is restricted on this Mac, so its videos can't be included.",
                    buttonTitle: nil,
                    action: nil)
            case .authorized, .limited:
                return nil
            }
        }
    }

    /// Where the videos come from: the Photos access prompt (or its state) and Local Files, as two compact rows
    /// under the charts. The totals themselves are in the cards above.
    struct SourcesGroup: View {
        let model: ConvertModel
        let summary: OverviewSummary

        var body: some View {
            OverviewGroup(title: "Sources", systemImage: "externaldrive") {
                VStack(alignment: .leading) {
                    photosRow
                    Divider()
                    localFilesRow
                }
            }
        }

        @ViewBuilder private var photosRow: some View {
            if !model.photos.isAuthorizationKnown {
                LabeledContent {
                    ProgressView()
                        .controlSize(.small)
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .accessibilityLabel("Checking access to Photos")
            } else if let prompt = PhotosPermissionPrompt.make(
                model: model, emptyMessage: "Access to Photos is off, so its videos aren't included.")
            {
                LabeledContent {
                    if let buttonTitle = prompt.buttonTitle, let action = prompt.action {
                        Button(buttonTitle, action: action)
                            .accessibilityHint(
                                model.photos.authorization == .notDetermined
                                    ? "Shows the system prompt to allow access to your Photos library" : "")
                    }
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                    Text(prompt.message)
                }
            } else {
                LabeledContent {
                    Text(Self.detail(summary.videos))
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
            }
        }

        @ViewBuilder private var localFilesRow: some View {
            if summary.localFiles.count == 0 {
                LabeledContent {
                    Button("Add Local Files…") {
                        model.selection = .localFiles
                        model.isImporterPresented = true
                    }
                } label: {
                    Label("Local Files", systemImage: "folder")
                    Text("Add videos or folders from this Mac.")
                }
            } else {
                LabeledContent {
                    Text(Self.detail(summary.localFiles))
                } label: {
                    Label("Local Files", systemImage: "folder")
                }
            }
        }

        private static func detail(_ totals: OverviewSummary.Totals) -> String {
            let videos = totals.count == 1 ? "1 video" : "\(totals.count.formatted()) videos"
            return "\(videos) · \(ByteFormat.string(totals.bytes))"
        }
    }

    // MARK: - Smart picks

    /// Where to start: with the on-device model, up to three groups of videos worth shrinking first, each with a
    /// reason, Show and Add These to the Queue. Without it (unavailable, or no usable answer) the same place lists the
    /// biggest groups as plain rows, with no mention of the model.
    struct SmartPicksGroup: View {
        let model: ConvertModel

        private var store: SmartPicksStore { model.assistant.smartPicks }

        var body: some View {
            if !store.buckets.isEmpty {
                if case .picks(let picks) = store.state {
                    OverviewGroup(title: "Smart Picks", systemImage: "sparkles") {
                        VStack(alignment: .leading) {
                            ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                                if index > 0 { Divider() }
                                SmartPickRow(
                                    pick: pick, canAdd: model.canAddToQueue(pick.bucket),
                                    show: { model.show(pick.bucket) }, add: { model.addToQueue(pick.bucket) })
                            }
                            Text("Suggested on this Mac. Nothing is added until you choose.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            UndatedNote(count: store.undatedCount)
                        }
                    }
                } else if store.isShowingPicks, store.state == .loading {
                    OverviewGroup(title: "Smart Picks", systemImage: "sparkles") {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding where to start…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    OverviewGroup(title: "Biggest Groups") {
                        VStack(alignment: .leading) {
                            ForEach(Array(store.buckets.prefix(Self.listedGroups).enumerated()), id: \.element.identity)
                            {
                                index, bucket in
                                if index > 0 { Divider() }
                                BiggestGroupRow(bucket: bucket) { model.show(bucket) }
                            }
                            UndatedNote(count: store.undatedCount)
                        }
                    }
                }
            }
        }

        private static let listedGroups = 5
    }

    /// Videos left out of every group for want of a capture date; nothing when there are none.
    private struct UndatedNote: View {
        let count: Int

        var body: some View {
            if count > 0 {
                Text(
                    count == 1
                        ? "1 video without a capture date isn't in any group."
                        : "\(count.formatted()) videos without a capture date aren't in any group."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private struct SmartPickRow: View {
        let pick: SmartPick
        let canAdd: Bool
        let show: () -> Void
        let add: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(pick.title)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(pick.why)
                    .foregroundStyle(.secondary)
                Text(pick.bucket.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Show", action: show)
                        .help("Show these videos in \(pick.bucket.sourceName)")
                        .accessibilityLabel("Show \(pick.bucket.title)")
                        .accessibilityHint("Opens \(pick.bucket.sourceName) with filters for these videos")
                    Button("Add These to the Queue…", action: add)
                        .disabled(!canAdd)
                        .help(
                            canAdd
                                ? "Select these videos and add them to the queue" : "Choose where to save copies first"
                        )
                        .accessibilityLabel("Add \(pick.bucket.title) to the queue")
                        .accessibilityHint("Selects these videos and adds them to the queue after the usual checks")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(pick.title). \(pick.why). \(pick.bucket.detail)")
        }
    }

    private struct BiggestGroupRow: View {
        let bucket: SavingsBucket
        let show: () -> Void

        var body: some View {
            HStack {
                VStack(alignment: .leading) {
                    Text(bucket.title)
                    Text(bucket.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show", action: show)
                    .help("Show these videos in \(bucket.sourceName)")
                    .accessibilityLabel("Show \(bucket.title)")
                    .accessibilityHint("Opens \(bucket.sourceName) with filters for these videos")
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Empty state

    /// Nothing to total yet: a grouped form in the style of System Settings, with a row for each place to start from
    /// and what is promised underneath.
    struct OverviewEmptyState: View {
        let model: ConvertModel

        var body: some View {
            let photosPrompt = PhotosPermissionPrompt.make(
                model: model, emptyMessage: "Access to Photos is off, so its videos aren't included.")
            Form {
                Section {
                    if let photosPrompt {
                        LabeledContent {
                            if let buttonTitle = photosPrompt.buttonTitle, let action = photosPrompt.action {
                                Button(buttonTitle, action: action)
                            }
                        } label: {
                            Label("Photos", systemImage: "photo.on.rectangle")
                            Text(photosPrompt.message)
                        }
                    }
                    LabeledContent {
                        Button("Add Local Files…") {
                            model.selection = .localFiles
                            model.isImporterPresented = true
                        }
                    } label: {
                        Label("Local Files", systemImage: "folder")
                        Text("Choose videos or folders on this Mac.")
                    }
                } header: {
                    Text("Choose Where to Look")
                } footer: {
                    Text(
                        "\(AppInfo.displayName) shows how much space your videos take and keeps smaller copies that "
                            + "look the same. Nothing changes until you add videos to the queue, copies keep the date, "
                            + "location and camera details, and an original is only replaced when you choose it.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
#endif
