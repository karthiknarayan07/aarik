#if os(macOS)
    import Convert
    import AppCore
    import AppServices
    import AppUI
    import Assistant
    import Charts
    import LocalLibrary
    import SwiftUI

    /// Finished conversions as a ledger: a summary with the week's savings, then one section per day with a
    /// savings badge on each row. Select rows for the context menu (Show in Finder, Remove from List);
    /// double-click or Return shows the file in Finder.
    struct CompletedView: View {
        let model: ConvertModel
        @State private var selection = Set<UUID>()
        @State private var compareTarget: CompareTarget?

        var body: some View {
            let rows = model.completedJobs
            let days = ResultsLedger.days(rows, date: \.job.createdAt, saved: \.outcome.savedBytes)
            Group {
                if rows.isEmpty {
                    VideoPage.completed.emptyState
                } else {
                    VStack(spacing: 0) {
                        LedgerSummary(days: days, savedBytes: model.activity.savedBytes, count: rows.count)
                        Divider()
                        List(selection: $selection) {
                            ForEach(days, id: \.day) { day in
                                Section {
                                    ForEach(day.rows, id: \.job.id) { row in
                                        CompletedRow(
                                            job: row.job, outcome: row.outcome,
                                            thumbnails: model.thumbnailSource.cache,
                                            thumbnailSource: model.thumbnailSource,
                                            assistant: model.assistant
                                        ) {
                                            compareTarget = CompareTarget(job: row.job, outcome: row.outcome)
                                        }
                                    }
                                } header: {
                                    LedgerDayHeader(
                                        title: day.title,
                                        detail: day.savedBytes > 0 ? "Saved \(ByteFormat.string(day.savedBytes))" : nil)
                                }
                            }
                        }
                        .jobListActions(model: model, kind: .completed, selection: selection)
                        // Space compares the selected video, as it previews one in Finder.
                        .onKeyPress(.space) {
                            guard selection.count == 1, let row = rows.first(where: { selection.contains($0.job.id) })
                            else { return .ignored }
                            compareTarget = CompareTarget(job: row.job, outcome: row.outcome)
                            return .handled
                        }
                    }
                }
            }
            .sheet(item: $compareTarget) { CompareSheet(target: $0) }
            .navigationTitle("Completed")
            .navigationSubtitle(
                JobListActions.subtitle(
                    kind: .completed, count: rows.count, savedBytes: model.activity.savedBytes, pauseText: nil))
        }
    }

    /// A day's title with what it saved, as a section header.
    struct LedgerDayHeader: View {
        let title: String
        let detail: String?

        var body: some View {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// The ledger's headline: the total saved, how many videos, and a bar for each of the last seven days.
    struct LedgerSummary: View {
        let days: [LedgerDay<(job: Job, outcome: JobOutcome)>]
        let savedBytes: Int64
        let count: Int
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private struct Bar: Identifiable {
            let day: Date
            let bytes: Int64
            var id: Date { day }
        }

        private var bars: [Bar] {
            ResultsLedger.lastDays(days).map { Bar(day: $0.day, bytes: $0.savedBytes) }
        }

        var body: some View {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved in total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(savedBytes))
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                        .animation(Motion.animation(reduceMotion: reduceMotion), value: savedBytes)
                    Text("from \(ActivityText.videos(count))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Saved", bar.bytes))
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(3)
                }
                // Labels sit under the plot, so they never cover a bar.
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true, anchor: .top)
                    }
                }
                .chartYAxis(.hidden)
                .chartPlotStyle { $0.padding(.bottom, 4) }
                .frame(width: 260, height: 76)
                .accessibilityLabel("Saved in the last seven days")
                .accessibilityValue(
                    bars.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \(ByteFormat.string($0.bytes))" }
                        .joined(separator: ", "))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    struct CompletedRow: View {
        let job: Job
        let outcome: JobOutcome
        let thumbnails: ThumbnailCache
        var thumbnailSource: ThumbnailSource? = nil
        let assistant: AssistantServices
        /// Opens the before/after compare; nil leaves the button out.
        var onCompare: (() -> Void)?
        @State private var isWhyShown = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(
            job: Job, outcome: JobOutcome, thumbnails: ThumbnailCache,
            thumbnailSource: ThumbnailSource? = nil, assistant: AssistantServices,
            onCompare: (() -> Void)? = nil
        ) {
            self.job = job
            self.outcome = outcome
            self.thumbnails = thumbnails
            self.thumbnailSource = thumbnailSource
            self.assistant = assistant
            self.onCompare = onCompare
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    JobThumbnail(
                        url: outcome.output, thumbnails: thumbnails, thumbnailSource: thumbnailSource,
                        size: CGSize(width: 64, height: 44))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(outcome.output.isFileURL ? outcome.output.lastPathComponent : job.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(ActivityText.sizeChange(outcome))
                                .monospacedDigit()
                            if outcome.replacedOriginal {
                                Text("·")
                                Text("Original in the Trash")
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
                    SavingsBadge(before: outcome.bytesBefore, after: outcome.bytesAfter)
                    if let onCompare, outcome.output.isFileURL {
                        Button("Compare", systemImage: "square.split.2x1", action: onCompare)
                            .buttonStyle(.borderless)
                            .help("Drag a divider across the original and the converted video (Space)")
                            .accessibilityLabel("Compare \(outcome.output.lastPathComponent) with the original")
                    }
                    InlineWhyToggle(assistant: assistant, isShown: $isWhyShown)
                    ReportBadge(outcome: outcome)
                }
                if isWhyShown {
                    WhyText(assistant: assistant, job: job, outcome: outcome)
                        .padding(.leading, 76)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .animation(Motion.animation(reduceMotion: reduceMotion), value: isWhyShown)
        }
    }

    /// "Why?" on a row: opens the explanation under the row instead of in a popover. Not there at all while Apple
    /// Intelligence is unavailable.
    struct InlineWhyToggle: View {
        let assistant: AssistantServices
        @Binding var isShown: Bool

        var body: some View {
            if assistant.isAvailable {
                Button("Why?", systemImage: "sparkles") { isShown.toggle() }
                    .buttonStyle(.borderless)
                    .help("Explain this result in plain words, on \(DeviceCopy.thisDevice)")
                    .accessibilityLabel("Why? Explain this result")
                    .accessibilityValue(isShown ? "Shown" : "Hidden")
            }
        }
    }

    /// Videos left untouched, with the reason, grouped by day.
    struct KeptAsIsView: View {
        let model: ConvertModel
        @State private var selection = Set<UUID>()

        var body: some View {
            let rows = model.keptAsIsJobs
            let days = ResultsLedger.days(rows, date: \.job.createdAt, saved: { _ in 0 })
            Group {
                if rows.isEmpty {
                    VideoPage.keptAsIs.emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(days, id: \.day) { day in
                            Section {
                                ForEach(day.rows, id: \.job.id) { row in
                                    ReasonRow(
                                        job: row.job, reason: row.reason, thumbnails: model.thumbnailSource.cache,
                                        thumbnailSource: model.thumbnailSource,
                                        assistant: model.assistant, badge: "Kept as Is")
                                }
                            } header: {
                                LedgerDayHeader(title: day.title, detail: ActivityText.videos(day.rows.count))
                            }
                        }
                    }
                    .jobListActions(model: model, kind: .keptAsIs, selection: selection)
                }
            }
            .navigationTitle("Kept as Is")
            .navigationSubtitle(
                JobListActions.subtitle(kind: .keptAsIs, count: rows.count, savedBytes: 0, pauseText: nil))
        }
    }

    /// Conversions that couldn't finish, with Retry and Retry all.
    struct FailedView: View {
        let model: ConvertModel
        @State private var selection = Set<UUID>()

        var body: some View {
            let rows = model.failedJobs
            Group {
                if rows.isEmpty {
                    VideoPage.failed.emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(rows, id: \.job.id) { row in
                            ReasonRow(
                                job: row.job, reason: row.reason, thumbnails: model.thumbnailSource.cache,
                                thumbnailSource: model.thumbnailSource,
                                assistant: model.assistant
                            ) {
                                Button("Retry") { model.retry(row.job) }
                                    .accessibilityLabel("Retry \(row.job.displayName)")
                            }
                        }
                    }
                    .jobListActions(model: model, kind: .failed, selection: selection)
                }
            }
            .navigationTitle("Failed")
            .navigationSubtitle(
                JobListActions.subtitle(kind: .failed, count: rows.count, savedBytes: 0, pauseText: nil)
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Retry All", systemImage: "arrow.clockwise") { model.retryAllFailed() }
                        .disabled(rows.isEmpty)
                        .help("Put every failed video back in the queue")
                }
            }
        }
    }

    struct ReasonRow<Actions: View>: View {
        let job: Job
        let reason: String
        let thumbnails: ThumbnailCache
        var thumbnailSource: ThumbnailSource? = nil
        let assistant: AssistantServices
        /// A capsule at the trailing edge naming the outcome, when the list wants one.
        var badge: String?
        @ViewBuilder var actions: Actions
        @State private var isWhyShown = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    JobThumbnail(
                        url: job.source, thumbnails: thumbnails, thumbnailSource: thumbnailSource,
                        size: CGSize(width: 64, height: 44))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                    InlineWhyToggle(assistant: assistant, isShown: $isWhyShown)
                    actions
                }
                if isWhyShown {
                    WhyText(assistant: assistant, job: job, outcome: nil)
                        .padding(.leading, 76)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .animation(Motion.animation(reduceMotion: reduceMotion), value: isWhyShown)
        }
    }

    extension ReasonRow where Actions == EmptyView {
        init(
            job: Job, reason: String, thumbnails: ThumbnailCache, thumbnailSource: ThumbnailSource? = nil,
            assistant: AssistantServices, badge: String? = nil
        ) {
            self.init(
                job: job, reason: reason, thumbnails: thumbnails, thumbnailSource: thumbnailSource,
                assistant: assistant, badge: badge
            ) { EmptyView() }
        }
    }
#endif
