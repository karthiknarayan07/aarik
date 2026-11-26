#if os(iOS)
    import AppCore
    import AppUI
    import Assistant
    import Convert
    import LocalLibrary
    import MediaEngine
    import PhotosLibrary
    import SwiftUI

    /// iOS Overview: native grouped list showing Photos and Local Files totals, Smart Picks (when Apple Intelligence
    /// is available) or Biggest Groups, Biggest Savings, and Saved So Far.
    struct IOSOverviewView: View {
        @Environment(\.openToolRoute) private var openRoute
        @Bindable var model: ConvertModel
        @State private var summary: OverviewSummary?
        @State private var refreshTick = 0

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

        private struct PicksTrigger: Hashable {
            let revision: Int
            let isAvailable: Bool
        }

        private var picksTrigger: PicksTrigger {
            PicksTrigger(revision: model.assistant.smartPicks.revision, isAvailable: model.assistant.isAvailable)
        }

        var body: some View {
            Group {
                if model.photos.items.isEmpty && model.library.items.isEmpty {
                    if model.photos.isAuthorizationKnown
                        && (!model.photos.authorization.allowsReading || model.photos.hasLoaded)
                    {
                        IOSOverviewEmptyState(model: model)
                    } else {
                        ProgressView()
                    }
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(IOSGreeting.text())
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                IOSSavingsHero(snapshot: charts, activity: model.activity)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        IOSContinueSection(model: model)
                        IOSReadySection(model: model)
                        IOSRecentSection(model: model)
                        Section {
                            IOSInsightCards(
                                snapshot: charts, activity: model.activity,
                                groupsPage: model.photos.items.isEmpty ? .files : .photos,
                                open: { open($0) })
                        } header: {
                            Text("Pinned")
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        if let charts, !charts.throughput.isEmpty || !charts.groups.isEmpty {
                            Section("Trends") {
                                IOSTrendCharts(snapshot: charts)
                            }
                        }
                        if let summary {
                            IOSSmartPicksSection(model: model)
                            IOSLibraryOverviewSections(model: model, summary: summary)
                            IOSBiggestSavingsSection(summary: summary, reveal: model.reveal)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Home")
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

        /// Opens one of the tool's pages in the Tools tab.
        private func open(_ page: IOSPage) {
            openRoute(ToolRoute(toolID: model.tool.id, page: page.rawValue))
        }

        private var cache: SavingsStatsCache { model.services.savingsStats }

        /// What the charts draw: the stored numbers at once, then the refreshed ones.
        private var charts: OverviewCharts? {
            cache.snapshot.map(OverviewCharts.init(snapshot:))
        }

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
                    self.summary = analysis.summary
                }
                return OverviewCharts.snapshot(summary: analysis.summary, buckets: analysis.buckets, finished: finished)
            }
        }

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

    private struct IOSLibraryOverviewSections: View {
        @Environment(\.openToolRoute) private var openRoute
        let model: ConvertModel
        let summary: OverviewSummary

        var body: some View {
            Section("Videos in Photos") {
                switch model.photos.isAuthorizationKnown ? model.photos.authorization : nil {
                case nil:
                    HStack {
                        ProgressView()
                        Text("Checking access to Photos…")
                            .foregroundStyle(.secondary)
                    }
                case .authorized, .limited:
                    IOSTotalsRows(totals: summary.videos)
                case .notDetermined:
                    Text("Include the videos in your Photos library.")
                        .foregroundStyle(.secondary)
                    Button("Allow Access to Photos…") { model.allowPhotos() }
                case .denied, .restricted:
                    Text("Access to Photos is off, so its videos aren't included.")
                        .foregroundStyle(.secondary)
                    if model.photos.authorization == .denied {
                        Button("Open Photos Settings…") { model.openPhotosAccessSettings() }
                    }
                }
            }
            Section {
                if summary.localFiles.count == 0 {
                    Text("Add videos or folders from Files.")
                        .foregroundStyle(.secondary)
                    Button("Add Local Files…") {
                        openRoute(model.route(to: .files))
                        model.isImporterPresented = true
                    }
                } else {
                    IOSTotalsRows(totals: summary.localFiles)
                }
            } header: {
                Text("Local Files")
            } footer: {
                Text(
                    "Estimated at the \(model.preset.displayName) preset. Nothing changes until you add videos to the queue."
                )
            }
        }
    }

    private struct IOSTotalsRows: View {
        let totals: OverviewSummary.Totals

        var body: some View {
            LabeledContent("Videos", value: totals.count.formatted())
            LabeledContent("Size", value: ByteFormat.string(totals.bytes))
            LabeledContent("Could Free") {
                if totals.couldFree > 0 {
                    Text("about \(ByteFormat.string(totals.couldFree))")
                        .foregroundStyle(.tint)
                } else {
                    Text("Nothing")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct IOSSmartPicksSection: View {
        @Environment(\.openToolRoute) private var openRoute
        let model: ConvertModel

        private var store: SmartPicksStore { model.assistant.smartPicks }

        var body: some View {
            if !store.buckets.isEmpty {
                if store.isShowingPicks {
                    Section {
                        if case .picks(let picks) = store.state {
                            ForEach(picks) { pick in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(pick.title)
                                        .font(.headline)
                                    Text(pick.why)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(pick.bucket.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ViewThatFits(in: .horizontal) {
                                        HStack {
                                            Button("Show") {
                                                model.show(pick.bucket)
                                                openRoute(model.routeToSelection())
                                            }
                                            .buttonStyle(.bordered)
                                            Button("Add These to the Queue…") { model.addToQueue(pick.bucket) }
                                                .buttonStyle(.borderedProminent)
                                                .disabled(!model.canAddToQueue(pick.bucket))
                                        }
                                        VStack(alignment: .leading, spacing: 8) {
                                            Button("Show") {
                                                model.show(pick.bucket)
                                                openRoute(model.routeToSelection())
                                            }
                                            .buttonStyle(.bordered)
                                            Button("Add These to the Queue…") { model.addToQueue(pick.bucket) }
                                                .buttonStyle(.borderedProminent)
                                                .disabled(!model.canAddToQueue(pick.bucket))
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                                .padding(.vertical, 4)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("\(pick.title). \(pick.why). \(pick.bucket.detail)")
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Finding where to start…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Label("Smart Picks", systemImage: "sparkles")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suggested on \(DeviceCopy.thisDevice). Nothing is added until you choose.")
                            if store.undatedCount > 0 {
                                Text(undatedText(store.undatedCount))
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(store.buckets.prefix(Self.listedGroups), id: \.identity) { bucket in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bucket.title)
                                    Text(bucket.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show") {
                                    model.show(bucket)
                                    openRoute(model.routeToSelection())
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Show \(bucket.title)")
                            }
                        }
                    } header: {
                        Text("Biggest Groups")
                    } footer: {
                        if store.undatedCount > 0 {
                            Text(undatedText(store.undatedCount))
                        }
                    }
                }
            }
        }

        private static let listedGroups = 5

        private func undatedText(_ count: Int) -> String {
            count == 1
                ? "1 video without a capture date isn't in any group."
                : "\(count.formatted()) videos without a capture date aren't in any group."
        }
    }

    private struct IOSBiggestSavingsSection: View {
        @Environment(\.openToolRoute) private var openRoute
        let summary: OverviewSummary
        let reveal: (OverviewSummary.Entry) -> Void

        var body: some View {
            Section("Biggest Savings") {
                if summary.biggest.isEmpty {
                    Text("Nothing here would get meaningfully smaller at this preset.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.biggest) { entry in
                        let libraryName = entry.library == .photos ? "Photos" : "Local Files"
                        Button {
                            reveal(entry)
                        } label: {
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    Image(systemName: entry.library == .photos ? "photo.on.rectangle" : "folder")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("\(libraryName) · \(ByteFormat.string(entry.bytes))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("about \(ByteFormat.string(entry.couldFree))")
                                        .font(.callout)
                                        .foregroundStyle(.tint)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("\(libraryName) · \(ByteFormat.string(entry.bytes))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Could free about \(ByteFormat.string(entry.couldFree))")
                                        .font(.callout)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityLabel(
                            "\(entry.name), \(libraryName), \(ByteFormat.string(entry.bytes)), could free about "
                                + "\(ByteFormat.string(entry.couldFree))")
                    }
                }
            }
        }
    }

    private struct IOSOverviewEmptyState: View {
        @Environment(\.openToolRoute) private var openRoute
        let model: ConvertModel

        var body: some View {
            ContentUnavailableView {
                Label("Welcome to \(AppInfo.displayName)", systemImage: "film.stack")
            } description: {
                Text(
                    "See how much space your videos take, then keep smaller copies that look the same. "
                        + "Nothing changes until you add videos to the queue.")
            } actions: {
                if model.photos.isAuthorizationKnown, model.photos.authorization == .notDetermined {
                    Button("Allow Access to Photos…") { model.allowPhotos() }
                        .buttonStyle(.borderedProminent)
                }
                if model.photos.authorization == .limited {
                    Button("Choose More Photos…") { openRoute(model.route(to: .photos)) }
                        .buttonStyle(.borderedProminent)
                }
                if model.photos.authorization == .denied {
                    Button("Open Photos Settings…") { model.openPhotosAccessSettings() }
                }
                Button("Add Local Files…") {
                    openRoute(model.route(to: .files))
                    model.isImporterPresented = true
                }
            }
        }
    }
#endif
