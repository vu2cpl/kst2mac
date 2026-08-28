import Foundation

/// Splits a byte-stream into lines while keeping track of what the server
/// is currently prompting for.
///
/// This exists because of a bug worth remembering. The ON4KST prompts —
/// `Login:`, `Password:`, `Your choice           :` — are **CRLF
/// terminated**. The server writes the prompt, ends the line, and waits.
///
/// The first version of this client got this wrong twice over.
///
/// It searched for a line ending with `pending.firstIndex(of: "\n")` —
/// but Swift treats CR-LF as a *single* Character, so that never matches
/// a `\r\n` ending. Nothing was ever split; the entire session piled up
/// in one buffer. `Login:` and `Password:` were still answered, because
/// the prompt test was a substring search over that whole buffer and the
/// words were in there. The chat menu then stalled: its test also required
/// the buffer to *end* with a colon, and the buffer ended with the CR-LF
/// after `Your choice           :`. Two capture runs died at exactly 480
/// bytes.
///
/// The fix is both halves. Split on unicode scalars, where `\r` and `\n`
/// are separate — that also makes a CR and its LF landing in different TCP
/// segments a non-event. And take the prompt candidate from the
/// un-terminated remainder **or**, when there is none, the last complete
/// line, so a prompt works whether or not it carries a newline.
public struct LineAccumulator {

    private var pending = ""
    private var lastComplete = ""

    public init() {}

    /// Feed decoded text; returns any lines completed by it.
    ///
    /// Splitting happens at the **unicode scalar** level, not the
    /// Character level. Swift treats CR-LF as a single grapheme cluster,
    /// so `pending.firstIndex(of: "\n")` never matches a `\r\n` line
    /// ending — the original splitter silently never split anything, and
    /// the whole session accumulated in one buffer. Working in scalars
    /// also makes a CR and its LF arriving in different TCP segments a
    /// non-event.
    public mutating func feed(_ text: String) -> [String] {
        pending += text

        let scalars = Array(pending.unicodeScalars)
        var lines: [String] = []
        var start = 0

        for i in scalars.indices where scalars[i] == "\n" {
            var end = i
            if end > start, scalars[end - 1] == "\r" { end -= 1 }
            let raw = String(String.UnicodeScalarView(scalars[start..<end]))
            start = i + 1
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lastComplete = raw
            lines.append(raw)
        }

        pending = String(String.UnicodeScalarView(scalars[start...]))
        return lines
    }

    /// What the server appears to be waiting on right now.
    public var promptCandidate: String {
        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? lastComplete : tail
    }

    /// Called after answering a prompt, so the same prompt is not matched
    /// a second time from stale buffer contents.
    public mutating func clear() {
        pending = ""
        lastComplete = ""
    }
}

/// Recognises the three prompts of the ON4KST login handshake.
///
/// Matching is deliberately loose — a substring plus a prompt-shaped
/// ending — because a mis-fire here is harmless: nothing sent during the
/// handshake can reach the room, since we are not in the room yet.
public enum LoginPrompt: Sendable {
    case login
    case password
    case room

    /// Prompt text as verified against a live session on 2026-08-28:
    /// `Login:` / `Password:` / `Your choice           :`
    public func matches(_ candidate: String) -> Bool {
        let t = candidate.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // Every one of them ends in a colon; requiring it stops a banner
        // line that merely mentions "login" from being treated as one.
        guard t.hasSuffix(":") || t.hasSuffix(">") || t.hasSuffix("?") else { return false }

        switch self {
        case .login:    return t.contains("login") || t.contains("callsign") || t.contains("user")
        case .password: return t.contains("password")
        case .room:     return t.contains("choice") || t.contains("chat") || t.contains("number")
        }
    }
}
