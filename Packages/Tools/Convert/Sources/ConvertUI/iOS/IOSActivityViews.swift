#if os(iOS)
    import AppCore
    import AppServices
    import AppUI
    import Assistant
    import Convert
    import LocalLibrary
    import MediaEngine
    import PhotosLibrary
    import SwiftUI

    /// iOS Queue screen: shows waiting and converting jobs, pause/heat status, the low-battery warning, per-row cancel and Cancel All.
    struct IOSQueueView: View {
        let model: ConvertModel
        @State private var isConfirmingCancelAll = false
        @State private var editingJob: Job?

        var body: some View {
            let jobs = model.queuedJobs
            let waitsForStart = model.waitsForStart
            // Before Start the waiting videos say so; "Paused" is for a run the user paused.
            let waitingText = waitsForStart ? "Ready to Start" : model.queuePause.statusText
            Group {
                if jobs.isEmpty {
                    ContentUnavailableView {
                        Label("Queue Is Empty", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Videos you add wait here until they convert.")
                    } actions: {
                        NavigationLink("Browse Photos", value: model.route(to: .photos))
                            .buttonStyle(.borderedProminent)
                        NavigationLink("Browse Files", value: model.route(to: .files))
                    }
                } else {
                    List {
                        ForEach(jobs) { job in
                            row(for: job, waitingText: waitingText)
                                .swipeActions(edge: .trailing) {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        model.cancel(job)
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                LowBatteryBanner(pause: model.queuePause)
            }
            .safeAreaInset(edge: .bottom) {
                if !jobs.isEmpty && model.isQueuePaused {
                    startButton(waitsForStart: waitsForStart)
                }
            }
            .sheet(item: $editingJob) { job in
                IOSQueueJobEditor(model: model, job: job)
            }
            .navigationTitle("Queue")
            .navigationSubtitle(
                JobListActions.subtitle(
                    kind: .queue, count: jobs.count, savedBytes: 0, pauseText: waitingText)
            )
            .toolbar {
                // While paused with videos waiting, the bottom button starts or resumes; the toolbar pauses a run.
                if !(model.isQueuePaused && !jobs.isEmpty) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.toggleQueuePaused()
                        } label: {
                            Label(
                                model.isQueuePaused ? "Resume" : "Pause",
                                systemImage: model.isQueuePaused ? "play.fill" : "pause.fill")
                        }
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityIdentifier("pauseResume")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel All…", systemImage: "xmark.circle") { isConfirmingCancelAll = true }
                        .disabled(jobs.isEmpty)
                }
            }
            .sensoryFeedback(.impact, trigger: model.isQueuePaused)
            .confirmationDialog("Cancel All Conversions?", isPresented: $isConfirmingCancelAll) {
                Button("Cancel All Conversions", role: .destructive) { model.cancelAll() }
                Button("Keep Converting", role: .cancel) {}
            } message: {
                Text("Waiting videos leave the queue and the current conversion stops. Originals aren't touched.")
            }
        }
    }

    extension IOSQueueView {
        @ViewBuilder
        fileprivate func row(for job: Job, waitingText: String?) -> some View {
            if job.state == .queued {
                Button {
                    editingJob = job
                } label: {
                    HStack(spacing: 8) {
                        IOSQueueRow(
                            job: job, pauseText: waitingText, thumbnails: model.thumbnailSource
                        ) {
                            model.cancel(job)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edits selected video and conversion settings")
            } else {
                IOSQueueRow(
                    job: job, pauseText: waitingText, thumbnails: model.thumbnailSource
                ) {
                    model.cancel(job)
                }
            }
        }

        /// Start (or Resume, after a pause) with what the waiting videos would save together.
        fileprivate func startButton(waitsForStart: Bool) -> some View {
            let saving = model.queuedSavingEstimate
            return Button {
                model.startQueue()
            } label: {
                Text(
                    waitsForStart
                        ? QueueButtonTitle.startTitle(saved: saving > 0 ? ByteFormat.string(saving) : nil)
                        : "Resume"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 4)
            .accessibilityIdentifier("startQueue")
        }
    }

    private struct IOSQueueRow: View {
        let job: Job
        let pauseText: String?
        let thumbnails: ThumbnailSource
        let cancel: () -> Void

        private var progress: Double? {
            if case .running(let progress) = job.state { return progress }
            return nil
        }

        private var stateText: String {
            if let progress { return "\(job.phase ?? "Converting") · \(Int((progress * 100).rounded()))%" }
            return pauseText ?? "Waiting"
        }

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(
                    url: job.source, thumbnails: thumbnails.cache, thumbnailSource: thumbnails)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let preset = job.presetLabel { Text(preset) }
                        Text("·")
                        Text(stateText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Progress")
                    }
                }
                Spacer()
                if let lost = job.predictedLost { PredictedLossBadge(lost: lost) }
                if progress != nil {
                    Button("Cancel Conversion", systemImage: "xmark.circle.fill", action: cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel conversion: \(job.displayName)")
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(job.displayName), \(stateText)")
        }
    }

    /// Everything that has finished, in one list like Fitness's history: what failed first (it needs a decision), then
    /// the finished conversions with the space they saved, then the videos left as they were.
    struct IOSCompletedView: View {
        let model: ConvertModel

        var body: some View {
            let done = model.completedJobs
            let failed = model.failedJobs
            let kept = model.keptAsIsJobs
            Group {
                if done.isEmpty && failed.isEmpty && kept.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Finished Yet", systemImage: "checkmark.circle")
                    } description: {
                        Text("Converted videos, and videos kept as they were, show up here with what they saved.")
                    }
                } else {
                    List {
                        if !failed.isEmpty {
                            Section {
                                ForEach(failed, id: \.job.id) { row in
                                    IOSReasonRow(
                                        job: row.job, reason: row.reason, thumbnails: model.thumbnailSource,
                                        assistant: model.assistant
                                    ) {
                                        Button("Retry") { model.retry(row.job) }
                                            .buttonStyle(.bordered)
                                            .accessibilityLabel("Retry \(row.job.displayName)")
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button("Retry", systemImage: "arrow.clockwise") { model.retry(row.job) }
                                            .tint(.blue)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                            model.remove(row.job)
                                        }
                                    }
                                }
                            } header: {
                                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        if !done.isEmpty {
                            Section {
                                ForEach(done, id: \.job.id) { row in
                                    IOSCompletedRow(
                                        job: row.job, outcome: row.outcome, thumbnails: model.thumbnailSource,
                                        assistant: model.assistant,
                                        reveal: { model.host.reveal([row.outcome.output]) }
                                    )
                                    .swipeActions(edge: .trailing) {
                                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                            model.remove(row.job)
                                        }
                                    }
                                }
                            } header: {
                                Label("Completed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } footer: {
                                Text(
                                    JobListActions.subtitle(
                                        kind: .completed, count: done.count, savedBytes: model.activity.savedBytes,
                                        pauseText: nil))
                            }
                        }
                        if !kept.isEmpty {
                            Section {
                                ForEach(kept, id: \.job.id) { row in
                                    IOSReasonRow(
                                        job: row.job, reason: row.reason, thumbnails: model.thumbnailSource,
                                        assistant: model.assistant
                                    )
                                    .swipeActions(edge: .trailing) {
                                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                            model.remove(row.job)
                                        }
                                    }
                                }
                            } header: {
                                Label("Kept as Is", systemImage: "equal.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(IOSPage.completed.title)
            .toolbar {
                if !failed.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry All", systemImage: "arrow.clockwise") { model.retryAllFailed() }
                    }
                }
            }
            .sensoryFeedback(.success, trigger: done.count)
            .sensoryFeedback(.error, trigger: failed.count)
        }
    }

    private struct IOSCompletedRow: View {
        let job: Job
        let outcome: JobOutcome
        let thumbnails: ThumbnailSource
        let assistant: AssistantServices
        let reveal: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(url: outcome.output, thumbnails: thumbnails.cache, thumbnailSource: thumbnails)
                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.output.isFileURL ? outcome.output.lastPathComponent : job.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(ActivityText.sizeChange(outcome))
                        Text("·")
                        Text(ActivityText.saved(outcome))
                        if outcome.replacedOriginal {
                            Text("·")
                            Text("Original in Recently Deleted")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(outcome.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if !outcome.isVerified { WhyButton(assistant: assistant, job: job, outcome: outcome) }
                ReportBadge(outcome: outcome) {
                    if !outcome.isVerified { WhyInline(assistant: assistant, job: job, outcome: outcome) }
                }
            }
            .padding(.vertical, 2)
            .contextMenu {
                if outcome.output.isFileURL {
                    Button("Show in Files", systemImage: "folder", action: reveal)
                    ShareLink(items: [outcome.output]) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private struct IOSReasonRow<Actions: View>: View {
        let job: Job
        let reason: String
        let thumbnails: ThumbnailSource
        let assistant: AssistantServices
        @ViewBuilder var actions: Actions

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(url: job.source, thumbnails: thumbnails.cache, thumbnailSource: thumbnails)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                WhyButton(assistant: assistant, job: job, outcome: nil)
                actions
            }
            .padding(.vertical, 2)
        }
    }

    extension IOSReasonRow where Actions == EmptyView {
        init(job: Job, reason: String, thumbnails: ThumbnailSource, assistant: AssistantServices) {
            self.init(job: job, reason: reason, thumbnails: thumbnails, assistant: assistant) { EmptyView() }
        }
    }

    /// Edit sheet opened when tapping a waiting video in Queue: adjust resolution, bit rate, format, save destination,
    /// or swap/remove the queued video.
    private struct IOSQueueJobEditor: View {
        @Bindable var model: ConvertModel
        let job: Job
        let existing: ConvertJobSettings
        @Environment(\.dismiss) private var dismiss

        @State private var options: AdvancedOptions
        @State private var photosSaveLocation: PhotosSaveLocation
        @State private var fileSaveLocation: SaveLocation
        @State private var replacement: VideoItem?
        @State private var isPickingVideo = false

        init(model: ConvertModel, job: Job) {
            self.model = model
            self.job = job
            let decoded =
                (try? JSONDecoder().decode(ConvertJobSettings.self, from: job.settings))
                ?? ConvertJobSettings(saveTo: SaveLocation(platform: .iOS).destination ?? .documents)
            self.existing = decoded
            _options = State(initialValue: AdvancedOptions(from: decoded.custom, preset: decoded.preset))
            _photosSaveLocation = State(initialValue: PhotosSaveLocation(destination: decoded.photosDestination))
            _fileSaveLocation = State(initialValue: SaveLocation(destination: decoded.saveTo, platform: .iOS))
        }

        private var activeItem: VideoItem? { replacement ?? model.libraryItem(for: job) }

        private var isPhotos: Bool {
            if let replacement { return replacement.photosIdentifier != nil }
            return job.toolID == ConvertTool.photosToolID
        }

        private var decision: PlanDecision? {
            activeItem.map { item in
                let source = item.savingsSource
                return SavingsCalculator.decision(
                    byteSize: source.byteSize, inventory: source.inventory, preset: existing.preset,
                    custom: options.spec)
            }
        }

        private var locksFrameRate: Bool {
            activeItem.map {
                $0.badges.contains(.sloMo) || ConvertPlanner.locksFrameRate($0.savingsSource.inventory)
            } ?? false
        }

        private var canSave: Bool {
            isPhotos ? photosSaveLocation.destination != nil : fileSaveLocation.destination != nil
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section("Selected Video") {
                        if let item = activeItem {
                            IOSItemSummaryHeader(item: item, thumbnails: model.thumbnailSource)
                            if let decision {
                                IOSSingleEstimateCard(decision: decision, originalBytes: item.byteSize)
                            }
                        } else {
                            HStack(spacing: 12) {
                                JobThumbnail(
                                    url: job.source, thumbnails: model.thumbnailSource.cache,
                                    thumbnailSource: model.thumbnailSource, size: CGSize(width: 72, height: 48))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.displayName)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if let preset = job.presetLabel {
                                        Text(preset)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !model.photos.items.isEmpty || !model.library.items.isEmpty {
                            Button("Change Selected Video…", systemImage: "arrow.triangle.2.circlepath") {
                                isPickingVideo = true
                            }
                        }
                    }

                    IOSQualitySections(
                        resolution: $options.resolution,
                        bitRateMbps: $options.bitRateMbps,
                        frameRate: $options.frameRate,
                        codec: $options.codec,
                        locksFrameRate: locksFrameRate)

                    if case .convert(_, _, let predicted) = decision {
                        Section("What Happens to Metadata") {
                            MetadataSummary(report: predicted)
                        }
                    }

                    if isPhotos {
                        IOSPhotosSaveSection(location: $photosSaveLocation)
                    } else {
                        Section("Save to") {
                            SaveDestinationPicker(location: $fileSaveLocation)
                        }
                    }

                    Section {
                        Button("Remove from Queue", systemImage: "trash", role: .destructive) {
                            model.remove(job)
                            dismiss()
                        }
                    }
                }
                .navigationTitle("Edit Queued Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.updateQueuedJob(
                                job, existing: existing, options: options,
                                photosSaveLocation: photosSaveLocation,
                                fileSaveLocation: fileSaveLocation,
                                replacement: replacement)
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveJobSettings")
                    }
                }
                .sheet(isPresented: $isPickingVideo) {
                    IOSQueueMediaPicker(model: model, editingJob: job, selection: $replacement)
                }
            }
        }
    }

    private struct IOSQueueMediaPicker: View {
        let model: ConvertModel
        let editingJob: Job
        @Binding var selection: VideoItem?
        @Environment(\.dismiss) private var dismiss
        @State private var search = ""

        private func isBusyElsewhere(_ item: VideoItem) -> Bool {
            let source: URL? =
                if let identifier = item.photosIdentifier {
                    PhotoAssetURL.url(for: identifier)
                } else {
                    item.fileURL?.standardizedFileURL
                }
            guard let source else { return true }
            return model.queuedJobs.contains { other in
                guard other.id != editingJob.id else { return false }
                return other.source == source || other.source.standardizedFileURL == source
            }
        }

        private func filter(_ items: [VideoItem]) -> [VideoItem] {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return items }
            return items.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }

        var body: some View {
            let photosItems = filter(model.photos.items)
            let fileItems = filter(model.library.items.filter(\.isAvailable))
            NavigationStack {
                List {
                    if !photosItems.isEmpty {
                        Section("Photos") {
                            ForEach(photosItems) { row($0) }
                        }
                    }
                    if !fileItems.isEmpty {
                        Section("Files") {
                            ForEach(fileItems) { row($0) }
                        }
                    }
                }
                .searchable(text: $search, prompt: "Search videos")
                .navigationTitle("Choose Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }

        private func row(_ item: VideoItem) -> some View {
            let busy = isBusyElsewhere(item)
            return Button {
                selection = item
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    IOSPickerThumbnail(item: item, thumbnails: model.thumbnailSource)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(ItemDescription.details(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy {
                        Text("In Queue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
        }
    }

    private struct IOSPickerThumbnail: View {
        let item: VideoItem
        let thumbnails: ThumbnailSource
        @State private var image: CGImage?

        var body: some View {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 32)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 4))
            .accessibilityHidden(true)
            .task(id: item.id) {
                image = await thumbnails.image(for: item, maxPixel: 144)
            }
        }
    }
#endif
