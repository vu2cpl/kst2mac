import Foundation

/// A DX spot broken into fields, so it can be shown as a table rather
/// than a line of run-together text.
///
/// The relay never uses this — it forwards the original line verbatim.
/// This is purely for display, which is why every field is optional and
/// `raw` is always kept: a spot that parses oddly should still be
/// readable, and must never be dropped.
public struct SpotRecord: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let raw: String
    public let spotter: String
    public let frequency: Double?
    public let dx: String
    public let comment: String
    public let time: String
    public let received: Date

    public static func == (a: SpotRecord, b: SpotRecord) -> Bool { a.raw == b.raw }

    /// Frequency in kHz as the cluster sends it, formatted the way an
    /// operator reads it — 3573.6, 10368200.0 — without inventing
    /// precision the spot did not carry.
    public var frequencyText: String {
        guard let frequency else { return "" }
        return frequency == frequency.rounded()
            ? String(format: "%.1f", frequency)
            : String(format: "%.1f", frequency)
    }
}

public enum SpotParser {

    /// `DX de w9ffa:      3573.6  KS0AA        FT8, EM69ij <-> EM28    1241Z`
    ///
    /// Tolerant of the single-spaced form too, since `/SET DX` sends that
    /// and the columns are then gone.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^DX de\s+([A-Z0-9/\-]+):?\s+([\d.]+)\s+([A-Z0-9/\-]+)\s*(.*?)\s*(\d{4}Z)?$"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ line: String, received: Date = Date()) -> SpotRecord {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        guard let m = pattern.firstMatch(in: trimmed, range: range) else {
            return SpotRecord(raw: trimmed, spotter: "", frequency: nil,
                              dx: "", comment: trimmed, time: "", received: received)
        }

        func group(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: trimmed) else { return "" }
            return String(trimmed[r]).trimmingCharacters(in: .whitespaces)
        }

        return SpotRecord(raw: trimmed,
                          spotter: group(1).uppercased(),
                          frequency: Double(group(2)),
                          dx: group(3).uppercased(),
                          comment: HTMLText.decode(group(4)),
                          time: group(5),
                          received: received)
    }
}
