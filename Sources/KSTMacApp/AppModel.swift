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
    // Defaults to 144/432 MHz rather than the region-3 room: R3 is
    // usually empty, and a first run that shows an empty window looks
    // like a broken client rather than a quiet band.
    @AppStorage("roomRaw")   var roomRaw: Int = ChatRoom.vhfUhf.rawValue
    @AppStorage("savePassword") var savePassword: Bool = true

    var room: ChatRoom {
        get { ChatRoom(rawValue: roomRaw) ?? .vhfUhf }
        set {
            guard newValue != room else { return }
            roomRaw = newValue.rawValue
            // While connected the server can move us with /CHAT, so the
            // picker stays live rather than being locked until reconnect.
            if isInChat {
                stations = []
                connection?.switchChat(to: newValue)
            }
        }
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
    private var rosterTimer: Task<Void, Never>?

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

        // Take the stream *before* connecting. `events` builds its
        // continuation on first access, so if the socket got there first
        // the early status events would be yielded into nothing.
        let stream = conn.events
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        conn.connect(username: callsign, password: password, room: room)
    }

    /// Ask the server who is present. Safe to call at any time; ignored
    /// unless we are in the chat.
    func refreshRoster() {
        connection?.requestRoster()
    }

    /// The roster is a snapshot, so it needs re-asking. A minute is well
    /// under the rate at which a VHF chat's population changes.
    private func startRosterRefresh() {
        rosterTimer?.cancel()
        rosterTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.isInChat else { return }
                self.refreshRoster()
            }
        }
    }

    func disconnect() {
        rosterTimer?.cancel()
        rosterTimer = nil
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
            if case .roster = line.kind { return }   // the table shows these
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
            // Backfill the window and find out who is actually here,
            // rather than waiting for someone to speak.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.connection?.requestBacklog()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refreshRoster()
            }
            startRosterRefresh()
        case .rosterComplete(let present):
            // Authoritative presence. Keep anything we already learned
            // from traffic (a name, a locator) for stations still here.
            stations = present.map { fresh in
                guard let known = stations.first(where: { $0.callsign == fresh.callsign }) else { return fresh }
                var merged = fresh
                merged.name = fresh.name ?? known.name
                merged.locator = fresh.locator ?? known.locator
                return merged
            }
            .sorted { a, b in
                // Operators at their terminal first — they are the ones
                // you can actually raise a sked with.
                if a.isAway != b.isAway { return !a.isAway }
                return a.callsign < b.callsign
            }

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
