#if os(macOS)
    import AppUI
    import Convert
    import LocalLibrary
    import SwiftUI

    /// Native compression preset sheet for the selected Local Files or Photos videos.
    struct CompressSheet: View {
        @Bindable var model: ConvertModel

        private var localItems: [VideoItem] { model.isPhotosPage ? [] : model.queueableItems }
        private var photoItems: [VideoItem] { model.isPhotosPage ? model.selectedPhotoItems : [] }
        private var itemCount: Int { model.isPhotosPage ? photoItems.count : localItems.count }

        private var title: String {
            itemCount == 1 ? "Compress Video" : "Compress \(itemCount) Videos"
        }

        private var totalBytes: Int64 {
            let items = model.isPhotosPage ? photoItems : localItems
            return items.reduce(0) { $0 + $1.byteSize }
        }

        private var destinationText: String {
            if model.isPhotosPage {
                switch model.photosSaveLocation.choice {
                case .newAsset: return "Photos, as a new video"
                case .replace: return "Replace Original in Photos"
                case .folder: return model.photosSaveLocation.folder?.lastPathComponent ?? "Folder"
                }
            }
            switch model.saveLocation.choice {
            case .nextToOriginal: return "Next to Original"
            case .replace: return "Replace Original"
            case .folder: return model.saveLocation.folder?.lastPathComponent ?? "Folder"
            }
        }

        private var selectedDetail: String {
            if !model.isPhotosPage, localItems.count == 1 {
                let item = localItems[0]
                let estimates = SavingsCalculator.compressEstimates(
                    byteSize: item.byteSize, inventory: item.inventory)
                if let match = estimates.first(where: { $0.preset == model.compressPreset }),
                    case .keptAsIs(let reason, _) = match.decision
                {
                    return "\(model.compressPreset.detail) Currently: \(reason.lowercased())."
                }
            }
            return model.compressPreset.detail
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text("Keeps resolution, frame rate, HDR, and all metadata.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Form {
                    Section {
                        if totalBytes > 0 {
                            LabeledContent("Original", value: ByteFormat.string(totalBytes))
                        }
                        Picker("Quality", selection: $model.compressPreset) {
                            ForEach(CompressPreset.allCases) { preset in
                                optionRow(for: preset)
                                    .tag(preset)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    } footer: {
                        Text(selectedDetail)
                    }

                    Section {
                        LabeledContent("Save to", value: destinationText)
                    } footer: {
                        if model.isPhotosPage {
                            Text("Details and exact savings are checked when each video is converted.")
                        }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.isCompressPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Compress", action: model.confirmCompress)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAddSelectionToQueue)
                        .help("Add the selected videos to the queue to compress")
                }
            }
            .scenePadding()
            .presentationSizing(.form)
        }

        @ViewBuilder
        private func optionRow(for preset: CompressPreset) -> some View {
            let detail = estimateText(for: preset)
            Text("\(preset.displayName)  \(Text(detail).foregroundStyle(.secondary))")
                .monospacedDigit()
                .help(preset.detail)
                .accessibilityLabel("\(preset.displayName), \(detail). \(preset.detail)")
        }

        private func estimateText(for preset: CompressPreset) -> String {
            if model.isPhotosPage {
                return preset.approximateSavingText
            }
            if localItems.count == 1 {
                let item = localItems[0]
                let estimate = SavingsCalculator.compressEstimates(byteSize: item.byteSize, inventory: item.inventory)
                    .first { $0.preset == preset }
                guard let bytes = estimate?.estimatedBytes else { return "Kept as is" }
                let size = "≈ \(ByteFormat.string(bytes))"
                guard let saved = ByteFormat.savedPercent(before: item.byteSize, after: bytes) else { return size }
                return "\(size) (\(saved))"
            }
            let freed = SavingsCalculator.couldFreeBytes(
                for: localItems.map(\.savingsSource), compressPreset: preset)
            return freed > 0 ? "Could free about \(ByteFormat.string(freed))" : "Already small"
        }
    }
#endif
