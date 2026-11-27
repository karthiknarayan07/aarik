#if os(macOS)
    import AppCore
    import AppUI
    import Convert
    import LocalLibrary
    import MediaEngine
    import SwiftUI
    import UniformTypeIdentifiers

    /// macOS Inspector section set for image selections: resolution presets with live resulting dimensions & byte
    /// estimates, output format, quality slider, lossless mode, custom dimensions, target size cap, Live Photo option,
    /// and metadata outcome preview.
    struct ImageInspectorSection: View {
        @Binding var options: ImageAdvancedOptions
        var singleItem: VideoItem? = nil
        var items: [VideoItem] = []

        @State private var showsMoreOptions = false

        private var sourceUTI: String {
            singleItem?.imageSourceUTI ?? items.first?.imageSourceUTI ?? UTType.heic.identifier
        }

        private var effectiveFormat: ImageOutputFormat {
            options.format.resolvedFormat(sourceUTI: sourceUTI)
        }

        private var decision: ImagePlanDecision? {
            guard let item = singleItem else { return nil }
            return ImagePlanner.decide(
                byteSize: item.byteSize,
                pixelSize: item.pixelSize,
                sourceUTI: item.imageSourceUTI,
                inventory: item.inventory,
                spec: options.spec,
                isLivePhoto: item.badges.contains(.livePhoto)
            )
        }

        private var resolutionEstimates: [ImageResolutionEstimate]? {
            guard let item = singleItem, item.pixelSize.width > 0, item.pixelSize.height > 0 else { return nil }
            return ImageLossCheck.resolutionEstimates(
                sourcePixelSize: item.pixelSize,
                sourceBytes: item.byteSize,
                sourceUTI: item.imageSourceUTI,
                baseSpec: options.spec,
                isLivePhoto: item.badges.contains(.livePhoto)
            )
        }

        private var customEnabled: Binding<Bool> {
            Binding {
                options.resolution == .custom
            } set: { enabled in
                options.resolution = enabled ? .custom : .keepOriginal
            }
        }

        var body: some View {
            Section("Image Resolution") {
                ForEach(ImageAdvancedOptions.Resolution.primaryCases) { option in
                    let est = resolutionEstimates?.first { $0.option == option }
                    Button {
                        options.resolution = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .fontWeight(options.resolution == option ? .semibold : .regular)
                                    .foregroundStyle(.primary)
                                if let est {
                                    Text(
                                        "\(Int(est.outputPixelSize.width.rounded())) × \(Int(est.outputPixelSize.height.rounded())) · ~\(ByteFormat.string(est.estimatedBytes))"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                } else {
                                    Text(option.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if options.resolution == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                DisclosureGroup("More Options", isExpanded: $showsMoreOptions) {
                    Picker("Output Format", selection: $options.format) {
                        ForEach(ImageOutputFormat.allCases.filter(\.isEncodingSupported)) { fmt in
                            Text(fmt.title).tag(fmt)
                        }
                    }

                    if effectiveFormat.supportsLossless {
                        Toggle("Lossless Compression", isOn: $options.isLossless)
                    }

                    if !options.isLossless && effectiveFormat != .png && effectiveFormat != .tiff {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Quality")
                                Spacer()
                                Text(
                                    "\(ImageAdvancedOptions.qualityTier(percent: options.qualityPercent).title) · \(Int(options.qualityPercent.rounded()))%"
                                )
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }
                            Slider(
                                value: $options.qualityPercent,
                                in: ImageAdvancedOptions
                                    .minimumQualityPercent...ImageAdvancedOptions
                                    .maximumQualityPercent,
                                step: 5
                            )
                        }
                    }

                    Toggle("Custom Max Dimensions", isOn: customEnabled)
                    if options.resolution == .custom {
                        HStack {
                            Text("Max W × H")
                            Spacer()
                            TextField("Width", value: $options.customMaxWidth, format: .number)
                                .frame(width: 70)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Height", value: $options.customMaxHeight, format: .number)
                                .frame(width: 70)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }

                    Picker("Target File Size", selection: $options.targetSize) {
                        ForEach(ImageAdvancedOptions.TargetSize.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    if options.targetSize == .custom {
                        HStack {
                            Text("Max Size (KB)")
                            Spacer()
                            TextField("KB", value: $options.customTargetKB, format: .number)
                                .frame(width: 80)
                        }
                    }

                    if items.contains(where: { $0.badges.contains(.livePhoto) }) {
                        Picker("Live Photos", selection: $options.livePhotoMode) {
                            ForEach(LivePhotoMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                }
            }

            if let decision {
                Section("What Happens to Metadata") {
                    switch decision {
                    case .convert(_, _, _, _, let predicted):
                        MetadataSummary(report: predicted)
                    case .keptAsIs(let reason, _):
                        Label("Kept as is: \(reason)", systemImage: "equal.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
#endif
