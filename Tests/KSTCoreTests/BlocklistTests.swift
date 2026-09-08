import XCTest
@testable import KSTCore

final class BlocklistTests: XCTestCase {

    // MARK: - Spotters

    func testExactSpotterMatch() {
        let list = Blocklist(spotters: ["AA1AR"])
        XCTAssertTrue(list.blocks(spotter: "AA1AR"))
        XCTAssertFalse(list.blocks(spotter: "AA1ARX"))
    }

    func testSpotterMatchIgnoresCaseAndPadding() {
        let list = Blocklist(spotters: ["AA1AR"])
        XCTAssertTrue(list.blocks(spotter: "  aa1ar "))
    }

    /// The shipped list is truncated to KST2Me's seven-character storage
    /// width — `EI/GI0U` has to catch `EI/GI0UHV` or most of it is inert.
    func testSevenCharacterEntryMatchesAsPrefix() {
        let list = Blocklist(spotters: ["EI/GI0U"])
        XCTAssertTrue(list.blocks(spotter: "EI/GI0UHV"))
    }

    /// Only at exactly seven. A shorter entry is a whole callsign and
    /// prefix-matching it would take out unrelated stations.
    func testShorterEntryDoesNotMatchAsPrefix() {
        let list = Blocklist(spotters: ["CE/K7C"])
        XCTAssertFalse(list.blocks(spotter: "CE/K7CXY"))
        XCTAssertTrue(list.blocks(spotter: "CE/K7C"))
    }

    func testEmptySpotterIsNeverBlocked() {
        XCTAssertFalse(Blocklist(spotters: ["AA1AR"]).blocks(spotter: ""))
        XCTAssertFalse(Blocklist.empty.blocks(spotter: "AA1AR"))
    }

    // MARK: - Names

    func testScrubStripsFragmentAndKeepsTheName() {
        let list = Blocklist(nameFragments: ["CQ 144"])
        XCTAssertEqual(list.scrub(name: "Manoj CQ 144 here"), "Manoj here")
    }

    func testScrubIsCaseInsensitive() {
        let list = Blocklist(nameFragments: ["WSJT"])
        XCTAssertEqual(list.scrub(name: "Heinz wsjt"), "Heinz")
    }

    /// Leading and trailing spaces are part of the pattern — `"@ home"`
    /// and `"SM/ "` are meaningless without them.
    func testScrubHonoursSignificantWhitespaceInFragments() {
        let list = Blocklist(nameFragments: ["@ home"])
        XCTAssertEqual(list.scrub(name: "Dithmar@ home"), "Dithmar")
        XCTAssertEqual(list.scrub(name: "Dithmar@home"), "Dithmar@home")
    }

    func testScrubReturnsNilWhenNothingSurvives() {
        let list = Blocklist(nameFragments: ["InnovAntennas"])
        XCTAssertNil(list.scrub(name: "InnovAntennas"))
    }

    func testScrubPassesCleanNamesThrough() {
        let list = Blocklist.seeded(tier: .conservative)
        XCTAssertEqual(list.scrub(name: "Manoj"), "Manoj")
        XCTAssertEqual(list.scrub(name: "Bo"), "Bo")
    }

    func testScrubCollapsesWhitespaceItCreates() {
        let list = Blocklist(nameFragments: ["QRV"])
        XCTAssertEqual(list.scrub(name: "Jan QRV now"), "Jan now")
    }

    func testLongestFragmentIsAppliedFirst() {
        // "no cw" must win over "no", or the longer pattern never fires.
        let list = Blocklist(nameFragments: ["no", "no cw"])
        XCTAssertEqual(list.nameFragments.first, "no cw")
    }

    func testNilNameStaysNil() {
        XCTAssertNil(Blocklist.seeded(tier: .full).scrub(name: nil))
    }

    func testEmptyListLeavesNameUntouched() {
        XCTAssertEqual(Blocklist.empty.scrub(name: "  Manoj  "), "  Manoj  ")
    }

    // MARK: - Tiers

    func testConservativeTierExcludesShortEnglishWords() {
        let list = Blocklist.seeded(tier: .conservative)
        XCTAssertFalse(list.nameFragments.contains { $0.lowercased() == "only" })
        XCTAssertFalse(list.nameFragments.contains { $0.lowercased() == "test" })
        XCTAssertTrue(list.nameFragments.allSatisfy { $0.count >= 6 })
    }

    func testFullTierIsTheWholeShippedList() {
        XCTAssertEqual(Blocklist.seeded(tier: .full).nameFragments.count,
                       Blocklist.seedNameFragments.count)
    }

    func testOffTierUsesNoSeededFragments() {
        let list = Blocklist.seeded(tier: .off)
        XCTAssertTrue(list.nameFragments.isEmpty)
        XCTAssertEqual(list.scrub(name: "InnovAntennas"), "InnovAntennas")
    }

    /// Turning the seeded name list off must not silently disarm the
    /// operator's own patterns — they were typed on purpose.
    func testOperatorAdditionsApplyAtEveryTier() {
        let list = Blocklist.seeded(tier: .off, extraNameFragments: [" mobile"])
        XCTAssertEqual(list.scrub(name: "Ana mobile"), "Ana")
    }

