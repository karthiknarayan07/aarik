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
            let imageSpec: ImageSpec
            let completed: Int
            let saved: Int64
        }

        private var inputs: Inputs {
            Inputs(
                photosRevision: model.photos.revision, filesRevision: model.library.revision, preset: model.preset,
                overrides: model.presetOverrides, custom: model.advanced.spec, imageSpec: model.imageAdvanced.spec,
                completed: model.activity.completed, saved: model.activity.savedBytes)
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
            let imageSpec = model.imageAdvanced.spec
            let key = inputs
            let model = model
            // The first read of the page isn't held back: the live groups wait for it.
            let delay = summary == nil ? Duration.zero : Self.debounce
            await cache.refresh(after: delay) { [finished] in
                let analysis = await Self.analyze(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom,
                    imageSpec: imageSpec, completed: finished.map(\.outcome), shrunk: shrunk)
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

        /// The totals, the groups and the count of undated items. Estimating reads metadata, so it is
        /// done once for each item and shared by all three, off the main actor.
        @concurrent private static func analyze(
            photos: [VideoItem], files: [VideoItem], preset: Preset, overrides: PresetOverrides<UUID>,
            custom: DownscaleSpec?, imageSpec: ImageSpec, completed: [JobOutcome], shrunk: Set<UUID>
        ) async -> (summary: OverviewSummary, buckets: [SavingsBucket], undated: Int) {
            let estimates = OverviewSummary.estimates(
                photos: photos, files: files, preset: preset, overrides: overrides, custom: custom,
                imageSpec: imageSpec)
            return (
                OverviewSummary(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom,
                    completed: completed, estimates: estimates, imageSpec: imageSpec),
                SavingsAnalyzer.buckets(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom, shrunk: shrunk,
                    estimates: estimates, imageSpec: imageSpec),
                SavingsAnalyzer.undatedCount(
                    photos: photos, files: files, preset: preset, overrides: overrides, custom: custom, shrunk: shrunk,
                    estimates: estimates, imageSpec: imageSpec)
            )
        }
    }
#endif
