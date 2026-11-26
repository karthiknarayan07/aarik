#if os(macOS)
    import Convert
    import AppCore
    import AppUI
    import AppServices
    import LocalLibrary
    import SwiftUI

    extension View {
        /// What every Activity list does with its selection, from `JobListActions`: a context menu on the selected
        /// rows, double-click and Return for the primary action, and Delete.
        func jobListActions(
            model: ConvertModel, kind: JobListKind, selection: Set<UUID>,
            onDelete: ((Set<UUID>) -> Void)? = nil
        ) -> some View {
            contextMenu(forSelectionType: UUID.self) { ids in
                ForEach(model.contextMenu(for: ids, in: kind), id: \.action) { command in
                    Button(command.title) { model.perform(command.action, on: ids, in: kind) }
                }
            } primaryAction: { ids in
                model.performPrimaryAction(on: ids, in: kind)
            }
            .onDeleteCommand {
                if let onDelete { onDelete(selection) } else { model.performDelete(on: selection, in: kind) }
            }
        }
    }

    /// Videos waiting or converting, in order: a header with the time left and the speed, then a row per video.
    struct QueueView: View {
        let model: ConvertModel
        @State private var isConfirmingCancelAll = false
        @State private var pendingRunningRemoval: Set<UUID>?
        @State private var selection = Set<UUID>()
        @State private var timeline = ProgressTimeline()

        private var isConfirmingRunningRemoval: Binding<Bool> {
            Binding {
                pendingRunningRemoval != nil
            } set: { shown in
                if !shown { pendingRunningRemoval = nil }
            }
        }

        private func deleteSelection(_ ids: Set<UUID>) {
            let includesRunning = model.jobs(withIDs: ids).contains {
                if case .running = $0.state { true } else { false }
            }
            if includesRunning {
                pendingRunningRemoval = ids
            } else {
                model.performDelete(on: ids, in: .queue)
            }
        }

        var body: some View {
            let jobs = model.queuedJobs
            let items = model.library.items + model.photos.items
            Group {
                if jobs.isEmpty {
                    VideoPage.queue.emptyState
                        .action("Go to Local Files") { model.selection = .localFiles }
                } else {
                    VStack(spacing: 0) {
                        LowBatteryBanner(pause: model.queuePause)
                        QueueHeader(
                            jobs: jobs, timeline: timeline, pauseText: model.queuePause.statusText,
                            speed: Bindable(model.services).speed)
                        Divider()
                        List(selection: $selection) {
                            ForEach(jobs) { job in
                                QueueRow(
                                    job: job, pauseText: model.queuePause.statusText,
                                    thumbnails: model.thumbnailSource.cache,
                                    sizes: QueueSizes.sizes(for: job, in: items),
                                    remaining: timeline.remaining(for: job.id)
                                ) {
                                    model.cancel(job)
                                }
                            }
                        }
                        .jobListActions(model: model, kind: .queue, selection: selection, onDelete: deleteSelection)
                    }
                }
            }
            .onAppear { timeline.observe(jobs) }
            .onChange(of: jobs) { _, jobs in timeline.observe(jobs) }
            .navigationTitle("Queue")
            // Kept while empty too: videos added later wait until Resume.
            .navigationSubtitle(
                JobListActions.subtitle(
                    kind: .queue, count: jobs.count, savedBytes: 0, pauseText: model.queuePause.statusText)
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) { PauseResumeButton(model: model) }
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel All…", systemImage: "xmark.circle") { isConfirmingCancelAll = true }
                        .disabled(jobs.isEmpty)
                        .help("Empty the queue and stop the current conversion")
                }
            }
            .confirmationDialog("Cancel All Conversions?", isPresented: $isConfirmingCancelAll) {
                Button("Cancel All Conversions", role: .destructive) { model.cancelAll() }
                Button("Keep Converting", role: .cancel) {}
            } message: {
                Text("Waiting videos leave the queue and the current conversion stops. Originals aren't touched.")
            }
            .confirmationDialog("Cancel Running Conversion?", isPresented: isConfirmingRunningRemoval) {
                Button("Cancel Conversion", role: .destructive) {
                    if let ids = pendingRunningRemoval { model.performDelete(on: ids, in: .queue) }
                    pendingRunningRemoval = nil
                }
                Button("Keep Converting", role: .cancel) { pendingRunningRemoval = nil }
            } message: {
                Text("Stopping a running conversion removes it from the queue. Originals aren't touched.")
            }
        }
    }

    /// The queue's summary: a ring for the whole queue, the time left, and the speed setting.
    struct QueueHeader: View {
        let jobs: [Job]
        let timeline: ProgressTimeline
        let pauseText: String?
        @Binding var speed: SpeedSetting
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var running: [Job] {
            jobs.filter {
                if case .running = $0.state { true } else { false }
            }
        }

        /// How much of the queue's work is done: the running jobs' progress over every job in it.
        private var overall: Double {
            let total = Double(jobs.count)
            guard total > 0 else { return 0 }
            let done = running.reduce(0.0) { sum, job in
                if case .running(let progress) = job.state { sum + progress } else { sum }
            }
            return done / total
        }

        private var timeLeft: String {
            if let pauseText { return pauseText }
            guard
                let seconds = timeline.totalRemaining(running: running, waitingCount: jobs.count - running.count)
            else { return running.isEmpty ? "Waiting to start" : "Estimating time left…" }
            return "\(TimeLeftText.string(seconds)) left"
        }

        var body: some View {
            HStack(spacing: 16) {
                ProgressRing(value: overall, lineWidth: 6) {
                    Text(overall, format: .percent.precision(.fractionLength(0)))
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeLeft)
                        .font(.title3.weight(.semibold))
                        .contentTransition(.numericText())
                        .animation(Motion.animation(reduceMotion: reduceMotion), value: timeLeft)
                    Text("\(ActivityText.videos(jobs.count)) in the queue")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Speed", selection: $speed) {
                    ForEach(SpeedSetting.allCases) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("How hard conversion works; Settings explains each option")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .contain)
        }
    }

    struct QueueRow: View {
        let job: Job
        /// "Paused", or why the queue stopped itself; nil while it runs.
        let pauseText: String?
        let thumbnails: ThumbnailCache
        var sizes: QueueSizes?
        /// Seconds this video has left, once there is enough to estimate.
        var remaining: TimeInterval?
        /// Stops the one converting. A waiting video is removed with Delete or the context menu.
        let cancel: () -> Void

        init(
            job: Job, pauseText: String?, thumbnails: ThumbnailCache, sizes: QueueSizes? = nil,
            remaining: TimeInterval? = nil, cancel: @escaping () -> Void
        ) {
            self.job = job
            self.pauseText = pauseText
            self.thumbnails = thumbnails
            self.sizes = sizes
            self.remaining = remaining
            self.cancel = cancel
        }

        private var progress: Double? {
            if case .running(let progress) = job.state { return progress }
            return nil
        }

        private var stateText: String {
            // A phase of its own (a download from iCloud) names itself and counts its own progress.
            if progress != nil {
                guard let remaining else { return job.phase ?? "Converting" }
                return "\(job.phase ?? "Converting") · \(TimeLeftText.string(remaining).lowercased()) left"
            }
            return pauseText ?? "Waiting"
        }

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(url: job.source, thumbnails: thumbnails, size: CGSize(width: 64, height: 44))
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let preset = job.presetLabel {
                            Text(preset)
                            Text("·")
                        }
                        Text(stateText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let sizes {
                        Text(sizes.text)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let lost = job.predictedLost { PredictedLossBadge(lost: lost) }
                if let progress {
                    ProgressRing(value: progress, lineWidth: 4) {
                        Text(Int((progress * 100).rounded()), format: .number)
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                    // Only the running video has a button, like Safari's stop button on a download.
                    Button("Cancel Conversion", systemImage: "xmark.circle.fill", action: cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Cancel Conversion")
                        .accessibilityLabel("Cancel conversion: \(job.displayName)")
                } else {
                    Image(systemName: "clock")
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, height: 38)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityText)
        }

        private var accessibilityText: String {
            var parts = [job.displayName, stateText]
            if let progress { parts.append("\(Int((progress * 100).rounded())) percent") }
            if let sizes { parts.append(sizes.text) }
            return parts.joined(separator: ", ")
        }
    }
#endif
