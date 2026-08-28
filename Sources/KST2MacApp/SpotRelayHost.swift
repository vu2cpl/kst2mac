import SwiftUI
import KSTCore

/// One relay for the whole app, not one per pane.
///
/// Several panes may be watching different rooms, but a DX-cluster client
/// wants a single node to dial — so every pane's spots feed the same
/// listener. Duplicate spots across rooms are dropped here rather than
/// sent twice: dxca dedupes too, but a relay that repeats itself is a
/// relay someone has to debug.
@MainActor
final class SpotRelayHost: ObservableObject {

    static let shared = SpotRelayHost()

    private let relay = SpotRelay()
    private var recent: [String: Date] = [:]

    @Published private(set) var status = "Off"
    @Published private(set) var clients = 0
    @Published private(set) var forwarded = 0

    // Plain @Published over UserDefaults rather than @AppStorage: this is
    // an ObservableObject, not a View, and @AppStorage's didSet does not
    // fire dependably outside one — so toggling it never started the
    // listener.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "relay.enabled")
            enabled ? start() : stop()
            // Enabling mid-session should start the spots flowing without
            // waiting for a reconnect.
            if enabled { onEnabled?() }
        }
    }

    /// Called when the relay is switched on, so connected panes can ask
    /// the server for spots.
    var onEnabled: (() -> Void)?

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "relay.port") }
    }

    /// Off by default: the feed is unauthenticated — anyone who connects
    /// gets the spots — so it stays on the loopback interface unless the
    /// operator deliberately opens it up.
    @Published var allowNetwork: Bool {
        didSet {
            UserDefaults.standard.set(allowNetwork, forKey: "relay.allowNetwork")
            restart()
        }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "relay.enabled")
        port = (UserDefaults.standard.object(forKey: "relay.port") as? Int)
            ?? Int(SpotRelay.defaultPort)
        allowNetwork = UserDefaults.standard.bool(forKey: "relay.allowNetwork")

        relay.onStatus = { [weak self] text in
            Task { @MainActor in self?.status = text }
        }
        relay.onClientCount = { [weak self] count in
            Task { @MainActor in self?.clients = count }
        }
        if enabled { start() }
    }

    func start() {
        relay.start(port: UInt16(port), loopbackOnly: !allowNetwork)
    }

    func stop() {
        relay.stop()
        status = "Off"
        clients = 0
    }

    func restart() {
        stop()
        if enabled { start() }
    }

    func broadcast(_ line: String) {
        guard enabled else { return }
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 300 }
        guard recent[line] == nil else { return }
        recent[line] = now

        relay.broadcast(line)
        forwarded += 1
    }
}
