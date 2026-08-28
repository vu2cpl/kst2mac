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
    private let queue = DispatchQueue(label: "net.vu2cpl.kstmac.connection")
    private let parser = LineParser()

    private var connection: NWConnection?
    private var codec = TelnetCodec()
    private var phase: Phase = .idle
    /// Text received but not yet terminated by a newline. Prompts arrive
    /// without one, so this is also where we look for them.
    private var pending = ""
    /// Set while a prompt answer is in flight, so we answer each prompt once.
    private var responding = false
    private var username = ""
    private var password = ""
    private var room: ChatRoom = .vhfUhf

    /// Every decoded chunk, verbatim, before line splitting. Set by the
    /// KSTCapture tool so a transcript includes the prompts — which never
    /// end in a newline and so never surface as `KSTLine`s.
    public var rawMonitor: (@Sendable (String) -> Void)?

    private var continuation: AsyncStream<KSTEvent>.Continuation?
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
            self.pending = ""
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

    /// Send a directed message, the `/CQ CALL text` form the chat uses to
    /// highlight a message for one station.
    public func sendDirected(to callsign: String, text: String) {
        let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return send(text) }
        send("/CQ \(call) \(text)")
    }

    private func write(_ line: String) {
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
        pending += text

        // Emit every complete line; whatever is left is a partial line or,
        // during the handshake, a prompt.
        while let nl = pending.firstIndex(of: "\n") {
            let raw = String(pending[pending.startIndex..<nl])
                .replacingOccurrences(of: "\r", with: "")
            pending = String(pending[pending.index(after: nl)...])
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            handle(line: raw)
        }

        if phase != .inChat { checkForPrompt() }
    }

    private func handle(line raw: String) {
        let parsed = parser.parse(raw)
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

    /// Look at the un-terminated tail for a prompt and answer it once.
    ///
    /// The prompts are matched loosely — the exact wording is not
    /// guaranteed stable and has only been confirmed second-hand. A
    /// mis-fire here is harmless: nothing we send during the handshake can
    /// reach the room, because we are not in the room yet.
    private func checkForPrompt() {
        guard !responding else { return }
        let tail = pending.lowercased()
        guard !tail.isEmpty else { return }

        switch phase {
        case .awaitingLogin:
            guard tail.contains("login") || tail.contains("callsign") || tail.contains("user") else { return }
            emit(.status("Sending callsign…"))
            respond(username, then: .awaitingPassword)

        case .awaitingPassword:
            guard tail.contains("password") else { return }
            emit(.status("Sending password…"))
            respond(password, then: .awaitingRoom)

        case .awaitingRoom:
            // The chat menu ends in a prompt with no newline. Require both
            // some evidence of the menu and a prompt-shaped tail so we
            // don't answer mid-banner.
            let looksLikeMenu = tail.contains("144/432") || tail.contains("chat")
                || tail.contains("choice") || tail.contains("number")
            let promptShaped = tail.hasSuffix(":") || tail.hasSuffix("> ")
                || tail.hasSuffix(">") || tail.hasSuffix("? ")
            guard looksLikeMenu, promptShaped else { return }
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
        pending = ""
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
