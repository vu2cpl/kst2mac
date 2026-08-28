import SwiftUI
import KSTCore

struct ContentView: View {
    /// Set when this pane can be torn out into its own window.
    var onFloat: (() -> Void)?
    /// Set when this pane can be closed — nil for the last pane in a
    /// window, which is closed by closing the window.
    var onClose: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isInChat ? .green : (model.isConnected ? .orange : .secondary))
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !model.serverTime.isEmpty {
                Text(model.serverTime)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
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
            .frame(width: 210)
            .help("Switches room in place while connected (/CHAT)")

            Spacer()

            if let onFloat {
                Button(action: onFloat) {
                    Image(systemName: "macwindow.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Move this chat into its own window, keeping the connection")
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Close this chat and disconnect it")
            }

            Button(model.isConnected ? "Disconnect" : "Connect") {
                if model.isConnected {
                    model.disconnect()
                } else if let saved = model.storedPassword() {
                    model.connect(password: saved)
                } else {
                    showLogin = true
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                    .frame(minWidth: 280, idealWidth: 340)
            }
            .frame(maxHeight: .infinity)

            Divider()
            statusBar
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
