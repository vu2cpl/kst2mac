import Foundation
import Network

/// Serves the chat's DX spots as a DX-cluster telnet node.
///
/// The point is that no translation happens. `/SET DXCLX` makes ON4KST
/// emit standard fixed-column `DX de …` lines — the same thing an
/// AR-Cluster or CLX node sends — so this listens on a port, does the
/// login handshake a cluster client expects, and forwards those lines
/// **verbatim**. Anything that re-encoded them could only introduce bugs.
///
/// dxca then treats it as one more `[[cluster_nodes]]` entry:
///
/// ```toml
/// [[cluster_nodes]]
/// name = "KST2Mac"
/// host = "127.0.0.1"
/// port = 7373
/// login_call = "VU2CPL"
/// ```
///
/// dxca looks for `login:` / `callsign:` / `call:` (case-insensitive
/// substrings) and sends its `login_call`; there is no password. It takes
/// a welcome line or any data as evidence the session is healthy.
public final class SpotRelay: @unchecked Sendable {

    public static let defaultPort: UInt16 = 7373

    private final class Client {
        let connection: NWConnection
        var codec = TelnetCodec()
        var pending = ""
        var loggedIn = false
        var call = ""
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "net.vu2cpl.kst2mac.spotrelay")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    /// Human-readable state, for the UI.
    public var onStatus: (@Sendable (String) -> Void)?
    /// Number of logged-in clients.
    public var onClientCount: (@Sendable (Int) -> Void)?

    public init() {}

    /// `28-Aug-2026 1300Z`, the shape cluster nodes use in their prompt.
    static func nodeTimestamp(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd-MMM-yyyy HHmm'Z'"
        return formatter.string(from: now)
    }

    // MARK: - Lifecycle

    /// - Parameter loopbackOnly: bind `127.0.0.1` rather than every
    ///   interface. Default, because dxca runs on the same machine and an
    ///   unauthenticated feed should not be offered to the whole LAN
    ///   without being asked for.
    public func start(port: UInt16, loopbackOnly: Bool = true) {
        queue.async {
            guard self.listener == nil else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.onStatus?("Invalid port \(port)")
                return
            }
            do {
                let parameters = NWParameters.tcp
                if loopbackOnly {
                    // `requiredInterfaceType = .loopback` is the supported
                    // way to confine a listener. Setting
                    // `requiredLocalEndpoint` instead — which reads like
                    // it should work — silently fails to bind at all.
                    parameters.requiredInterfaceType = .loopback
                }
                let listener = try NWListener(using: parameters, on: nwPort)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.onStatus?(loopbackOnly ? "Listening on 127.0.0.1:\(port)"
                                                     : "Listening on port \(port) (all interfaces)")
                    case .failed(let error): self?.onStatus?("Failed: \(error.localizedDescription)")
                    case .cancelled: self?.onStatus?("Stopped")
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            } catch {
                self.onStatus?("Could not listen on \(port): \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        queue.async {
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.onClientCount?(0)
        }
    }

    // MARK: - Clients

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // The banner names the source, and the prompt contains
                // "login:" because that is one of the substrings a cluster
                // client watches for.
                self?.send(to: client, "KST2Mac ON4KST spot relay")
                self?.send(to: client, "Enter your callsign at the login: prompt")
                self?.write(client, "login: ")
            case .failed, .cancelled:
                self?.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data, from: client) }
            if error != nil || isComplete {
                self.drop(client.connection)
                return
            }
            self.receive(client)
        }
    }

    private func ingest(_ data: Data, from client: Client) {
        // Cluster clients open with telnet negotiation; strip it or the
        // option bytes end up treated as a callsign.
        let (payload, reply) = client.codec.decode(data)
        if !reply.isEmpty {
            client.connection.send(content: reply, completion: .idempotent)
        }
        guard !payload.isEmpty, !client.loggedIn else { return }

        client.pending += String(decoding: payload, as: UTF8.self)
        guard let newline = client.pending.unicodeScalars.firstIndex(of: "\n") else { return }

        let line = String(String.UnicodeScalarView(client.pending.unicodeScalars[..<newline]))
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        client.pending = ""
        client.call = line.isEmpty ? "anonymous" : line.uppercased()
        client.loggedIn = true

        send(to: client, "Hello \(client.call), you are connected to KST2Mac")
        send(to: client, "Spots follow as they arrive from the ON4KST chat.")
        // A real node ends its login with a prompt, and a cluster client
        // treats one as proof the session works rather than merely being
        // open — dxca classifies any line ending in ">" that contains
        // " de " as a node prompt, and stays amber until it sees a prompt,
        // a spot, a WWV report or an announcement. Without this the link
        // reads as unhealthy until the first spot happens along, which on
        // a quiet band can be a long wait.
        send(to: client, "\(client.call) de KST2Mac \(Self.nodeTimestamp()) >")
        onStatus?("\(client.call) connected")
        onClientCount?(clients.values.filter(\.loggedIn).count)
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        if clients.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            onClientCount?(clients.values.filter(\.loggedIn).count)
        }
    }

    // MARK: - Sending

    /// Forward a spot line. Sent only to clients past the login prompt.
    public func broadcast(_ line: String) {
        queue.async {
            for client in self.clients.values where client.loggedIn {
                self.send(to: client, line)
            }
        }
    }

    private func send(to client: Client, _ line: String) {
        write(client, line + "\r\n")
    }

    private func write(_ client: Client, _ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        client.connection.send(content: data, completion: .idempotent)
    }
}
