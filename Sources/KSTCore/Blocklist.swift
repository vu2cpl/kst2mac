import Foundation

/// Suppression rules for the two places ON4KST traffic carries junk: the
/// spotter callsign on a DX spot, and the operator's name field.
///
/// Seeded from Bo OZ2M's KST2Me lists (see `BlocklistSeed.swift`), which
/// are the only curated source for either — twenty years of one operator
/// watching the same rooms. Nothing here is derived from the wire, so
/// unlike the parser it cannot be validated against a capture; it is a
/// display preference, and every rule is one the operator can turn off.
///
/// Deliberately not a policy engine. Two operations, both total, both
/// cheap enough to run on every roster row:
///
///   - `blocks(spotter:)` — drop the spot entirely.
///   - `scrub(name:)` — strip junk out of a name, keep what is left.
public struct Blocklist: Sendable, Equatable {

    /// How much of the seeded name list to apply.
    ///
    /// The list is sorted longest-first and its short end is ordinary
    /// English (`"only"`, `"with"`, `"Very"`, `"Seal"`, `"test"`) plus
    /// four-character locator squares. Those are right for the room OZ2M
    /// tuned them against and wrong for a name like "Sealey" — so the
    /// default stops at six characters and the full list is opt-in.
    public enum Tier: String, Sendable, CaseIterable, Identifiable {
        /// Names are shown exactly as the server sends them.
        case off
        /// Fragments of six characters or more.
        case conservative
        /// Every fragment KST2Me ships.
        case full

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .off:          return "Off"
            case .conservative: return "Longer fragments only"
            case .full:         return "Everything KST2Me strips"
            }
        }

        /// Shortest fragment this tier will apply.
        var minimumLength: Int {
            switch self {
            case .off:          return .max
            case .conservative: return 6
            case .full:         return 1
            }
        }
    }

    /// KST2Me's storage width for a spotter callsign. Entries of exactly
    /// this length are truncations rather than whole callsigns.
    private static let spotterFieldWidth = 7

    /// Uppercased, whitespace-free.
    public let spotters: Set<String>
    /// Longest first — the order matters, a shorter fragment must not eat
    /// part of a longer one before the longer one has been tried.
    public let nameFragments: [String]

    public init(spotters: Set<String> = [], nameFragments: [String] = []) {
        self.spotters = spotters
        self.nameFragments = nameFragments.sorted { a, b in
            a.count == b.count ? a.lowercased() < b.lowercased() : a.count > b.count
        }
    }

    public static let empty = Blocklist()

    /// The shipped lists at the given tier, plus the operator's own
    /// additions. Additions are always applied in full — someone who
    /// types a two-letter fragment into the settings box meant it.
    public static func seeded(tier: Tier,
                              useSeedSpotters: Bool = true,
                              extraSpotters: [String] = [],
                              extraNameFragments: [String] = []) -> Blocklist {
        let calls = (useSeedSpotters ? seedSpotters : [])
            + extraSpotters.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        let fragments = seedNameFragments.filter { $0.count >= tier.minimumLength }
            + extraNameFragments
        return Blocklist(spotters: Set(calls.filter { !$0.isEmpty }),
                         nameFragments: fragments)
    }

    /// One entry per line; blank lines and `#` comments ignored.
    ///
    /// Leading and trailing spaces are **kept** — a name fragment like
    /// `"@ home"` or `"SM/ "` depends on them, and silently trimming would
    /// change what the operator typed into something that matches more.
    ///
    /// CRLF is normalised *before* splitting, not after: Swift treats
    /// "\r\n" as a single Character, so splitting on "\n" first finds no
    /// separator at all and returns the whole paste as one entry. The
    /// operator pasting from a Windows-shipped list is the expected case
    /// here, so this is the common path rather than an edge one.
    public static func entries(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    // MARK: - Spots

    /// Whether a spot from this callsign should be dropped.
    ///
    /// Exact match, or a prefix match against a seven-character entry.
    /// The prefix rule exists because most of KST2Me's list is truncated
    /// to seven characters: `EI/GI0U` has to catch `EI/GI0UHV` or three
    /// quarters of the list is inert. The risk it carries — a genuine
    /// callsign that merely starts with a blocked seven-character one —
    /// needs an eight-character call sharing seven characters with a
    /// busted one, which is not a case that occurs in the shipped data.
    public func blocks(spotter: String) -> Bool {
        let call = spotter.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return false }
        if spotters.contains(call) { return true }
        guard call.count > Self.spotterFieldWidth else { return false }
        let head = String(call.prefix(Self.spotterFieldWidth))
        return spotters.contains(head)
    }

    // MARK: - Names

    /// Strips every matching fragment out of a name and tidies what is
    /// left, or returns nil if nothing survives.
    ///
    /// Matching is case-insensitive; the fragments' own leading and
    /// trailing spaces are significant, which is why this is substring
    /// removal rather than tokenising. Runs of whitespace left behind by
    /// a removal are collapsed, so stripping `"CQ 144"` out of
    /// `"Manoj CQ 144 here"` gives `"Manoj here"` and not `"Manoj  here"`.
    public func scrub(name: String?) -> String? {
        guard let name, !nameFragments.isEmpty else { return name }
        var result = name
        for fragment in nameFragments {
            guard !result.isEmpty else { break }
            while let range = result.range(of: fragment, options: [.caseInsensitive]) {
                result.replaceSubrange(range, with: " ")
            }
        }
        let tidied = result
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return tidied.isEmpty ? nil : tidied
    }
}
