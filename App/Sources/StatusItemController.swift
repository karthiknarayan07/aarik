import AppKit
import Observation
import QuickRunService
import SwiftUI

/// The menu bar item: a template SF Symbol that shows the queue's progress, a popover with the current job, and a
/// drop target for movies. It is added and removed live by the "Show in Menu Bar" setting.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var defaultsObserver: (any NSObjectProtocol)?
    private var appliedIcon: StatusIconState?
    private var isTrackingModel = false

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuBarPanel(model: model, close: { [weak self] in self?.popover.performClose(nil) }))
        // The popover follows the panel's height as the run's status comes and goes.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    func start() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: model.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    func popoverDidShow(_ notification: Notification) { model.isStatusPopoverVisible = true }
    func popoverDidClose(_ notification: Notification) { model.isStatusPopoverVisible = false }

    /// Adds or removes the item to match the setting.
    private func reconcile() {
        let wanted = MenuBarPreference.isShown(model.defaults)
        if wanted, item == nil {
            install()
        } else if !wanted, let existing = item {
            // No animation: the item (the popover's anchor) goes away right after.
            popover.close()
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
            appliedIcon = nil
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A stable identity keeps the item's place in the menu bar and its "Allow in the Menu Bar" choice.
        item.autosaveName = "status"
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        self.item = item
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = AppModel.displayName
        button.addSubview(StatusItemDropView(button: button) { [model] urls in model.runFromMenuBar(urls) })
        applyIcon()
        if !isTrackingModel { trackModel() }
    }

    /// Re-reads the queue state whenever it changes. The observation fires once per change, so it is set up again
    /// each time.
    private func trackModel() {
        // Nothing to draw while the item is off; `install()` starts it again.
        guard item != nil else {
            isTrackingModel = false
            return
        }
        isTrackingModel = true
        let state = withObservationTracking {
            StatusIconState(model.activity, isPaused: model.queuePause.isPaused)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackModel() }
        }
        apply(state)
    }

    private func applyIcon() {
        appliedIcon = nil
        apply(StatusIconState(model.activity, isPaused: model.queuePause.isPaused))
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
        let image =
            if let value = shown.variableValue {
                NSImage(systemSymbolName: shown.symbolName, variableValue: value, accessibilityDescription: nil)
            } else {
                NSImage(systemSymbolName: shown.symbolName, accessibilityDescription: nil)
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
            // A click leaves the app in the background, as Apple's menu bar extras do; opened from the keyboard or
            // VoiceOver, the popover needs the app active to take keystrokes.
            if PopoverActivation.shouldActivate(openedBy: NSApp.currentEvent?.type) { NSApp.activate() }
        }
    }
}
