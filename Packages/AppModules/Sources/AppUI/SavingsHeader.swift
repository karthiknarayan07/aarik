import SwiftUI

/// "Could free about X" for what's shown, a now → after bar, and the trust note.
public struct SavingsHeader<Accessory: View>: View {
    let couldFree: Int64
    let totalBytes: Int64
    let accessory: Accessory

    public init(couldFree: Int64, totalBytes: Int64, @ViewBuilder accessory: () -> Accessory) {
        self.couldFree = couldFree
        self.totalBytes = totalBytes
        self.accessory = accessory()
    }

    private var afterBytes: Int64 { max(0, totalBytes - couldFree) }
    private var afterFraction: Double { totalBytes > 0 ? Double(afterBytes) / Double(totalBytes) : 1 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Could free about \(Text(ByteFormat.string(couldFree)).foregroundStyle(.tint))")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory
            }
            SavingsBar(fraction: afterFraction)
                .accessibilityHidden(true)
            Text(
                "\(ByteFormat.string(totalBytes)) now → about \(ByteFormat.string(afterBytes)) after · "
                    + "Nothing changes until you add to the queue"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(
                "\(ByteFormat.string(totalBytes)) now, about \(ByteFormat.string(afterBytes)) after. "
                    + "Nothing changes until you add to the queue.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The whole track is the size now; the filled part is what's left after converting.
private struct SavingsBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
    }
}
