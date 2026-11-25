import AppCore
import AppUI
import LocalLibrary
import SwiftUI

/// Videos waiting or converting, in order.
struct QueueView: View {
    let model: AppModel

    var body: some View {
        let jobs = model.queuedJobs
        Group {
            if jobs.isEmpty {
                SidebarDestination.queue.emptyState
            } else {
                List {
                    ForEach(jobs) { job in
                        QueueRow(job: job, isPaused: model.isQueuePaused, thumbnails: model.thumbnails) {
                            model.remove(job)
                        }
                    }
                }
            }
        }
        .navigationTitle("Queue")
        .navigationSubtitle(model.isQueuePaused && !jobs.isEmpty ? "Paused" : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { PauseResumeButton(model: model) }
        }
    }
}

private struct QueueRow: View {
    let job: Job
    let isPaused: Bool
    let thumbnails: ThumbnailCache
    let remove: () -> Void

    private var progress: Double? {
        if case .running(let progress) = job.state { return progress }
        return nil
    }

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
            if progress == nil {
                Button("Remove from queue", systemImage: "xmark.circle.fill", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from queue")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.displayName), \(stateText)")
        .contextMenu {
            if progress == nil { Button("Remove from queue", action: remove) }
        }
    }
}
