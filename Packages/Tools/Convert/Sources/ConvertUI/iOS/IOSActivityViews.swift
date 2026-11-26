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
                HStack(spacing: 10) {
                    Button {
                        editingJob = job
                    } label: {
                        IOSQueueRowSummary(job: job, pauseText: waitingText, thumbnails: model.thumbnailSource)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edits selected video and conversion settings")
                    if let lost = job.predictedLost { PredictedLossBadge(lost: lost) }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            } else {
                IOSQueueRow(job: job, pauseText: waitingText, thumbnails: model.thumbnailSource) {
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

    private struct IOSQueueRowSummary: View {
        let job: Job
        let pauseText: String?
        let thumbnails: ThumbnailSource

        var progress: Double? {
            if case .running(let progress) = job.state { return progress }
            return nil
        }

        var stateText: String {
            if let progress { return "\(job.phase ?? "Converting") · \(Int((progress * 100).rounded()))%" }
            return pauseText ?? "Waiting"
        }

        var subtitle: String {
            [job.presetLabel, stateText].compactMap { $0 }.joined(separator: " · ")
        }

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(
                    url: job.source, thumbnails: thumbnails.cache, thumbnailSource: thumbnails)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Progress")
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .padding(.vertical, 2)
        }
    }

    private struct IOSQueueRow: View {
        let job: Job
        let pauseText: String?
        let thumbnails: ThumbnailSource
        let cancel: () -> Void

        private var isRunning: Bool {
            if case .running = job.state { return true }
            return false
        }

        var body: some View {
            let summary = IOSQueueRowSummary(job: job, pauseText: pauseText, thumbnails: thumbnails)
            HStack(spacing: 12) {
                summary
                if let lost = job.predictedLost { PredictedLossBadge(lost: lost) }
                if isRunning {
                    Button("Cancel Conversion", systemImage: "xmark.circle.fill", action: cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel conversion: \(job.displayName)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(job.displayName), \(summary.stateText)")
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
                    Text(
                        [
                            ActivityText.sizeChange(outcome),
                            ActivityText.saved(outcome),
                            outcome.replacedOriginal ? "Original in Recently Deleted" : nil,
                        ]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
#endif
