import AppKit
import Foundation
import Observation

/// Whether the assistant's controls may appear at all. Reads the system model's availability; any reason it
/// isn't available (no Apple Intelligence, turned off, model still downloading, unsupported language) hides
/// every control. Checked again whenever the app becomes active, since the user may change the setting in
/// System Settings while the app runs.
@MainActor
@Observable
public final class AssistantAvailability {
    public private(set) var isAvailable: Bool

    @ObservationIgnored private let client: any LanguageModelClient
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// `observesActivation` re-checks when the app becomes active; tests turn it off and call `refresh()`.
    public init(client: any LanguageModelClient = .real, observesActivation: Bool = true) {
        self.client = client
        self.isAvailable = client.isAvailable
        guard observesActivation else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Reads the model's availability again.
    public func refresh() {
        let current = client.isAvailable
        if current != isAvailable { isAvailable = current }
    }
}
