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
                        keepOriginalBitRate: optionsBinding.keepOriginalBitRate,
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
#endif
