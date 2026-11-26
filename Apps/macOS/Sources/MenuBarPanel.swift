import AppCore
import AppUI
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var runningJobs: [(job: Job, progress: Double)] {
        shell.services.jobs.compactMap { job in
            if case .running(let progress) = job.state { return (job, progress) }
            return nil
        }
    }

    private var modules: MenuBarModules {
        MenuBarModules(activity: shell.services.activity, isPaused: shell.services.queuePause.isPaused)
    }

    var body: some View {
        let modules = modules
        VStack(alignment: .leading, spacing: 10) {
            header
            MenuBarStatusModules(
                modules: modules, currentName: runningJobs.first?.job.displayName,
                currentPhase: runningJobs.first?.job.phase, pauseText: shell.services.queuePause.statusText,
                spokenStatus: spokenStatus, togglePause: { shell.services.toggleQueuePaused() })
            runStatus
            MenuBarDropModule(isTargeted: isDropTargeted, choose: chooseVideos)
            Button {
                close()
                shell.showMainWindow()
            } label: {
                Label("Open Main Window", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .controlModule()
            .accessibilityHint("Shows the main window")
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AppInfo.displayName) menu bar")
        .onDrop(of: [.fileURL], delegate: PopoverDropDelegate(shell: shell, isTargeted: $isDropTargeted))
    }

    private var header: some View {
        let icon = StatusIconState(shell.services.activity, isPaused: shell.services.queuePause.isPaused)
        return Label {
            Text(AppInfo.displayName)
        } icon: {
            Group {
                if let value = icon.variableValue {
                    Image(systemName: icon.symbolName, variableValue: value)
                } else {
                    Image(systemName: icon.symbolName)
                }
            }
            // The symbol bounces once each time a video finishes.
            .symbolEffect(
                .bounce, options: .nonRepeating,
                value: Motion.bounceTrigger(shell.services.activity.completed, reduceMotion: reduceMotion))
        }
        .font(.headline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppInfo.displayName)
        .accessibilityValue(icon.accessibilityStatus)
        .accessibilityAddTraits(.isHeader)
    }

    private var spokenStatus: String {
        let running = runningJobs
        guard !running.isEmpty else { return idleText }
        return running.map { "\($0.job.displayName), \(runningDetail($0.job, progress: $0.progress))" }
            .joined(separator: "; ")
    }

    /// The runs started from the menu bar: what they are doing, then how they ended in one tally, with the skipped
    /// files one click away. A drop with nothing to shrink says so for a few seconds.
    @ViewBuilder private var runStatus: some View {
        let board = shell.menuBarRuns
        if !board.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(board.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let notice = board.notice {
                    Text(notice.text)
                        .font(.callout)
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

    private func runningDetail(_ job: Job, progress: Double) -> String {
        let percent = "\(Int((progress * 100).rounded())) percent"
        return job.phase.map { "\($0) \(percent)" } ?? percent
    }

    private var idleText: String {
        let waiting = shell.services.activity.queue
        if waiting == 0 { return "Nothing in the queue." }
        guard let paused = shell.services.queuePause.statusText else { return "\(waiting) waiting." }
        // The user's pause keeps its wording; an automatic one says why.
        return shell.services.isQueuePaused ? "Queue paused, \(waiting) waiting." : "\(paused), \(waiting) waiting."
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
