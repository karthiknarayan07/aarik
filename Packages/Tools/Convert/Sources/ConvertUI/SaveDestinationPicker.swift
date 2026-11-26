import Convert
import SwiftUI
import UniformTypeIdentifiers

/// Next to original, a chosen folder, or replace the original.
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
        Picker("Save to", selection: choice) {
            ForEach(SaveLocation.Choice.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel("Save to")
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? location.setFolder(url)
        }
        if location.choice == .folder, let folder = location.folder {
            HStack {
                Label(folder.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                Spacer()
                Button("Change…") { isChoosingFolder = true }
                    .accessibilityLabel("Change the output folder")
            }
        }
        if location.choice == .replace {
            Text("The original goes to the Trash after the smaller copy is verified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
