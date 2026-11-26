#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import MediaEngine
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    /// In-app Settings screen for iOS: Quality, Queue, Performance, Output (Documents or Folder) and Notifications.
    /// Mac-only options (Sparkle updates, Finder Quick Action, menu bar / Services, Trash backup) are omitted.
    public struct IOSSettingsView: View {
        @Bindable var model: ConvertModel
        @Environment(\.dismiss) private var dismiss

        @AppStorage(AppSettings.Keys.defaultResolution) private var resolution = AdvancedOptions.Resolution.p1080
        @AppStorage(AppSettings.Keys.defaultBitRateMbps) private var bitRateMbps = AdvancedOptions.suggestedHEVCMbps
        @AppStorage(AppSettings.Keys.defaultKeepOriginalBitRate) private var keepOriginalBitRate = false
        @AppStorage(AppSettings.Keys.defaultFrameRate) private var frameRate = AdvancedOptions.FrameRate.keep
        @AppStorage(AppSettings.Keys.defaultCodec) private var codec = VideoCodec.hevcKeepHDR
        @AppStorage(AppSettings.Keys.speed) private var speed = SpeedSetting.default
        @AppStorage(AppSettings.Keys.defaultSaveTo) private var saveTo = SaveLocation.defaultChoice(for: .iOS)
        @AppStorage(AppSettings.Keys.defaultSaveFolder) private var saveFolder: Data?
        @State private var isChoosingFolder = false

        public init(model: ConvertModel) {
            self.model = model
        }

        private var saveToChoice: Binding<SaveLocation.Choice> {
            Binding {
                saveTo == .folder ? .folder : .documents
            } set: { newValue in
                if newValue == .folder, saveFolder == nil {
                    isChoosingFolder = true
                } else {
                    saveTo = newValue
                }
            }
        }

        public var body: some View {
            NavigationStack {
                Form {
                    IOSQualitySections(
                        resolution: $resolution,
                        bitRateMbps: $bitRateMbps,
                        keepOriginalBitRate: $keepOriginalBitRate,
                        frameRate: $frameRate,
                        codec: $codec,
                        resolutionSectionTitle: "Default Resolution")
                    Section {
                        Picker("Conversion Speed", selection: $speed) {
                            ForEach(SpeedSetting.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } header: {
                        Text("Performance")
                    } footer: {
                        Text(speed.summary(on: DeviceCopy.deviceNoun, hasFan: false))
                    }
                    Section {
                        Picker("Save Converted Files", selection: saveToChoice) {
                            Text(SaveLocation.Choice.documents.title).tag(SaveLocation.Choice.documents)
                            Text(SaveLocation.Choice.folder.title).tag(SaveLocation.Choice.folder)
                        }
                        if saveTo == .folder, let folder = saveFolder.flatMap(AppSettings.resolve) {
                            LabeledContent("Folder") {
                                HStack {
                                    Text(folder.lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                    Button("Choose…") { isChoosingFolder = true }
                                }
                            }
                        }
                    } header: {
                        Text("Output")
                    } footer: {
                        Text(
                            "Files inputs save to \(DeviceCopy.filesAppLocation) unless you choose another folder. "
                                + "Replacing Files originals isn't available on iOS.")
                    }
                    Section {
                        Button("Open Settings…") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } header: {
                        Text("Permissions and Notifications")
                    } footer: {
                        Text("Choose Photos access and notification preferences in Settings.")
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    var location = SaveLocation(platform: .iOS)
                    guard (try? location.setFolder(url)) != nil else { return }
                    saveFolder = location.folderBookmark
                    saveTo = .folder
                }
                .onChange(of: resolution) { oldValue, newValue in
                    syncBitRateForResolutionChange(from: oldValue, to: newValue)
                    model.applyDefaultAdvancedOptions()
                }
                .onChange(of: codec) { oldValue, newValue in
                    syncBitRateForCodecChange(from: oldValue, to: newValue)
                    model.applyDefaultAdvancedOptions()
                }
                .onChange(of: bitRateMbps) { model.applyDefaultAdvancedOptions() }
                .onChange(of: keepOriginalBitRate) { model.applyDefaultAdvancedOptions() }
                .onChange(of: frameRate) { model.applyDefaultAdvancedOptions() }
                .onChange(of: speed) { _, newValue in
                    if model.services.speed != newValue { model.services.speed = newValue }
                }
                .onChange(of: saveTo) { model.applyDefaultSaveLocation() }
                .onChange(of: saveFolder) { model.applyDefaultSaveLocation() }
            }
        }

        private func syncBitRateForResolutionChange(
            from oldValue: AdvancedOptions.Resolution, to newValue: AdvancedOptions.Resolution
        ) {
            let previousSuggested = AdvancedOptions.suggestedMbps(for: oldValue, codec: codec)
            if bitRateMbps == previousSuggested {
                bitRateMbps = AdvancedOptions.suggestedMbps(for: newValue, codec: codec)
            }
        }

        private func syncBitRateForCodecChange(from oldValue: VideoCodec, to newValue: VideoCodec) {
            let previousSuggested = AdvancedOptions.suggestedMbps(for: resolution, codec: oldValue)
            if bitRateMbps == previousSuggested {
                bitRateMbps = AdvancedOptions.suggestedMbps(for: resolution, codec: newValue)
            }
        }
    }
#endif
