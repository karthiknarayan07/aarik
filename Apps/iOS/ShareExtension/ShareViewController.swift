import AppCore
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Stages shared videos into the App Group container by streaming copies, posts a local notification, and instructs
/// the user to open the app. Extensions never encode.
final class ShareViewController: UIViewController {
    private let model = ShareStagingModel()
    private var stagingTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(
            rootView: ShareView(
                model: model,
                onCancel: { [weak self] in self?.cancel() },
                onDone: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        stagingTask = Task { [weak self] in
            await self?.model.stage(items: items)
        }
    }

    private func cancel() {
        stagingTask?.cancel()
        model.cleanupStagedCopies()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareStagingModel {
    enum Phase: Equatable {
        case staging(completed: Int, total: Int)
        case ready(staged: Int, skippedNonVideos: Int, failed: Int)
        case empty(skippedNonVideos: Int)
        case failed(String)
    }

    var phase: Phase = .staging(completed: 0, total: 0)
    var currentFileProgress: Progress?

    private var stagedStore: StagedInputs?
    private var stagedURLs: [URL] = []

    func stage(items: [NSExtensionItem]) async {
        guard let store = StagedInputs.appGroup(in: .main) else {
            phase = .failed("Shared container is unavailable.")
            return
        }
        stagedStore = store

        var mediaProviders: [(provider: NSItemProvider, typeIdentifier: String)] = []
        var skippedNonMedia = 0
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    mediaProviders.append((provider, UTType.movie.identifier))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    mediaProviders.append((provider, UTType.image.identifier))
                } else {
                    skippedNonMedia += 1
                }
            }
        }

        guard !mediaProviders.isEmpty else {
            phase = .empty(skippedNonVideos: skippedNonMedia)
            return
        }

        let total = mediaProviders.count
        var failed = 0
        phase = .staging(completed: 0, total: total)

        for (index, entry) in mediaProviders.enumerated() {
            if Task.isCancelled {
                cleanupStagedCopies()
                return
            }
            if let url = await stageProvider(entry.provider, typeIdentifier: entry.typeIdentifier, into: store) {
                stagedURLs.append(url)
            } else {
                failed += 1
            }
            phase = .staging(completed: index + 1, total: total)
        }

        if Task.isCancelled {
            cleanupStagedCopies()
            return
        }

        currentFileProgress = nil

        if stagedURLs.isEmpty {
            if skippedNonMedia > 0, failed == 0 {
                phase = .empty(skippedNonVideos: skippedNonMedia)
            } else {
                phase = .failed("The selected files couldn't be copied.")
            }
            return
        }

        await postReadyNotification(stagedCount: stagedURLs.count, skippedNonVideos: skippedNonMedia)
        phase = .ready(staged: stagedURLs.count, skippedNonVideos: skippedNonMedia, failed: failed)
    }

    func cleanupStagedCopies() {
        guard let store = stagedStore else { return }
        for url in stagedURLs { store.remove(url) }
        stagedURLs.removeAll()
    }

    private func stageProvider(
        _ provider: NSItemProvider, typeIdentifier: String, into store: StagedInputs
    ) async -> URL? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            let progress = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let filename = Self.resolvedFilename(suggestedName: suggestedName, sourceURL: url)
                do {
                    let staged = try store.stage(copying: url, name: filename)
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
            currentFileProgress = progress
        }
    }

    private nonisolated static func resolvedFilename(suggestedName: String?, sourceURL: URL) -> String {
        guard let suggestedName, !suggestedName.isEmpty else { return sourceURL.lastPathComponent }
        let ext = sourceURL.pathExtension
        if (suggestedName as NSString).pathExtension.isEmpty, !ext.isEmpty {
            return "\(suggestedName).\(ext)"
        }
        return suggestedName
    }

    private func postReadyNotification(stagedCount: Int, skippedNonVideos: Int) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let appName = AppInfo.displayName
        let itemLabel = stagedCount == 1 ? "1 Item" : "\(stagedCount) Items"
        let content = UNMutableNotificationContent()
        content.title = "Open \(appName) to Convert \(itemLabel)"
        if skippedNonVideos > 0 {
            let skippedLabel =
                skippedNonVideos == 1
                ? "1 unsupported item was skipped." : "\(skippedNonVideos) unsupported items were skipped."
            content.body = skippedLabel
        } else {
            content.body = "Tap to open \(appName) and convert."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "staged-\(UUID().uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }
}

struct ShareView: View {
    let model: ShareStagingModel
    let onCancel: () -> Void
    let onDone: () -> Void

    private var appName: String { AppInfo.displayName }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .staging(let completed, let total):
                    VStack(spacing: 16) {
                        if let progress = model.currentFileProgress {
                            ProgressView(progress)
                                .progressViewStyle(.linear)
                                .padding(.horizontal, 32)
                        } else {
                            ProgressView()
                        }
                        Text(
                            total > 1 ? "Preparing File \(min(completed + 1, total)) of \(total)…" : "Preparing File…"
                        )
                        .font(.headline)
                        Text("Copying to \(appName)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                case .ready(let staged, let skippedNonVideos, let failed):
                    ContentUnavailableView(
                        "Open \(appName)",
                        systemImage: "checkmark.circle.fill",
                        description: Text(readyDescription(staged: staged, skipped: skippedNonVideos, failed: failed))
                    )
                case .empty(let skippedNonVideos):
                    ContentUnavailableView(
                        "No Supported Files",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(emptyDescription(skipped: skippedNonVideos))
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't Add Files",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .staging = model.phase {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
        .accessibilityIdentifier("shareRoot")
    }

    private func readyDescription(staged: Int, skipped: Int, failed: Int) -> String {
        let itemLabel = staged == 1 ? "1 file" : "\(staged) files"
        var parts = ["Open \(appName) to convert \(itemLabel)."]
        if skipped > 0 {
            parts.append(
                skipped == 1 ? "1 unsupported item was skipped." : "\(skipped) unsupported items were skipped.")
        }
        if failed > 0 {
            parts.append(failed == 1 ? "1 file couldn't be copied." : "\(failed) files couldn't be copied.")
        }
        return parts.joined(separator: " ")
    }

    private func emptyDescription(skipped: Int) -> String {
        if skipped > 0 {
            return skipped == 1
                ? "Skipped 1 unsupported item. Only videos and images can be converted."
                : "Skipped \(skipped) unsupported items. Only videos and images can be converted."
        }
        return "No supported files were shared."
    }
}
