import Foundation
import Network

/// TCP client for the ON4KST chat.
///
/// Two things about this server shape the design:
///
/// 1. **The login is prompt-driven and impatient.** The server asks for
///    login, then password, then the chat number, one at a time, and it
///    rejects the lot if you fire them off together. So we answer each
///    prompt only when we've actually seen it, with a short settle delay.
///
/// 2. **Once you are in the chat, everything you write is broadcast.**
///    There is no draft state on the server. `send(_:)` therefore refuses
///    to transmit unless the state machine says we are past login — a
///    stray write during the handshake would put the text in front of the
///    whole room, or worse, echo a password.
public final class KSTConnection: @unchecked Sendable {

    public static let defaultHost = "www.on4kst.info"
    public static let defaultPort: UInt16 = 23000

    private enum Phase {
        case idle
        case connecting
        case awaitingLogin
        case awaitingPassword
        case awaitingRoom
        case inChat
        case closed
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "net.vu2cpl.kst2mac.connection")
    private let parser = LineParser()

    private var connection: NWConnection?
    private var codec = TelnetCodec()
    private var phase: Phase = .idle
    /// Line splitting plus prompt tracking. See LineAccumulator for why
    /// the prompt candidate is not simply the un-terminated tail.
    private var accumulator = LineAccumulator()
    /// Set while a prompt answer is in flight, so we answer each prompt once.
    private var responding = false
    private var username = ""
    private var password = ""
    private var room: ChatRoom = .vhfUhf

    /// Every decoded chunk, verbatim, before line splitting. Set by the
    /// KSTCapture tool so a transcript includes the prompts — which never
    /// end in a newline and so never surface as `KSTLine`s.
    public var rawMonitor: (@Sendable (String) -> Void)?

    /// The server allows roughly one command per minute and answers a
    /// too-soon one with "Please wait N second(s) between two commands."
    ///
    /// The rule this enforces: **the app never spends the operator's
    /// command budget without being asked.** Anything the operator types
    /// goes out immediately — they are watching, and they will see any
    /// refusal. Only the app's own housekeeping (roster polls, backlog
    /// fetches) is queued and throttled, and it always yields to a
    /// user-initiated command.
    private static let commandInterval: TimeInterval = 60
    private var nextCommandAllowed = Date.distantPast
    private var queuedCommands: [String] = []
    private var drainScheduled = false

    /// Which command's output we are currently reading. The server has no
    /// markers around command replies, but it reprints its prompt when one
    /// ends — so the prompt is the delimiter.
    private enum Expecting { case nothing, roster }
    private var expecting: Expecting = .nothing
    private var rosterBuffer: [Station] = []

    /// Set while a `/CHAT` switch is in flight.
    ///
    /// `/CHAT` does not always move the session silently — the server can
    /// answer by re-presenting the chat-selection menu and waiting for a
    /// digit, exactly as it does at login. Left unanswered the session
    /// sits at that menu: the room never changes, and everything after it
    /// (the roster, `/SET DXCLX`) is issued into a prompt. So the digit is
    /// kept until either the menu appears and is answered, or a welcome
    /// line confirms the move.
    private var pendingRoomChoice: ChatRoom?

    private var continuation: AsyncStream<KSTEvent>.Continuation?
    /// Access this **before** calling `connect(_:)`. The continuation is
    /// created on first access, so events emitted earlier have nowhere to
    /// go and are silently dropped.
    public private(set) lazy var events: AsyncStream<KSTEvent> = {
        AsyncStream { self.continuation = $0 }
    }()

    public init(host: String = KSTConnection.defaultHost, port: UInt16 = KSTConnection.defaultPort) {
        self.host = host
        self.port = port
    }

    /// True once the handshake is complete and it is safe to send chat text.
    public var isInChat: Bool { queue.sync { phase == .inChat } }

    // MARK: - Lifecycle

