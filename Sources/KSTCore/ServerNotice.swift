import Foundation

/// Notices the server emits about itself, as opposed to chat traffic.
public enum ServerNotice {

    private static let wait = try! NSRegularExpression(
        pattern: #"^\s*please wait\s+(\d+)\s+second"#, options: [.caseInsensitive])

    /// Seconds the server wants us to wait before the next command, from
    /// `Please wait 55 second(s) between two commands.`
    ///
    /// Anchored to the start of the line, and only ever applied to lines
    /// that did not parse as chat traffic. An operator typing "please wait
    /// 30 seconds, I'm turning the beam" must reach the chat log as a
    /// message, not silently reconfigure our command throttle.
    public static func waitSeconds(in line: String) -> Double? {
        let r = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = wait.firstMatch(in: line, range: r),
              let g = Range(m.range(at: 1), in: line) else { return nil }
        return Double(line[g])
    }
}


/// The "preamble" convention: a station addresses you by typing your
/// callsign as the **first word** of an ordinary message, rather than
/// using `/CQ`.
///
/// It is a client-side convention with no server involvement, so it only
/// shows up as a highlight for people whose client implements it — which
/// is why `/CQ` remains the right default for outgoing replies.
public enum Preamble {

    /// Whether `text` opens by addressing `callsign`.
    public static func addresses(_ callsign: String, in text: String) -> Bool {
        let me = callsign.uppercased()
        guard !me.isEmpty, let first = text.split(separator: " ").first else { return false }
        // Trailing punctuation is common — "VU2CPL:" or "VU2CPL," — but a
        // callsign's own slash and hyphen must survive.
        let cleaned = first.uppercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ":,;.!?()<>"))
        return cleaned == me
    }
}
