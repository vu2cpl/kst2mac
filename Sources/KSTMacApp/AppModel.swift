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

    @AppStorage("savePassword") var savePassword: Bool = true

    /// Callsigns worth watching for — their traffic is tinted so it can be
    /// picked out of a busy room. Shared across windows on purpose: a
    /// watch is about a station, not about a room.
    @AppStorage("watchedCalls") private var watchedRaw: String = ""

    /// **Per window.** Each window owns its own connection, so two
    /// windows are two sessions in two different rooms — this cannot live
    /// in shared storage or the windows would fight over it. The last
    /// choice made is remembered only as the *default* for the next new
    /// window.
    ///
    /// Defaults to 144/432 MHz rather than the region-3 room: R3 is
    /// usually empty, and a first run showing an empty window reads as a
    /// broken client rather than a quiet band.
    @Published var room: ChatRoom {
        didSet {
            guard room != oldValue else { return }
            UserDefaults.standard.set(room.rawValue, forKey: Self.defaultRoomKey)
            // While connected the server moves us with /CHAT, so the
            // picker stays live rather than locked until reconnect.
            if isInChat {
                // Keep the old list visible and marked stale: the
                // replacement roster may be a minute away, and an empty
                // table reads as "nobody here" rather than "asking".
                stationsAreStale = true
                connection?.switchChat(to: room)
            }
        }
    }

    static let defaultRoomKey = "roomRaw"

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.defaultRoomKey)
        room = ChatRoom(rawValue: stored) ?? .vhfUhf
    }

    // MARK: Live state
    @Published private(set) var lines: [KSTLine] = []
    @Published private(set) var stations: [Station] = []
    @Published private(set) var status: String = "Not connected"
    @Published private(set) var isConnected = false
    @Published private(set) var isInChat = false
    /// The server's own UTC clock, from its command prompt.
    @Published private(set) var serverTime: String = ""
    /// Set when the roster belongs to a room we have just left, until the
    /// replacement arrives.
    @Published private(set) var stationsAreStale = false

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
        // Ask on first connect rather than at launch: the permission
        // prompt makes sense once there is something to be notified about.
        Notifier.shared.requestAuthorization()

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

    /// Ask the server who is present, right now — the refresh button.
    /// Sends immediately: the operator asked, and will see any refusal.
    func refreshRoster() {
        connection?.requestRoster(userInitiated: true)
    }

    /// Fetch recent messages. A deliberate action, because it costs one of
    /// the operator's roughly-one-per-minute command slots.
    func loadBacklog() {
        connection?.requestBacklog(userInitiated: true)
    }

    /// The roster is a snapshot and needs re-asking, but each poll spends
    /// one of the operator's command slots — so five minutes, not one. A
    /// chat's population does not turn over faster than that, and the
    /// refresh button covers the impatient case.
    private func startRosterRefresh() {
        rosterTimer?.cancel()
        rosterTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self, self.isInChat else { return }
                self.connection?.requestRoster()
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
            if case .roster = line.kind { return }        // the table shows these
            if case .boilerplate = line.kind { return }   // fixed banner text
            if case .joined(let chat) = line.kind {
                // The welcome line names the room we actually landed in,
                // which after a /CHAT switch is the first confirmation
                // that the server moved us.
                status = "In \(chat) as \(callsign)"
            }
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
            // One command on join, not two: the server allows about one
            // a minute, and the roster is worth more than the backlog.
            // Backlog is a button the operator can spend a slot on.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.connection?.requestRoster()
            }
            startRosterRefresh()
        case .rosterComplete(let present):
            // Authoritative presence. Keep anything we already learned
            // from traffic (a name, a locator) for stations still here.
            let known = Dictionary(stations.map { ($0.callsign, $0) },
                                   uniquingKeysWith: { first, _ in first })
            stations = present
                .map { fresh in
                    guard let old = known[fresh.callsign] else { return fresh }
                    var merged = fresh
                    merged.name = fresh.name ?? old.name
                    merged.locator = fresh.locator ?? old.locator
                    return merged
                }
                .sorted { a, b in
                    // Operators at their terminal first — they are the
                    // ones you can actually raise a sked with.
                    if a.isAway != b.isAway { return !a.isAway }
                    return a.callsign < b.callsign
                }
            stationsAreStale = false

        case .disconnected(let reason):
            isConnected = false
            isInChat = false
            status = reason.map { "Disconnected: \($0)" } ?? "Disconnected"
            append(.local(status))
        }
    }

    private func append(_ line: KSTLine) {
        if mentionsMe(line), case .message(let from, let name, let to, let text) = line.kind {
            Notifier.shared.mention(from: from, name: name, text: text,
                                    room: room.title, directed: to == callsign.uppercased())
        }
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

    // MARK: - Emphasis

    /// How a line should be picked out of the log. Modelled on KST2Me,
    /// which colours to-me, from-me and watched traffic differently —
    /// the three things you scan a busy chat for.
    enum Emphasis {
        case mention   // addressed to us, or naming us
        case watched   // a callsign we are waiting on
        case own       // something we sent
        case none
    }

    var watched: Set<String> {
        Set(watchedRaw.split(separator: ",").map { String($0).uppercased() })
            .subtracting([""])
    }

    func isWatched(_ callsign: String) -> Bool {
        watched.contains(callsign.uppercased())
    }

    func toggleWatch(_ callsign: String) {
        let call = callsign.uppercased()
        var set = watched
        if set.contains(call) { set.remove(call) } else { set.insert(call) }
        watchedRaw = set.sorted().joined(separator: ",")
        objectWillChange.send()
    }

    func clearWatches() {
        watchedRaw = ""
        objectWillChange.send()
    }

    /// Mention wins over watch, and watch over our own traffic: a line
    /// addressed to you matters more than one merely from a station you
    /// are following.
    func emphasis(for line: KSTLine) -> Emphasis {
        guard case .message(let from, _, _, _) = line.kind else { return .none }
        if mentionsMe(line) { return .mention }
        if isWatched(from) { return .watched }
        if !callsign.isEmpty, from == callsign.uppercased() { return .own }
        return .none
    }

    /// True if the line is addressed to, or mentions, our own callsign.
    func mentionsMe(_ line: KSTLine) -> Bool {
        guard !callsign.isEmpty else { return false }
        let me = callsign.uppercased()
        if case .message(let from, _, let to, let text) = line.kind {
            // Our own message naming us is not a mention of us.
            if from == me { return false }
            if to == me { return true }
            return text.uppercased().contains(me)
        }
        return false
    }
}
