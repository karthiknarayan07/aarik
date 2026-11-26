import AppCore
import Convert
import SwiftUI
import UniformTypeIdentifiers

/// Next to original (macOS) or Documents (iOS), a chosen folder, or replace the original (macOS only).
struct SaveDestinationPicker: View {
    @Binding var location: SaveLocation
    @State private var isChoosingFolder = false

    private var choice: Binding<SaveLocation.Choice> {
        Binding {
            location.choice
        } set: { newValue in
            if newValue == .folder, location.folderBookmark == nil {
                isChoosingFolder = true
            } else {
                location.choice = newValue
            }
        }
    }

    var body: some View {
        Picker("Save To", selection: choice) {
            ForEach(SaveLocation.availableChoices()) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel("Save To")
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? location.setFolder(url)
        }
        if location.choice == .folder {
            FolderStatusRow(
                folder: location.folder, buttonTitle: "Change…",
                accessibilityLabel: "Change the output folder"
            ) {
                isChoosingFolder = true
            }
        }
        if location.choice == .documents {
            Text(
                "Saved in Files under \(DeviceCopy.filesAppLocation). Replacing Files originals isn't available on iOS."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if location.choice == .replace {
            Text("The original goes to the Trash after the smaller copy is verified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension PhotosSaveLocation.Choice {
    /// Explanation shown under the Photos "Save to" picker on Mac and iOS.
    var footerNote: String {
        let orderNote =
            "Saved copies keep their capture date and albums; sort Photos by Date Captured to see them in their "
            + "original spot."
        switch self {
        case .replace:
            return "Each video is downloaded from iCloud when its turn comes. When the queue finishes, Photos asks "
                + "you to move the originals to Recently Deleted. \(orderNote)"
        case .newAsset:
            return "Each video is downloaded from iCloud when its turn comes. Your original stays in Photos. "
                + orderNote
        case .folder:
            return "Each video is downloaded from iCloud when its turn comes. Your original stays in Photos."
        }
    }
}

/// Shows the picked folder (or an unavailable recovery prompt when its bookmark failed to resolve) next to a
/// Choose / Change button.
struct FolderStatusRow: View {
    let folder: URL?
    let buttonTitle: String
    let accessibilityLabel: String
    let choose: () -> Void

    var body: some View {
        HStack {
            if let folder {
                Label(folder.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            } else {
                Label("Folder unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(folder == nil ? "Choose Folder…" : buttonTitle, action: choose)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}
