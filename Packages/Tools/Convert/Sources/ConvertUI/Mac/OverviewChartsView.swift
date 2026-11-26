#if os(macOS)
    import AppUI
    import Charts
    import Convert
    import SwiftUI

    /// The Overview's top half, drawn from cached numbers: a savings ring with one sentence about it, a row of summary
    /// cards that each hold a small chart, and larger trend charts. System colours only (so they follow the appearance and
    /// Increase Contrast); every chart has a spoken summary and per-mark values, and a chart without data says so.
    struct OverviewInsights: View {
        let charts: OverviewCharts
        let presetName: String
        let isRefreshing: Bool

        private static let cardColumns = [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)]
        private static let trendColumns = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                SavingsHero(charts: charts, presetName: presetName, isRefreshing: isRefreshing)
                LazyVGrid(columns: Self.cardColumns, spacing: 12) {
                    SummaryCard(
                        title: "Could Free", systemImage: "arrow.down.right.circle.fill", tint: .blue,
                        value: charts.couldFree > 0 ? ByteFormat.string(charts.couldFree) : "Nothing",
                        detail: "at the \(presetName) preset"
                    ) {
                        MiniBars(
                            values: charts.sizes.flatMap { [$0.now, $0.after] }.map(Double.init), tint: .blue)
                    }
                    SummaryCard(
                        title: "Saved So Far", systemImage: "checkmark.circle.fill", tint: .green,
                        value: ByteFormat.string(charts.savedBytes),
                        detail: charts.hasHistory ? "across all conversions" : "after the first conversion"
                    ) {
                        MiniArea(points: charts.savedOverTime, tint: .green)
                    }
                    SummaryCard(
                        title: "Converted", systemImage: "film.stack.fill", tint: .orange,
                        value: charts.conversions.formatted(),
                        detail: charts.conversions == 1 ? "video" : "videos"
                    ) {
                        MiniBars(values: charts.throughput.map { Double($0.videos) }, tint: .orange)
                    }
                    SummaryCard(
                        title: "Biggest Group", systemImage: "rectangle.stack.fill", tint: .purple,
                        value: charts.groups.first.map { ByteFormat.string($0.bytes) } ?? "None",
                        detail: charts.groups.first?.title ?? "Nothing to free"
                    ) {
                        MiniBars(values: charts.groups.map { Double($0.bytes) }, tint: .purple)
                    }
                }
                Text("Trends")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Self.trendColumns, spacing: 16) {
                    BeforeAfterChart(sizes: charts.sizes)
                    GroupSavingsChart(groups: charts.groups)
                    SavedOverTimeChart(points: charts.savedOverTime)
                    ThroughputChart(days: charts.throughput)
                }
            }
        }
    }

    // MARK: - Hero

    /// A ring of how much of the library could go, beside one sentence that says it in words.
    private struct SavingsHero: View {
        let charts: OverviewCharts
        let presetName: String
        let isRefreshing: Bool

        private struct Slice: Identifiable {
            let name: String
            let bytes: Double
            var id: String { name }
        }

        private var slices: [Slice] {
            [
                Slice(name: "Could free", bytes: Double(charts.couldFree)),
                Slice(name: "Stays", bytes: Double(max(0, charts.totalBytes - charts.couldFree))),
            ]
        }

        private var percent: String { charts.freeFraction.formatted(.percent.precision(.fractionLength(0))) }

        /// The headline, in words, for what the ring shows.
        private var insight: String {
            guard charts.totalBytes > 0 else { return "Add videos to see what converting them could free." }
            guard charts.couldFree > 0 else { return "Your videos are already about as small as they get." }
            return
                "Converting could free about \(ByteFormat.string(charts.couldFree)), \(percent) of your videos' size."
        }

        var body: some View {
            GroupBox {
                HStack(spacing: 24) {
                    ring
                    VStack(alignment: .leading, spacing: 6) {
                        Text(insight)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if charts.couldFree > 0 {
                            Text(
                                "\(ByteFormat.string(charts.totalBytes)) now, about "
                                    + "\(ByteFormat.string(max(0, charts.totalBytes - charts.couldFree))) after at the "
                                    + "\(presetName) preset."
                            )
                            .foregroundStyle(.secondary)
                        }
                        Text("Nothing changes until you add videos to the queue.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if isRefreshing {
                                ProgressView().controlSize(.small)
                                Text("Updating…")
                            } else {
                                Text("Updated \(charts.updatedAt.formatted(.relative(presentation: .named)))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
            }
            .accessibilityElement(children: .combine)
        }

        private var ring: some View {
            Chart(slices) { slice in
                SectorMark(angle: .value("Size", slice.bytes), innerRadius: .ratio(0.72), angularInset: 1.5)
                    .cornerRadius(5)
                    .foregroundStyle(by: .value("Part", slice.name))
            }
            .chartForegroundStyleScale(["Could free": Color.blue, "Stays": Color(nsColor: .quaternaryLabelColor)])
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(charts.couldFree > 0 ? percent : "—")
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text("smaller")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            .accessibilityLabel("Share of your videos that could be freed")
            .accessibilityValue(
                charts.couldFree > 0 ? "\(percent), about \(ByteFormat.string(charts.couldFree))" : "None")
        }
    }

    // MARK: - Summary cards

    /// One pinned figure with a small chart under it.
    private struct SummaryCard<Sparkline: View>: View {
        let title: String
        let systemImage: String
        let tint: Color
        let value: String
        let detail: String
        @ViewBuilder let sparkline: Sparkline

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                    Text(value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    sparkline
                        .frame(height: 36)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(value), \(detail)")
        }
    }

    /// A few bars with no axes: the shape of a series, not its numbers.
    private struct MiniBars: View {
        let values: [Double]
        let tint: Color

        var body: some View {
            Chart(Array(values.enumerated()), id: \.offset) { entry in
                BarMark(x: .value("Item", entry.offset), y: .value("Value", entry.element))
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }

    private struct MiniArea: View {
        let points: [OverviewCharts.SavedPoint]
        let tint: Color

        var body: some View {
            Chart(points) { point in
                AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                    .foregroundStyle(tint.opacity(0.25).gradient)
                LineMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }

    // MARK: - Trend charts

    /// A titled box for one chart, with a note in place of the chart when there is nothing to draw.
    private struct ChartBox<Content: View>: View {
        let title: String
        let subtitle: String
        let isEmpty: Bool
        let emptyText: String
        @ViewBuilder let content: Content

        var body: some View {
            GroupBox {
                Group {
                    if isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: Self.height)
                    } else {
                        content.frame(height: Self.height)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private static var height: CGFloat { 160 }
    }

    private struct BeforeAfterChart: View {
        let sizes: [OverviewCharts.SizePair]

        private struct Bar: Identifiable {
            let library: String
            let kind: String
            let bytes: Int64
            var id: String { "\(library)/\(kind)" }
        }

        private var bars: [Bar] {
            sizes.flatMap {
                [
                    Bar(library: $0.library, kind: "Now", bytes: $0.now),
                    Bar(library: $0.library, kind: "After", bytes: $0.after),
                ]
            }
        }

        var body: some View {
            ChartBox(
                title: "Before and After", subtitle: "Size now and after converting", isEmpty: sizes.isEmpty,
                emptyText: "Add videos or allow access to Photos to compare sizes."
            ) {
                Chart(bars) { bar in
                    BarMark(x: .value("Size", bar.bytes), y: .value("Library", bar.library))
                        .foregroundStyle(by: .value("When", bar.kind))
                        .position(by: .value("When", bar.kind))
                        .cornerRadius(3)
                        .accessibilityLabel("\(bar.library), \(bar.kind)")
                        .accessibilityValue(ByteFormat.string(bar.bytes))
                }
                .chartForegroundStyleScale(["Now": Color.indigo.opacity(0.45), "After": Color.indigo])
                .chartXAxis { byteAxisMarks() }
                .accessibilityLabel("Size now and after converting")
                .accessibilityValue(
                    sizes.map {
                        "\($0.library): \(ByteFormat.string($0.now)) now, about \(ByteFormat.string($0.after)) after"
                    }.joined(separator: ". "))
            }
        }
    }

    private struct GroupSavingsChart: View {
        let groups: [OverviewCharts.GroupSaving]

        var body: some View {
            ChartBox(
                title: "Savings by Group", subtitle: "What each group could free", isEmpty: groups.isEmpty,
                emptyText: "Nothing here would get meaningfully smaller at this preset."
            ) {
                Chart(groups) { group in
                    BarMark(x: .value("Could Free", group.bytes), y: .value("Group", group.title))
                        .foregroundStyle(Color.blue.gradient)
                        .cornerRadius(3)
                        .accessibilityLabel(group.title)
                        .accessibilityValue("could free about \(ByteFormat.string(group.bytes))")
                }
                .chartXAxis { byteAxisMarks() }
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.caption) }
                }
                .accessibilityLabel("What each group of videos could free")
                .accessibilityValue(
                    groups.map { "\($0.title): about \(ByteFormat.string($0.bytes))" }.joined(separator: ". "))
            }
        }
    }

    private struct SavedOverTimeChart: View {
        let points: [OverviewCharts.SavedPoint]

        var body: some View {
            ChartBox(
                title: "Space Saved Over Time", subtitle: "Total by the day videos were added",
                isEmpty: points.isEmpty, emptyText: "Appears after the first conversion finishes."
            ) {
                Chart(points) { point in
                    AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(Color.green.opacity(0.22).gradient)
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(Color.green)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(Color.green)
                        .accessibilityLabel(point.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(ByteFormat.string(point.cumulativeBytes)) saved in total")
                }
                .chartYAxis { byteAxisMarks(position: .leading) }
                .accessibilityLabel("Total space saved by day")
                .accessibilityValue(
                    "\(ByteFormat.string(points.last?.cumulativeBytes ?? 0)) saved in total over "
                        + "\(points.count) \(points.count == 1 ? "day" : "days")")
            }
        }
    }

    private struct ThroughputChart: View {
        let days: [OverviewCharts.DayThroughput]

        var body: some View {
            ChartBox(
                title: "Queue Throughput", subtitle: "Videos converted by day", isEmpty: days.isEmpty,
                emptyText: "Appears after the first conversion finishes."
            ) {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Videos", day.videos))
                        .foregroundStyle(Color.orange.gradient)
                        .cornerRadius(3)
                        .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(day.videos == 1 ? "1 video converted" : "\(day.videos) videos converted")
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .accessibilityLabel("Videos converted by day")
                .accessibilityValue(
                    "\(days.reduce(0) { $0 + $1.videos }) videos converted over "
                        + "\(days.count) \(days.count == 1 ? "day" : "days")")
            }
        }
    }

    /// A size axis with byte-formatted labels ("1.2 GB") instead of raw numbers.
    @AxisContentBuilder private func byteAxisMarks(position: AxisMarkPosition = .bottom) -> some AxisContent {
        AxisMarks(position: position, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let bytes = value.as(Int64.self) { Text(bytes == 0 ? "0" : ByteFormat.string(bytes)) }
            }
        }
    }
#endif
