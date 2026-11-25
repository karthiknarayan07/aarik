import SwiftUI

@main
struct MainApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            SidebarCommands()
            InspectorCommands()
        }
    }
}
