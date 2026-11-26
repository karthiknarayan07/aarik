#if os(macOS)
    import AppCore
    import AppUI
    import Assistant
    import Convert
    import LocalLibrary
    import MediaEngine
    import PhotosLibrary
    import SwiftUI

    /// Home on the Mac: the app-level savings summary. How much space the videos take and what converting them could free, where to start, and what has
    /// been saved so far. A vertical stack of titled groups, so another group (suggestions, for instance) can be added
    /// without changing the rest.
    struct OverviewView: View {
        @Bindable var model: ConvertModel
        @State private var summary: OverviewSummary?
        /// The numbers of this session's own read, drawn even if the stored cache is slow or its refresh is cancelled.
        @State private var liveSnapshot: SavingsSnapshot?
        @State private var refreshTick = 0

        /// Everything the summary depends on; when it changes the summary is made again.
        private struct Inputs: Hashable {
            let photosRevision: Int
            let filesRevision: Int
            let preset: Preset
            let overrides: PresetOverrides<UUID>
            let custom: DownscaleSpec?
            let completed: Int
            let saved: Int64
        }

        private var inputs: Inputs {
            Inputs(
                photosRevision: model.photos.revision, filesRevision: model.library.revision, preset: model.preset,
                overrides: model.presetOverrides, custom: model.advanced.spec, completed: model.activity.completed,
                saved: model.activity.savedBytes)
        }

        /// What asks the model again: new groups, or the model becoming available.
        private struct PicksTrigger: Hashable {
            let revision: Int
            let isAvailable: Bool
        }

        private var picksTrigger: PicksTrigger {
            PicksTrigger(revision: model.assistant.smartPicks.revision, isAvailable: model.assistant.isAvailable)
        }

        var body: some View {
            // A container, not a Group: the tasks below belong to this one view. On a Group they attach to each branch,
            // and switching branch (spinner to content) cancelled the refresh that had just drawn the page.
            ZStack {
                if model.photos.items.isEmpty && model.library.items.isEmpty {
                    // Not before Photos has answered, so the welcome doesn't flash ahead of the totals.
                    if model.photos.isAuthorizationKnown
                        && (!model.photos.authorization.allowsReading || model.photos.hasLoaded)
                    {
                        OverviewEmptyState(model: model)
                    } else {
                        ProgressView()
                    }
                } else if summary != nil || cache.snapshot != nil || liveSnapshot != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // The cached numbers draw at once; the live groups below follow when they are read.
                            if let snapshot = cache.snapshot ?? liveSnapshot {
                                OverviewInsights(
                                    charts: OverviewCharts(snapshot: snapshot), presetName: model.preset.displayName,
                                    isRefreshing: cache.isRefreshing)
                            }
                            if let summary {
                                SmartPicksGroup(model: model)
                                SourcesGroup(model: model, summary: summary)
                            } else {
                                ProgressView("Reading your videos…")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxWidth: 900, alignment: .leading)
                        .scenePadding()
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(VideoPage.overview.title)
            // Reads the list of videos when access is already allowed; never shows the access prompt.
            .task { await model.photos.start() }
            .task { await cache.load() }
            // Every few minutes while the page is showing; leaving the page cancels the loop and any refresh.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    guard !Task.isCancelled else { return }
                    refreshTick += 1
                }
            }
            .task(id: RefreshKey(inputs: inputs, tick: refreshTick)) { await refresh() }
            .task(id: picksTrigger) { await model.assistant.smartPicks.generateIfNeeded() }
        }

        private var cache: SavingsStatsCache { model.services.savingsStats }

        /// How often the numbers are made again while the page is open, besides when something changes.
        private static let refreshInterval = Duration.seconds(300)
        /// A burst of changes (a scan, jobs finishing one after another) makes one refresh.
        private static let debounce = Duration.seconds(1)

        private struct RefreshKey: Hashable {
            let inputs: Inputs
            let tick: Int
        }

        private func refresh() async {
            let photos = model.photos.items
            let files = model.library.items
            let finished = model.completedJobs.map { (addedOn: $0.job.createdAt, outcome: $0.outcome) }
            let shrunk = model.shrunkIDs(in: model.browser)
            let preset = model.preset
            let overrides = model.presetOverrides
            let custom = model.advanced.spec
            let key = inputs
            let model = model
            // The first read of the page isn't held back: the live groups wait for it.
            let delay = summary == nil ? Duration.zero : Self.debounce
            await cache.refresh(after: delay) { [finished] in
                let analysis = await Self.analyze(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom,
                    completed: finished.map(\.outcome), shrunk: shrunk)
                await MainActor.run {
                    // Same inputs as last time keep the picks; changed libraries or job outcomes ask again.
                    model.assistant.smartPicks.update(
                        buckets: analysis.buckets, undatedCount: analysis.undated, key: key)
                }
                let snapshot = OverviewCharts.snapshot(
                    summary: analysis.summary, buckets: analysis.buckets, finished: finished)
                await self.show(analysis.summary, snapshot)
                return snapshot
            }
        }

        private func show(_ summary: OverviewSummary, _ snapshot: SavingsSnapshot) {
            self.summary = summary
            liveSnapshot = snapshot
        }

        /// The totals, the groups and the count of undated videos. Estimating a video reads its metadata, so it is
        /// done once for each video and shared by all three, off the main actor.
        @concurrent private static func analyze(
            photos: [VideoItem], files: [VideoItem], preset: Preset, overrides: PresetOverrides<UUID>,
            custom: DownscaleSpec?, completed: [JobOutcome], shrunk: Set<UUID>
        ) async -> (summary: OverviewSummary, buckets: [SavingsBucket], undated: Int) {
            let estimates = OverviewSummary.estimates(
                photos: photos, files: files, preset: preset, overrides: overrides, custom: custom)
            return (
                OverviewSummary(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom,
                    completed: completed, estimates: estimates),
                SavingsAnalyzer.buckets(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom, shrunk: shrunk,
                    estimates: estimates),
                SavingsAnalyzer.undatedCount(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom, shrunk: shrunk,
                    estimates: estimates)
            )
        }
    }

    // MARK: - Groups

    /// A titled group: a headline over a grouped box, as in System Settings.
    private struct OverviewGroup<Content: View>: View {
        /// The accessibility identifier is `home.group.<id>`.
        let id: String
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
            .accessibilityIdentifier("home.group.\(id)")
        }
    }

    /// Where the videos come from: the Photos access prompt (or its state) and Local Files, as two compact rows
    /// under the charts. The totals themselves are in the cards above.
    private struct SourcesGroup: View {
        let model: ConvertModel
        let summary: OverviewSummary

        var body: some View {
            OverviewGroup(id: "sources", title: "Sources", systemImage: "externaldrive") {
                VStack(alignment: .leading) {
                    photosRow
                    Divider()
                    localFilesRow
                }
            }
        }

        @ViewBuilder private var photosRow: some View {
            switch model.photos.isAuthorizationKnown ? model.photos.authorization : nil {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking access to Photos")
            case .authorized, .limited:
                LabeledContent {
                    Text(Self.detail(summary.videos))
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
            case .notDetermined:
                LabeledContent {
                    Button("Allow Access to Photos…") { model.allowPhotos() }
                        .accessibilityHint("Shows the system prompt to allow access to your Photos library")
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                    Text("Include the videos in your Photos library.")
                }
            case .denied, .restricted:
                LabeledContent {
                    Button("Open System Settings…") { PrivacySettings.open(PrivacySettings.photos) }
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                    Text("Access to Photos is off, so its videos aren't included.")
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
    private struct SmartPicksGroup: View {
        let model: ConvertModel

        private var store: SmartPicksStore { model.assistant.smartPicks }

        var body: some View {
            if !store.buckets.isEmpty {
                if store.isShowingPicks {
                    OverviewGroup(id: "smartPicks", title: "Smart Picks", systemImage: "sparkles") {
                        if case .picks(let picks) = store.state {
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
                        } else if store.state == .loading {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Finding where to start…")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } else {
                    OverviewGroup(id: "biggestGroups", title: "Biggest Groups") {
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
    private struct OverviewEmptyState: View {
        let model: ConvertModel

        private var photosRow: (text: String, button: String, action: () -> Void)? {
            guard model.photos.isAuthorizationKnown else { return nil }
            switch model.photos.authorization {
            case .notDetermined:
                return (
                    "Include the videos in your Photos library.", "Allow Access to Photos…",
                    { model.allowPhotos() }
                )
            case .denied:
                return (
                    "Access to Photos is off, so its videos aren't included.", "Open System Settings…",
                    { PrivacySettings.open(PrivacySettings.photos) }
                )
            default:
                return nil
            }
        }

        var body: some View {
            Form {
                Section {
                    if let photosRow {
                        LabeledContent {
                            Button(photosRow.button, action: photosRow.action)
                        } label: {
                            Label("Photos", systemImage: "photo.on.rectangle")
                            Text(photosRow.text)
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
