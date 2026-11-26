import AppCore
import AppKit
import ConvertUI
import QuickRunService
import SwiftUI
import UniformTypeIdentifiers

/// The status item's popover: the current job, the queue, and a place to drop videos. Standard controls and
/// semantic colors only, so it follows the system's look.
struct MenuBarPanel: View {
    let shell: MacShell
    let close: () -> Void
    @State private var isDropTargeted = false

    private var runningJob: (job: Job, progress: Double)? {
        for job in shell.services.jobs {
            if case .running(let progress) = job.state { return (job, progress) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(AppInfo.displayName)
            } icon: {
                let icon = StatusIconState(shell.services.activity, isPaused: shell.services.queuePause.isPaused)
                if let value = icon.variableValue {
                    Image(systemName: icon.symbolName, variableValue: value)
                } else {
                    Image(systemName: icon.symbolName)
                }
            }
            .font(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppInfo.displayName)
            .accessibilityValue(
                StatusIconState(shell.services.activity, isPaused: shell.services.queuePause.isPaused)
                    .accessibilityStatus
            )
            .accessibilityAddTraits(.isHeader)
            currentJob
            runStatus
            Divider()
            HStack {
                Button(shell.services.isQueuePaused ? "Resume Queue" : "Pause Queue") {
                    shell.services.toggleQueuePaused()
                }
                .disabled(shell.services.activity.isIdle && !shell.services.isQueuePaused)
                .accessibilityHint("Pauses or resumes converting videos in the queue")
                Spacer()
                Button("Open Main Window") {
                    close()
                    shell.showMainWindow()
                }
                .accessibilityHint("Shows the main window")
            }
            dropZone
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AppInfo.displayName) menu bar")
        .onDrop(of: [.fileURL], delegate: PopoverDropDelegate(shell: shell, isTargeted: $isDropTargeted))
    }

    /// The runs started from the menu bar: what they are doing, then how they ended in one tally, with the skipped
    /// files one click away. A drop with nothing to shrink says so for a few seconds.
    @ViewBuilder private var runStatus: some View {
        let board = shell.menuBarRuns
        if !board.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(board.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
                if let notice = board.notice {
                    Text(notice.text)
                        .foregroundStyle(.secondary)
                }
                if !board.reviewRunIDs.isEmpty {
                    Button("Show Skipped…") {
                        close()
                        let runs = board.reviewRunIDs
                        Task { await shell.reviewQuickRuns(runs) }
                    }
                    .accessibilityHint("Opens the main window with the skipped videos selected")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick run status")
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
                if let paused = shell.services.queuePause.statusText {
                    Text(paused)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(idleText)
                .foregroundStyle(.secondary)
        }
    }

    private func runningDetail(_ job: Job, progress: Double) -> String {
        let waiting = max(shell.services.activity.queue - 1, 0)
        let percent = "\(Int((progress * 100).rounded())) percent"
        let head = job.phase.map { "\($0) \(percent)" } ?? percent
        return waiting > 0 ? "\(head), \(waiting) waiting" : head
    }

    private var idleText: String {
        let waiting = shell.services.activity.queue
        if waiting == 0 { return "Nothing in the queue." }
        guard let paused = shell.services.queuePause.statusText else { return "\(waiting) waiting." }
        // The user's pause keeps its wording; an automatic one says why.
        return shell.services.isQueuePaused ? "Queue paused, \(waiting) waiting." : "\(paused), \(waiting) waiting."
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
                    .accessibilityHint("Opens a window to choose videos to convert, instead of dropping them here")
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop videos here to convert them")
        .accessibilityHint("Drag video files onto this area, or use Choose Videos")
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
            Task { @MainActor in shell.runFromMenuBar(urls) }
        }
    }
}

/// The popover's drop target. Like the status icon it refuses a drag that names a type other than a movie (a folder,
/// an image), judged from the types the drag advertises, so no file is read while the pointer moves. The files
/// themselves are checked before the run starts.
private struct PopoverDropDelegate: DropDelegate {
    let shell: MacShell
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        MovieDropFilter.providersMightHoldMovie(
            info.itemProviders(for: [.fileURL]).map(\.registeredTypeIdentifiers))
    }

    func dropEntered(info: DropInfo) { isTargeted = true }

    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { shell.runFromMenuBar(urls) }
        }
        return true
    }
}
