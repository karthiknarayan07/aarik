#if os(iOS)
    import AppServices
    import AppUI
    import Convert
    import LocalLibrary
    import MediaEngine
    import SwiftUI
    import UniformTypeIdentifiers

    /// Approachable Resolution checklist and collapsible More Options (Bit Rate, Frame Rate, Format) shared between
    /// Conversion Options, Queue Editor, and iOS Settings.
    struct IOSQualitySections: View {
        @Binding var resolution: AdvancedOptions.Resolution
        @Binding var bitRateMbps: Double
        @Binding var keepOriginalBitRate: Bool
        @Binding var frameRate: AdvancedOptions.FrameRate
        @Binding var codec: VideoCodec
        var locksFrameRate = false
        var resolutionSectionTitle = "Resolution"

        @State private var showsBitRateTip = false
        @State private var showsMoreOptions = false

        private var suggested: Double {
            AdvancedOptions.suggestedMbps(for: resolution, codec: codec)
        }

        private var tier: AdvancedOptions.BitRateTier {
            AdvancedOptions.bitRateTier(mbps: bitRateMbps, resolution: resolution, codec: codec)
        }

        private var bitRateText: String {
            let number = bitRateMbps.formatted(.number.precision(.fractionLength(0...1)))
            return "\(number) Mbps"
        }

        private var tierTint: Color {
            switch tier {
            case .compact: .orange
            case .recommended: .green
            case .highDetail: .blue
            }
        }

        private var moreSummary: String {
            let rate = keepOriginalBitRate ? "Original bit rate" : bitRateText
            let format = codec == .hevcKeepHDR ? "HEVC" : "H.264"
            return "\(rate) · \(frameRate.title) · \(format)"
        }

        var body: some View {
            Section(resolutionSectionTitle) {
                ForEach(AdvancedOptions.Resolution.allCases) { option in
                    Button {
                        resolution = option
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(option.title)
                                        .font(.body.weight(option == resolution ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    if option == .p1080 {
                                        Text("Recommended")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.14), in: .capsule)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(option.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if option == resolution {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == resolution ? .isSelected : [])
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsMoreOptions) {
                    Toggle("Keep Same Bit Rate as Original", isOn: $keepOriginalBitRate)
                    if keepOriginalBitRate {
                        Text("Encodes using the original video's bit rate so detail stays the same.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("Bit Rate")
                                Text(tier.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(tierTint.opacity(0.16), in: .capsule)
                                    .foregroundStyle(tierTint)
                                Spacer()
                                Text(bitRateText)
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }

                            Slider(
                                value: $bitRateMbps,
                                in: AdvancedOptions.minimumSliderMbps...AdvancedOptions.maximumSliderMbps,
                                step: 1
                            ) {
                                Text("Bit Rate")
                            }
                            .accessibilityLabel("Bit rate in megabits per second")
                            .accessibilityValue("\(tier.title), \(bitRateText)")

                            HStack {
                                Text("Smaller file")
                                Spacer()
                                Text("Sharper video")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            Text(tier.advice)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Text(AdvancedOptions.bitRateGuide(for: resolution, codec: codec))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if abs(bitRateMbps - suggested) >= 0.5 {
                                    Button("Use \(Int(suggested.rounded())) Mbps") {
                                        bitRateMbps = suggested
                                    }
                                    .font(.caption.weight(.medium))
                                    .buttonStyle(.borderless)
                                }
                            }

                            Button {
                                withAnimation(.snappy) { showsBitRateTip.toggle() }
                            } label: {
                                Label(
                                    showsBitRateTip ? "Hide bit rate guide" : "How to choose bit rate",
                                    systemImage: showsBitRateTip ? "info.circle.fill" : "info.circle"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.borderless)

                            if showsBitRateTip {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Bit rate controls how much detail each second keeps.")
                                    Text(
                                        "Start with Recommended — it stays sharp on phones and TVs while shrinking files most."
                                    )
                                    Text("Go higher for sports or dark scenes, or keep original bit rate above.")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Picker("Frame Rate", selection: $frameRate) {
                        ForEach(AdvancedOptions.FrameRate.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(locksFrameRate)
                    if locksFrameRate {
                        Text("Slo-mo videos keep their original frame rate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Format", selection: $codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("HEVC makes smaller files and keeps HDR. Pick H.264 only for older devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    struct IOSPhotosSaveSection: View {
        @Binding var location: PhotosSaveLocation
        @State private var isChoosingFolder = false

        private var choice: Binding<PhotosSaveLocation.Choice> {
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
            Section {
                Picker("Save to", selection: choice) {
                    ForEach(PhotosSaveLocation.Choice.allCases) { Text($0.title).tag($0) }
                }
                if location.choice == .folder {
                    FolderStatusRow(
                        folder: location.folder,
                        buttonTitle: "Change…",
                        accessibilityLabel: "Change the output folder"
                    ) {
                        isChoosingFolder = true
                    }
                }
            } header: {
                Text("Save to")
            } footer: {
                Text(location.choice.footerNote)
            }
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try? location.setFolder(url)
            }
        }
    }

    struct IOSItemSummaryHeader: View {
        let item: VideoItem
        let thumbnails: ThumbnailSource
        @State private var image: CGImage?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                poster
                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(ItemDescription.details(item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !item.badges.isEmpty {
                    BadgeFlowLayout(spacing: 4) {
                        ForEach(MediaBadge.ordered(item.badges), id: \.self) { badge in
                            Text(badge.displayName)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if !item.isAvailable {
                    StatusLabel(
                        "The file is missing or unavailable.", systemImage: "exclamationmark.circle", tint: .orange)
                }
            }
            .task(id: item) {
                image = nil
                guard item.isAvailable else { return }
                image = await thumbnails.image(for: item, maxPixel: 640)
            }
        }

        private var poster: some View {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
        }
    }

    private struct BadgeFlowLayout: Layout {
        var spacing: CGFloat = 4

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let maxWidth = proposal.width ?? .infinity
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                if x > 0, x + size.width > maxWidth {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x = bounds.minX
            var y = bounds.minY
            var rowHeight: CGFloat = 0
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                if x > bounds.minX, x + size.width > bounds.maxX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }
#endif
