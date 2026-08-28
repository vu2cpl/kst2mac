import SwiftUI
import KSTCore

@main
struct KST2MacApp: App {

    init() {
        // Before any @AppStorage is read.
        Migration.runIfNeeded()
    }

    var body: some Scene {
        // The window's value is a comma-separated list of session ids, so
        // a window can be opened around sessions that already exist —
        // which is how a floated pane keeps its live connection.
        WindowGroup(id: "chat", for: String.self) { $ids in
            ChatWindow(seed: ids ?? "")
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
            }
            CommandGroup(after: .toolbar) {
                TextSizeCommands()
            }
            CommandMenu("Chat") {
                AddPaneButton()
                Divider()
                ClearWatchesButton()
            }
        }

        Settings {
            SettingsView()
                .frame(width: 420)
        }
    }
}

/// A window showing one or more stacked chat panes.
///
/// Panes can be added, closed, or floated out into their own window. The
/// sessions themselves belong to `SessionStore`, so any of that can happen
/// without disturbing a connection.
struct ChatWindow: View {
    let seed: String

    @StateObject private var store = SessionStore.shared
    @State private var paneIDs: [UUID] = []
    /// Survives a window restore, so reopening finds the same panes.
    @SceneStorage("paneIDs") private var storedIDs: String = ""

    @Environment(\.openWindow) private var openWindow
    @AppStorage("callsign") private var callsign: String = ""

    private var models: [AppModel] { paneIDs.map { store.model(for: $0) } }

    private var subtitle: String {
        let rooms = models.filter(\.isInChat).map(\.room.title)
        var parts: [String] = []
        if !callsign.isEmpty { parts.append(callsign.uppercased()) }
        parts.append(rooms.isEmpty ? "not connected" : rooms.joined(separator: " + "))
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VSplitView {
            ForEach(paneIDs, id: \.self) { id in
                pane(id)
            }
        }
        .frame(minWidth: 900, minHeight: paneIDs.count > 1 ? 780 : 520)
        .navigationTitle("KST2Mac")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    addPane()
                } label: {
                    Label("Add chat", systemImage: "rectangle.split.1x2")
                }
                .help("Add another chat below, with its own room and connection")
            }
        }
        .focusedSceneValue(\.addPane, addPane)
        .onAppear(perform: restore)
        .onChange(of: paneIDs) { _ in
            storedIDs = paneIDs.map(\.uuidString).joined(separator: ",")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Notifier.shared.clearBadge()
        }
    }

    /// Extracted from the `VSplitView` body: inline, the optional
    /// closures plus the modifier chain defeated the type checker.
    @ViewBuilder
    private func pane(_ id: UUID) -> some View {
        let multiple = paneIDs.count > 1
        ContentView(
            onFloat: multiple ? { float(id) } : nil,
            onClose: multiple ? { close(id) } : nil
        )
        .environmentObject(store.model(for: id))
        // maxHeight lets VSplitView share the height between panes rather
        // than giving the first its ideal size and squeezing the rest
        // below their minimum, where they get clipped.
        .frame(minHeight: 240, maxHeight: .infinity)
    }

    private func addPane() {
        paneIDs.append(store.newSession())
    }

    private func restore() {
        guard paneIDs.isEmpty else { return }
        // A window opened around existing sessions (a floated pane) takes
        // its ids from the scene value; a restored window takes them from
        // scene storage; a genuinely new window gets a fresh session.
        let source = seed.isEmpty ? storedIDs : seed
        let ids = source.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        paneIDs = ids.isEmpty ? [store.newSession()] : ids
    }

    /// Move a pane into a window of its own. The session stays in the
    /// store, so the connection, scrollback and roster all survive.
    private func float(_ id: UUID) {
        paneIDs.removeAll { $0 == id }
        openWindow(id: "chat", value: id.uuidString)
    }

    private func close(_ id: UUID) {
        paneIDs.removeAll { $0 == id }
        store.discard(id)
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

/// Adding a chat below is a window action, so it reaches the focused
/// window through the focused-value system rather than a shared object.
struct AddPaneKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var addPane: (() -> Void)? {
        get { self[AddPaneKey.self] }
        set { self[AddPaneKey.self] = newValue }
    }
}

private struct AddPaneButton: View {
    @FocusedValue(\.addPane) private var addPane

    var body: some View {
        Button("Add chat below") { addPane?() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(addPane == nil)
    }
}

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New chat window") { openWindow(id: "chat", value: "") }
            .keyboardShortcut("n", modifiers: .command)
    }
}
