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
