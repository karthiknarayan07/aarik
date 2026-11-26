import Convert
import AppCore
import AppUI
import LocalLibrary
import SwiftUI

extension View {
    /// What every Activity list does with its selection, from `JobListActions`: a context menu on the selected
    /// rows, double-click and Return for the primary action, and Delete.
    func jobListActions(model: ConvertModel, kind: JobListKind, selection: Set<UUID>) -> some View {
        contextMenu(forSelectionType: UUID.self) { ids in
            ForEach(model.contextMenu(for: ids, in: kind), id: \.action) { command in
                Button(command.title) { model.perform(command.action, on: ids, in: kind) }
            }
        } primaryAction: { ids in
            model.performPrimaryAction(on: ids, in: kind)
        }
        .onDeleteCommand { model.performDelete(on: selection, in: kind) }
    }
}

/// Videos waiting or converting, in order.
struct QueueView: View {
    let model: ConvertModel
    @State private var isConfirmingCancelAll = false
    @State private var selection = Set<UUID>()

    var body: some View {
        let jobs = model.queuedJobs
        Group {
            if jobs.isEmpty {
                VideoPage.queue.emptyState
                    .action("Go to Local Files") { model.selection = .localFiles }
            } else {
                List(selection: $selection) {
                    ForEach(jobs) { job in
                        QueueRow(
                            job: job, pauseText: model.queuePause.statusText, thumbnails: model.thumbnailSource.cache
                        ) {
                            model.cancel(job)
                        }
                    }
                }
                .jobListActions(model: model, kind: .queue, selection: selection)
            }
        }
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
    }
}

private struct QueueRow: View {
    let job: Job
    /// "Paused", or why the queue stopped itself; nil while it runs.
    let pauseText: String?
    let thumbnails: ThumbnailCache
    /// Stops the one converting. A waiting video is removed with Delete or the context menu.
    let cancel: () -> Void

    private var progress: Double? {
        if case .running(let progress) = job.state { return progress }
        return nil
    }

    private var stateText: String {
        // A phase of its own (a download from iCloud) names itself and counts its own progress.
        if let progress { return "\(job.phase ?? "Converting") · \(Int((progress * 100).rounded()))%" }
        return pauseText ?? "Waiting"
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
            // Only the running video has a button, like Safari's stop button on a download.
            if progress != nil {
                Button("Cancel Conversion", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel Conversion")
                    .accessibilityLabel("Cancel conversion: \(job.displayName)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.displayName), \(stateText)")
    }
}
