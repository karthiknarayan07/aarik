import AppCore
import AppUI
import CoreGraphics
import Convert
import LocalLibrary
import SwiftUI

extension Job {
    /// The file's name; a Photos video's file name in Photos (its source is an address, not a file).
    public var displayName: String {
        guard isPhotosJob else { return source.lastPathComponent }
        return downscaleSettings?.photosFileName ?? "Video in Photos"
    }

    var isPhotosJob: Bool { toolID == ConvertTool.photosToolID }

    private var downscaleSettings: ConvertJobSettings? {
        guard toolID == ConvertTool.toolID || isPhotosJob else { return nil }
        return try? JSONDecoder().decode(ConvertJobSettings.self, from: settings)
    }

    /// "Balanced", "Custom", or "Compress · Balanced"; nil for a job of another tool.
    var presetLabel: String? {
        downscaleSettings.map { settings in
            switch settings.kind {
            case .shrink: settings.custom == nil ? settings.preset.displayName : "Custom"
            case .compress(let preset): "Compress · \(preset.displayName)"
            }
        }
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
            StatusLabel(
                title, systemImage: lost.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                tint: lost.isEmpty ? .secondary : .orange)
        }
        .buttonStyle(.borderless)
        .disabled(lost.isEmpty)
        .help(lost.isEmpty ? "All metadata is kept" : "Show what will be lost")
        .accessibilityLabel(lost.isEmpty ? "All metadata kept" : "\(title). Show what will be lost")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lost, id: \.self) { name in
                    StatusLabel("\(name) is lost", systemImage: "exclamationmark.triangle", tint: .orange)
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
        // A Photos address isn't a file: it gets the generic icon.
        .task(id: url) {
            guard url.isFileURL else { return image = nil }
            image = await thumbnails.thumbnail(for: url, maxPixel: 96)
        }
    }
}

/// Pause or resume the queue (⌥⌘P lives on the Queue menu item).
struct PauseResumeButton: View {
    let model: ConvertModel

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
        .help(model.isQueuePaused ? "Resume the queue (⌥⌘P)" : "Pause after the current video (⌥⌘P)")
    }
}
