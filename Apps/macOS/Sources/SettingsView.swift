import AppCore
import AppKit
import AppUI
import Convert
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: General and Output.
struct SettingsView: View {
    let shell: MacShell
    let updater: Updater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(shell: shell, updater: updater) }
            Tab("Output", systemImage: "square.and.arrow.down") { OutputSettings(shell: shell) }
        }
        .frame(minWidth: 450)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    let shell: MacShell
    @Bindable var updater: Updater
    @AppStorage(AppSettings.Keys.preset) private var preset = Preset.balanced
    @AppStorage(AppSettings.Keys.autoStartQueue) private var autoStart = true
    @AppStorage(AppSettings.Keys.speed) private var speed = SpeedSetting.default

    var body: some View {
        Form {
            Picker("Default Preset", selection: $preset) {
                ForEach(Preset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle(isOn: $autoStart) {
                Text("Start the Queue Automatically")
                Text("When off, the queue waits until you press Resume.")
            }
            Section {
                Picker("Conversion Speed", selection: $speed) {
                    ForEach(SpeedSetting.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Conversion Speed")
                .accessibilityHint(speed.summary)
            } header: {
                Text("Performance")
            } footer: {
                // What the selected option does, drawn by the grouped form like System Settings' explanatory text.
                Text(speed.summary)
            }
            Section("Updates") {
                if updater.isConfigured {
                    Toggle("Check for Updates Automatically", isOn: $updater.automaticallyChecksForUpdates)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
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
            if shell.convert.preset != newValue { shell.convert.preset = newValue }
        }
        .onChange(of: speed) { _, newValue in
            if shell.services.speed != newValue { shell.services.speed = newValue }
        }
    }
}

private struct OutputSettings: View {
    let shell: MacShell
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
                Picker("Save Converted Videos", selection: saveToChoice) {
                    Text(SaveLocation.Choice.nextToOriginal.title).tag(SaveLocation.Choice.nextToOriginal)
                    Text(SaveLocation.Choice.folder.title).tag(SaveLocation.Choice.folder)
                }
                if saveTo == .folder, let folder = saveFolder.flatMap(AppSettings.resolve) {
                    FolderRow(folder: folder, accessibilityName: "output folder") { chooseFolder(for: .output) }
                }
            }
            Section {
                Toggle(isOn: $keepOriginals) {
                    Text("Keep a Copy of Originals")
                    Text(
                        "Before Replace moves an original to the Trash, a copy is saved here. Nothing in the folder is "
                            + "overwritten.")
                }
                if keepOriginals {
                    FolderRow(folder: originalsFolder, accessibilityName: "originals folder") {
                        chooseFolder(for: .originals)
                    }
                    if !FileManager.default.fileExists(atPath: originalsFolder.path) {
                        StatusLabel(
                            "The folder is missing. Replace keeps originals until it's back.",
                            systemImage: "exclamationmark.triangle", tint: .orange)
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
            if isOn { AppSettings.prepareOriginalsFolder(shell.services.defaults) }
        }
        .onChange(of: saveTo) { shell.convert.applyDefaultSaveLocation() }
        .onChange(of: saveFolder) { shell.convert.applyDefaultSaveLocation() }
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
        LabeledContent("Folder") {
            HStack {
                Text(folder.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(folder.path)
                Button("Choose…", action: change)
                    .accessibilityLabel("Choose the \(accessibilityName)")
            }
        }
    }
}
