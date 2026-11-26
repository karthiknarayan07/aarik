#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import LocalLibrary
    import Photos
    import PhotosLibrary
    import PhotosUI
    import QuickLook
    import SwiftUI
    import UIKit

    /// Presents PhotoKit's limited library picker from the active key window's top view controller.
    @MainActor
    private enum LimitedLibraryPicker {
        static func present() {
            let scene =
                UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard var controller = scene?.keyWindow?.rootViewController else { return }
            while let presented = controller.presentedViewController {
                controller = presented
            }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        }
    }

    /// iOS Photos browser: reads metadata without downloading originals, handles limited and denied access states
    /// natively, and presents the Photos grid with Apple Intelligence search tokens.
    struct IOSPhotosView: View {
        @Bindable var model: ConvertModel
        /// A video the Search tab asked to open.
        @Binding var incoming: UUID?

        var body: some View {
            let photos = model.photos
            Group {
                if !photos.isAuthorizationKnown {
                    ProgressView()
                } else {
                    switch photos.authorization {
                    case .notDetermined:
                        IOSPhotosAccessPrompt { Task { await photos.requestAccess() } }
                    case .denied, .restricted:
                        IOSPhotosAccessDenied(
                            isRestricted: photos.authorization == .restricted,
                            openSettings: model.openPhotosAccessSettings)
                    case .limited, .authorized:
                        IOSPhotosGridView(model: model, incoming: $incoming)
                    }
                }
            }
            .navigationTitle(IOSPage.photos.title)
            .task { await photos.start() }
        }
    }

    private struct IOSPhotosAccessPrompt: View {
        let allow: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("See Your Photos Videos", systemImage: "photo.on.rectangle")
            } description: {
                Text(
                    "\(AppInfo.displayName) lists your videos without downloading them and changes nothing in Photos "
                        + "until you convert a video.")
            } actions: {
                Button("Allow Access to Photos…", action: allow)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private struct IOSPhotosAccessDenied: View {
        let isRestricted: Bool
        let openSettings: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("Photos Access Is Off", systemImage: "lock")
            } description: {
                Text(
                    isRestricted
                        ? "Access to Photos is restricted on \(DeviceCopy.thisDevice), so its videos can't be shown."
                        : "Allow access to Photos in Settings to see your videos here.")
            } actions: {
                if !isRestricted {
                    Button("Open Settings…", action: openSettings)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private struct IOSPhotosAccessLimited: View {
        let openSettings: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("No Videos Are Shared", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(
                    "You gave \(AppInfo.displayName) access to some of your photos only, and none of them is a video. "
                        + "Choose more videos to see them here.")
            } actions: {
                Button("Choose More Videos…") { LimitedLibraryPicker.present() }
                    .buttonStyle(.borderedProminent)
                Button("Open Settings…", action: openSettings)
            }
        }
    }

    private struct IOSPhotosGridView: View {
        @Bindable var model: ConvertModel
        @Binding var incoming: UUID?
        @State private var opened: UUID?
        @State private var isSelecting = false
        @Namespace private var zoom

        var body: some View {
            @Bindable var browser = model.photosBrowser
            let photos = model.photos
            Group {
                if photos.items.isEmpty {
                    if photos.hasLoaded, photos.loadError == nil, photos.authorization == .limited {
                        IOSPhotosAccessLimited(openSettings: model.openPhotosAccessSettings)
                    } else {
                        IOSPhotosEmpty(isLoading: !photos.hasLoaded, error: photos.loadError) {
                            Task { await photos.start() }
                        }
                    }
                } else {
                    grid(browser)
                        .safeAreaBar(edge: .top) {
                            VStack(spacing: 0) {
                                IOSPhotosHeader(
                                    totalBytes: browser.snapshot.totalBytes, count: browser.snapshot.items.count)
                                if photos.authorization == .limited {
                                    IOSLimitedPhotosNote(openSettings: model.openPhotosAccessSettings)
                                }
                            }
                        }
                        .safeAreaBar(edge: .bottom) {
                            if let error = photos.loadError { IOSProblemNote(text: error) }
                        }
                }
            }
            .navigationSubtitle(subtitle)
            .toolbar { IOSGridToolbar(browser: browser, shareURLs: nil, isSelecting: $isSelecting) }
            .sensoryFeedback(.selection, trigger: browser.selection)
            .safeAreaInset(edge: .bottom) {
                IOSSelectionBar(
                    model: model, count: model.selectedPhotoItems.count, isSelecting: $isSelecting,
                    clear: { browser.selection = [] })
            }
            .animation(.smooth, value: isSelecting)
            .onChange(of: incoming, initial: true) {
                guard let id = incoming else { return }
                incoming = nil
                opened = id
            }
            .navigationDestination(item: $opened) { id in
                IOSVideoDetailView(model: model, id: id)
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
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
                        ContentUnavailableView {
                            Label("No Matching Videos", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No videos here match these filters.")
                        } actions: {
                            Button("Clear Filters") { browser.quality = QualityFilter() }
                        }
                    } else {
                        ContentUnavailableView.search(text: browser.search)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaGrid(
                    sections: sections, selection: $browser.selection, name: \.name,
                    actions: MediaGridActions(open: { opened = $0.first }, quickLook: model.quickLookPhotoPoster),
                    opensOnTap: !isSelecting
                ) { item, state in
                    LibraryTile(item: item, state: state, thumbnails: model.thumbnailSource)
                        .matchedTransitionSource(id: item.id, in: zoom)
                        .contextMenu {
                            Button("Add to Queue", systemImage: "plus") { model.addPhotosToQueue(clicked: item) }
                            Divider()
                            Button("Show in Photos", systemImage: "photo.on.rectangle") { model.showInPhotos(item) }
                            Button("Quick Look", systemImage: "eye") { model.quickLookPhotoPoster(of: item) }
                        } preview: {
                            LibraryTile(item: item, state: MediaTileState(), thumbnails: model.thumbnailSource)
                                .frame(width: 280, height: 190)
                        }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Videos in Photos")
            }
        }

        private var subtitle: String {
            guard !model.photos.items.isEmpty else { return "" }
            return model.subtitle(
                for: model.photosBrowser, total: model.photos.items.count, selected: model.selectedPhotoItems,
                activity: model.photos.isScanning ? "Reading…" : nil)
        }
    }

    private struct IOSPhotosEmpty: View {
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

    private struct IOSPhotosHeader: View {
        let totalBytes: Int64
        let count: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(totalBytes > 0 ? "\(ByteFormat.string(totalBytes)) in videos" : "Your Photos videos")
                    .font(.title3)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "\(count == 1 ? "1 video" : "\(count) videos") · Nothing in Photos changes until you convert a video"
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

    private struct IOSLimitedPhotosNote: View {
        let openSettings: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Limited access: only selected photos are shown.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Choose More…") { LimitedLibraryPicker.present() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Settings…", action: openSettings)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
        }
    }
#endif
