import AppCore
import AppKit
import CoreGraphics
import DownscaleVideo
import LocalLibrary
import SwiftUI

extension Job {
    var displayName: String { source.lastPathComponent }

    private var downscaleSettings: DownscaleJobSettings? {
        guard toolID == DownscaleTool.toolID else { return nil }
        return try? JSONDecoder().decode(DownscaleJobSettings.self, from: settings)
    }

    /// "Balanced", "Custom"; nil for a job of another tool.
    var presetLabel: String? {
        downscaleSettings.map { $0.custom == nil ? $0.preset.displayName : "Custom" }
    }

    /// What the job was predicted to lose when it was added; nil when unknown (an older job, another tool).
    var predictedLost: [String]? { downscaleSettings?.predictedLost }
}

/// **All kept** or **N will be lost** for a waiting job; click for what will be lost.
struct PredictedLossBadge: View {
    let lost: [String]
    @State private var isShowingDetails = false

    private var title: String { lost.isEmpty ? "All kept" : "\(lost.count) will be lost" }

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            Label(title, systemImage: lost.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(lost.isEmpty ? Color.secondary : Color.orange)
        }
        .buttonStyle(.borderless)
        .disabled(lost.isEmpty)
        .help(lost.isEmpty ? "All metadata is kept" : "Show what will be lost")
        .accessibilityLabel(lost.isEmpty ? "All metadata kept" : "\(title). Show what will be lost")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lost, id: \.self) { name in
                    Label("\(name) is lost", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .padding()
        }
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
