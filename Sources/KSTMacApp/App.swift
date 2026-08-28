import SwiftUI
import KSTCore

@main
struct KSTMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("KST Mac") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 420)
        }
    }
}
