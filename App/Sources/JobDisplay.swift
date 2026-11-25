import AppCore
import AppKit
import CoreGraphics
import DownscaleVideo
import LocalLibrary
import SwiftUI

extension Job {
    var displayName: String { source.lastPathComponent }

    /// "Balanced", "Custom"; nil for a job of another tool.
    var presetLabel: String? {
        guard toolID == DownscaleTool.toolID,
            let settings = try? JSONDecoder().decode(DownscaleJobSettings.self, from: settings)
        else { return nil }
        return settings.custom == nil ? settings.preset.displayName : "Custom"
    }
}

/// A small poster frame for a job's file, or a generic icon when there is none.
struct JobThumbnail: View {
    let url: URL
    let thumbnails: ThumbnailCache
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 32)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) { image = await thumbnails.thumbnail(for: url, maxPixel: 96) }
    }
}

/// Reveals a file in Finder.
struct ShowInFinderButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Show in Finder")
        .accessibilityLabel("Show \(url.lastPathComponent) in Finder")
    }
}

/// Pause or resume the queue (⌘. lives on the Queue menu item).
struct PauseResumeButton: View {
    let model: AppModel

    var body: some View {
        Button {
            model.toggleQueuePaused()
        } label: {
            if model.isQueuePaused {
                Label("Resume", systemImage: "play.fill")
            } else {
                Label("Pause", systemImage: "pause.fill")
            }
        }
        .help(model.isQueuePaused ? "Resume the queue (⌘.)" : "Pause after the current video (⌘.)")
    }
}
