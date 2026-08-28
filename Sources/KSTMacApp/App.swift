import SwiftUI
import KSTCore

@main
struct KSTMacApp: App {

    var body: some Scene {
        // A plain WindowGroup, so File ▸ New chat window opens another
        // one. Each carries its own AppModel and therefore its own
        // connection — that is the whole point: one window per room.
        WindowGroup(id: "chat") {
            ChatWindow()
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
            }
            CommandMenu("Chat") {
                ClearWatchesButton()
            }
        }

        Settings {
            SettingsView()
                .frame(width: 420)
        }
    }
}

/// One window: its own model, its own connection, its own room.
struct ChatWindow: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ContentView()
            .environmentObject(model)
            .frame(minWidth: 900, minHeight: 520)
            // The room in the title bar is how you tell two windows apart
            // in Mission Control and the Window menu.
            .navigationTitle(model.isInChat ? model.room.title : "KST Mac")
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                Notifier.shared.clearBadge()
            }
    }
}

/// Watches are global, so this needs a model only to reach the shared
/// defaults — any instance will do.
private struct ClearWatchesButton: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Button("Clear all watches") { model.clearWatches() }
            .disabled(model.watched.isEmpty)
    }
}

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New chat window") { openWindow(id: "chat") }
            .keyboardShortcut("n", modifiers: .command)
    }
}
