#if os(macOS)
    import SwiftUI

    extension View {
        /// A Control Center module: a rounded plate on the popover's material.
        public func controlModule() -> some View {
            padding(12).background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 14))
        }
    }

    /// The popover's status modules: a ring for the current job on the left, the queue count and the pause tile
    /// on the right.
    public struct MenuBarStatusModules: View {
        let modules: MenuBarModules
        /// The job being converted, if any, and what it is doing now ("Downloading from iCloud…").
        let currentName: String?
        let currentPhase: String?
        /// Why the queue is held, when it is ("Paused", "Waiting for power").
        let pauseText: String?
        /// What VoiceOver reads for the ring module.
        let spokenStatus: String
        let togglePause: () -> Void

        public init(
            modules: MenuBarModules, currentName: String?, currentPhase: String?, pauseText: String?,
            spokenStatus: String, togglePause: @escaping () -> Void
        ) {
            self.modules = modules
            self.currentName = currentName
            self.currentPhase = currentPhase
            self.pauseText = pauseText
            self.spokenStatus = spokenStatus
            self.togglePause = togglePause
        }

        public var body: some View {
            HStack(alignment: .top, spacing: 10) {
                ring
                VStack(spacing: 10) {
                    queue
                    pause
                }
                .frame(width: 112)
            }
        }

        private var ring: some View {
            VStack(spacing: 8) {
                ProgressRing(value: modules.ringValue, lineWidth: 8) {
                    if modules.isRunning {
                        Text(modules.ringValue, format: .percent.precision(.fractionLength(0)))
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: modules.isPaused ? "pause.fill" : "checkmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(modules.ringCaption).font(.callout.weight(.semibold))
                    if let currentName {
                        Text(currentName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let currentPhase {
                            Text(currentPhase).font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if let pauseText {
                        Text(pauseText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .controlModule()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(modules.ringCaption)
            .accessibilityValue(spokenStatus)
        }

        private var queue: some View {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(modules.queueCount, format: .number)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("in the queue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .controlModule()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(modules.queueCaption)
        }

        private var pause: some View {
            Button(action: togglePause) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: modules.pauseSymbol)
                        .contentTransition(.symbolEffect(.replace))
                    Spacer(minLength: 4)
                    Text(modules.pauseTitle).font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            }
            .buttonStyle(.plain)
            .controlModule()
            .disabled(!modules.isPauseEnabled)
            .opacity(modules.isPauseEnabled ? 1 : 0.5)
            .accessibilityLabel(modules.isPaused ? "Resume Queue" : "Pause Queue")
            .accessibilityHint("Pauses or resumes converting videos in the queue")
        }
    }

    /// The "Drop Videos Here" tile; its outline turns to the accent colour while a drag is over it.
    public struct MenuBarDropModule: View {
        let isTargeted: Bool
        let choose: () -> Void

        public init(isTargeted: Bool, choose: @escaping () -> Void) {
            self.isTargeted = isTargeted
            self.choose = choose
        }

        public var body: some View {
            VStack(spacing: 6) {
                Label("Drop Videos Here", systemImage: "square.and.arrow.down")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
                Text("Or drop them on the menu bar icon. They are converted without opening the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Videos…", action: choose)
                    .accessibilityHint("Opens a window to choose videos to convert, instead of dropping them here")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .controlModule()
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 2)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drop videos here to convert them")
            .accessibilityHint("Drag video files onto this area, or use Choose Videos")
        }
    }
#endif
