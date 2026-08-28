import Foundation

/// Parses a row of `/SHow USer` output.
///
/// Captured format — callsign left-justified in a 17-character field, then
/// a locator, then the operator's name:
///
///     VU2CPL           MK83TE Manoj
///     |<--- 17 cols --->|
///
/// The columns are *not* parsed by fixed offset. A long callsign
/// (`SV1DH/P`, `OH2GEK`) or a missing locator would break that, and the
/// only capture available has a single short callsign in it. Splitting on
/// whitespace and identifying the locator by shape survives both.
///
/// Field **order** matters and is not guessable: `/SHow CONFig` prints the
/// same three values as `CALL Name LOC` rather than `CALL LOC Name`. That
/// is why roster rows are only ever parsed while a `/SHow USer` is
/// outstanding — see `KSTConnection.requestRoster()`, which uses the
/// server's command prompt as the end-of-output delimiter.
public enum RosterParser {

    private static let callsign = try! NSRegularExpression(
        pattern: #"^[A-Z0-9]{1,3}[0-9][A-Z0-9]{1,4}(?:/[A-Z0-9]{1,4})?$"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ raw: String) -> Station? {
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = parts.first else { return nil }

        let call = first.uppercased()
        let r = NSRange(call.startIndex..<call.endIndex, in: call)
        guard callsign.firstMatch(in: call, range: r) != nil else { return nil }

        var rest = Array(parts.dropFirst())
        var locator: String?
        if let candidate = rest.first, let normalised = LineParser.normalisedLocator(candidate) {
            locator = normalised
            rest.removeFirst()
        }

        let name = rest.joined(separator: " ")
        return Station(callsign: call,
                       name: name.isEmpty ? nil : name,
                       locator: locator)
    }
}
