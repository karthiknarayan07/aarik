#if os(macOS)
    import Convert
    import AppCore
    import AppUI
    import Assistant
    import LocalLibrary
    import SwiftUI

    /// Finished conversions with what they saved and the report badge. Select rows for the context menu (Show in
    /// Finder, Remove from List); double-click or Return shows the file in Finder.
    struct CompletedView: View {
        let model: ConvertModel
        @State private var selection = Set<UUID>()

        var body: some View {
            let rows = model.completedJobs
            Group {
                if rows.isEmpty {
                    VideoPage.completed.emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(rows, id: \.job.id) { row in
                            CompletedRow(
                                job: row.job, outcome: row.outcome, thumbnails: model.thumbnailSource.cache,
                                assistant: model.assistant)
                        }
                    }
                    .jobListActions(model: model, kind: .completed, selection: selection)
                }
            }
            .navigationTitle("Completed")
            .navigationSubtitle(
                JobListActions.subtitle(
                    kind: .completed, count: rows.count, savedBytes: model.activity.savedBytes, pauseText: nil))
        }
    }

    private struct CompletedRow: View {
        let job: Job
        let outcome: JobOutcome
        let thumbnails: ThumbnailCache
        let assistant: AssistantServices

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(url: outcome.output, thumbnails: thumbnails)
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
                if !outcome.isVerified { WhyButton(assistant: assistant, job: job, outcome: outcome) }
                ReportBadge(outcome: outcome) {
                    if !outcome.isVerified { WhyInline(assistant: assistant, job: job, outcome: outcome) }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Videos left untouched, with the reason.
    struct KeptAsIsView: View {
        let model: ConvertModel
        @State private var selection = Set<UUID>()

        var body: some View {
            let rows = model.keptAsIsJobs
            Group {
                if rows.isEmpty {
                    VideoPage.keptAsIs.emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(rows, id: \.job.id) { row in
                            ReasonRow(
                                job: row.job, reason: row.reason, thumbnails: model.thumbnailSource.cache,
                                assistant: model.assistant)
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

    private struct ReasonRow<Actions: View>: View {
        let job: Job
        let reason: String
        let thumbnails: ThumbnailCache
        let assistant: AssistantServices
        @ViewBuilder var actions: Actions

        var body: some View {
            HStack(spacing: 12) {
                JobThumbnail(url: job.source, thumbnails: thumbnails)
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

    extension ReasonRow where Actions == EmptyView {
        init(job: Job, reason: String, thumbnails: ThumbnailCache, assistant: AssistantServices) {
            self.init(job: job, reason: reason, thumbnails: thumbnails, assistant: assistant) { EmptyView() }
        }
    }
#endif
