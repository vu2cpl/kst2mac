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
    /// When set, the next send is addressed to this callsign.
    @Published var directedTo: String?

    /// How to address a reply. `/CQ` is the default because it highlights
    /// for every chat user whatever client they run; a preamble only
    /// highlights for clients that implement the convention.
    @AppStorage("replyWithPreamble") var replyWithPreamble: Bool = false

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

    /// Where the raw transcript goes while a probe is running.
    @Published private(set) var transcriptURL: URL?
    private var transcript: TranscriptWriter?

    /// Run the spot-format probe and write every byte the server sends to
    /// a file on the Desktop, so the exact format can be read rather than
    /// squinted at in the chat log.
    func probeSpotFormat() {
        guard let connection, isInChat else { return }

        let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kst2mac-spot-probe.txt")
        guard let writer = TranscriptWriter(url: url) else {
            append(.local("Could not open \(url.lastPathComponent) for writing."))
            return
        }

        transcript = writer
        transcriptURL = url
        // The monitor is called on the connection's queue, so the writer
        // owns its own lock rather than touching this main-actor model.
        connection.setRawMonitor { [weak writer] chunk in writer?.write(chunk) }
        connection.probeSpotFormat()
        append(.local("Recording to \(url.path) — about four minutes."))
    }

    /// Stop recording and close the file. Stopping early truncates it.
    func endProbe() {
        connection?.setRawMonitor(nil)
        transcript?.close()
        transcript = nil
        if let url = transcriptURL {
            append(.local("Spot probe written to \(url.path)"))
        }
        transcriptURL = nil
    }

    /// Fetch recent messages. A deliberate action, because it costs one of
    /// the operator's roughly-one-per-minute command slots.
    func loadBacklog() {
        Sounds.shared.beQuiet(for: 8)
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
            if replyWithPreamble {
                connection.send("\(to.uppercased()) \(text)")
            } else {
                connection.sendDirected(to: to, text: text)
            }
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
            // Joining a busy room replays recent traffic; alerting on
            // messages sent before we arrived would be a volley of noise.
            Sounds.shared.beQuiet(for: 8)
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
        switch emphasis(for: line) {
        case .directed, .preamble:
            let kind = emphasis(for: line)
            if case .message(let from, let name, _, let text) = line.kind {
                Notifier.shared.mention(from: from, name: name, text: text,
                                        room: room.title, directed: kind == .directed)
            }
            // Sound plays whether or not the app is frontmost — that is
            // the case notifications cannot cover.
            Sounds.shared.play(kind == .directed ? .directed : .preamble)
        case .watched:
            Sounds.shared.play(.watched)
        default:
            break
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

    /// How a line should be picked out of the log.
    ///
    /// The tiers and their precedence come straight from the KST2Me
    /// manual (§4.6), which is the convention ON4KST regulars already
    /// have in their eyes:
    ///
    /// 1. **`/CQ`** — a real server-side directed message. Works for
    ///    every chat user, whatever client they run.
    /// 2. **Preamble** — the partner's callsign typed as the first word
    ///    of an ordinary message. A *client-side convention*, not a
    ///    protocol feature: it only highlights for people running a
    ///    client that implements it. That is why `/CQ` stays the default
    ///    for outgoing replies here.
    /// 3. **Watch** — a string you asked to be told about.
    /// 4. **Own** — something we sent. Not a KST2Me tier; added because
    ///    a sent message that looks like everyone else's gives you no
    ///    confirmation it went out.
    enum Emphasis {
        case directed
        case preamble
        case watched
        case own
        case none
    }

    var watched: Set<String> {
        var set = Set(watchedRaw.split(separator: ",").map { String($0).uppercased() })
        set.remove("")
        // Our own callsign is an implicit watch. The manual suggests
        // exactly this (§3.4: watch your own call "in case no /CQ or
        // preamble are received"), and it means a mention that is
        // neither a /CQ nor a preamble still gets noticed — at watch
        // level, which is the right weight for it.
        if !callsign.isEmpty { set.insert(callsign.uppercased()) }
        return set
    }

    /// Watches the operator set, without the implicit own-callsign one —
    /// what the UI should show and let them clear.
    var explicitWatches: Set<String> {
        watched.subtracting([callsign.uppercased()])
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

    func emphasis(for line: KSTLine) -> Emphasis {
        guard case .message(let from, _, let to, let text) = line.kind else { return .none }
        let me = callsign.uppercased()

        if !me.isEmpty, from == me { return .own }
        if !me.isEmpty, to == me { return .directed }
        if Preamble.addresses(me, in: text) { return .preamble }
        if isWatched(from) || matchesWatch(text) { return .watched }
        return .none
    }



    /// Watches match anywhere in the message text, as well as by
    /// callsign. KST2Me offers a scope per watch (message / user list /
    /// spots); this is the "included in the chat message" case, which is
    /// the one its own manual gives as the worked example.
    private func matchesWatch(_ text: String) -> Bool {
        let haystack = text.uppercased()
        return watched.contains { !$0.isEmpty && haystack.contains($0) }
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
