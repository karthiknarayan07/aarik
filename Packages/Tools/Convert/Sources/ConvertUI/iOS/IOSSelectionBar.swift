#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI

    /// The bar over a grid while selecting: "3 Videos · Could free about 1.2 GB" and a Next button to review
    /// resolution, quality, and save options before queuing.
    struct IOSSelectionBar: View {
        let model: ConvertModel
        let count: Int
        @Binding var isSelecting: Bool
        let clear: () -> Void
        @State private var isShowingOptions = false

        var body: some View {
            Group {
                if isSelecting && count > 0 {
                    VStack(spacing: 8) {
                        Text(
                            QueueButtonTitle.selectionSummary(
                                count: count,
                                saved: model.couldFreeSelected > 0 ? ByteFormat.string(model.couldFreeSelected) : nil)
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("selectionSummary")
                        Button {
                            isShowingOptions = true
                        } label: {
                            Label("Next", systemImage: "chevron.right")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!model.canAddSelectionToQueue)
                        .accessibilityIdentifier("selectionNext")
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $isShowingOptions) {
                IOSLibraryInspector(
                    model: model, isCompact: true,
                    onQueued: {
                        clear()
                        isSelecting = false
                    },
                    dismiss: { isShowingOptions = false })
            }
        }
    }
#endif
