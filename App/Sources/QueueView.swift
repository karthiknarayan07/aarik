import AppCore
import AppUI
import LocalLibrary
import SwiftUI

/// Videos waiting or converting, in order.
struct QueueView: View {
    let model: AppModel
    @State private var isConfirmingCancelAll = false

    var body: some View {
        let jobs = model.queuedJobs
        Group {
            if jobs.isEmpty {
                SidebarDestination.queue.emptyState
                    .action("Go to Local files") { model.selection = .localFiles }
            } else {
                List {
                    ForEach(jobs) { job in
                        QueueRow(job: job, isPaused: model.isQueuePaused, thumbnails: model.thumbnails) {
                            model.cancel(job)
                        }
                    }
                }
            }
        }
        .navigationTitle("Queue")
        .navigationSubtitle(model.isQueuePaused && !jobs.isEmpty ? "Paused" : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { PauseResumeButton(model: model) }
            ToolbarItem(placement: .primaryAction) {
                Button("Cancel all", systemImage: "xmark.circle") { isConfirmingCancelAll = true }
                    .disabled(jobs.isEmpty)
                    .help("Empty the queue and stop the current conversion")
            }
        }
        .confirmationDialog("Cancel all conversions?", isPresented: $isConfirmingCancelAll) {
            Button("Cancel all", role: .destructive) { model.cancelAll() }
            Button("Keep converting", role: .cancel) {}
        } message: {
            Text("Waiting videos leave the queue and the current conversion stops. Originals aren't touched.")
        }
    }
}

private struct QueueRow: View {
    let job: Job
    let isPaused: Bool
    let thumbnails: ThumbnailCache
    /// Removes a waiting job, or stops the one converting.
    let cancel: () -> Void

    private var progress: Double? {
        if case .running(let progress) = job.state { return progress }
        return nil
    }

    private var cancelTitle: String { progress == nil ? "Remove from queue" : "Cancel conversion" }

    private var stateText: String {
        if let progress { return "Converting · \(Int((progress * 100).rounded()))%" }
        return isPaused ? "Paused" : "Waiting"
    }

    var body: some View {
        HStack(spacing: 12) {
            JobThumbnail(url: job.source, thumbnails: thumbnails)
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
            Button(cancelTitle, systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(cancelTitle)
                .accessibilityLabel("\(cancelTitle): \(job.displayName)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.displayName), \(stateText)")
        .contextMenu {
            Button(cancelTitle, action: cancel)
        }
    }
}
