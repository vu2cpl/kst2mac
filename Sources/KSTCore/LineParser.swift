import Foundation

/// Classifies a decoded server line.
///
/// The documented chat-message shape is
///
///     HH:MM FROMCALL FromName > (TOCALL) message text
///
/// with the `(TOCALL)` part present only for a directed `/CQ` message.
/// The leading stamp is accepted both colon-separated (`21:15`) and bare
/// (`2115`) — the second-hand format documentation writes it only as
/// "TIME", and which one the server actually sends is one of the things
/// the KSTCapture transcript settles.
/// Everything else the server emits — the login banner, the chat menu,
/// join/leave notices, `/HELP` output, the user list — is passed through
/// unclassified as `.other` with `raw` intact. That is deliberate: the
/// exact wording of those lines has not been verified against a live
/// session yet (see docs/PROTOCOL.md), and a client that hides lines it
/// doesn't understand is worse than one that shows them verbatim.
public struct LineParser {

    private static let message = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,2}:\d{2}(?::\d{2})?|\d{4})\s+([A-Z0-9/\-]{3,})\s+(.*?)\s*>\s*(?:\(([A-Z0-9/\-]+)\)\s*)?(.*)$"#,
        options: [.caseInsensitive]
    )

    /// The command prompt the server reprints after every command and at
    /// idle: `0829Z VU2CPL 144/432 MHz IARU R 3 chat>`. It is furniture,
    /// not traffic, so the UI keeps it out of the chat log — but it does
    /// carry the server's idea of the current UTC time.
    private static let prompt = try! NSRegularExpression(
        pattern: #"^\s*(\d{4})Z\s+([A-Z0-9/\-]{3,})\s+(.*?)\s*chat>\s*$"#,
        options: [.caseInsensitive]
    )

    /// A locator anywhere in a line: 4 or 6 characters, e.g. JO20 / MK68qm.
    private static let locator = try! NSRegularExpression(
        pattern: #"\b([A-R]{2}\d{2}(?:[A-X]{2})?)\b"#,
        options: [.caseInsensitive]
    )

    public init() {}

    public func parse(_ raw: String) -> KSTLine {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)

        if let p = Self.prompt.firstMatch(in: raw, range: range) {
            func g(_ i: Int) -> String {
                guard let r = Range(p.range(at: i), in: raw) else { return "" }
                return String(raw[r]).trimmingCharacters(in: .whitespaces)
            }
            return KSTLine(raw: raw,
                           kind: .prompt(callsign: g(2).uppercased(), chat: g(3)),
                           stamp: g(1))
        }

        guard let m = Self.message.firstMatch(in: raw, range: range) else {
            return KSTLine(raw: raw, kind: .other)
        }

        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: raw) else { return nil }
            let s = String(raw[r]).trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }

        let stamp = group(1)
        guard let from = group(2) else { return KSTLine(raw: raw, kind: .other) }

        return KSTLine(
            raw: raw,
            kind: .message(from: from.uppercased(),
                           name: group(3),
                           to: group(4)?.uppercased(),
                           text: group(5) ?? ""),
            stamp: stamp
        )
    }

    /// Whether a bare token is a Maidenhead locator, normalised to the
    /// conventional `AB12cd` casing if so. Shared with `RosterParser`.
    public static func normalisedLocator(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        let r = NSRange(t.startIndex..<t.endIndex, in: t)
        guard let m = locator.firstMatch(in: t, range: r),
              m.range == r,      // the whole token, not a substring of it
              let g = Range(m.range(at: 1), in: t) else { return nil }
        let value = String(t[g])
        return value.prefix(4).uppercased() + value.dropFirst(4).lowercased()
    }

    /// First Maidenhead locator in a line, if any. Used both to enrich the
    /// station table from chat traffic and — once the user-list format is
    /// confirmed — to pull locators out of the roster.
    public func locator(in raw: String) -> String? {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let m = Self.locator.firstMatch(in: raw, range: range),
              let r = Range(m.range(at: 1), in: raw) else { return nil }
        let g = String(raw[r])
        // Normalise to the conventional AB12cd casing.
        return g.prefix(4).uppercased() + g.dropFirst(4).lowercased()
    }
}
