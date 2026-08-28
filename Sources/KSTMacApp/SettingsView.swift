import SwiftUI
import KSTCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newPassword = ""
    @State private var note: String?

    var body: some View {
        Form {
            Section("Station") {
                TextField("Callsign", text: Binding(
                    get: { model.callsign },
                    set: { model.callsign = $0.uppercased() }))
                TextField("Locator", text: Binding(
                    get: { model.homeGrid },
                    set: { model.homeGrid = $0.trimmingCharacters(in: .whitespaces) }),
                    prompt: Text("e.g. JO20dh"))
                if !model.homeGrid.isEmpty && Maidenhead.coordinates(model.homeGrid) == nil {
                    Text("Not a valid Maidenhead locator")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section("Password") {
                SecureField("ON4KST password", text: $newPassword)
                HStack {
                    Button("Save to Keychain") {
                        do {
                            try Keychain.setPassword(newPassword, account: model.callsign)
                            newPassword = ""
                            note = "Saved."
                        } catch {
                            note = error.localizedDescription
                        }
                    }
                    .disabled(model.callsign.isEmpty || newPassword.isEmpty)

                    Button("Forget") {
                        Keychain.removePassword(account: model.callsign)
                        note = "Removed from Keychain."
                    }
                    .disabled(model.callsign.isEmpty)
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
                    get: { model.host }, set: { model.host = $0 }))
                TextField("Port", value: Binding(
                    get: { model.port }, set: { model.port = $0 }),
                    format: .number.grouping(.never))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
