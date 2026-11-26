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
                ("Concert", 3_100_000_000, 1_100_000_000), ("Road Trip", 1_400_000_000, 560_000_000),
                ("Garden", 800_000_000, 300_000_000),
            ].map { name, before, after in
                (Self.job(name, .queued), Self.outcome(name, before: Int64(before), after: Int64(after)))
            }

            for dark in [false, true] {
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
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(queued) { job in
                            QueueRow(job: job, pauseText: nil, thumbnails: cache) {}
                            Divider()
                        }
                    }.padding(16),
                    name: "queue", size: CGSize(width: 760, height: 260), dark: dark, folder: folder)
                try Self.write(
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(finished, id: \.0.id) { job, outcome in
                            CompletedRow(job: job, outcome: outcome, thumbnails: cache, assistant: model.assistant)
                            Divider()
                        }
                    }.padding(16),
                    name: "completed", size: CGSize(width: 760, height: 260), dark: dark, folder: folder)
            }
        }
    }
#endif