    public func connect(username: String, password: String, room: ChatRoom) {
        queue.async {
            guard self.phase == .idle || self.phase == .closed else { return }
            self.username = username
            self.password = password
            self.room = room
            self.codec = TelnetCodec()
            self.accumulator = LineAccumulator()
            self.expecting = .nothing
            self.rosterBuffer = []
            self.queuedCommands = []
            self.drainScheduled = false
            self.nextCommandAllowed = .distantPast
            self.pendingRoomChoice = nil
            self.responding = false
            self.phase = .connecting

            let endpoint = NWEndpoint.Host(self.host)
            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                self.finish(reason: "Invalid port \(self.port)")
                return
            }
            // Plain TCP. The chat has no TLS on this port — the password
            // crosses the wire in clear, which is why the README tells you
            // to use a throwaway password here.
            let conn = NWConnection(host: endpoint, port: nwPort, using: .tcp)
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.emit(.status("Connected to \(self.host):\(self.port) — waiting for login prompt"))
                    self.queue.async { self.phase = .awaitingLogin }
                    self.receiveLoop()
                case .waiting(let error):
                    self.emit(.status("Waiting: \(error.localizedDescription)"))
                case .failed(let error):
                    self.finish(reason: error.localizedDescription)
                case .cancelled:
                    self.finish(reason: nil)
                default:
                    break
                }
            }
            self.emit(.status("Connecting to \(self.host):\(self.port)…"))
            conn.start(queue: self.queue)
        }
    }

    public func disconnect() {
        queue.async {
            guard self.phase != .closed else { return }
            self.connection?.cancel()
        }
    }

    // MARK: - Sending

    /// Send a line of chat. Silently refuses before the handshake completes.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            guard self.phase == .inChat else {
                self.emit(.line(.local("Not sent — not in the chat yet: \(trimmed)")))
                return
            }
            self.write(trimmed)
        }
    }

    /// Move to another chat without dropping the connection. The server
    /// keeps the session; only the room changes.
    public func switchChat(to newRoom: ChatRoom) {
        queue.async {
            guard self.phase == .inChat, newRoom != self.room else { return }
            self.room = newRoom
            self.expecting = .nothing
            self.rosterBuffer = []
            self.emit(.status("Switching to \(newRoom.title)…"))
            self.queuedCommands = []          // stale: they were for the old room
            self.pendingRoomChoice = newRoom
            self.accumulator.clear()
            self.write("/CHAT \(newRoom.chatToken)")
        }
    }

    /// Run the spot-format probe on this live session.
    ///
    /// Exists because the standalone `KSTCapture` tool has to ask for the
    /// password on a terminal, while a connected app already holds an
    /// authenticated session — so the operator never has to type a
    /// password to collect a transcript.
    ///
    /// The commands are spaced a minute apart because the server allows
    /// about one a minute; anything faster just collects wait notices.
    /// They reply privately and post nothing to the room, but `/SET DX`
    /// and `/SET DXCLX` do change the operator's own spot preferences —
    /// `/UNSET DX` puts them back.
    public func probeSpotFormat() {
        let commands = ["/SET DXCLX", "/SHOW DX 10", "/SET DX", "/SHOW DX 10"]
        queue.async {
            guard self.phase == .inChat else {
                self.emit(.line(.local("Spot probe needs a connected chat.")))
                return
            }
            self.emit(.line(.local("Spot probe: \(commands.count) commands, about a minute apart.")))
            for (index, command) in commands.enumerated() {
                self.queue.asyncAfter(deadline: .now() + Double(index) * 62) { [weak self] in
                    guard let self, self.phase == .inChat else { return }
                    self.emit(.line(.local("Spot probe → \(command)")))
                    self.write(command)
                }
            }
        }
    }

    /// Mirror of every decoded chunk, for transcript capture.
    public func setRawMonitor(_ monitor: (@Sendable (String) -> Void)?) {
        queue.async { self.rawMonitor = monitor }
    }

    /// Turn DX spots on for this account, in CLX format.
    ///
    /// Queued as housekeeping, so it waits its turn behind anything the
    /// operator asked for and respects the one-a-minute limit. Harmless
    /// to repeat: the server answers "DX messages allowed (CLX format)."
    /// whether or not it was already on.
    public func enableSpots() {
        queue.async {
            guard self.phase == .inChat else { return }
            self.enqueueHousekeeping("/SET DXCLX")
        }
    }

    /// Ask the server who is present. The reply arrives as `.line`s of
    /// kind `.roster` and is closed by a `.rosterComplete` event.
    /// - Parameter userInitiated: `true` when the operator asked for it
    ///   (the refresh button), which sends immediately; `false` for the
    ///   periodic poll, which waits its turn.
    public func requestRoster(userInitiated: Bool = false) {
        queue.async {
            guard self.phase == .inChat else { return }
            self.expecting = .roster
            self.rosterBuffer = []
            if userInitiated {
                self.write("/SHOW USER")
            } else {
                self.enqueueHousekeeping("/SHOW USER")
            }
        }
    }

    /// Ask for the last `count` chat messages, to backfill the log on join
    /// rather than starting from an empty window.
    public func requestBacklog(_ count: Int = 15, userInitiated: Bool = false) {
        queue.async {
            guard self.phase == .inChat else { return }
            if userInitiated {
                self.write("/SHOW MSG \(count)")
            } else {
                self.enqueueHousekeeping("/SHOW MSG \(count)")
            }
        }
    }

    /// Send a directed message, the `/CQ CALL text` form the chat uses to
    /// highlight a message for one station.
    public func sendDirected(to callsign: String, text: String) {
        let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return send(text) }
        send("/CQ \(call) \(text)")
    }

    /// Queue a command the *app* wants to run. Deferred until the server
    /// will accept it, deduplicated, and dropped if we leave the chat.
    private func enqueueHousekeeping(_ command: String) {
        guard !queuedCommands.contains(command) else { return }
        queuedCommands.append(command)
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !drainScheduled, !queuedCommands.isEmpty else { return }
        drainScheduled = true
        let delay = max(0, nextCommandAllowed.timeIntervalSinceNow)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            guard self.phase == .inChat, !self.queuedCommands.isEmpty else {
                self.queuedCommands = []
                return
            }
            self.write(self.queuedCommands.removeFirst())
            self.scheduleDrain()
        }
    }

    private func write(_ line: String) {
        // Any command — ours or the operator's — starts the server's
        // cooling-off window, so our own queue must respect it too.
        if line.hasPrefix("/") {
            nextCommandAllowed = Date().addingTimeInterval(Self.commandInterval)
        }
        guard let data = (line + "\r\n").data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.emit(.status("Send failed: \(error.localizedDescription)")) }
        })
    }

    private func writeRaw(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if let error {
                self.finish(reason: error.localizedDescription)
                return
            }
            if isComplete {
                self.finish(reason: "Server closed the connection")
                return
            }
            self.receiveLoop()
        }
    }

    private func ingest(_ data: Data) {
        let (payload, reply) = codec.decode(data)
        if !reply.isEmpty { writeRaw(reply) }
        guard !payload.isEmpty else { return }

        // The chat is Latin-1 in practice (European accented names show up
        // in the Name column); fall back to a lossy decode rather than
        // dropping the chunk.
        let text = String(data: payload, encoding: .utf8)
            ?? String(data: payload, encoding: .isoLatin1)
            ?? String(decoding: payload, as: UTF8.self)

        rawMonitor?(text)
        for line in accumulator.feed(text) {
            handle(line: line)
        }

        // Prompts also matter mid-session while a room switch is pending.
        if phase != .inChat || pendingRoomChoice != nil { checkForPrompt() }
    }

    private func handle(line raw: String) {
        var parsed = parser.parse(raw)

        // `Welcome … on this <room> amateur chat` is the server confirming
        // where we actually are — the only trustworthy end to a switch.
        if case .joined = parsed.kind, let choice = pendingRoomChoice {
            pendingRoomChoice = nil
            room = choice
            expecting = .nothing
            rosterBuffer = []
            emit(.loggedIn(choice))
        }

        // The server telling us to slow down is the authority on when the
        // next command may go out — believe it over our own estimate.
        // Checked only against lines that are *not* chat traffic, so an
        // operator typing "please wait 30 seconds" stays a message.
        if case .other = parsed.kind, let seconds = ServerNotice.waitSeconds(in: raw) {
            nextCommandAllowed = Date().addingTimeInterval(seconds + 2)
            emit(.status("Server asked us to wait \(Int(seconds))s before the next command"))
            scheduleDrain()
            emit(.line(KSTLine(raw: raw, kind: .local)))
            return
        }

        // The prompt closes whatever command reply was in flight.
        if case .prompt = parsed.kind {
            if expecting == .roster {
                emit(.rosterComplete(rosterBuffer))
                rosterBuffer = []
            }
            expecting = .nothing
            emit(.line(parsed))
            return
        }

        // Roster rows only count while a /SHow USer is outstanding: the
        // same three fields appear in a different order in other replies.
        if expecting == .roster, case .other = parsed.kind,
           let station = RosterParser.parse(raw) {
            rosterBuffer.append(station)
            parsed = KSTLine(raw: raw, kind: .roster(station))
            emit(.line(parsed))
            return
        }

        emit(.line(parsed))

        // Learn the roster from the traffic itself. Once the user-list
        // command and its column layout are confirmed against a live
        // session this gets a proper roster parser alongside it.
        if case .message(let from, let name, _, _) = parsed.kind {
            var station = Station(callsign: from, name: name)
            station.locator = parser.locator(in: raw)
            emit(.station(station))
        }
    }

    // MARK: - Login state machine

    /// Answer whichever prompt we are waiting on, once.
    private func checkForPrompt() {
        guard !responding else { return }
        let candidate = accumulator.promptCandidate
        guard !candidate.isEmpty else { return }

        // A `/CHAT` that came back with the selection menu instead of
        // moving us. Answer it with the digit and carry on.
        if let choice = pendingRoomChoice, LoginPrompt.room.matches(candidate) {
            emit(.status("Answering chat menu with \(choice.rawValue) — \(choice.title)"))
            respond(String(choice.rawValue), then: .inChat)
            return
        }

        switch phase {
        case .awaitingLogin:
            guard LoginPrompt.login.matches(candidate) else { return }
            emit(.status("Sending callsign…"))
            respond(username, then: .awaitingPassword)

        case .awaitingPassword:
            guard LoginPrompt.password.matches(candidate) else { return }
            emit(.status("Sending password…"))
            respond(password, then: .awaitingRoom)

        case .awaitingRoom:
            guard LoginPrompt.room.matches(candidate) else { return }
            emit(.status("Entering \(room.title)…"))
            respond(String(room.rawValue), then: .inChat)

        default:
            return
        }
    }

    /// Answer a prompt after a short settle delay, then advance the state
    /// machine. The server drops the login if the three answers arrive
    /// back-to-back, so each one waits for its own prompt *and* pauses
    /// before replying. `responding` blocks re-entry in the meantime.
    private func respond(_ value: String, then next: Phase) {
        accumulator.clear()
        responding = true
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.write(value)
            self.phase = next
            self.responding = false
            if next == .inChat {
                self.password = ""      // no longer needed; don't keep it around
                self.emit(.loggedIn(self.room))
            }
        }
    }

    // MARK: - Plumbing

    private func emit(_ event: KSTEvent) {
        continuation?.yield(event)
    }

    private func finish(reason: String?) {
        queue.async {
            guard self.phase != .closed else { return }
            self.phase = .closed
            self.password = ""
            self.connection = nil
            self.emit(.disconnected(reason))
            self.continuation?.finish()
        }
    }
}
