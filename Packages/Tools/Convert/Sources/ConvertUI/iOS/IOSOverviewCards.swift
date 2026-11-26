#if os(iOS)
    import AppCore
    import AppUI
    import Charts
    import Convert
    import SwiftUI

    // MARK: - Hero

    /// The Overview's hero: a ring of where the space stands (saved, could free, stays) and one line saying what it
    /// means. The ring is a Swift Charts donut, so VoiceOver reads each part.
    struct IOSSavingsHero: View {
        let snapshot: SavingsStatsSnapshot?
        let activity: ActivitySummary
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 190

        private struct Part: Identifiable {
            let name: String
            let bytes: Int64
            var id: String { name }
        }

        private var parts: [Part] {
            guard let snapshot else { return [] }
            let stays = max(0, snapshot.totalBytes - snapshot.couldFree)
            return [
                Part(name: "Saved", bytes: snapshot.savedBytes),
                Part(name: "Could Free", bytes: snapshot.couldFree),
                Part(name: "Stays", bytes: stays),
            ]
        }

        private var hasData: Bool { parts.contains { $0.bytes > 0 } }

        var body: some View {
            VStack(spacing: 20) {
                ring
                    .frame(width: ringSize, height: ringSize)
                VStack(spacing: 6) {
                    Text(headline)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityIdentifier("overview.hero")
        }

        @ViewBuilder private var ring: some View {
            if snapshot == nil {
                ProgressView()
            } else {
                Chart(hasData ? parts : [Part(name: "Empty", bytes: 1)]) { part in
                    SectorMark(
                        angle: .value("Space", part.bytes), innerRadius: .ratio(0.7), angularInset: 2
                    )
                    .cornerRadius(8)
                    .foregroundStyle(by: .value("Part", part.name))
                    .accessibilityLabel(part.name)
                    .accessibilityValue(hasData ? ByteFormat.string(part.bytes) : "Nothing yet")
                }
                .chartForegroundStyleScale([
                    "Saved": Color.green, "Could Free": Color.blue, "Stays": Color(.systemFill),
                    "Empty": Color(.systemFill),
                ])
                .chartLegend(.hidden)
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        Text(ByteFormat.string(snapshot?.savedBytes ?? 0))
                            .font(.title2.bold())
                            .contentTransition(.numericText())
                        Text("Saved")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }
                .animation(reduceMotion ? nil : .smooth, value: snapshot)
            }
        }

        private var headline: String {
            guard let snapshot else { return "Looking at Your Videos" }
            if snapshot.savedBytes > 0 { return "You've Saved \(ByteFormat.string(snapshot.savedBytes))" }
            if snapshot.couldFree > 0 { return "About \(ByteFormat.string(snapshot.couldFree)) Could Be Freed" }
            return "Nothing to Shrink Yet"
        }

        private var detail: String {
            guard let snapshot else { return "Reading sizes. Nothing leaves \(DeviceCopy.thisDevice)." }
            if snapshot.savedBytes > 0, snapshot.couldFree > 0 {
                return "About \(ByteFormat.string(snapshot.couldFree)) more could be freed from what's left."
            }
            if snapshot.savedBytes > 0 { return "Your videos are as small as they can get at this preset." }
            if snapshot.couldFree > 0 { return "Add videos to the queue to keep smaller copies that look the same." }
            return "Videos you record or add will show up here."
        }
    }

    // MARK: - Cards

    /// A pinned summary: a title with its symbol, a value, and a mini chart. It opens the page it summarizes.
    struct IOSInsightCard<Chart: View>: View {
        let title: String
        let systemImage: String
        let tint: Color
        let value: String
        let caption: String
        let identifier: String
        let open: () -> Void
        @ViewBuilder var chart: Chart

        var body: some View {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(title, systemImage: systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(value)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    chart
                        .frame(height: 44)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .background(.background.secondary, in: .rect(cornerRadius: 20))
                .contentShape(.rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(value). \(caption)")
            .accessibilityHint("Opens \(title)")
            .accessibilityIdentifier(identifier)
        }
    }

    /// The pinned cards: space saved, what could be freed, the queue, and the biggest groups.
    struct IOSInsightCards: View {
        let snapshot: SavingsStatsSnapshot?
        let history: [SavingsDay]
        let activity: ActivitySummary
        let open: (IOSPage) -> Void

        private struct Count: Identifiable {
            let name: String
            let value: Int
            var id: String { name }
        }

        private var counts: [Count] {
            [
                Count(name: "Waiting", value: activity.queue), Count(name: "Done", value: activity.completed),
                Count(name: "Kept", value: activity.keptAsIs), Count(name: "Failed", value: activity.failed),
            ]
        }

        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                IOSInsightCard(
                    title: "Space Saved", systemImage: "arrow.down.circle.fill", tint: .green,
                    value: ByteFormat.string(snapshot?.savedBytes ?? 0),
                    caption: activity.completed == 1 ? "1 conversion" : "\(activity.completed) conversions",
                    identifier: "card.saved", open: { open(.completed) }
                ) {
                    Chart(history) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Saved", day.savedBytes))
                            .foregroundStyle(.green)
                            .cornerRadius(3)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                }
                IOSInsightCard(
                    title: "Could Free", systemImage: "sparkles", tint: .blue,
                    value: ByteFormat.string(snapshot?.couldFree ?? 0),
                    caption: "In Photos and Files",
                    identifier: "card.couldFree",
                    open: {
                        open((snapshot?.photos.couldFree ?? 0) >= (snapshot?.files.couldFree ?? 0) ? .photos : .files)
                    }
                ) {
                    Chart {
                        BarMark(x: .value("Freed", snapshot?.photos.couldFree ?? 0), y: .value("Library", "Photos"))
                            .foregroundStyle(.blue)
                        BarMark(x: .value("Freed", snapshot?.files.couldFree ?? 0), y: .value("Library", "Files"))
                            .foregroundStyle(.cyan)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                }
                IOSInsightCard(
                    title: "Queue", systemImage: "list.bullet.rectangle.fill", tint: .orange,
                    value: activity.queue == 0 ? "Idle" : "\(activity.queue) Left",
                    caption: activity.failed > 0 ? "\(activity.failed) failed" : "Converting on this device",
                    identifier: "card.queue", open: { open(.queue) }
                ) {
                    Chart(counts) { count in
                        BarMark(x: .value("Status", count.name), y: .value("Videos", count.value))
                            .foregroundStyle(by: .value("Status", count.name))
                            .cornerRadius(3)
                    }
                    .chartForegroundStyleScale([
                        "Waiting": Color.orange, "Done": Color.green, "Kept": Color.gray, "Failed": Color.red,
                    ])
                    .chartLegend(.hidden)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                }
                IOSInsightCard(
                    title: "Biggest Groups", systemImage: "rectangle.3.group.fill", tint: .purple,
                    value: snapshot?.groups.first?.title ?? "None Yet",
                    caption: snapshot?.groups.first.map { "Could free \(ByteFormat.string($0.couldFree))" }
                        ?? "Groups appear once videos load",
                    identifier: "card.groups", open: { open(.files) }
                ) {
                    Chart(snapshot?.groups.prefix(4).map { $0 } ?? []) { group in
                        BarMark(x: .value("Freed", group.couldFree), y: .value("Group", group.title))
                            .foregroundStyle(.purple)
                            .cornerRadius(3)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                }
            }
            .accessibilityIdentifier("overview.cards")
        }
    }

    // MARK: - Trends

    /// Full-size charts with axes, for the Overview's Trends section.
    struct IOSTrendCharts: View {
        let snapshot: SavingsStatsSnapshot?
        let history: [SavingsDay]

        private static let dayFormat = Date.FormatStyle().month(.abbreviated).day()

        var body: some View {
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Space Saved by Day")
                        .font(.headline)
                    Chart(history) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Saved", day.savedBytes))
                            .foregroundStyle(.green.gradient)
                            .cornerRadius(4)
                            .accessibilityLabel(day.date.formatted(Self.dayFormat))
                            .accessibilityValue(ByteFormat.string(day.savedBytes))
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) { Text(ByteFormat.string(bytes)) }
                            }
                        }
                    }
                    .frame(height: 160)
                    .accessibilityChartDescriptor(
                        BarChartDescriptor(
                            title: "Space Saved by Day",
                            summary: "Bytes freed by the conversions that finished on each day.",
                            xTitle: "Day", yTitle: "Saved",
                            points: history.map { ($0.date.formatted(Self.dayFormat), Double($0.savedBytes)) }))
                }
                .padding(.vertical, 4)
            }
            if let groups = snapshot?.groups, !groups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Savings by Group")
                        .font(.headline)
                    Chart(groups.prefix(6).map { $0 }) { group in
                        BarMark(x: .value("Could free", group.couldFree), y: .value("Group", group.title))
                            .foregroundStyle(.purple.gradient)
                            .cornerRadius(4)
                            .accessibilityLabel(group.title)
                            .accessibilityValue("Could free \(ByteFormat.string(group.couldFree))")
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) { Text(ByteFormat.string(bytes)) }
                            }
                        }
                    }
                    .frame(height: CGFloat(min(groups.count, 6)) * 36 + 36)
                    .accessibilityChartDescriptor(
                        BarChartDescriptor(
                            title: "Savings by Group",
                            summary: "What converting each group of videos would free.",
                            xTitle: "Group", yTitle: "Could free",
                            points: groups.prefix(6).map { ($0.title, Double($0.couldFree)) }))
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The audio-graph description VoiceOver offers for a bar chart: its axes, values and a summary.
    struct BarChartDescriptor: AXChartDescriptorRepresentable {
        let title: String
        let summary: String
        let xTitle: String
        let yTitle: String
        let points: [(String, Double)]

        func makeChartDescriptor() -> AXChartDescriptor {
            let x = AXCategoricalDataAxisDescriptor(title: xTitle, categoryOrder: points.map(\.0))
            let top = max(points.map(\.1).max() ?? 1, 1)
            let y = AXNumericDataAxisDescriptor(
                title: yTitle, range: 0...top, gridlinePositions: []
            ) { ByteFormat.string(Int64($0)) }
            let series = AXDataSeriesDescriptor(
                name: title, isContinuous: false,
                dataPoints: points.map { AXDataPoint(x: $0.0, y: $0.1) })
            return AXChartDescriptor(
                title: title, summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
        }

        func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
    }
#endif
