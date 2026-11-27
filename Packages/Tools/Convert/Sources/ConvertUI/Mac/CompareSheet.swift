#if os(macOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI

    /// A finished conversion to compare.
    struct CompareTarget: Identifiable {
        let job: Job
        let outcome: JobOutcome
        var id: UUID { job.id }

        /// The file the conversion read; it may be in the Trash now if the conversion replaced it.
        var original: URL { outcome.source ?? job.source }
        var title: String { outcome.output.lastPathComponent }
    }

    /// The original and the converted frame with a divider to drag across them, as a Quick Look panel: Space on a
    /// finished video opens it and Escape closes it.
    struct CompareSheet: View {
        let target: CompareTarget
        @Environment(\.dismiss) private var dismiss
        @State private var before: CGImage?
        @State private var after: CGImage?
        @State private var isLoading = true

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.title).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(ActivityText.sizeChange(target.outcome))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    SavingsBadge(before: target.outcome.bytesBefore, after: target.outcome.bytesAfter)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                Group {
                    if isLoading {
                        ProgressView("Reading frames…")
                    } else if let after {
                        VStack(spacing: 8) {
                            BeforeAfterSlider(before: before, after: after)
                            if before == nil {
                                StatusLabel(
                                    "The original isn't where it was, so only the converted frame is shown.",
                                    systemImage: "info.circle", tint: .secondary
                                )
                                .font(.caption)
                            }
                        }
                        .padding(16)
                    } else {
                        ContentUnavailableView(
                            "Can't Compare",
                            systemImage: ConvertTool.isImageJob(target.job.toolID) ? "photo.on.rectangle" : "film",
                            description: Text("The converted item couldn't be read."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 640, minHeight: 440)
            // Space closes it as it does Quick Look.
            .onKeyPress(.space) {
                dismiss()
                return .handled
            }
            .task(id: target.id) {
                before = nil
                after = nil
                isLoading = true
                async let original = CompareFrames.frame(of: target.original)
                async let converted = CompareFrames.frame(of: target.outcome.output)
                before = await original
                after = await converted
                isLoading = false
            }
        }
    }

    /// Two frames with a draggable divider: the original to its left, the converted one to its right. Arrow keys and
    /// VoiceOver's adjust gestures move it too.
    struct BeforeAfterSlider: View {
        let before: CGImage?
        let after: CGImage
        @State private var split = CompareSplit()
        @FocusState private var isFocused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var aspect: CGFloat { CGFloat(after.width) / CGFloat(max(1, after.height)) }

        var body: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                let x = width * split.fraction
                ZStack(alignment: .leading) {
                    frame(after)
                    if let before {
                        frame(before)
                            .mask(alignment: .leading) { Rectangle().frame(width: x) }
                    }
                    if before != nil {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .shadow(radius: 2)
                            .offset(x: x - 1)
                            .accessibilityHidden(true)
                        Image(systemName: "arrow.left.and.right.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, .white)
                            .shadow(radius: 3)
                            .position(x: x, y: proxy.size.height / 2)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topLeading) { if before != nil { Tag("Original") } }
                .overlay(alignment: .topTrailing) { Tag("Converted") }
                .clipShape(.rect(cornerRadius: 8))
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        isFocused = true
                        split.drag(to: value.location.x, width: width)
                    }
                )
                .focusable(before != nil)
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(-1) }
                .onKeyPress(.rightArrow) { move(1) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Before and after")
                .accessibilityValue(split.spoken)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: split.nudge(1)
                    case .decrement: split.nudge(-1)
                    @unknown default: break
                    }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
        }

        private func move(_ direction: Int) -> KeyPress.Result {
            withAnimation(Motion.animation(.smooth(duration: 0.15), reduceMotion: reduceMotion)) {
                split.nudge(direction)
            }
            return .handled
        }

        private func frame(_ image: CGImage) -> some View {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    /// A caption on a dark plate over the frame, readable on any picture.
    private struct Tag: View {
        let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: .capsule)
                .padding(10)
                .accessibilityHidden(true)
        }
    }
#endif
