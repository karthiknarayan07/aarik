import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. The updater starts only when the build names an update feed and the public key
/// that signs it (`SUFeedURL`, `SUPublicEDKey`); development builds leave them empty and never touch the network.
@MainActor
@Observable
final class Updater {
    /// Whether this build can update itself. When false the updater is never started.
    let isConfigured: Bool
    /// False while a check or an update is already under way, and always false when the updater isn't configured.
    private(set) var canCheckForUpdates = false
    /// Sparkle keeps the choice in the app's defaults; the build's default is on (`SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard isConfigured, controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates
            else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let configured = Self.hasValue(bundle, "SUFeedURL") && Self.hasValue(bundle, "SUPublicEDKey")
        isConfigured = configured
        controller = SPUStandardUpdaterController(
            startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = configured && controller.updater.automaticallyChecksForUpdates
        guard configured else { return }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            // Sparkle changes the property on the main thread.
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
    }

    /// Shows Sparkle's update window: the progress of the check, then the result.
    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    private static func hasValue(_ bundle: Bundle, _ key: String) -> Bool {
        let value = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
