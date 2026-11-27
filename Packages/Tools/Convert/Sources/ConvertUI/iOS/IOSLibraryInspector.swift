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
        var itemID: UUID? = nil
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
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { compactButtons }
                                VStack(spacing: 8) { compactButtons }
                            }
                            .controlSize(.large)
                            .disabled(!model.canAddSelectionToQueue)
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        }
                }
            } else {
                content
            }
        }

        @ViewBuilder private var compactButtons: some View {
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

        private func queue(startsQueue: Bool) {
            dismiss()
            // Wait until the options sheet has dismissed before triggering any ancestor loss sheet or replace alert.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                model.requestAddSelectionToQueue(startsQueue: startsQueue)
                if model.lossReview == nil && !model.isConfirmingReplace {
                    onQueued?()
                }
            }
        }

        private var selectedItems: [VideoItem] {
            let items =
                model.isPhotosPage
                ? model.selectedPhotoItems
                : (model.selection?.showsLibrary == true ? model.selectedItems : [])
            if items.isEmpty, let itemID, let fallback = model.item(withID: itemID) {
                return [fallback]
            }
            return items
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
                    message: "Select videos or images to choose quality and see estimated savings.")
            } else {
                let images = items.filter(\.isImage)
                let videos = items.filter(\.isVideo)
                let single = items.count == 1 ? items[0] : nil
                let isMixed = !images.isEmpty && !videos.isEmpty

                let videoDecision: PlanDecision? =
                    if let single, single.isVideo {
                        SavingsCalculator.decision(
                            byteSize: single.savingsSource.byteSize,
                            inventory: single.savingsSource.inventory,
                            preset: model.effectivePreset(for: single),
                            custom: optionsBinding.wrappedValue.spec)
                    } else {
                        nil
                    }
                let imageDecision: ImagePlanDecision? =
                    if let single, single.isImage {
                        ImagePlanner.decide(
                            byteSize: single.byteSize,
                            pixelSize: single.pixelSize,
                            sourceUTI: single.imageSourceUTI,
                            inventory: single.inventory,
                            spec: model.imageAdvanced.spec,
                            isLivePhoto: single.badges.contains(.livePhoto))
                    } else {
                        nil
                    }
                let videoSources = videos.map(model.inspectorSource(for:))
                let locksFrameRate =
                    videos.contains { $0.badges.contains(.sloMo) }
                    || videoSources.contains { ConvertPlanner.locksFrameRate($0.inventory) }

                Form {
                    Section {
                        if let single {
                            IOSItemSummaryHeader(item: single, thumbnails: model.thumbnailSource)
                            if let videoDecision {
                                IOSSingleEstimateCard(decision: videoDecision, originalBytes: single.byteSize)
                            } else if let imageDecision {
                                IOSImageEstimateCard(decision: imageDecision, originalBytes: single.byteSize)
                            }
                        } else {
                            IOSBulkSummaryCard(
                                videoSources: videoSources,
                                imageItems: images,
                                customVideo: optionsBinding.wrappedValue.spec,
                                imageSpec: model.imageAdvanced.spec)
                        }
                    }

                    if !images.isEmpty {
                        let singleImage = (single?.isImage == true) ? single : nil
                        let estimates = singleImage.flatMap { img in
                            img.pixelSize.width > 0 && img.pixelSize.height > 0
                                ? ImageLossCheck.resolutionEstimates(
                                    sourcePixelSize: img.pixelSize,
                                    sourceBytes: img.byteSize,
                                    sourceUTI: img.imageSourceUTI,
                                    baseSpec: model.imageAdvanced.spec,
                                    isLivePhoto: img.badges.contains(.livePhoto))
                                : nil
                        }
                        IOSImageQualitySections(
                            options: $model.imageAdvanced,
                            estimates: estimates,
                            sourceUTI: singleImage?.imageSourceUTI ?? images[0].imageSourceUTI,
                            showsLivePhotoOption: images.contains { $0.badges.contains(.livePhoto) },
                            sectionTitle: isMixed ? "Image Resolution" : "Resolution")
                    }

                    if !videos.isEmpty {
                        IOSQualitySections(
                            resolution: optionsBinding.resolution,
                            bitRateMbps: optionsBinding.bitRateMbps,
                            keepOriginalBitRate: optionsBinding.keepOriginalBitRate,
                            frameRate: optionsBinding.frameRate,
                            codec: optionsBinding.codec,
                            locksFrameRate: locksFrameRate,
                            resolutionSectionTitle: isMixed ? "Video Resolution" : "Resolution")
                    }

                    if case .convert(_, _, let predicted) = videoDecision {
                        Section("What Happens to Metadata") {
                            MetadataSummary(report: predicted)
                        }
                    } else if case .convert(_, _, _, _, let predicted) = imageDecision {
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

    /// Summary card for multiple selected items (videos, images, or mixed) with live gauge and warnings.
    private struct IOSBulkSummaryCard: View {
        let videoSources: [InspectorSource]
        let imageItems: [VideoItem]
        let customVideo: DownscaleSpec?
        let imageSpec: ImageSpec

        var body: some View {
            let availableVideos = videoSources.filter(\.isAvailable)
            let availableImages = imageItems.filter(\.isAvailable)
            let availableCount = availableVideos.count + availableImages.count
            let totalCount = videoSources.count + imageItems.count
            let total =
                availableVideos.reduce(Int64(0)) { $0 + $1.byteSize }
                + availableImages.reduce(Int64(0)) { $0 + $1.byteSize }
            let videoFreed = SavingsCalculator.couldFreeBytes(
                for: availableVideos.map { (source: $0.savings, preset: $0.preset) }, custom: customVideo)
            let imageFreed = availableImages.reduce(Int64(0)) { acc, img in
                guard let after = img.estimatedBytes(imageSpec: imageSpec) else { return acc }
                return acc + max(0, img.byteSize - after)
            }
            let freed = videoFreed + imageFreed
            let after = max(0, total - freed)
            let afterFraction = total > 0 ? min(max(Double(after) / Double(total), 0), 1) : 1
            let losingVideos = LossCheck.losses(
                for: availableVideos.enumerated().map {
                    (id: $0.offset, source: $0.element.savings, preset: $0.element.preset)
                },
                custom: customVideo
            ).count
            let losingImages = ImageLossCheck.losses(
                for: availableImages.map {
                    (
                        id: $0.id, sourceUTI: $0.imageSourceUTI, byteSize: $0.byteSize, pixelSize: $0.pixelSize,
                        inventory: $0.inventory, isLivePhoto: $0.badges.contains(.livePhoto)
                    )
                },
                spec: imageSpec
            ).count
            let losing = losingVideos + losingImages
            let missing = totalCount - availableCount
            let noun =
                if availableVideos.isEmpty {
                    availableCount == 1 ? "1 Image" : "\(availableCount) Images"
                } else if availableImages.isEmpty {
                    availableCount == 1 ? "1 Video" : "\(availableCount) Videos"
                } else {
                    availableCount == 1 ? "1 Item" : "\(availableCount) Items"
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(noun)
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
                    losing == 1 ? "1 item will lose metadata" : "\(losing) items will lose metadata",
                    systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if missing > 0 {
                StatusLabel(
                    missing == 1 ? "1 missing file is skipped" : "\(missing) missing files are skipped",
                    systemImage: "exclamationmark.circle", tint: .orange)
            }
        }
    }
#endif
