#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import SwiftUI

    /// The bar over a grid while selecting: "3 Videos · Save 1.2 GB" over two actions. Add to Queue only queues the
    /// selection; Convert Now queues it and starts the run.
    struct IOSSelectionBar: View {
        let model: ConvertModel
        let count: Int
        @Binding var isSelecting: Bool
        let clear: () -> Void

        var body: some View {
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
                    HStack(spacing: 12) {
                        Button {
                            add(startsQueue: false)
                        } label: {
                            Text("Add to Queue").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("addSelectionToQueue")
                        Button {
                            add(startsQueue: true)
                        } label: {
                            Text("Convert Now").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("convertSelection")
                    }
                    .controlSize(.large)
                    .disabled(!model.canAddSelectionToQueue)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }

        private func add(startsQueue: Bool) {
            model.requestAddSelectionToQueue(startsQueue: startsQueue)
            // A conversion that would lose metadata asks first and keeps the selection it asks about.
            if model.lossReview == nil {
                clear()
                isSelecting = false
            }
        }
    }
#endif
