import Foundation
import KSTCore

/// Carries settings across the rename from "KST Mac" to "KST2Mac".
///
/// The bundle identifier changed with the name, and a bundle identifier
/// *is* the preferences domain and the Keychain account namespace — so
/// without this, the rename silently loses the operator's callsign,
/// locator, watches and saved password, and looks like a fresh install.
///
/// Runs once, copies only when the new domain has nothing, and never
/// deletes the old values: a downgrade should still find its settings.
enum Migration {

    // These two are the *old* names and must never be rewritten to the
    // new ones — they are the only way back to the previous settings.
    private static let oldBundleID = "net.vu2cpl.kstmac"
    private static let oldKeychainService = "net.vu2cpl.kstmac.on4kst"
    private static let doneKey = "migratedFromKSTMac"

    private static let keys = [
        "callsign", "homeGrid", "host", "port", "roomRaw",
        "savePassword", "watchedCalls", "replyWithPreamble",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        guard let old = UserDefaults(suiteName: oldBundleID) else { return }

        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = old.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }

        // The password moves too, or the first launch after the rename
        // asks for it again for no reason the operator can see.
        let callsign = defaults.string(forKey: "callsign") ?? ""
        if !callsign.isEmpty,
           Keychain.password(account: callsign) == nil,
           let carried = Keychain.password(account: callsign, service: oldKeychainService) {
            try? Keychain.setPassword(carried, account: callsign)
        }
    }
}
