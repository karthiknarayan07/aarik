#if os(iOS)
    import AppServices
    import AppUI
    import Convert
    import LocalLibrary
    import MediaEngine
    import SwiftUI
    import UniformTypeIdentifiers

    /// iOS inspector for both Photos and Local Files selections. Used both as a single-video detail page and as the
    /// bulk Conversion Options sheet.
    struct IOSLibraryInspector: View {
        @Bindable var model: ConvertModel
        let isCompact: Bool
        var onQueued: (() -> Void)? = nil
        let dismiss: () -> Void

        var body: some View {
            if isCompact {
                NavigationStack {
                    content
                        .navigationTitle("Conversion Options")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", action: dismiss)
                            }
                        }
                        .safeAreaInset(edge: .bottom) {
                            HStack(spacing: 12) {
                                Button {
                                    queue(startsQueue: false)
                                } label: {
                                    Text("Add to Queue").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("addSelectionToQueue")
                                Button {
                                    queue(startsQueue: true)
                                } label: {
                                    Text("Convert Now").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                                .accessibilityIdentifier("convertSelection")
                            }
                            .controlSize(.large)
                            .disabled(!model.canAddSelectionToQueue)
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .background(.bar)
                        }
                }
            } else {
                content
            }
        }

        private func queue(startsQueue: Bool) {
            dismiss()
            model.requestAddSelectionToQueue(startsQueue: startsQueue)
            // Keep selection visible when metadata loss confirmation opens; otherwise finish select mode.
            if model.lossReview == nil && !model.isConfirmingReplace {
                onQueued?()
            }
        }

        private var selectedItems: [VideoItem] {
            if model.isPhotosPage { return model.selectedPhotoItems }
            return model.selection?.showsLibrary == true ? model.selectedItems : []
        }

        private var optionsBinding: Binding<AdvancedOptions> {
            Binding {
                var options = model.advanced
                options.isEnabled = true
                return options
            } set: { newValue in
                var updated = newValue
                updated.isEnabled = true
                model.advanced = updated
            }
        }

        @ViewBuilder private var content: some View {
            let items = selectedItems
            if items.isEmpty {
                EmptyState(
                    "No Selection", systemImage: "rectangle.dashed",
                    message: "Select videos to choose quality and see estimated savings.")
            } else {
                let sources = items.map(model.inspectorSource(for:))
                let single = items.count == 1 ? items[0] : nil
                let decision = single.map { item in
                    let source = item.savingsSource
                    return SavingsCalculator.decision(
                        byteSize: source.byteSize, inventory: source.inventory,
                        preset: model.effectivePreset(for: item), custom: optionsBinding.wrappedValue.spec)
                }
                let locksFrameRate =
                    items.contains { $0.badges.contains(.sloMo) }
                    || sources.contains { ConvertPlanner.locksFrameRate($0.inventory) }

                Form {
                    Section {
                        if let single {
                            IOSItemSummaryHeader(item: single, thumbnails: model.thumbnailSource)
                            if let decision {
                                IOSSingleEstimateCard(decision: decision, originalBytes: single.byteSize)
                            }
                        } else {
                            IOSBulkSummaryCard(sources: sources, custom: optionsBinding.wrappedValue.spec)
                        }
                    }

                    IOSQualitySections(
                        resolution: optionsBinding.resolution,
                        bitRateMbps: optionsBinding.bitRateMbps,
                        frameRate: optionsBinding.frameRate,
                        codec: optionsBinding.codec,
                        locksFrameRate: locksFrameRate)

                    if case .convert(_, _, let predicted) = decision {
                        Section("What Happens to Metadata") {
                            MetadataSummary(report: predicted)
                        }
                    }

                    if model.isPhotosPage {
                        IOSPhotosSaveSection(location: $model.photosSaveLocation)
                    } else {
                        Section("Save to") {
                            SaveDestinationPicker(location: $model.saveLocation)
                        }
                    }
                }
            }
        }
    }

    /// Friendly Before -> After card for a single selected video.
    struct IOSSingleEstimateCard: View {
        let decision: PlanDecision
        let originalBytes: Int64

        var body: some View {
            switch decision {
            case .convert(_, let estimate, _):
                let savedPercent = ByteFormat.savedPercent(before: originalBytes, after: estimate)
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

    /// Summary card for multiple selected videos with live before/after gauge and loss/missing warnings.
    private struct IOSBulkSummaryCard: View {
        let sources: [InspectorSource]
        let custom: DownscaleSpec?

        var body: some View {
            let available = sources.filter(\.isAvailable)
            let total = available.reduce(Int64(0)) { $0 + $1.byteSize }
            let freed = SavingsCalculator.couldFreeBytes(
                for: available.map { (source: $0.savings, preset: $0.preset) }, custom: custom)
            let after = max(0, total - freed)
            let afterFraction = total > 0 ? min(max(Double(after) / Double(total), 0), 1) : 1
            let losing = LossCheck.losses(
                for: available.enumerated().map {
                    (id: $0.offset, source: $0.element.savings, preset: $0.element.preset)
                },
                custom: custom
            ).count
            let missing = sources.count - available.count

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(available.count == 1 ? "1 Video" : "\(available.count) Videos")
                        .font(.headline)
                    Spacer()
                    Text(freed > 0 ? "Could free ~\(ByteFormat.string(freed))" : "No space saved")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(freed > 0 ? Color.green : Color.secondary)
                }
                if total > 0 {
                    Text("\(ByteFormat.string(total)) now → about \(ByteFormat.string(after)) after")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if freed > 0 {
                        Gauge(value: afterFraction) {
                            Text("Estimated size after converting")
                        }
                        .gaugeStyle(.linearCapacity)
                        .tint(.accentColor)
                        .accessibilityHidden(true)
                    }
                }
            }
            .padding(.vertical, 2)
            if losing > 0 {
                StatusLabel(
                    losing == 1 ? "1 video will lose metadata" : "\(losing) videos will lose metadata",
                    systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if missing > 0 {
                StatusLabel(
                    missing == 1 ? "1 missing file is skipped" : "\(missing) missing files are skipped",
                    systemImage: "exclamationmark.circle", tint: .orange)
            }
        }
    }

    /// Approachable Resolution checklist, Picture Detail slider with plain-English bit rate advice, and collapsible
    /// advanced options shared between Conversion Options and iOS Settings.
    struct IOSQualitySections: View {
        @Binding var resolution: AdvancedOptions.Resolution
        @Binding var bitRateMbps: Double
        @Binding var frameRate: AdvancedOptions.FrameRate
        @Binding var codec: VideoCodec
        var locksFrameRate = false
        var resolutionSectionTitle = "Resolution"
        var detailSectionTitle = "Picture Detail"

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
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
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
                        Text("Picture Detail")
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
                }
                .padding(.vertical, 4)

                if showsBitRateTip {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("How to pick a bit rate", systemImage: "lightbulb")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Bit rate controls how much detail each second keeps.")
                        Text("Start with Recommended — it stays sharp on phones and TVs while shrinking files most.")
                        Text("Go higher for sports, concerts, or night shots; go lower for quick messaging.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text(detailSectionTitle)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { showsBitRateTip.toggle() }
                    } label: {
                        Label(
                            showsBitRateTip ? "Hide tip" : "How to choose",
                            systemImage: showsBitRateTip ? "info.circle.fill" : "info.circle"
                        )
                        .font(.caption)
                        .textCase(nil)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsMoreOptions) {
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
                        Text("\(frameRate.title) · \(codec == .hevcKeepHDR ? "HEVC" : "H.264")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                if location.choice == .folder, let folder = location.folder {
                    HStack {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Change…") { isChoosingFolder = true }
                            .accessibilityLabel("Change the output folder")
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
                    HStack(spacing: 4) {
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
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
        }
    }
#endif
