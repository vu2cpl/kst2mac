import SwiftUI
import KSTCore

/// Tints the two things an operator actually scans a chat line for: grid
/// squares and frequencies.
///
/// Everything else is left exactly as typed. The temptation is to
/// highlight signal reports and callsigns too, but message text is free
/// prose full of numbers — "420/5db", "2x10", "160/1" — and a highlighter
/// that fires on all of them tints the whole line, which is the same as
/// tinting none of it.
enum MessageText {

    private static let grid = try! NSRegularExpression(
        pattern: #"\b[A-R]{2}\d{2}(?:[A-X]{2})?\b"#, options: [.caseInsensitive])

    /// A frequency in MHz or kHz with a decimal point — "144.300",
    /// "10368.910". Bare integers are excluded: too many of them in
    /// ordinary chat are reports or antenna counts.
    private static let frequency = try! NSRegularExpression(
        pattern: #"\b\d{2,6}\.\d{1,4}\b"#)

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        func tint(_ regex: NSRegularExpression, _ colour: Color) {
            for m in regex.matches(in: text, range: whole) {
                guard let r = Range(m.range, in: text),
                      let a = Range(r, in: out) else { continue }
                out[a].foregroundColor = colour
            }
        }

        tint(grid, Color(red: 0.55, green: 0.82, blue: 0.60))
        tint(frequency, Color(red: 0.95, green: 0.72, blue: 0.45))
        return out
    }
}
