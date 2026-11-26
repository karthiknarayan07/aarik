import SwiftUI

/// A ring that fills clockwise from the top, as in Fitness: `value` runs from 0 to 1. It fills smoothly unless
/// Reduce Motion is on.
public struct ProgressRing<Center: View>: View {
    let value: Double
    let tint: Color
    let lineWidth: CGFloat
    let center: Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        value: Double, tint: Color = .accentColor, lineWidth: CGFloat = 4, @ViewBuilder center: () -> Center
    ) {
        self.value = min(max(value, 0), 1)
        self.tint = tint
        self.lineWidth = lineWidth
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.animation(reduceMotion: reduceMotion), value: value)
            center
        }
        .padding(lineWidth / 2)
    }
}

extension ProgressRing where Center == EmptyView {
    public init(value: Double, tint: Color = .accentColor, lineWidth: CGFloat = 4) {
        self.init(value: value, tint: tint, lineWidth: lineWidth) { EmptyView() }
    }
}
