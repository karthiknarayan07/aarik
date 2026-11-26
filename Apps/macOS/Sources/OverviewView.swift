import AarikCore
import SharedUI
import Assistant
import Convert
import LocalLibrary
import MediaEngine
import PhotosLibrary
import SwiftUI

/// Overview: how much space the videos take and what converting them could free, where to start, and what has
/// been saved so far. A vertical stack of titled groups, so another group (suggestions, for instance) can be added
/// without changing the rest.
struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var summary: OverviewSummary?

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
        Group {
            if model.photos.items.isEmpty && model.library.items.isEmpty {
                // Not before Photos has answered, so the welcome doesn't flash ahead of the totals.
                if model.photos.isAuthorizationKnown
                    && (!model.photos.authorization.allowsReading || model.photos.hasLoaded)
                {
                    OverviewEmptyState(model: model)
                } else {
                    ProgressView()
                }
            } else if let summary {
                ScrollView {
                    VStack(alignment: .leading) {
                        LibraryGroup(model: model, summary: summary)
                        SmartPicksGroup(model: model)
                        BiggestSavingsGroup(summary: summary, reveal: model.reveal)
                        SavedGroup(savedBytes: summary.savedBytes, conversions: model.activity.completed)
                    }
                    .scenePadding()
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(SidebarDestination.overview.title)
        // Reads the list of videos when access is already allowed; never shows the access prompt.
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
            // Same inputs as last time keep the picks; changed libraries or job outcomes ask again.
            model.assistant.smartPicks.update(
                buckets: analysis.buckets, undatedCount: analysis.undated, key: inputs)
        }
        .task(id: picksTrigger) { await model.assistant.smartPicks.generateIfNeeded() }
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

/// Count, size and what could be freed, for Photos videos and for Local Files.
private struct LibraryGroup: View {
    let model: AppModel
    let summary: OverviewSummary

    var body: some View {
        OverviewGroup(title: "Videos in Photos") {
            switch model.photos.isAuthorizationKnown ? model.photos.authorization : nil {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking access to Photos")
            case .authorized, .limited:
                TotalsRows(totals: summary.videos)
            case .notDetermined:
                HStack {
                    Text("Include the videos in your Photos library.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow Access to Photos…") { model.allowPhotos() }
                        .accessibilityHint("Shows the system prompt to allow access to your Photos library")
                }
            case .denied, .restricted:
                HStack {
                    Text("Access to Photos is off, so its videos aren't included.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Photos Settings") { PrivacySettings.open(PrivacySettings.photos) }
                }
            }
        }
        OverviewGroup(title: "Local Files") {
            if summary.localFiles.count == 0 {
                HStack {
                    Text("Add videos or folders from this Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Local Files…") {
                        model.selection = .localFiles
                        model.isImporterPresented = true
                    }
                }
            } else {
                TotalsRows(totals: summary.localFiles)
            }
        }
        Text(
            "Estimated at the \(model.preset.displayName) preset. Nothing changes until you add videos to the queue."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct TotalsRows: View {
    let totals: OverviewSummary.Totals

    var body: some View {
        VStack(alignment: .leading) {
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Smart picks

/// Where to start: with the on-device model, up to three groups of videos worth shrinking first, each with a
/// reason, Show and Add These to the Queue. Without it (unavailable, or no usable answer) the same place lists the
/// biggest groups as plain rows, with no mention of the model.
private struct SmartPicksGroup: View {
    let model: AppModel

    private var store: SmartPicksStore { model.assistant.smartPicks }

    var body: some View {
        if !store.buckets.isEmpty {
            if store.isShowingPicks {
                OverviewGroup(title: "Smart Picks", systemImage: "sparkles") {
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
                    } else {
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
                OverviewGroup(title: "Biggest Groups") {
                    VStack(alignment: .leading) {
                        ForEach(Array(store.buckets.prefix(Self.listedGroups).enumerated()), id: \.element.identity) {
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
                        canAdd ? "Select these videos and add them to the queue" : "Choose where to save copies first"
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

/// The ten videos that would free the most, from both libraries. Clicking one shows it in its grid.
private struct BiggestSavingsGroup: View {
    let summary: OverviewSummary
    let reveal: (OverviewSummary.Entry) -> Void

    var body: some View {
        OverviewGroup(title: "Biggest Savings") {
            if summary.biggest.isEmpty {
                Text("Nothing here would get meaningfully smaller at this preset.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading) {
                    ForEach(Array(summary.biggest.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        BiggestSavingsRow(entry: entry) { reveal(entry) }
                    }
                }
            }
        }
    }
}

private struct BiggestSavingsRow: View {
    let entry: OverviewSummary.Entry
    let reveal: () -> Void

    private var libraryName: String { entry.library == .photos ? "Photos" : "Local Files" }

    var body: some View {
        Button(action: reveal) {
            HStack {
                Image(systemName: entry.library == .photos ? "photo.on.rectangle" : "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(libraryName) · \(ByteFormat.string(entry.bytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("about \(ByteFormat.string(entry.couldFree))")
                    .foregroundStyle(.tint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show in \(libraryName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.name), \(libraryName), \(ByteFormat.string(entry.bytes)), could free about "
                + "\(ByteFormat.string(entry.couldFree))"
        )
        .accessibilityHint("Shows it in the \(libraryName) grid")
        .accessibilityAddTraits(.isButton)
    }
}

/// What finished conversions have freed so far.
private struct SavedGroup: View {
    let savedBytes: Int64
    let conversions: Int

    var body: some View {
        OverviewGroup(title: "Saved So Far") {
            VStack(alignment: .leading) {
                LabeledContent("Space Saved", value: ByteFormat.string(savedBytes))
                LabeledContent("Conversions", value: conversions.formatted())
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Empty state

/// Nothing to total yet: one system empty state with the two ways to start.
private struct OverviewEmptyState: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to \(AppModel.displayName)", systemImage: "film.stack")
        } description: {
            Text(
                "See how much space your videos take, then keep smaller copies that look the same. "
                    + "Nothing changes until you add videos to the queue.")
        } actions: {
            if model.photos.isAuthorizationKnown, model.photos.authorization == .notDetermined {
                Button("Allow Access to Photos…") { model.allowPhotos() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Shows the system prompt to allow access to your Photos library")
            }
            if model.photos.authorization == .denied {
                Button("Open Photos Settings") { PrivacySettings.open(PrivacySettings.photos) }
            }
            Button("Add Local Files…") {
                model.selection = .localFiles
                model.isImporterPresented = true
            }
        }
    }
}
