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
