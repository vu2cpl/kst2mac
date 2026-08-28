import Foundation

/// The chat rooms the ON4KST telnet menu offers, keyed by the digit you
/// send at the "Your choice :" prompt.
///
/// Transcribed verbatim from a live session on 2026-08-28 — all thirteen
/// of them. Third-party write-ups of this menu list only six rooms and
/// claim there is no 6; both are wrong. Rooms 6 and 9 are the IARU
/// Region 3 rooms, which are the relevant ones from VU.
public enum ChatRoom: Int, CaseIterable, Identifiable, Sendable {
    case fiftySeventy      = 1
    case vhfUhf            = 2
    case microwave         = 3
    case eme               = 4
    case lowBand           = 5
    case fiftyRegion3      = 6
    case fiftyRegion2      = 7
    case vhfUhfRegion2     = 8
    case vhfUhfRegion3     = 9
    case kilohertz         = 10
    case warc              = 11
    case twentyEight       = 12
    case forty             = 13

    public var id: Int { rawValue }

    /// The token `/CHAT` expects, for switching room without dropping the
    /// connection. From the captured `/HELP`: "Values are 28 40 50 50R2
    /// 50R3 144 144R2 144R3 GHZ EME HF KHZ WARC" — thirteen values for
    /// thirteen rooms.
    public var chatToken: String {
        switch self {
        case .fiftySeventy:  return "50"
        case .vhfUhf:        return "144"
        case .microwave:     return "GHZ"
        case .eme:           return "EME"
        case .lowBand:       return "HF"
        case .fiftyRegion3:  return "50R3"
        case .fiftyRegion2:  return "50R2"
        case .vhfUhfRegion2: return "144R2"
        case .vhfUhfRegion3: return "144R3"
        case .kilohertz:     return "KHZ"
        case .warc:          return "WARC"
        case .twentyEight:   return "28"
        case .forty:         return "40"
        }
    }

    public var title: String {
        switch self {
        case .fiftySeventy:  return "50 / 70 MHz"
        case .vhfUhf:        return "144 / 432 MHz"
        case .microwave:     return "Microwave"
        case .eme:           return "EME / JT65"
        case .lowBand:       return "Low Band"
        case .fiftyRegion3:  return "50 MHz IARU Region 3"
        case .fiftyRegion2:  return "50 MHz IARU Region 2"
        case .vhfUhfRegion2: return "144 / 432 MHz IARU R2"
        case .vhfUhfRegion3: return "144 / 432 MHz IARU R3"
        case .kilohertz:     return "kHz (2000 – 630 m)"
        case .warc:          return "WARC (30, 17, 12 m)"
        case .twentyEight:   return "28 MHz"
        case .forty:         return "40 MHz"
        }
    }
}

/// One line as received from the server, after telnet decoding.
///
/// `raw` is always the verbatim line. Everything else is best-effort: if the
/// parser doesn't recognise a line it still arrives here as `.other` with
/// `raw` intact, so nothing the server says can ever be silently dropped.
public struct KSTLine: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// A chat message: `HH:MM CALL Name > (ToCall) text`
        case message(from: String, name: String?, to: String?, text: String)
        /// The server's command prompt, reprinted after every command:
        /// `0829Z VU2CPL 144/432 MHz IARU R 3 chat>`. Furniture, not
        /// traffic — kept out of the chat log.
        case prompt(callsign: String, chat: String)
        /// The server's welcome line, emitted on every join *and* every
        /// `/CHAT` switch. Rendered as a compact room divider rather than
        /// as four lines of banner text.
        case joined(chat: String)
        /// Fixed banner text that repeats verbatim with every welcome —
        /// the CLX cluster hint and the "/HELP" pointer. Shown once would
        /// be generous; shown on every room switch is noise.
        case boilerplate
        /// A row of `/SHow USer` output. Feeds the station table, not the
        /// chat log.
        case roster(Station)
        /// Anything the server said that we didn't classify.
        case other
        /// Locally generated notice (connect/disconnect/errors) — never
        /// came off the wire.
        case local
    }

    public let id = UUID()
    public let received: Date
    public let raw: String
    public let kind: Kind
    /// Server-supplied timestamp text (`HH:MM`) when the line carried one.
    public let stamp: String?

    public init(received: Date = Date(), raw: String, kind: Kind, stamp: String? = nil) {
        self.received = received
        self.raw = raw
        self.kind = kind
        self.stamp = stamp
    }

    public static func local(_ text: String) -> KSTLine {
        KSTLine(raw: text, kind: .local)
    }
}

/// A station seen on the chat, as shown in the side table.
public struct Station: Identifiable, Sendable, Equatable {
    public var id: String { callsign }
    public var callsign: String
    public var name: String?
    public var locator: String?
    /// Free-text status/comment the operator set, when the server gives one.
    public var status: String?
    /// The roster brackets the callsign of an operator who has said they
    /// are away from the terminal (`/UNSET HERE`).
    public var isAway: Bool
    public var lastHeard: Date

    public init(callsign: String, name: String? = nil, locator: String? = nil,
                status: String? = nil, isAway: Bool = false, lastHeard: Date = Date()) {
        self.callsign = callsign
        self.name = name
        self.locator = locator
        self.status = status
        self.isAway = isAway
        self.lastHeard = lastHeard
    }
}

/// Everything the connection reports back to the UI.
public enum KSTEvent: Sendable {
    case status(String)          // human-readable connection state
    case line(KSTLine)
    case station(Station)        // a station was seen or updated
    case loggedIn(ChatRoom)
    /// A complete `/SHow USer` reply — the authoritative list of who is
    /// present, replacing whatever the table held before.
    case rosterComplete([Station])
    case disconnected(String?)   // nil = clean, otherwise the reason
}
