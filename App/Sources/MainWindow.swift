import AppKit
import SwiftUI

/// The main window is the one `Window` scene with this id: opening a file while the app runs must not make a second
/// one.
enum MainWindow {
    static let id = "main"
}

extension AppModel {
    /// Open, or minimized to the Dock. A closed window, or one SwiftUI has dropped, doesn't count.
    var isMainWindowOpen: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isVisible || mainWindow.isMiniaturized
    }

    /// Brings the main window to the front, opening it first when it was closed.
    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

extension View {
    /// Lets the model find the main window (is it open?) and open it from code.
    func tracksMainWindow(_ model: AppModel) -> some View {
        modifier(MainWindowTracking(model: model))
    }
}

private struct MainWindowTracking: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .background(WindowReader(model: model))
            .onAppear { model.openMainWindow = { openWindow(id: MainWindow.id) } }
    }
}

private struct WindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(model: model)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        private let model: AppModel

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { model.mainWindow = window }
        }
    }
}
