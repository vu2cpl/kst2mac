import SwiftUI
import KSTCore

/// Owns the live `Blocklist` and the settings behind it.
///
/// Shared rather than per-window, for the same reason watches are: a
/// busted spotter is busted in every room. Rebuilding the list is cheap
/// (a set union and a filter over ~750 strings) and only happens when a
/// setting changes, so every edit publishes a whole new `Blocklist`
/// rather than mutating one in place.
@MainActor
final class BlocklistStore: ObservableObject {

    static let shared = BlocklistStore()

    private enum Key {
        static let tier          = "blocklist.nameTier"
        static let useSeedCalls  = "blocklist.useSeedSpotters"
        static let extraCalls    = "blocklist.extraSpotters"
        static let extraNames    = "blocklist.extraNameFragments"
    }

    /// What the rest of the app reads. Never optional — filtering off is
    /// an empty list, not a missing one, so no call site needs a branch.
    @Published private(set) var current: Blocklist = .empty

    @Published var nameTier: Blocklist.Tier {
        didSet { defaults.set(nameTier.rawValue, forKey: Key.tier); rebuild() }
    }

    @Published var useSeedSpotters: Bool {
        didSet { defaults.set(useSeedSpotters, forKey: Key.useSeedCalls); rebuild() }
    }

    /// Free text, one entry per line, exactly as typed in Settings. Kept
    /// as text rather than a parsed array so a half-finished line does not
    /// vanish under the operator mid-edit.
    @Published var extraSpottersText: String {
        didSet { defaults.set(extraSpottersText, forKey: Key.extraCalls); rebuild() }
    }

    @Published var extraNamesText: String {
        didSet { defaults.set(extraNamesText, forKey: Key.extraNames); rebuild() }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let stored = defaults.string(forKey: Key.tier)
        nameTier = stored.flatMap(Blocklist.Tier.init(rawValue:)) ?? .conservative
        // A missing Bool reads as false, which would silently ship the
        // spot filtering turned off on first run.
        useSeedSpotters = defaults.object(forKey: Key.useSeedCalls) as? Bool ?? true
        extraSpottersText = defaults.string(forKey: Key.extraCalls) ?? ""
        extraNamesText = defaults.string(forKey: Key.extraNames) ?? ""
        rebuild()
    }

    /// How many spots this list has dropped since launch — shown in
    /// Settings so a filter that is quietly eating everything is visible
    /// rather than mysterious.
    @Published private(set) var droppedSpots = 0

    func countDroppedSpot() { droppedSpots += 1 }

    var seedSpotterCount: Int { Blocklist.seedSpotters.count }
    var seedFragmentCount: Int { Blocklist.seedNameFragments.count }
    var activeFragmentCount: Int { current.nameFragments.count }
    var activeSpotterCount: Int { current.spotters.count }

    private func rebuild() {
        current = .seeded(tier: nameTier,
                          useSeedSpotters: useSeedSpotters,
                          extraSpotters: Blocklist.entries(extraSpottersText),
                          extraNameFragments: Blocklist.entries(extraNamesText))
    }
}
