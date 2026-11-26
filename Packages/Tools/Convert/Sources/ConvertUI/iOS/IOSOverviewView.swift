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
        @Bindable var model: ConvertModel
        let stats: any SavingsStatsSource
        @State private var summary: OverviewSummary?

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
                            IOSSavingsHero(snapshot: stats.snapshot, activity: model.activity)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        Section {
                            IOSInsightCards(
                                snapshot: stats.snapshot, history: stats.history, activity: model.activity,
                                open: { model.selection = $0.videoPage })
                        } header: {
                            Text("Pinned")
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        Section("Trends") {
                            IOSTrendCharts(snapshot: stats.snapshot, history: stats.history)
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
            .navigationTitle(IOSPage.overview.title)
            .task { await model.photos.start() }
            .task(id: inputs) {
                let photos = model.photos.items
                let files = model.library.items
                let completed = model.completedJobs.map(\.outcome)
                let shrunk = model.shrunkIDs(in: model.browser)
                let analysis = await Self.analyze(
                    photos: photos, files: files, preset: model.preset, overrides: model.presetOverrides,
                    custom: model.advanced.spec, completed: completed, shrunk: shrunk)
                guard !Task.isCancelled else { return }
                summary = analysis.summary
                stats.store(
                    SavingsStatsSnapshot(
                        photos: analysis.summary.videos, files: analysis.summary.localFiles,
                        savedBytes: analysis.summary.savedBytes, conversions: completed.count,
                        groups: analysis.buckets.prefix(6).map {
                            SavingsStatsSnapshot.Group(id: $0.id, title: $0.title, couldFree: $0.couldFree)
                        }),
                    history: Self.history(of: model.completedJobs.map { ($0.job.createdAt, $0.outcome.savedBytes) }))
                model.assistant.smartPicks.update(
                    buckets: analysis.buckets, undatedCount: analysis.undated, key: inputs)
            }
            .task(id: picksTrigger) { await model.assistant.smartPicks.generateIfNeeded() }
        }

        /// Bytes freed per day, the last 14 days that had a conversion.
        private static func history(of finished: [(Date, Int64)]) -> [SavingsDay] {
            let calendar = Calendar.current
            let perDay = Dictionary(grouping: finished) { calendar.startOfDay(for: $0.0) }
                .mapValues { $0.reduce(Int64(0)) { $0 + $1.1 } }
            return perDay.keys.sorted().suffix(14).map { SavingsDay(date: $0, savedBytes: perDay[$0] ?? 0) }
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
                        model.selection = .localFiles
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
                                    HStack {
                                        Button("Show") { model.show(pick.bucket) }
                                            .buttonStyle(.bordered)
                                        Button("Add These to the Queue…") { model.addToQueue(pick.bucket) }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(!model.canAddToQueue(pick.bucket))
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
                                Button("Show") { model.show(bucket) }
                                    .buttonStyle(.bordered)
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
                        }
                        .accessibilityLabel(
                            "\(entry.name), \(libraryName), \(ByteFormat.string(entry.bytes)), could free about "
                                + "\(ByteFormat.string(entry.couldFree))")
                    }
                }
            }
        }
    }

    private struct IOSSavedSoFarSection: View {
        let savedBytes: Int64
        let conversions: Int

        var body: some View {
            Section("Saved So Far") {
                LabeledContent("Space Saved", value: ByteFormat.string(savedBytes))
                LabeledContent("Conversions", value: conversions.formatted())
            }
        }
    }

    private struct IOSOverviewEmptyState: View {
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
                if model.photos.authorization == .denied {
                    Button("Open Photos Settings…") { model.openPhotosAccessSettings() }
                }
                Button("Add Local Files…") {
                    model.selection = .localFiles
                    model.isImporterPresented = true
                }
            }
        }
    }
#endif