    func testOperatorSpotterAdditionsApplyWithSeedOff() {
        let list = Blocklist.seeded(tier: .off,
                                    useSeedSpotters: false,
                                    extraSpotters: ["vu2xyz"])
        XCTAssertTrue(list.blocks(spotter: "VU2XYZ"))
        XCTAssertFalse(list.blocks(spotter: "AA1AR"))   // seed is off
    }

    // MARK: - Settings text

    func testEntriesSplitsLinesAndDropsBlanksAndComments() {
        let text = "AA1AR\n\n# a comment\n  \nEI/GI0U\n"
        XCTAssertEqual(Blocklist.entries(text), ["AA1AR", "EI/GI0U"])
    }

    /// The settings box must not tidy what the operator typed: a name
    /// pattern's outer spaces are load-bearing.
    func testEntriesKeepsLeadingAndTrailingSpaces() {
        XCTAssertEqual(Blocklist.entries("@ home \n SM/ "), ["@ home ", " SM/ "])
    }

    func testEntriesToleratesCRLF() {
        XCTAssertEqual(Blocklist.entries("AA1AR\r\nEI/GI0U\r\n"), ["AA1AR", "EI/GI0U"])
    }

    // MARK: - The shipped data

    func testSeedListsAreNonEmptyAndWellFormed() {
        XCTAssertGreaterThan(Blocklist.seedSpotters.count, 50)
        XCTAssertGreaterThan(Blocklist.seedNameFragments.count, 700)
        XCTAssertTrue(Blocklist.seedSpotters.allSatisfy { $0 == $0.uppercased() })
        XCTAssertTrue(Blocklist.seedSpotters.allSatisfy { !$0.isEmpty })
        // Under three characters a fragment matches inside almost any
        // name; the importer drops them and must keep doing so.
        XCTAssertTrue(Blocklist.seedNameFragments.allSatisfy { $0.count >= 3 })
    }

    func testSeededSpottersBlockAKnownBustedCall() {
        // EA117UR is in the shipped list; a valid Spanish call is not.
        let list = Blocklist.seeded(tier: .conservative)
        XCTAssertTrue(list.blocks(spotter: "EA117UR"))
        XCTAssertFalse(list.blocks(spotter: "EA5DIT"))
    }

    /// Guards the case that makes this feature worth having: a real name
    /// with an announcement stapled to it comes back as just the name.
    func testSeededScrubOnARealisticNameField() {
        let list = Blocklist.seeded(tier: .conservative)
        XCTAssertEqual(list.scrub(name: "Heinz InnovAntennas"), "Heinz")
    }
}

/// The check that decides whether this feature is safe to leave on.
///
/// Names lifted from a real `/SHow USer` capture of room 2. The transcript
/// itself is git-ignored (it contains whatever the room said that day), so
/// the names are inlined — a callsign and an operator's first name are
/// public either way, and without a fixture there is nothing stopping a
/// future tier change from quietly eating them.
final class BlocklistRealNamesTests: XCTestCase {

    /// Every one of these came off the wire and every one is somebody's
    /// actual name field. The default tier must not touch any of them.
    private static let captured = [
        "josé", "Pedro", "Dithmar", "Jochen", "Achim", "Peter", "Wilhelm",
        "Fabio", "Maurice", "John", "Tim", "Steve", "Jeff", "Keith", "Viv",
        "Robert", "Nick", "Franco", "Nicolantonio", "Petri", "Milos",
        "Alain", "Thomas", "Trygvi", "Jan", "Rick", "René", "Sjoerd",
        "Richard", "Janez", "Mauritz", "Mats", "Roger", "PeO", "Alex",
        "Manoj", "Dumitru", "Zoran", "ILCHO", "alessio", "Andy ™",
        "Heinz 2 & 4m", "Andy 4Ele/75W", "Ray 4x8el 200w", "Jamie 144/432",
        "Emil 8/6/4/2/.70", "Paolo 2-70-23-13", "Markus2m11el150W",
        "Laci 2/70 horiz", "Dare/11el./500w", "Constantin 23", "Jens 2m",
    ]

    func testDefaultTierLeavesRealNamesAlone() {
        let list = Blocklist.seeded(tier: .conservative)
        for name in Self.captured {
            XCTAssertEqual(list.scrub(name: name), name,
                           "the default tier damaged a real captured name")
        }
    }

    func testDefaultTierStillStripsRealJunk() {
        let list = Blocklist.seeded(tier: .conservative)
        // The one row in that capture the default tier does change.
        XCTAssertEqual(list.scrub(name: "KST4Contest1263"), "KST4 1263")
    }

    /// Documents *why* the full list is not the default: run over the same
    /// capture it takes "TEST" out of "TESTING" and "SM5" out of a
    /// callsign. Recorded as a test so the trade-off stays visible rather
    /// than living only in a comment.
    func testFullTierIsKnownToOverreach() {
        let list = Blocklist.seeded(tier: .full)
        XCTAssertEqual(list.scrub(name: "TESTING"), "ING")
        XCTAssertEqual(list.scrub(name: "SM5DWF"), "DWF")
    }
}
