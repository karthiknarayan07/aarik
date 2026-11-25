import AppCore
import AppKit
import QuickRunService
import SwiftUI
import UniformTypeIdentifiers

/// The status item's popover: the current job, the queue, and a place to drop videos. Standard controls and
/// semantic colors only, so it follows the system's look.
struct MenuBarPanel: View {
    let model: AppModel
    let close: () -> Void
    @State private var isDropTargeted = false

    private var runningJob: (job: Job, progress: Double)? {
        for job in model.jobs {
            if case .running(let progress) = job.state { return (job, progress) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppModel.displayName, systemImage: "film.stack")
                .font(.headline)
            currentJob
            Divider()
            HStack {
                Button(model.isQueuePaused ? "Resume Queue" : "Pause Queue") { model.toggleQueuePaused() }
                    .disabled(model.activity.isIdle && !model.isQueuePaused)
                    .accessibilityHint("Pauses or resumes converting videos in the queue")
                Spacer()
                Button("Open Main Window") {
                    close()
                    model.showMainWindow()
                }
            }
            dropZone
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .dropDestination(for: URL.self) { urls, _ in
            let movies = MovieDropFilter.movies(in: urls)
            guard !movies.isEmpty else { return false }
            model.runQuickly(movies)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    @ViewBuilder private var currentJob: some View {
        if let running = runningJob {
            VStack(alignment: .leading, spacing: 6) {
                Text(running.job.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: running.progress)
                    .accessibilityLabel("Converting \(running.job.displayName)")
                Text(runningDetail(running.job, progress: running.progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(idleText)
                .foregroundStyle(.secondary)
        }
    }

    private func runningDetail(_ job: Job, progress: Double) -> String {
        let waiting = max(model.activity.queue - 1, 0)
        let percent = "\(Int((progress * 100).rounded())) percent"
        let head = job.phase.map { "\($0) \(percent)" } ?? percent
        return waiting > 0 ? "\(head), \(waiting) waiting" : head
    }

    private var idleText: String {
        let waiting = model.activity.queue
        if waiting == 0 { return "Nothing in the queue." }
        return model.isQueuePaused ? "Queue paused, \(waiting) waiting." : "\(waiting) waiting."
    }

    private var dropZone: some View {
        GroupBox {
            VStack(spacing: 8) {
                Label("Drop Videos Here", systemImage: "square.and.arrow.down")
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.primary)
                Text("Or drop them on the menu bar icon. They are converted without opening the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Videos…", action: chooseVideos)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop videos here to convert them")
    }

    /// The keyboard and VoiceOver way to do what the drop does.
    private func chooseVideos() {
        close()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose videos to convert."
        panel.prompt = "Convert"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in model.runQuickly(urls) }
        }
    }
}
