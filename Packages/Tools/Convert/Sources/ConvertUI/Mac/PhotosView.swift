#if os(macOS)
    import AppCore
    import AppKit
    import AppUI
    import Convert
    import LocalLibrary
    import PhotosLibrary
    import SwiftUI
    import UniformTypeIdentifiers

    /// Where System Settings opens for the two permissions this page can ask about.
    public enum PrivacySettings {
        public static let photos = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
        static let fullDiskAccess = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

        @MainActor public static func open(_ url: URL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// The Videos page: the access prompt, the denied state, or the user's Photos videos in the same grid and
    /// inspector as Local Files.
    struct PhotosView: View {
        @Bindable var model: ConvertModel
        @State private var resumeTask: Task<Void, Never>?

        var body: some View {
            let photos = model.photos
            Group {
                if !photos.isAuthorizationKnown {
                    ProgressView()
                } else {
                    switch photos.authorization {
                    case .notDetermined:
                        PhotosAccessPrompt { Task { await photos.requestAccess() } }
                    case .denied, .restricted:
                        PhotosAccessDenied(isRestricted: photos.authorization == .restricted)
                    case .limited, .authorized:
                        PhotosGridView(model: model)
                    }
                }
            }
            .navigationTitle(VideoPage.photosVideos.title)
            .task { await photos.start() }
            // Access or Full Disk Access may have been changed in System Settings while the app was in the background.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resumeTask?.cancel()
                resumeTask = Task {
                    await photos.start()
                    guard !Task.isCancelled else { return }
                    if photos.indexStatus == .noAccess { await photos.reloadIndex() }
                }
            }
            .onDisappear {
                resumeTask?.cancel()
                resumeTask = nil
            }
        }
    }

    private struct PhotosAccessPrompt: View {
        let allow: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("See Your Photos Videos", systemImage: "photo.on.rectangle")
            } description: {
                Text(
                    "\(AppInfo.displayName) reads your video list on this Mac and changes nothing in Photos until you convert a video."
                )
            } actions: {
                Button("Allow Access to Photos…", action: allow)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Asks macOS for permission to read your Photos library")
            }
        }
    }

    private struct PhotosAccessDenied: View {
        let isRestricted: Bool

        var body: some View {
            ContentUnavailableView {
                Label("Photos Access Is Off", systemImage: "lock")
            } description: {
                Text(
                    isRestricted
                        ? "Access to Photos is restricted on this Mac, so its videos can't be shown."
                        : "Allow access to Photos in System Settings to see your videos here.")
            } actions: {
                if !isRestricted {
                    Button("Open System Settings…") { PrivacySettings.open(PrivacySettings.photos) }
                        .accessibilityHint("Opens System Settings, where you can allow access")
                }
            }
        }
    }

    /// Access is limited to a few photos and none of them is a video, so there is nothing to list.
    private struct PhotosAccessLimited: View {
        var body: some View {
            ContentUnavailableView {
                Label("No Videos Are Shared", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(
                    "You gave \(AppInfo.displayName) access to some of your photos only, and none of them is a video. "
                        + "Choose more in System Settings to see your videos here.")
            } actions: {
                Button("Open System Settings…") { PrivacySettings.open(PrivacySettings.photos) }
                    .accessibilityHint("Opens System Settings, where you can choose more photos")
            }
        }
    }

    private struct PhotosGridView: View {
        @Bindable var model: ConvertModel

        var body: some View {
            @Bindable var browser = model.photosBrowser
            let photos = model.photos
            Group {
                if photos.items.isEmpty {
                    VStack(spacing: 0) {
                        // Full Disk Access is about filters, which an empty grid can still explain; limited access has
                        // a state of its own.
                        if photos.hasLoaded, photos.authorization != .limited {
                            PhotosNotes(authorization: photos.authorization, indexStatus: photos.indexStatus)
                                .padding(.top, 8)
                        }
                        if photos.hasLoaded, photos.loadError == nil, photos.authorization == .limited {
                            PhotosAccessLimited()
                        } else {
                            PhotosEmpty(isLoading: !photos.hasLoaded, error: photos.loadError) {
                                Task { await photos.start() }
                            }
                        }
                    }
                } else {
                    grid(browser)
                        // The header and the notes sit in the system's bar, so the grid scrolls under them.
                        .safeAreaBar(edge: .top) {
                            VStack(spacing: 0) {
                                HStack {
                                    MediaKindPicker(selection: $browser.mediaFilter)
                                        .frame(maxWidth: 260)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                PhotosHeader(
                                    totalBytes: browser.snapshot.totalBytes, count: browser.snapshot.items.count)
                                StorageBarLoader(
                                    items: browser.snapshot.items, preset: model.effectivePreset(for:),
                                    presetKey: AnyHashable([
                                        AnyHashable(model.preset), AnyHashable(model.presetOverrides),
                                    ]))
                                PhotosNotes(authorization: photos.authorization, indexStatus: photos.indexStatus)
                            }
                        }
                        .safeAreaBar(edge: .bottom) {
                            if let error = photos.loadError { LibraryProblemNote(text: error) }
                        }
                }
            }
            .navigationSubtitle(subtitle)
            .toolbar { GridToolbar(browser: browser) }
            .assistantSearchable(
                search: model.assistant.photosSearch, browser: browser, sidebarBadge: nil, shrunkIDs: nil
            )
            .quickLookPreview($model.quickLookURL)
        }

        @ViewBuilder private func grid(_ browser: LibraryBrowser) -> some View {
            @Bindable var browser = browser
            let sections = model.photoSections
            if sections.isEmpty {
                Group {
                    if browser.quality.isActive && browser.search.isEmpty {
                        NoMatchingVideos { browser.quality = QualityFilter() }
                    } else {
                        ContentUnavailableView.search(text: browser.search)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaGrid(
                    sections: sections, selection: $browser.selection, name: \.name,
                    actions: MediaGridActions(open: model.showInPhotos, quickLook: model.quickLookPhotoPoster)
                ) { item, state in
                    LibraryTile(
                        item: item, state: state, thumbnails: model.thumbnailSource,
                        savingsBadge: LibraryInsight.savingsBadge(
                            for: item, preset: model.effectivePreset(for: item), imageSpec: model.imageAdvanced.spec)
                    ).equatable()
                        .contextMenu { PhotoTileMenu(model: model, item: item) }
                }
            }
        }

        /// "218 of 1,203 videos · 29.8 GB · 3 selected, 1.2 GB"; what is still being read goes at the end.
        private var subtitle: String {
            guard !model.photos.items.isEmpty else { return "" }
            return model.subtitle(
                for: model.photosBrowser, total: model.photos.items.count, selected: model.selectedPhotoItems,
                activity: model.photos.isScanning ? "Reading…" : nil)
        }
    }

    /// Nothing to show yet: loading, a failed read, or a library without videos.
    private struct PhotosEmpty: View {
        let isLoading: Bool
        let error: String?
        let retry: () -> Void

        var body: some View {
            if let error {
                ContentUnavailableView {
                    Label("Couldn't Read Photos", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: retry)
                }
            } else if isLoading {
                ProgressView("Reading your Photos videos…")
            } else {
                EmptyState(
                    "No Videos in Photos", systemImage: "photo.on.rectangle",
                    message: "Videos you record or import show up here.")
            }
        }
    }

    /// How much the videos take now. Nothing is estimated for Photos yet.
    private struct PhotosHeader: View {
        let totalBytes: Int64
        let count: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(totalBytes > 0 ? ByteFormat.string(totalBytes) : "Your Photos library")
                    .font(.title3)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "\(count == 1 ? "1 item" : "\(count) items") · Nothing in Photos changes until you convert it"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }

    /// Small notes that never block the grid: limited access, and what Full Disk Access would add.
    private struct PhotosNotes: View {
        let authorization: PhotoAuthorization
        let indexStatus: PhotosIndexStatus?

        var body: some View {
            if authorization == .limited {
                note(
                    "You gave access to some of your photos only, so other videos aren't listed.",
                    button: "Open System Settings…", url: PrivacySettings.photos)
            }
            switch indexStatus {
            case .noAccess:
                note(
                    "Frame rate and codec filters need Full Disk Access. Everything else works without it.",
                    button: "Open System Settings…", url: PrivacySettings.fullDiskAccess)
            case .notFound, .unreadable:
                note("Frame rate and codec aren't available for this Photos library.", button: nil, url: nil)
            default:
                EmptyView()
            }
        }

        private func note(_ text: String, button: String?, url: URL?) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(text).foregroundStyle(.secondary)
                if let button, let url {
                    Button(button) { PrivacySettings.open(url) }
                        .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    /// A tile's context menu on the Videos page.
    private struct PhotoTileMenu: View {
        let model: ConvertModel
        let item: VideoItem

        var body: some View {
            Button("Add to Queue", systemImage: "plus") { model.addPhotosToQueue(clicked: item) }
            Button("Compress…", systemImage: "rectangle.compress.vertical") { model.compressPhotosClicked(item) }
            Divider()
            if model.isAskAvailable {
                Button("Ask About This…", systemImage: "sparkles") { model.askAbout(item) }
                Divider()
            }
            Button("Show in Photos", systemImage: "photo.on.rectangle") { model.showInPhotos(item) }
            // The poster frame: the video stays in Photos, so nothing is downloaded or exported.
            Button("Quick Look", systemImage: "eye") { model.quickLookPhotoPoster(of: item) }
        }
    }

    /// The inspector for the Videos page: what the selected videos are, and how to convert them.
    struct PhotosInspector: View {
        @Bindable var model: ConvertModel
        @State private var isChoosingFolder = false

        private var preset: Binding<Preset?> {
            Binding {
                model.photoSelectionPreset
            } set: {
                model.photoSelectionPreset = $0
            }
        }

        private var choice: Binding<PhotosSaveLocation.Choice> {
            Binding {
                model.photosSaveLocation.choice
            } set: { newValue in
                if newValue == .folder, model.photosSaveLocation.folderBookmark == nil {
                    isChoosingFolder = true
                } else {
                    model.photosSaveLocation.choice = newValue
                }
            }
        }

        var body: some View {
            let items = model.selectedPhotoItems
            let images = items.filter(\.isImage)
            let videos = items.filter(\.isVideo)
            if items.isEmpty {
                EmptyState(
                    "No Selection", systemImage: "rectangle.dashed",
                    message: "Select videos or images to see their details.")
            } else {
                Form {
                    if items.count == 1 {
                        Section { ItemSummaryHeader(item: items[0], thumbnails: model.thumbnailSource) }
                    } else {
                        Section {
                            Text(
                                "\(items.count) items · \(ByteFormat.string(items.reduce(0) { $0 + $1.byteSize }))"
                            )
                            .font(.headline)
                        }
                    }
                    if let prediction = LibraryInsight.prediction(
                        for: items, preset: model.effectivePreset(for:), imageSpec: model.imageAdvanced.spec)
                    {
                        Section {
                            PredictedSavingsGauge(
                                prediction: prediction, presetName: model.photoSelectionPreset?.displayName)
                        }
                    }
                    if !images.isEmpty {
                        ImageInspectorSection(
                            options: $model.imageAdvanced,
                            singleItem: items.count == 1 ? items[0] : nil,
                            items: images)
                    }
                    if !videos.isEmpty {
                        Section {
                            Picker("Quality preset for the selected videos", selection: preset) {
                                if preset.wrappedValue == nil { Text("Mixed").tag(Preset?.none) }
                                ForEach(Preset.allCases, id: \.self) { Text($0.displayName).tag(Preset?.some($0)) }
                            }
                            .labelsHidden()
                        } header: {
                            Text(images.isEmpty ? "Quality" : "Video Quality")
                        } footer: {
                            Text("Details are checked when each video is converted.")
                        }
                    }
                    Section {
                        Picker("Save To", selection: choice) {
                            ForEach(PhotosSaveLocation.Choice.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Save To")
                        if model.photosSaveLocation.choice == .folder {
                            FolderStatusRow(
                                folder: model.photosSaveLocation.folder,
                                buttonTitle: "Change…",
                                accessibilityLabel: "Change the output folder"
                            ) {
                                isChoosingFolder = true
                            }
                        }
                    } header: {
                        Text("Save To")
                    } footer: {
                        Text(model.photosSaveLocation.choice.footerNote)
                    }
                }
                .formStyle(.grouped)
                .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try? model.photosSaveLocation.setFolder(url)
                }
            }
        }
    }
#endif
