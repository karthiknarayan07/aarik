import AppUI
import DownscaleVideo
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: General and Output.
struct SettingsView: View {
    let model: AppModel
    let updater: Updater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model, updater: updater) }
            Tab("Output", systemImage: "square.and.arrow.down") { OutputSettings(model: model) }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @Bindable var updater: Updater
    @AppStorage(AppSettings.Keys.preset) private var preset = Preset.balanced
    @AppStorage(AppSettings.Keys.autoStartQueue) private var autoStart = true

    var body: some View {
        Form {
            Picker("Default preset", selection: $preset) {
                ForEach(Preset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle(isOn: $autoStart) {
                Text("Start the queue automatically")
                Text("When off, the queue waits until you press Resume.")
            }
            Section("Updates") {
                if updater.isConfigured {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                    LabeledContent("Look for a new version now") {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                } else {
                    Text("Updates are off in development builds.")
                        .foregroundStyle(.secondary)
                }
            }
            FinderQuickActionSection()
            QuickRunSettingsSections()
        }
        .formStyle(.grouped)
        // The inspector's preset is this same stored value; keep the open window in step.
        .onChange(of: preset) { _, newValue in
            if model.preset != newValue { model.preset = newValue }
        }
    }
}

private struct OutputSettings: View {
    let model: AppModel
    @AppStorage(AppSettings.Keys.defaultSaveTo) private var saveTo = SaveLocation.Choice.nextToOriginal
    @AppStorage(AppSettings.Keys.defaultSaveFolder) private var saveFolder: Data?
    @AppStorage(AppSettings.Keys.keepOriginals) private var keepOriginals = false
    @AppStorage(AppSettings.Keys.originalsFolder) private var originalsPath = ""
    @State private var isChoosingFolder = false
    /// Which folder the open panel picks; kept after the panel closes so its result still knows.
    @State private var folderTarget = FolderTarget.output

    private enum FolderTarget { case output, originals }

    private func chooseFolder(for target: FolderTarget) {
        folderTarget = target
        isChoosingFolder = true
    }

    private var saveToChoice: Binding<SaveLocation.Choice> {
        Binding {
            saveTo
        } set: { newValue in
            if newValue == .folder, saveFolder == nil { chooseFolder(for: .output) } else { saveTo = newValue }
        }
    }

    private var originalsFolder: URL {
        originalsPath.isEmpty ? AppSettings.defaultOriginalsFolder : URL(filePath: originalsPath)
    }

    var body: some View {
        Form {
            Section {
                Picker("Save converted videos", selection: saveToChoice) {
                    Text(SaveLocation.Choice.nextToOriginal.title).tag(SaveLocation.Choice.nextToOriginal)
                    Text(SaveLocation.Choice.folder.title).tag(SaveLocation.Choice.folder)
                }
                if saveTo == .folder, let folder = saveFolder.flatMap(AppSettings.resolve) {
                    FolderRow(folder: folder, accessibilityName: "output folder") { chooseFolder(for: .output) }
                }
            }
            Section {
                Toggle(isOn: $keepOriginals) {
                    Text("Keep a copy of originals")
                    Text(
                        "Before Replace moves an original to the Trash, a copy is saved here. Nothing in the folder is "
                            + "overwritten.")
                }
                if keepOriginals {
                    FolderRow(folder: originalsFolder, accessibilityName: "originals folder") {
                        chooseFolder(for: .originals)
                    }
                    if !FileManager.default.fileExists(atPath: originalsFolder.path) {
                        Label(
                            "The folder is missing. Replace keeps originals until it's back.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            chose(url)
        }
        .onChange(of: keepOriginals) { _, isOn in
            if isOn { AppSettings.prepareOriginalsFolder(.standard) }
        }
        .onChange(of: saveTo) { model.applyDefaultSaveLocation() }
        .onChange(of: saveFolder) { model.applyDefaultSaveLocation() }
    }

    private func chose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch folderTarget {
        case .output:
            var location = SaveLocation()
            guard (try? location.setFolder(url)) != nil else { return }
            saveFolder = location.folderBookmark
            saveTo = .folder
        case .originals:
            originalsPath = url.path
        }
    }
}

private struct FolderRow: View {
    let folder: URL
    let accessibilityName: String
    let change: () -> Void

    var body: some View {
        HStack {
            Label(folder.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
            Spacer()
            Button("Change…", action: change)
                .accessibilityLabel("Change the \(accessibilityName)")
        }
    }
}
