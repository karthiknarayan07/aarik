#if os(iOS)
    import AppCore
    import AppServices
    import AppUI
    import Convert
    import LocalLibrary
    import MediaEngine
    import PhotosLibrary
    import SwiftUI

    /// Edit sheet opened when tapping a waiting video in Queue: adjust resolution, bit rate, format, save destination,
    /// or swap/remove the queued video.
    struct IOSQueueJobEditor: View {
        @Bindable var model: ConvertModel
        let job: Job
        let existing: ConvertJobSettings
        @Environment(\.dismiss) private var dismiss

        @State private var options: AdvancedOptions
        @State private var imageOptions: ImageAdvancedOptions
        @State private var photosSaveLocation: PhotosSaveLocation
        @State private var fileSaveLocation: SaveLocation
        @State private var replacement: VideoItem?
        @State private var isPickingVideo = false

        init(model: ConvertModel, job: Job) {
            self.model = model
            self.job = job
            let decoded =
                (try? JSONDecoder().decode(ConvertJobSettings.self, from: job.settings))
                ?? ConvertJobSettings(saveTo: SaveLocation(platform: .iOS).destination ?? .documents)
            self.existing = decoded
            _options = State(initialValue: AdvancedOptions(from: decoded.custom, preset: decoded.preset))
            _imageOptions = State(
                initialValue: decoded.imageSpec.map(ImageAdvancedOptions.init(from:)) ?? ImageAdvancedOptions())
            _photosSaveLocation = State(initialValue: PhotosSaveLocation(destination: decoded.photosDestination))
            _fileSaveLocation = State(initialValue: SaveLocation(destination: decoded.saveTo, platform: .iOS))
        }

        private var activeItem: VideoItem? { replacement ?? model.libraryItem(for: job) }

        private var isImage: Bool {
            if let replacement { return replacement.isImage }
            return existing.isImage || ConvertTool.isImageJob(job.toolID)
        }

        private var isPhotos: Bool {
            if let replacement { return replacement.photosIdentifier != nil }
            return ConvertTool.isPhotosJob(job.toolID)
        }

        private var decision: PlanDecision? {
            guard !isImage else { return nil }
            return activeItem.map { item in
                let source = item.savingsSource
                return SavingsCalculator.decision(
                    byteSize: source.byteSize, inventory: source.inventory, preset: existing.preset,
                    custom: options.spec)
            }
        }

        private var imageDecision: ImagePlanDecision? {
            guard isImage else { return nil }
            return activeItem.map { item in
                ImagePlanner.decide(
                    byteSize: item.byteSize, pixelSize: item.pixelSize, sourceUTI: item.imageSourceUTI,
                    inventory: item.inventory, spec: imageOptions.spec, isLivePhoto: item.badges.contains(.livePhoto))
            }
        }

        private var imageResolutionEstimates: [ImageResolutionEstimate]? {
            guard isImage, let item = activeItem, item.pixelSize.width > 0, item.pixelSize.height > 0 else {
                return nil
            }
            return ImageLossCheck.resolutionEstimates(
                sourcePixelSize: item.pixelSize, sourceBytes: item.byteSize, sourceUTI: item.imageSourceUTI,
                baseSpec: imageOptions.spec, isLivePhoto: item.badges.contains(.livePhoto))
        }

        private var locksFrameRate: Bool {
            activeItem.map {
                $0.badges.contains(.sloMo) || ConvertPlanner.locksFrameRate($0.savingsSource.inventory)
            } ?? false
        }

        private var canSave: Bool {
            isPhotos ? photosSaveLocation.destination != nil : fileSaveLocation.destination != nil
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section(isImage ? "Selected Image" : "Selected Video") {
                        if let item = activeItem {
                            IOSItemSummaryHeader(item: item, thumbnails: model.thumbnailSource)
                            if let decision {
                                IOSSingleEstimateCard(decision: decision, originalBytes: item.byteSize)
                            } else if let imageDecision {
                                IOSImageEstimateCard(decision: imageDecision, originalBytes: item.byteSize)
                            }
                        } else {
                            HStack(spacing: 12) {
                                JobThumbnail(
                                    url: job.source, thumbnails: model.thumbnailSource.cache,
                                    thumbnailSource: model.thumbnailSource, size: CGSize(width: 72, height: 48))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.displayName)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if let preset = job.presetLabel {
                                        Text(preset)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !model.photos.items.isEmpty || !model.library.items.isEmpty {
                            Button("Change Selected Item…", systemImage: "arrow.triangle.2.circlepath") {
                                isPickingVideo = true
                            }
                        }
                    }

                    if isImage {
                        IOSImageQualitySections(
                            options: $imageOptions,
                            estimates: imageResolutionEstimates,
                            sourceUTI: activeItem?.imageSourceUTI ?? "public.heic",
                            showsLivePhotoOption: activeItem?.badges.contains(.livePhoto) ?? true)
                    } else {
                        IOSQualitySections(
                            resolution: $options.resolution,
                            bitRateMbps: $options.bitRateMbps,
                            keepOriginalBitRate: $options.keepOriginalBitRate,
                            frameRate: $options.frameRate,
                            codec: $options.codec,
                            locksFrameRate: locksFrameRate)
                    }

                    if case .convert(_, _, let predicted) = decision {
                        Section("What Happens to Metadata") {
                            MetadataSummary(report: predicted)
                        }
                    } else if case .convert(_, _, _, _, let predicted) = imageDecision {
                        Section("What Happens to Metadata") {
                            MetadataSummary(report: predicted)
                        }
                    }

                    if isPhotos {
                        IOSPhotosSaveSection(location: $photosSaveLocation)
                    } else {
                        Section("Save to") {
                            SaveDestinationPicker(location: $fileSaveLocation)
                        }
                    }

                    Section {
                        Button("Remove from Queue", systemImage: "trash", role: .destructive) {
                            model.remove(job)
                            dismiss()
                        }
                    }
                }
                .navigationTitle(isImage ? "Edit Queued Image" : "Edit Queued Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if isImage {
                                model.updateQueuedImageJob(
                                    job, existing: existing, options: imageOptions,
                                    photosSaveLocation: photosSaveLocation,
                                    fileSaveLocation: fileSaveLocation,
                                    replacement: replacement)
                            } else {
                                model.updateQueuedJob(
                                    job, existing: existing, options: options,
                                    photosSaveLocation: photosSaveLocation,
                                    fileSaveLocation: fileSaveLocation,
                                    replacement: replacement)
                            }
                            dismiss()
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveJobSettings")
                    }
                }
                .sheet(isPresented: $isPickingVideo) {
                    IOSQueueMediaPicker(model: model, editingJob: job, selection: $replacement)
                }
            }
        }
    }

    private struct IOSQueueMediaPicker: View {
        let model: ConvertModel
        let editingJob: Job
        @Binding var selection: VideoItem?
        @Environment(\.dismiss) private var dismiss
        @State private var search = ""

        private func isBusyElsewhere(_ item: VideoItem) -> Bool {
            let source: URL? =
                if let identifier = item.photosIdentifier {
                    PhotoAssetURL.url(for: identifier)
                } else {
                    item.fileURL?.standardizedFileURL
                }
            guard let source else { return true }
            return model.queuedJobs.contains { other in
                guard other.id != editingJob.id else { return false }
                return other.source == source || other.source.standardizedFileURL == source
            }
        }

        private func filter(_ items: [VideoItem]) -> [VideoItem] {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return items }
            return items.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }

        var body: some View {
            let photosItems = filter(model.photos.items)
            let fileItems = filter(model.library.items.filter(\.isAvailable))
            NavigationStack {
                Group {
                    if photosItems.isEmpty && fileItems.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        List {
                            if !photosItems.isEmpty {
                                Section("Photos") {
                                    ForEach(photosItems) { row($0) }
                                }
                            }
                            if !fileItems.isEmpty {
                                Section("Files") {
                                    ForEach(fileItems) { row($0) }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $search, prompt: "Search videos")
                .navigationTitle("Choose Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }

        private func row(_ item: VideoItem) -> some View {
            let busy = isBusyElsewhere(item)
            let thumbnailURL =
                item.photosIdentifier.map { PhotoAssetURL.url(for: $0) }
                ?? item.fileURL
                ?? URL(filePath: "/\(item.name)")
            return Button {
                selection = item
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    JobThumbnail(
                        url: thumbnailURL, thumbnails: model.thumbnailSource.cache,
                        thumbnailSource: model.thumbnailSource)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(ItemDescription.details(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy {
                        Text("In Queue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
        }
    }
#endif
