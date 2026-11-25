import AppKit
import Observation
import QuickRunService
import SwiftUI

/// The menu bar item: a template SF Symbol that shows the queue's progress, a popover with the current job, and a
/// drop target for movies. It is added and removed live by the "Show in Menu Bar" setting.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var defaultsObserver: (any NSObjectProtocol)?
    private var appliedIcon: StatusIconState?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanel(model: model, close: { [weak self] in self?.popover.performClose(nil) }))
    }

    func start() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: model.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
        trackModel()
    }

    /// Adds or removes the item to match the setting.
    private func reconcile() {
        let wanted = MenuBarPreference.isShown(model.defaults)
        if wanted, item == nil {
            install()
        } else if !wanted, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
            appliedIcon = nil
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = AppModel.displayName
        button.addSubview(StatusItemDropView(button: button) { [model] urls in model.runQuickly(urls) })
        applyIcon()
    }

    /// Re-reads the queue state whenever it changes. The observation fires once per change, so it is set up again
    /// each time.
    private func trackModel() {
        let state = withObservationTracking {
            StatusIconState(model.activity, isPaused: model.isQueuePaused)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackModel() }
        }
        apply(state)
    }

    private func applyIcon() {
        appliedIcon = nil
        apply(StatusIconState(model.activity, isPaused: model.isQueuePaused))
    }

    /// Progress is shown in whole percents, so a fast job doesn't redraw the icon for every tick.
    private func apply(_ state: StatusIconState) {
        guard let button = item?.button else { return }
        let shown: StatusIconState =
            if case .running(let progress) = state { .running(progress: (progress * 100).rounded() / 100) } else {
                state
            }
        guard shown != appliedIcon else { return }
        appliedIcon = shown
        let description = "\(AppModel.displayName), \(shown.accessibilityStatus)"
        let image =
            if let value = shown.variableValue {
                NSImage(
                    systemSymbolName: shown.symbolName, variableValue: value, accessibilityDescription: description)
            } else {
                NSImage(systemSymbolName: shown.symbolName, accessibilityDescription: description)
            }
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(AppModel.displayName)
        button.setAccessibilityValue(shown.accessibilityStatus)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // So the popover takes keyboard focus.
            NSApp.activate()
        }
    }
}
