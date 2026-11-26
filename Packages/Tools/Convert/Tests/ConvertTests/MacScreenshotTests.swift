#if os(macOS)
    import AppCore
    import AppKit
    import AppServices
    import AppUI
    import Foundation
    import LocalLibrary
    import PhotosLibrary
    import SwiftUI
    import Testing

    @testable import Convert
    @testable import ConvertUI

    /// Renders the redesigned Mac pages to PNGs for design review with `ImageRenderer`, from made-up numbers and jobs
    /// (never the user's media). Lists and the window frame can't be drawn this way, so the Queue and Completed pages are
    /// shown as their rows. Skipped unless `AARIK_MAC_SHOTS` names the folder to write to:
    ///
    ///     AARIK_MAC_SHOTS=/path/to/folder swift test --filter MacScreenshotTests
    @MainActor
    @Suite(.serialized) struct MacScreenshotTests {
        private static let day: TimeInterval = 86_400

        private static func snapshot() -> SavingsSnapshot {
            let today = Calendar.current.startOfDay(for: Date())
            let saved: [Int64] = [1_200_000_000, 0, 900_000_000, 1_400_000_000, 0, 2_000_000_000, 700_000_000]
            let days = saved.enumerated().compactMap { index, bytes -> SavingsSnapshot.Day? in
                bytes == 0
                    ? nil
                    : SavingsSnapshot.Day(
                        day: today.addingTimeInterval(-Double(6 - index) * day), videos: Int(bytes / 600_000_000) + 1,
                        savedBytes: bytes)
            }
            return SavingsSnapshot(
                updatedAt: Date().addingTimeInterval(-90),
                libraries: [
                    .init(name: "Videos in Photos", count: 218, bytes: 59_400_000_000, couldFree: 41_000_000_000),
                    .init(name: "Local Files", count: 34, bytes: 12_800_000_000, couldFree: 6_900_000_000),
                ],
                groups: [
                    .init(id: "B1", title: "4K from 2026 · Photos", bytes: 18_400_000_000),
                    .init(id: "B2", title: "4K from 2025 · Photos", bytes: 12_100_000_000),
                    .init(id: "B3", title: "1080p from 2025 · Photos", bytes: 7_600_000_000),
                    .init(id: "B4", title: "4K from 2024 · Local Files", bytes: 4_300_000_000),
                    .init(id: "B5", title: "1080p from 2024 · Photos", bytes: 2_900_000_000),
                ], days: days, savedBytes: saved.reduce(0, +), conversions: 17)
        }

        private static func write<Content: View>(
            _ content: Content, name: String, size: CGSize, dark: Bool, folder: URL
        ) throws {
            _ = NSApplication.shared
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root =
                content
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = appearance
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.alphaValue = 0
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            window.close()
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: folder.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
        }

        private static func job(_ name: String, _ state: JobState, daysAgo: Double = 0) -> Job {
            Job(
                toolID: ConvertTool.toolID, source: URL(filePath: "/Users/example/Movies/\(name).mov"),
                sourceBookmark: Data(), settings: Data("{}".utf8), state: state,
                createdAt: Date().addingTimeInterval(-daysAgo * day))
        }

        private static func outcome(_ name: String, before: Int64, after: Int64) -> JobOutcome {
            JobOutcome(
                output: URL(filePath: "/Users/example/Movies/\(name) (smaller).mov"), bytesBefore: before,
                bytesAfter: after, report: MetadataReport(), replacedOriginal: false)
        }

        private static func video(
            _ name: String, megabytes: Int64, width: Int = 3840, height: Int = 2160, fps: Double = 60,
            seconds: Double? = nil, badges: Set<MediaBadge> = [], location: Bool = false
        ) -> VideoItem {
            func item(_ key: String, _ category: MetadataCategory, _ value: String) -> MetadataItem {
                MetadataItem(key: key, category: category, displayName: key, value: value)
            }
            // About 100 Mbit/s, as an iPhone records 4K.
            let seconds = seconds ?? Double(megabytes) / 12
            var items = [
                item("video.dimensions", .video, "\(width)x\(height)"),
                item("video.frameRate", .video, String(fps)), item("video.duration", .video, String(seconds * 1000)),
            ]
            if location { items.append(item("qt.location", .location, "1,2")) }
            return VideoItem(
                id: UUID(), url: URL(filePath: "/Users/example/Movies/\(name).mov"), byteSize: megabytes * 1_000_000,
                duration: seconds, pixelSize: CGSize(width: width, height: height), frameRate: fps,
                captureDate: Date(), badges: badges, isAvailable: true, inventory: MetadataInventory(items: items))
        }

        /// A made-up frame: bands of colour, sharp or with its stripes softened.
        private static func frame(softened: Bool) -> CGImage? {
            let context = CGContext(
                data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let context else { return nil }
            let colors: [(CGFloat, CGFloat, CGFloat)] = [
                (0.1, 0.4, 0.8), (0.9, 0.5, 0.2), (0.2, 0.7, 0.4), (0.8, 0.2, 0.5), (0.95, 0.85, 0.3),
            ]
            for (index, color) in colors.enumerated() {
                let mix: CGFloat = softened ? 0.35 : 0
                context.setFillColor(
                    red: color.0 * (1 - mix) + 0.5 * mix, green: color.1 * (1 - mix) + 0.5 * mix,
                    blue: color.2 * (1 - mix) + 0.5 * mix, alpha: 1)
                context.fill(CGRect(x: index * 256, y: 0, width: 256, height: 720))
            }
            return context.makeImage()
        }

        @Test func rendersThePages() throws {
            guard let path = ProcessInfo.processInfo.environment["AARIK_MAC_SHOTS"] else { return }
            let folder = URL(filePath: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let directory = URL.temporaryDirectory.appending(
                path: "mac-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let services = AppServices(
                directory: directory, defaults: UserDefaults(suiteName: "MacShots-\(UUID().uuidString)")!,
                photoStore: FakePhotoStore())
            let model = ConvertModel(services: services)
            let cache = ThumbnailCache()
            let charts = OverviewCharts(snapshot: Self.snapshot())

            let sidebar = VideoSidebar.sections(
                VideoSidebarState(
                    photosCount: 218, localCount: 34, badgeCounts: [:],
                    activity: ActivitySummary(jobs: [
                        Self.job("a", .completed(Self.outcome("a", before: 1000, after: 400)))
                    ])))
            let queued = [
                Self.job("Lake House", .running(progress: 0.42)), Self.job("Night Walk", .queued),
                Self.job("Kitchen", .queued),
            ]
            let finished = [
                ("Concert", 3_100_000_000, 1_100_000_000, 0.0), ("Road Trip", 1_400_000_000, 560_000_000, 0.0),
                ("Garden", 800_000_000, 300_000_000, 1.0), ("Birthday", 2_200_000_000, 700_000_000, 2.0),
                ("Hike", 1_900_000_000, 800_000_000, 4.0),
            ].map { name, before, after, ago in
                (
                    job: Self.job(name, .queued, daysAgo: ago),
                    outcome: Self.outcome(name, before: Int64(before), after: Int64(after))
                )
            }
            let kept = [("Screen Recording", 0.0), ("Clip", 1.0)].map { name, ago in
                (job: Self.job(name, .queued, daysAgo: ago), reason: "Already small enough; converting wouldn't help.")
            }
            let completedDays = ResultsLedger.days(finished, date: \.job.createdAt, saved: \.outcome.savedBytes)
            let keptDays = ResultsLedger.days(kept, date: \.job.createdAt, saved: { _ in 0 })

            let library = [
                Self.video("Lake House", megabytes: 2400, badges: [.dolbyVision, .hdr, .k4], location: true),
                Self.video("Night Walk", megabytes: 1500, badges: [.hdr, .k4]),
                Self.video("Kitchen", megabytes: 900, badges: [.k4]),
                Self.video("Garden", megabytes: 600, width: 1920, height: 1080, fps: 30, badges: []),
                Self.video("Clip", megabytes: 8, width: 1280, height: 720, fps: 30, seconds: 3),
                Self.video("Dock", megabytes: 1200, badges: [.k4]),
            ]
            var timeline = ProgressTimeline()
            var begun = queued[0]
            begun.state = .running(progress: 0)
            timeline.observe([begun], now: Date().addingTimeInterval(-20))
            timeline.observe([queued[0]], now: Date())
            let selected = library[0]
            for dark in [false, true] {
                if let sharp = Self.frame(softened: false), let soft = Self.frame(softened: true) {
                    try Self.write(
                        BeforeAfterSlider(before: sharp, after: soft).padding(16),
                        name: "compare", size: CGSize(width: 720, height: 440), dark: dark, folder: folder)
                }
                try Self.write(
                    VStack(spacing: 0) {
                        SavingsHeader(couldFree: 4_100_000_000, totalBytes: 6_600_000_000, availableCount: 6) {
                            PresetPicker(
                                "Quality Preset", selection: Binding.constant(Preset.balanced),
                                options: Preset.allCases
                            ) { (preset: Preset) in preset.displayName }
                        }
                        StorageBar(breakdown: StorageBreakdown.make(items: library, preset: { _ in .balanced }))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12)
                        {
                            ForEach(library) { item in
                                LibraryTile(
                                    item: item, state: MediaTileState(isSelected: item.id == selected.id),
                                    thumbnails: model.thumbnailSource,
                                    savingsBadge: LibraryInsight.savingsBadge(for: item, preset: .balanced))
                            }
                        }
                        .padding(16)
                    },
                    name: "library", size: CGSize(width: 760, height: 560), dark: dark, folder: folder)
                try Self.write(
                    Form {
                        Section { ItemSummaryHeader(item: selected, thumbnails: model.thumbnailSource) }
                        if let prediction = LibraryInsight.prediction(for: [selected], preset: { _ in .balanced }) {
                            Section { PredictedSavingsGauge(prediction: prediction, presetName: "Balanced") }
                        }
                    }
                    .formStyle(.grouped),
                    name: "inspector", size: CGSize(width: 320, height: 520), dark: dark, folder: folder)
                try Self.write(
                    OverviewInsights(charts: charts, presetName: "Balanced", isRefreshing: false).padding(24),
                    name: "overview", size: CGSize(width: 940, height: 1080), dark: dark, folder: folder)
                try Self.write(
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sidebar, id: \.id) { section in
                            Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 10).padding(.leading, 8)
                            ForEach(section.items, id: \.id) { item in
                                HStack {
                                    SidebarRowLabel(title: item.title, systemImage: item.systemImage, tint: item.tint)
                                    Spacer()
                                    if let count = item.count, count > 0 {
                                        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                                .padding(.vertical, 3).padding(.horizontal, 8)
                                .background {
                                    if item.title == "Overview" {
                                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1))
                                    }
                                }
                            }
                        }
                    }
                    .padding(10),
                    name: "sidebar", size: CGSize(width: 240, height: 360), dark: dark, folder: folder)
                try Self.write(
                    SavingsHeader(couldFree: 41_000_000_000, totalBytes: 59_400_000_000, availableCount: 218) {
                        PresetPicker(
                            "Quality Preset", selection: Binding.constant(Preset.balanced), options: Preset.allCases
                        ) { (preset: Preset) in
                            preset.displayName
                        }
                    },
                    name: "library-header", size: CGSize(width: 860, height: 90), dark: dark, folder: folder)
                try Self.write(
                    VStack(alignment: .leading, spacing: 0) {
                        QueueHeader(
                            jobs: queued, timeline: timeline, pauseText: nil, speed: .constant(.balanced))
                        Divider()
                        ForEach(Array(queued.enumerated()), id: \.element.id) { index, job in
                            QueueRow(
                                job: job, pauseText: nil, thumbnails: cache,
                                sizes: QueueSizes(
                                    before: 2_400_000_000 - Int64(index) * 700_000_000, after: 900_000_000),
                                remaining: timeline.remaining(for: job.id)
                            ) {}
                            .padding(.horizontal, 16).padding(.vertical, 4)
                            Divider()
                        }
                    },
                    name: "queue", size: CGSize(width: 760, height: 330), dark: dark, folder: folder)
                try Self.write(
                    VStack(alignment: .leading, spacing: 0) {
                        LedgerSummary(
                            days: completedDays, savedBytes: finished.reduce(0) { $0 + $1.outcome.savedBytes },
                            count: finished.count)
                        Divider()
                        ForEach(completedDays, id: \.day) { day in
                            LedgerDayHeader(
                                title: day.title, detail: "Saved \(ByteFormat.string(day.savedBytes))"
                            )
                            .padding(.horizontal, 16).padding(.top, 10)
                            ForEach(day.rows, id: \.job.id) { row in
                                CompletedRow(
                                    job: row.job, outcome: row.outcome, thumbnails: cache,
                                    assistant: model.assistant
                                )
                                .padding(.horizontal, 16)
                                Divider()
                            }
                        }
                    },
                    name: "completed", size: CGSize(width: 760, height: 620), dark: dark, folder: folder)
                try Self.write(
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(keptDays, id: \.day) { day in
                            LedgerDayHeader(title: day.title, detail: ActivityText.videos(day.rows.count))
                                .padding(.horizontal, 16).padding(.top, 10)
                            ForEach(day.rows, id: \.job.id) { row in
                                ReasonRow(
                                    job: row.job, reason: row.reason, thumbnails: cache, assistant: model.assistant,
                                    badge: "Kept as Is"
                                )
                                .padding(.horizontal, 16)
                                Divider()
                            }
                        }
                    },
                    name: "kept-as-is", size: CGSize(width: 760, height: 260), dark: dark, folder: folder)
            }
        }
    }
#endif
