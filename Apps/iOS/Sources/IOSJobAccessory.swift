import AppCore
import Convert
import SwiftUI

/// The accessory over the tab bar, shown only while something is queued and not already on the Queue page.
struct IOSJobAccessoryModifier: ViewModifier {
    let model: ConvertModel
    var isHidden = false
    let open: @MainActor () -> Void

    private var isShown: Bool { !isHidden && model.activity.queue > 0 }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isShown) {
                IOSJobAccessory(model: model, open: open)
            }
        } else {
            content.tabViewBottomAccessory {
                if isShown {
                    IOSJobAccessory(model: model, open: open)
                }
            }
        }
    }
}

/// The job converting now with its progress, or why the queue waits. Tapping opens the queue.
private struct IOSJobAccessory: View {
    let model: ConvertModel
    let open: @MainActor () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

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

    private var title: String { running?.displayName ?? "Queue" }

    private var detail: String {
        // Before the person taps Start the videos are ready, not paused.
        if model.waitsForStart {
            let count = model.activity.queue
            return count == 1 ? "1 video ready to start" : "\(count) videos ready to start"
        }
        if let pause = model.queuePause.statusText { return pause }
        if let progress { return "\(running?.phase ?? "Converting") · \(Int((progress * 100).rounded()))%" }
        let count = model.activity.queue
        return count == 1 ? "1 video waiting" : "\(count) videos waiting"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    let paused = model.queuePause.isPaused && !model.waitsForStart
                    Image(systemName: paused ? "pause.circle.fill" : "clock.fill")
                        .foregroundStyle(paused ? .orange : .secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if placement != .inline {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint("Opens the queue")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("jobAccessory")
    }
}
