import SwiftUI
import KSTCore

/// Settings are global — callsign, locator, server — so this view reads
/// UserDefaults directly rather than a window's model. There is no single
/// model to reach for once there can be several windows.
struct SettingsView: View {
    @AppStorage("callsign") private var callsign: String = ""
    @AppStorage("homeGrid") private var homeGrid: String = ""
    @AppStorage("host") private var host: String = KSTConnection.defaultHost
    @AppStorage("port") private var port: Int = Int(KSTConnection.defaultPort)

    @AppStorage("sound.volume") private var soundVolume: Double = 0.7

    @StateObject private var relay = SpotRelayHost.shared

    @State private var newPassword = ""
    @State private var note: String?

    var body: some View {
        Form {
            Section("Station") {
                TextField("Callsign", text: Binding(
                    get: { callsign },
                    set: { callsign = $0.uppercased() }))
                    .textFieldStyle(.roundedBorder)
                TextField("Locator", text: Binding(
                    get: { homeGrid },
                    set: { homeGrid = $0.trimmingCharacters(in: .whitespaces) }),
                    prompt: Text("e.g. JO20dh"))
                if !homeGrid.isEmpty && Maidenhead.coordinates(homeGrid) == nil {
                    Text("Not a valid Maidenhead locator")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section("Password") {
                SecureField("ON4KST password", text: $newPassword)
                HStack {
                    Button("Save to Keychain") {
                        do {
                            try Keychain.setPassword(newPassword, account: callsign)
                            newPassword = ""
                            note = "Saved."
                        } catch {
                            note = error.localizedDescription
                        }
                    }
                    .disabled(callsign.isEmpty || newPassword.isEmpty)

                    Button("Forget") {
                        Keychain.removePassword(account: callsign)
                        note = "Removed from Keychain."
                    }
                    .disabled(callsign.isEmpty)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Text("Sent in clear over plain TCP. Use a password you use nowhere else.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sounds") {
                ForEach(Sounds.Event.allCases) { event in
                    HStack {
                        SoundPicker(event: event)
                    }
                }
                HStack {
                    Text("Volume")
                    Slider(value: $soundVolume, in: 0...1)
                }
                Text("Sounds play whether or not KST2Mac is in front — that is the case a notification banner cannot cover. Repeats within two seconds are suppressed, and a backlog arriving on join stays silent.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("DX spot relay") {
                Toggle("Serve spots as a DX-cluster node", isOn: $relay.enabled)
                HStack {
                    Text("Port")
                    TextField("", value: $relay.port, format: .number.grouping(.never))
                        .frame(width: 70)
                    Button("Restart") { relay.restart() }
                        .disabled(!relay.enabled)
                }
                Toggle("Allow connections from the network", isOn: $relay.allowNetwork)
                    .help("Off: only this Mac can connect. The feed is unauthenticated.")
                LabeledContent("Status") {
                    Text(relay.status)
                        .foregroundStyle(relay.clients > 0 ? .green : .secondary)
                }
                if relay.clients > 0 || relay.forwarded > 0 {
                    LabeledContent("Traffic") {
                        Text("\(relay.clients) client(s), \(relay.forwarded) spots forwarded")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Forwards ON4KST spots verbatim as standard `DX de` cluster lines. While this is on, each pane sends /SET DXCLX when it joins, so the server always has spots enabled for your account.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("In dxca add:  [[cluster_nodes]] name = \"KST2Mac\", host = \"127.0.0.1\", port = \(relay.port), login_call = \"\(callsign.isEmpty ? "YOURCALL" : callsign)\"")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Server") {
                TextField("Host", text: Binding(
                    get: { host }, set: { host = $0 }))
                TextField("Port", value: Binding(
                    get: { port }, set: { port = $0 }),
                    format: .number.grouping(.never))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}


/// One row: which sound fires for one event, with a preview.
private struct SoundPicker: View {
    let event: Sounds.Event
    @AppStorage private var choice: String

    init(event: Sounds.Event) {
        self.event = event
        _choice = AppStorage(wrappedValue: event.defaultSound, event.key)
    }

    var body: some View {
        Picker(event.title, selection: $choice) {
            ForEach(Sounds.available, id: \.self) { Text($0).tag($0) }
        }
        Button {
            Sounds.shared.preview(choice)
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .buttonStyle(.borderless)
        .disabled(choice == Sounds.off)
        .help("Play \(choice)")
    }
}
