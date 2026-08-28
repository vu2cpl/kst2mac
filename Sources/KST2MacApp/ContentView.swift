import SwiftUI
import KSTCore

struct ContentView: View {
    /// Set when this pane can be torn out into its own window.
    var onFloat: (() -> Void)?
    /// Set when this pane can be closed — nil for the last pane in a
    /// window, which is closed by closing the window.
    var onClose: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale
    @State private var showLogin = false

    /// One colour carries connection state through the whole pane — the
    /// header edge, the status dot and the status text — so a glance at
    /// any part of it tells you where you stand.
    private var stateColor: Color {
        if model.isInChat { return Palette.connected }
        if model.isConnected { return Palette.connecting }
        return Palette.offline
    }

    /// What this pane is doing, in one word and one colour.
    private var connectLabel: String {
        if model.isInChat { return "Disconnect" }
        if model.isConnected { return "Connecting…" }
        return "Connect"
    }

    /// Controls sit left-aligned and fixed-width, so the columns line up
    /// down a stack of panes however each one is doing.
    private var header: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(stateColor)
                .frame(width: 3, height: 18)
                .cornerRadius(1.5)

            Button(connectLabel) {
                if model.isConnected {
                    model.disconnect()
                } else if let saved = model.storedPassword() {
                    model.connect(password: saved)
                } else {
                    showLogin = true
                }
            }
            .buttonStyle(OutlineButtonStyle(color: stateColor,
                                            width: 108 * min(Typography.clamped(scale), 1.35)))
            .font(Typography.text(12, scale, weight: .medium))

            Picker("", selection: Binding(
                get: { model.room },
                set: { model.room = $0 })
            ) {
                ForEach(ChatRoom.allCases) { room in
                    Text(room.title).tag(room)
                }
            }
            .labelsHidden()
            .disabled(model.isConnected && !model.isInChat)
            .frame(width: 190 * min(Typography.clamped(scale), 1.35))
            .help("Switches room in place while connected (/CHAT)")

            if let onFloat {
                Button("Float", systemImage: "macwindow.on.rectangle", action: onFloat)
                    .help("Move this chat into its own window, keeping the connection")
            }
            if let onClose {
                Button("Close", systemImage: "xmark", action: onClose)
                    .help("Close this chat and disconnect it")
            }

            Spacer(minLength: 8)

            Text(model.status)
                .font(Typography.text(11, scale))
                .foregroundStyle(stateColor)
                .lineLimit(1)
                .truncationMode(.tail)

            if !model.serverTime.isEmpty {
                Text(model.serverTime)
                    .font(Typography.mono(11, scale, weight: .medium))
                    .foregroundStyle(Palette.utc)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(stateColor.opacity(0.08))
        .background(.bar)
    }

    var body: some View {
        // Deliberately a VStack rather than `.safeAreaInset(edge: .bottom)`:
        // HSplitView does not pass a bottom safe-area inset down to its
        // children, so the status bar drew *over* the composer and hid the
        // message field and its buttons entirely.
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ChatPane()
                StationPane()
                    .frame(minWidth: 340, idealWidth: 420)
            }
            .frame(maxHeight: .infinity)
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet()
                .environmentObject(model)
        }
    }
}

/// Asks for the password only. Callsign, grid and server live in Settings —
/// this sheet exists because the password is the one thing we may not have
/// in the Keychain yet.
struct LoginSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to ON4KST").font(.headline)

            Form {
                TextField("Callsign", text: Binding(
                    get: { model.callsign },
                    set: { model.callsign = $0.uppercased() }))
                SecureField("Password", text: $password)
                Toggle("Remember password in Keychain", isOn: Binding(
                    get: { model.savePassword },
                    set: { model.savePassword = $0 }))
            }

            Text("The chat has no TLS on port \(model.port) — this password crosses the network in clear. Use one you use nowhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") {
                    model.connect(password: password)
                    password = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.callsign.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
