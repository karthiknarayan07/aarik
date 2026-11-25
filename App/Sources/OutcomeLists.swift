import AppCore
import AppUI
import LocalLibrary
import SwiftUI

/// Finished conversions with what they saved, the report badge, and Show in Finder.
struct CompletedView: View {
    let model: AppModel

    var body: some View {
        let rows = model.completedJobs
        Group {
            if rows.isEmpty {
                SidebarDestination.completed.emptyState
            } else {
                List {
                    Section {
                        ForEach(rows, id: \.job.id) { row in
                            CompletedRow(job: row.job, outcome: row.outcome, thumbnails: model.thumbnails)
                        }
                    } header: {
                        Text("Saved \(ByteFormat.string(model.activity.savedBytes)) in total")
                            .font(.headline)
                    }
                }
            }
        }
        .navigationTitle("Completed")
    }
}

private struct CompletedRow: View {
    let job: Job
    let outcome: JobOutcome
    let thumbnails: ThumbnailCache

    var body: some View {
        HStack(spacing: 12) {
            JobThumbnail(url: outcome.output, thumbnails: thumbnails)
            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.output.lastPathComponent)
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
            }
            Spacer()
            ReportBadge(outcome: outcome)
            ShowInFinderButton(url: outcome.output)
        }
        .padding(.vertical, 2)
    }
}

/// Videos left untouched, with the reason.
struct KeptAsIsView: View {
    let model: AppModel

    var body: some View {
        let rows = model.keptAsIsJobs
        Group {
            if rows.isEmpty {
                SidebarDestination.keptAsIs.emptyState
            } else {
                List(rows, id: \.job.id) { row in
                    ReasonRow(job: row.job, reason: row.reason, thumbnails: model.thumbnails)
                }
            }
        }
        .navigationTitle("Kept as is")
    }
}

/// Conversions that couldn't finish, with Retry and Retry all.
struct FailedView: View {
    let model: AppModel

    var body: some View {
        let rows = model.failedJobs
        Group {
            if rows.isEmpty {
                SidebarDestination.failed.emptyState
            } else {
                List(rows, id: \.job.id) { row in
                    ReasonRow(job: row.job, reason: row.reason, thumbnails: model.thumbnails) {
                        Button("Retry") { model.retry(row.job) }
                            .accessibilityLabel("Retry \(row.job.displayName)")
                    }
                }
            }
        }
        .navigationTitle("Failed")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Retry all", systemImage: "arrow.clockwise") { model.retryAllFailed() }
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
            actions
            ShowInFinderButton(url: job.source)
        }
        .padding(.vertical, 2)
    }
}

extension ReasonRow where Actions == EmptyView {
    init(job: Job, reason: String, thumbnails: ThumbnailCache) {
        self.init(job: job, reason: reason, thumbnails: thumbnails) { EmptyView() }
    }
}
