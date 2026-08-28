import Foundation
import SwiftUI
import KSTCore

@MainActor
final class AppModel: ObservableObject {

    // MARK: Settings (persisted in UserDefaults; the password is in Keychain)
    @AppStorage("callsign")  var callsign: String = ""
    @AppStorage("homeGrid")  var homeGrid: String = ""
    @AppStorage("host")      var host: String = KSTConnection.defaultHost
    @AppStorage("port")      var port: Int = Int(KSTConnection.defaultPort)
    @AppStorage("roomRaw")   var roomRaw: Int = ChatRoom.vhfUhfRegion3.rawValue
    @AppStorage("savePassword") var savePassword: Bool = true

    var room: ChatRoom {
        get { ChatRoom(rawValue: roomRaw) ?? .vhfUhfRegion3 }
        set { roomRaw = newValue.rawValue }
    }

    // MARK: Live state
    @Published private(set) var lines: [KSTLine] = []
    @Published private(set) var stations: [Station] = []
    @Published private(set) var status: String = "Not connected"
    @Published private(set) var isConnected = false
    @Published private(set) var isInChat = false
    /// The server's own UTC clock, from its command prompt.
    @Published private(set) var serverTime: String = ""

    /// The message being composed. Nothing leaves the app until the
    /// operator presses Return — the chat has no draft state, so an
    /// accidental send is visible to the whole room.
    @Published var draft: String = ""
    /// When set, the next send goes out as `/CQ <call> …`.
    @Published var directedTo: String?

    /// Cap the scrollback so a long session doesn't grow without bound.
    private let maxLines = 5000

    private var connection: KSTConnection?
    private var pump: Task<Void, Never>?

    // MARK: - Connect / disconnect

    func connect(password: String) {
        guard !callsign.isEmpty else {
            append(.local("Set your callsign in Settings first."))
            return
        }
        disconnect()

        if savePassword {
            try? Keychain.setPassword(password, account: callsign)
        }

        let conn = KSTConnection(host: host, port: UInt16(port))
        connection = conn
        isConnected = true
        isInChat = false

        pump = Task { [weak self] in
            for await event in conn.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        conn.connect(username: callsign, password: password, room: room)
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
        pump?.cancel()
        pump = nil
        isConnected = false
        isInChat = false
    }

    func storedPassword() -> String? {
        guard !callsign.isEmpty else { return nil }
        return Keychain.password(account: callsign)
    }

    // MARK: - Sending

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let connection else { return }
        if let to = directedTo, !to.isEmpty, !text.hasPrefix("/") {
            connection.sendDirected(to: to, text: text)
        } else {
            connection.send(text)
        }
        draft = ""
    }

    // MARK: - Event handling

    private func handle(_ event: KSTEvent) {
        switch event {
        case .status(let text):
            status = text
        case .line(let line):
            if case .prompt(_, let chat) = line.kind {
                // Not traffic: it is the server telling us where we are
                // and what time it thinks it is.
                if let stamp = line.stamp { serverTime = stamp + "Z" }
                if !chat.isEmpty { status = "In \(chat) as \(callsign)" }
                return
            }
            append(line)
        case .station(let station):
            upsert(station)
        case .loggedIn(let room):
            isInChat = true
            status = "In \(room.title) as \(callsign)"
        case .disconnected(let reason):
            isConnected = false
            isInChat = false
            status = reason.map { "Disconnected: \($0)" } ?? "Disconnected"
            append(.local(status))
        }
    }

    private func append(_ line: KSTLine) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private func upsert(_ station: Station) {
        if let i = stations.firstIndex(where: { $0.callsign == station.callsign }) {
            // Never let a later sighting blank out something we already know.
            stations[i].name    = station.name ?? stations[i].name
            stations[i].locator = station.locator ?? stations[i].locator
            stations[i].status  = station.status ?? stations[i].status
            stations[i].lastHeard = station.lastHeard
        } else {
            stations.append(station)
        }
        stations.sort { $0.lastHeard > $1.lastHeard }
    }

    // MARK: - Derived

    /// Distance/bearing from the operator's own grid, when both grids are known.
    func path(to station: Station) -> (distanceKm: Double, bearing: Double)? {
        guard !homeGrid.isEmpty, let loc = station.locator else { return nil }
        return Maidenhead.path(from: homeGrid, to: loc)
    }

    /// True if the line is addressed to, or mentions, our own callsign.
    func mentionsMe(_ line: KSTLine) -> Bool {
        guard !callsign.isEmpty else { return false }
        let me = callsign.uppercased()
        if case .message(_, _, let to, let text) = line.kind {
            if to == me { return true }
            return text.uppercased().contains(me)
        }
        return false
    }
}
