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

/// A window holding one or two stacked chats, KST2Me style.
///
/// Each pane owns its own `AppModel` and therefore its own connection,
/// room, roster and composer — stacking them is a layout choice, not a
/// shared session. The second model exists whether or not the pane is
/// shown; an unconnected `AppModel` costs nothing but a few empty arrays.
///
/// Both layouts are available on purpose: stacked panes suit a laptop
/// screen, while separate windows (File ▸ New chat window) suit a large
/// display and are handled better by Mission Control and Stage Manager
/// than a hand-rolled split ever would be.
struct ChatWindow: View {
    @StateObject private var top = AppModel()
    @StateObject private var bottom = AppModel()
    /// Per window, and restored with it.
    @SceneStorage("showSecondChat") private var showSecond = false

    private var title: String {
        let rooms = [top, bottom]
            .prefix(showSecond ? 2 : 1)
            .filter(\.isInChat)
            .map(\.room.title)
        return rooms.isEmpty ? "KST Mac" : rooms.joined(separator: "  ·  ")
    }

    var body: some View {
        VSplitView {
            ContentView()
                .environmentObject(top)
                .frame(minHeight: 260)
            if showSecond {
                ContentView()
                    .environmentObject(bottom)
                    .frame(minHeight: 260)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showSecond) {
                    Label("Second chat", systemImage: "rectangle.split.1x2")
                }
                .help("Show a second chat below, with its own room and roster")
            }
        }
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
            .disabled(model.explicitWatches.isEmpty)
    }
}

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New chat window") { openWindow(id: "chat") }
            .keyboardShortcut("n", modifiers: .command)
    }
}
