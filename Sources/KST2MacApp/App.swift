import SwiftUI
import KSTCore

@main
struct KST2MacApp: App {

    init() {
        // Before any @AppStorage is read.
        Migration.runIfNeeded()
        // The relay host is a lazy singleton, so without this it is not
        // constructed until Settings is opened — and a relay that only
        // starts when you look at it is not serving anything.
        _ = SpotRelayHost.shared
        SpotRelayHost.shared.onEnabled = {
            SessionStore.shared.enableSpotsEverywhere()
        }
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
                SpotProbeButtons()
                Divider()
                ClearWatchesButton()
            }
        }

        Settings {
            SettingsView()
                // Tall enough that Rooms and the relay are not below the
                // fold — the panel has six sections now.
                .frame(width: 460, height: 620)
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
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale

    private var models: [AppModel] { paneIDs.map { store.model(for: $0) } }

    var body: some View {
        VStack(spacing: 0) {
            identityStrip
            Divider()
            VSplitView {
                ForEach(paneIDs, id: \.self) { id in
                    pane(id)
                }
            }
        }
        .frame(minWidth: 900, minHeight: paneIDs.count > 1 ? 780 : 520)
        // The system title is hidden and redrawn below, because AppKit's
        // title text takes no font, colour or size from us. navigationTitle
        // is still set so the Window menu and Mission Control have a name.
        .background(WindowAccessor { window in
            window.titleVisibility = .hidden
        })
        .navigationTitle("KST2Mac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addPane()
                } label: {
                    Label("Add chat", systemImage: "rectangle.split.1x2")
                }
                .help("Add another chat below, with its own room and connection")
            }
        }
        .focusedSceneValue(\.addPane, addPane)
        .focusedSceneValue(\.probeTarget, models.first(where: \.isInChat))
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

    /// The window's global row: only facts true of the whole window —
    /// the app name, the operator's callsign, and UTC.
    ///
    /// Room, station counts and connection state are deliberately absent.
    /// They belong to a pane, and with three panes open a single global
    /// value for any of them would be meaningless.
    private var identityStrip: some View {
        HStack(spacing: 11) {
            Text("KST2Mac")
                .font(Typography.text(21, scale, weight: .semibold))
                .foregroundStyle(Palette.utc)

            Spacer(minLength: 12)

            if !store.clock.isEmpty {
                Text(store.clock)
                    .font(Typography.mono(14, scale, weight: .medium))
                    .foregroundStyle(Palette.utc)
            }

            // Green once *any* pane is in a chat. That is not the same
            // ambiguity as a per-pane control: this answers "am I on the
            // chat at all", which has one true answer however many panes
            // are open. Which pane is which is the pane rows' job.
            Text(callsign.isEmpty ? "SET CALLSIGN" : callsign.uppercased())
                .font(Typography.mono(17, scale, weight: .semibold))
                .foregroundStyle(anyConnected ? Palette.connected : Palette.callsignTint)
                .padding(.horizontal, 11)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(anyConnected ? Palette.connected
                                                   : Palette.callsignTint.opacity(0.55),
                                      lineWidth: 1.5)
                )
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(anyConnected ? Palette.connected.opacity(0.14) : .clear)
                )
                .animation(.easeOut(duration: 0.2), value: anyConnected)
                .help(callsign.isEmpty ? "Set your callsign in Settings"
                      : anyConnected ? "Logged in as \(callsign.uppercased()) — \(rooms)"
                                     : "Not connected")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // Read from the store, which republishes the aggregate. Deriving
    // these from `models` here does not work: this view observes the
    // store, not each session, so a pane connecting would never redraw
    // the header.
    private var anyConnected: Bool { store.anyConnected }

    private var rooms: String {
        store.connectedRooms.isEmpty ? "not connected"
                                     : store.connectedRooms.joined(separator: "  +  ")
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

/// Protocol capture from a live session — see `AppModel.probeSpotFormat`.
struct ProbeKey: FocusedValueKey { typealias Value = AppModel }

extension FocusedValues {
    var probeTarget: AppModel? {
        get { self[ProbeKey.self] }
        set { self[ProbeKey.self] = newValue }
    }
}

private struct SpotProbeButtons: View {
    @FocusedValue(\.probeTarget) private var target

    var body: some View {
        Button("Record spot-format transcript") { target?.probeSpotFormat() }
            .disabled(target?.isInChat != true)
        Button("Finish spot transcript") { target?.endProbe() }
            .disabled(target?.transcriptURL == nil)
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
