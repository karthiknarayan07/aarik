import AppKit
import SharedUI
import Observation
import SwiftUI

/// Keeps the Dock icon in step with the queue: a progress bar under the icon while a video converts, and a badge
/// with the number of videos waiting. What the icon shows is decided by `DockTileState`; this only draws it.
@MainActor
final class DockTileController {
    private let model: AppModel
    private var shown: DockTileState?
    private let hosting = NSHostingView(rootView: DockProgressView(progress: 0))

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        update()
        observe()
    }

    /// The current state, for the Dock menu.
    var state: DockTileState { DockTileState(jobs: model.jobs, name: \.displayName) }

    private func observe() {
        withObservationTracking {
            _ = model.jobs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let state = self.state
        guard state != shown else { return }
        shown = state
        let tile = NSApp.dockTile
        tile.badgeLabel = state.badge
        if let progress = state.progress {
            hosting.rootView = DockProgressView(progress: progress)
            hosting.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = hosting
        } else {
            // Back to the plain app icon, which the system draws with the badge.
            tile.contentView = nil
        }
        tile.display()
    }
}

/// The app icon with a bar along its bottom edge.
private struct DockProgressView: View {
    let progress: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }
}
