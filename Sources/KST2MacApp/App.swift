import SwiftUI
import KSTCore

@main
struct KST2MacApp: App {

    init() {
        // Before any @AppStorage is read.
        Migration.runIfNeeded()
    }

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

    /// Who we are and where we are. The app name stays in the title so
    /// the window is identifiable in Mission Control and the Window menu;
    /// callsign and rooms go in the subtitle, which is where macOS puts
    /// the changing detail.
    private var subtitle: String {
        let panes = [top, bottom].prefix(showSecond ? 2 : 1)
        let rooms = panes.filter(\.isInChat).map(\.room.title)
        let call = panes.first?.callsign.uppercased() ?? ""

        var parts: [String] = []
        if !call.isEmpty { parts.append(call) }
        parts.append(rooms.isEmpty ? "not connected" : rooms.joined(separator: " + "))
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VSplitView {
            ContentView()
                .environmentObject(top)
                // maxHeight lets VSplitView share the space instead of
                // giving the first pane its ideal size and squeezing the
                // second below its minimum, where it gets clipped and
                // loses its Connect button.
                .frame(minHeight: 240, maxHeight: .infinity)
            if showSecond {
                ContentView()
                    .environmentObject(bottom)
                    .frame(minHeight: 240, maxHeight: .infinity)
            }
        }
        // Two panes need room for two of everything — header, composer
        // and status bar each — so the window grows when the second is
        // switched on rather than cramming both into a one-pane height.
        .frame(minWidth: 900, minHeight: showSecond ? 780 : 520)
        .navigationTitle("KST2Mac")
        .navigationSubtitle(subtitle)
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
