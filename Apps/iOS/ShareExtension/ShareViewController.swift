import SwiftUI
import UIKit

/// Placeholder share sheet. It will stage the shared videos by streaming copies and open the app; it never encodes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(onDone: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ShareView: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Shrink Videos",
                systemImage: "arrow.down.right.and.arrow.up.left",
                description: Text("Sharing videos to the app is coming soon.")
            )
            .navigationTitle("Shrink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .accessibilityIdentifier("shareRoot")
    }
}
