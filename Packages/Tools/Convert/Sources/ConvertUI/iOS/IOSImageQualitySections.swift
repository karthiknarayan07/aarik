#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import LocalLibrary
    import MediaEngine
    import SwiftUI
    import UniformTypeIdentifiers

    /// Approachable image Resolution checklist and collapsible More Options (Format, Quality %, Lossless, Custom W×H,
    /// Target Size, Live Photo handling) shared between Conversion Options, Queue Editor, and iOS Settings.
    struct IOSImageQualitySections: View {
        @Binding var options: ImageAdvancedOptions
        var estimates: [ImageResolutionEstimate]? = nil
        var sourceUTI: String = UTType.heic.identifier
        var showsLivePhotoOption: Bool = true
        var sectionTitle = "Resolution"

        @State private var showsMoreOptions = false
        @State private var showsQualityGuide = false

        private var effectiveFormat: ImageOutputFormat {
            options.format.resolvedFormat(sourceUTI: sourceUTI)
        }

        private var qualityTier: ImageAdvancedOptions.QualityTier {
            ImageAdvancedOptions.qualityTier(percent: options.qualityPercent)
        }

        private var tierTint: Color {
            switch qualityTier {
            case .compact: .orange
            case .recommended: .green
            case .highDetail: .blue
            }
        }

        private var supportsQualitySlider: Bool {
            !options.isLossless && effectiveFormat != .png && effectiveFormat != .tiff
        }

        private var moreSummary: String {
            var parts: [String] = [options.format.title]
            if options.isLossless && effectiveFormat.supportsLossless {
                parts.append("Lossless")
            } else if supportsQualitySlider {
                parts.append("\(Int(options.qualityPercent.rounded()))%")
            }
            if options.resolution == .custom {
                parts.append("\(options.customMaxWidth)×\(options.customMaxHeight)")
            }
            if options.targetSize != .off {
                parts.append(options.targetSize.title)
            }
            return parts.joined(separator: " · ")
        }

        private var customDimensionsEnabled: Binding<Bool> {
            Binding {
                options.resolution == .custom
            } set: { enabled in
                options.resolution = enabled ? .custom : .keepOriginal
            }
        }

        private var availableFormats: [ImageOutputFormat] {
            ImageOutputFormat.allCases.filter(\.isEncodingSupported)
        }

        private func isRecommended(_ option: ImageAdvancedOptions.Resolution) -> Bool {
            if let sourceSize = estimates?.first?.sourceBytes, let px = estimates?.first?.outputPixelSize {
                let sourceMP = (px.width * px.height) / 1_000_000.0
                if sourceMP > 20 || sourceSize > 8_000_000 { return option == .mp12 }
            }
            return option == .keepOriginal
        }

        private func estimate(for option: ImageAdvancedOptions.Resolution) -> ImageResolutionEstimate? {
            estimates?.first { $0.option == option }
        }

        var body: some View {
            Section(sectionTitle) {
                ForEach(ImageAdvancedOptions.Resolution.primaryCases) { option in
                    let est = estimate(for: option)
                    Button {
                        options.resolution = option
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(option.title)
                                        .font(.body.weight(option == options.resolution ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    if isRecommended(option) {
                                        Text("Recommended")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.14), in: .capsule)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                if let est {
                                    let w = Int(est.outputPixelSize.width.rounded())
                                    let h = Int(est.outputPixelSize.height.rounded())
                                    Text("\(w) × \(h) · About \(ByteFormat.string(est.estimatedBytes))")
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
                            if option == options.resolution {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == options.resolution ? .isSelected : [])
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsMoreOptions) {
                    Picker("Output Format", selection: $options.format) {
                        ForEach(availableFormats) { fmt in
                            Text(fmt.title).tag(fmt)
                        }
                    }
                    Text(
                        "HEIC keeps HDR, Depth, and Live Photo motion at a smaller size. "
                            + "RAW, ProRAW, and WebP photos default to HEIC when Keep Original is chosen."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if effectiveFormat.supportsLossless {
                        Toggle("Lossless Compression", isOn: $options.isLossless)
                    }

                    if supportsQualitySlider {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("Quality")
                                Text(qualityTier.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(tierTint.opacity(0.16), in: .capsule)
                                    .foregroundStyle(tierTint)
                                Spacer()
                                Text("\(Int(options.qualityPercent.rounded()))%")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }

                            Slider(
                                value: $options.qualityPercent,
                                in: ImageAdvancedOptions
                                    .minimumQualityPercent...ImageAdvancedOptions
                                    .maximumQualityPercent,
                                step: 5
                            ) {
                                Text("Quality")
                            }
                            .accessibilityLabel("Image compression quality")
                            .accessibilityValue(
                                "\(qualityTier.title), \(Int(options.qualityPercent.rounded())) percent")

                            HStack {
                                Text("Smaller file")
                                Spacer()
                                Text("Maximum detail")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            Text(qualityTier.advice)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if abs(options.qualityPercent - ImageAdvancedOptions.defaultQualityPercent) >= 1 {
                                Button("Reset to 80%") {
                                    options.qualityPercent = ImageAdvancedOptions.defaultQualityPercent
                                }
                                .font(.caption.weight(.medium))
                                .buttonStyle(.borderless)
                            }

                            Button {
                                withAnimation(.snappy) { showsQualityGuide.toggle() }
                            } label: {
                                Label(
                                    showsQualityGuide ? "Hide quality guide" : "How to choose quality",
                                    systemImage: showsQualityGuide ? "info.circle.fill" : "info.circle"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.borderless)

                            if showsQualityGuide {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Quality 80% matches original sharpness for almost all camera photos.")
                                    Text("Use 60–75% for web uploads, and 90–100% for heavy editing or printing.")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Toggle("Custom Max Dimensions", isOn: customDimensionsEnabled)
                    if options.resolution == .custom {
                        HStack {
                            Text("Max Width")
                            Spacer()
                            TextField("Width", value: $options.customMaxWidth, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("px").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Max Height")
                            Spacer()
                            TextField("Height", value: $options.customMaxHeight, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("px").foregroundStyle(.secondary)
                        }
                        Text("Fits proportionally within these bounds without ever upscaling.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Target File Size", selection: $options.targetSize) {
                        ForEach(ImageAdvancedOptions.TargetSize.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    if options.targetSize == .custom {
                        HStack {
                            Text("Target Limit")
                            Spacer()
                            TextField("KB", value: $options.customTargetKB, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("KB").foregroundStyle(.secondary)
                        }
                    }

                    if showsLivePhotoOption {
                        Picker("Live Photos", selection: $options.livePhotoMode) {
                            ForEach(LivePhotoMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("More Options")
                        Spacer()
                        Text(moreSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    /// Before -> After estimate card for a single image item.
    struct IOSImageEstimateCard: View {
        let decision: ImagePlanDecision
        let originalBytes: Int64

        var body: some View {
            switch decision {
            case .convert(_, let outputFormat, let targetSize, let estimate, _):
                let savedPercent =
                    estimate >= originalBytes * 98 / 100
                    ? "Similar size" : ByteFormat.savedPercent(before: originalBytes, after: estimate)
                let afterFraction = originalBytes > 0 ? min(max(Double(estimate) / Double(originalBytes), 0), 1) : 1
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(ByteFormat.string(originalBytes)) → About \(ByteFormat.string(estimate))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        if let savedPercent {
                            Text(savedPercent)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.green.opacity(0.16), in: .capsule)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(
                        "\(Int(targetSize.width.rounded())) × \(Int(targetSize.height.rounded())) · \(outputFormat.title)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    Gauge(value: afterFraction) {
                        Text("Estimated size")
                    }
                    .gaugeStyle(.linearCapacity)
                    .tint(.accentColor)
                    .accessibilityHidden(true)
                }
                .padding(.vertical, 2)
            case .keptAsIs(let reason, _):
                Label("Kept as is: \(reason)", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
#endif
