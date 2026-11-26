import AppCore
import SwiftUI

/// The low-battery warning for the Queue: a calm, non-blocking line. Work keeps running; nothing here pauses it.
struct LowBatteryBanner: View {
    let pause: QueuePause

    var body: some View {
        if let text = pause.warningText {
            Label(text, systemImage: "battery.25percent")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("lowBatteryWarning")
        }
    }
}
