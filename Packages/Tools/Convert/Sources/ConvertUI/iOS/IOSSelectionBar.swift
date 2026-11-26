#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI

    /// The bar over a grid while selecting: "Convert 3 Videos · Save 1.2 GB".
    struct IOSSelectionBar: View {
        let model: ConvertModel
        let count: Int
        @Binding var isSelecting: Bool
        let clear: () -> Void

        var body: some View {
            if isSelecting && count > 0 {
                Button {
                    model.requestAddSelectionToQueue()
                    // A conversion that would lose metadata asks first and keeps the selection it asks about.
                    if model.lossReview == nil {
                        clear()
                        isSelecting = false
                    }
                } label: {
                    Text(
                        QueueButtonTitle.selectionTitle(
                            count: count,
                            saved: model.couldFreeSelected > 0 ? ByteFormat.string(model.couldFreeSelected) : nil)
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!model.canAddSelectionToQueue)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("convertSelection")
            }
        }
    }
#endif
