#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI

    /// "Good Morning", "Good Afternoon" or "Good Evening" for the hour.
    enum IOSGreeting {
        static func text(at date: Date = Date(), calendar: Calendar = .current) -> String {
            switch calendar.component(.hour, from: date) {
            case 5..<12: "Good Morning"
            case 12..<18: "Good Afternoon"
            default: "Good Evening"
            }
        }
    }

    /// Home's "Continue": the job converting now (or the queue waiting), with its progress; it opens the queue.
    struct IOSContinueSection: View {
        let model: ConvertModel
        @Environment(\.openToolRoute) private var openRoute

        private var running: Job? {
            model.queuedJobs.first {
                if case .running = $0.state { return true }
                return false
            }
        }

        private var progress: Double? {
            if let running, case .running(let value) = running.state { return value }
            return nil
        }

        private var detail: String {
            // Before the person taps Start the videos are ready, not paused.
            if model.waitsForStart {
                let count = model.activity.queue
                return count == 1 ? "1 video ready to start" : "\(count) videos ready to start"
            }
            if let pause = model.queuePause.statusText { return pause }
            if let progress { return "\(running?.phaseTitle ?? "Converting") · \(Int((progress * 100).rounded()))%" }
            let count = model.activity.queue
            return count == 1 ? "1 video waiting" : "\(count) videos waiting"
        }

        var body: some View {
            if model.activity.queue > 0 {
                Section("Continue") {
                    Button {
                        openRoute(model.route(to: .queue))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(
                                    running?.displayName ?? "Queue",
                                    systemImage: model.queuePause.isPaused && !model.waitsForStart
                                        ? "pause.circle.fill" : "arrow.triangle.2.circlepath"
                                )
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            if let progress {
                                ProgressView(value: progress)
                                    .accessibilityHidden(true)
                            }
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home.continue")
                }
            }
        }
    }

    /// Home's "Ready to Save": the biggest groups of videos that could shrink, each a tap away from its Library page
    /// already filtered to that group.
    struct IOSReadySection: View {
        let model: ConvertModel
        @Environment(\.openToolRoute) private var openRoute

        private var buckets: [SavingsBucket] {
            model.assistant.smartPicks.buckets.filter { $0.couldFree > 0 }.prefix(6).map { $0 }
        }

        var body: some View {
            let buckets = buckets
            if !buckets.isEmpty {
                Section("Ready to Save") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(buckets, id: \.identity) { bucket in
                                Button {
                                    model.show(bucket)
                                    openRoute(model.routeToSelection())
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(bucket.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("Could free \(ByteFormat.string(bucket.couldFree))")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                        Text(bucket.detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 170, alignment: .leading)
                                    .padding(12)
                                    .background(.fill.tertiary, in: .rect(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollClipDisabled()
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("home.ready")
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Home's "Recent": the last few finished conversions with what each saved; it opens Completed.
    struct IOSRecentSection: View {
        let model: ConvertModel
        @Environment(\.openToolRoute) private var openRoute

        var body: some View {
            let recent = model.completedJobs.prefix(3)
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(Array(recent), id: \.job.id) { entry in
                        Button {
                            openRoute(model.route(to: .completed))
                        } label: {
                            HStack {
                                Text(entry.job.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(
                                    "Saved \(ByteFormat.string(max(0, entry.outcome.bytesBefore - entry.outcome.bytesAfter)))"
                                )
                                .font(.callout)
                                .foregroundStyle(.green)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
#endif
