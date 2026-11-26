import AppCore
import ConvertUI
import SwiftUI

@main
struct MainApp: App {
    @State private var shell = IOSShell()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            shell.scene.root()
                .accessibilityIdentifier("root")
                .task { await shell.start() }
                .onChange(of: scenePhase) { _, phase in
                    shell.handleScenePhase(phase)
                }
        }
    }
}
