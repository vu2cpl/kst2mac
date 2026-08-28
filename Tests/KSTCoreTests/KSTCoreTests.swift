import XCTest
@testable import KSTCore

final class TelnetCodecTests: XCTestCase {

    func testPassesPlainDataThrough() {
        var codec = TelnetCodec()
        let (payload, reply) = codec.decode(Data("hello\r\n".utf8))
        XCTAssertEqual(String(data: payload, encoding: .utf8), "hello\r\n")
        XCTAssertTrue(reply.isEmpty)
    }

    func testRefusesOptionNegotiation() {
        var codec = TelnetCodec()
        // IAC WILL ECHO(1), then "hi"
        let (payload, reply) = codec.decode(Data([255, 251, 1] + Array("hi".utf8)))
        XCTAssertEqual(String(data: payload, encoding: .utf8), "hi")
        XCTAssertEqual(Array(reply), [255, 254, 1])   // IAC DONT ECHO
    }

    func testAnswersDoWithWont() {
        var codec = TelnetCodec()
        let (_, reply) = codec.decode(Data([255, 253, 24]))   // IAC DO TERMINAL-TYPE
        XCTAssertEqual(Array(reply), [255, 252, 24])          // IAC WONT TERMINAL-TYPE
    }

    func testEscapedIACIsLiteralData() {
        var codec = TelnetCodec()
        let (payload, _) = codec.decode(Data([65, 255, 255, 66]))
        XCTAssertEqual(Array(payload), [65, 255, 66])
    }

    func testSubnegotiationIsDiscarded() {
        var codec = TelnetCodec()
        // "a" IAC SB 24 1 IAC SE "b"
        let (payload, _) = codec.decode(Data([97, 255, 250, 24, 1, 255, 240, 98]))
        XCTAssertEqual(String(data: payload, encoding: .utf8), "ab")
    }

    func testSplitAcrossChunks() {
        var codec = TelnetCodec()
        var out = Data()
        out += codec.decode(Data([97, 255])).payload      // "a" then a dangling IAC
        let second = codec.decode(Data([251, 1, 98]))     // WILL ECHO, then "b"
        out += second.payload
        XCTAssertEqual(String(data: out, encoding: .utf8), "ab")
        XCTAssertEqual(Array(second.reply), [255, 254, 1])
    }
}

final class LineParserTests: XCTestCase {

    private let parser = LineParser()

    /// Tolerated variants, **not observed**. Live traffic always uses
    /// `HHMMZ` (see CapturedTrafficTests, which is the evidence). These
    /// two forms are accepted because doing so is free, not because the
    /// server has ever been seen to send them — don't cite them as
    /// protocol facts.
    func testParsesBareTimestamp() {
        let line = parser.parse("2134 ON4KST Rik > anyone on 3cm tonight?")
        guard case .message(let from, let name, let to, let text) = line.kind else {
            return XCTFail("expected a message, got \(line.kind)")
        }
        XCTAssertEqual(from, "ON4KST")
        XCTAssertEqual(name, "Rik")
        XCTAssertNil(to)
        XCTAssertEqual(text, "anyone on 3cm tonight?")
        XCTAssertEqual(line.stamp, "2134")
    }

    /// Also a tolerated variant, not observed. See above.
    func testParsesTimestampedMessage() {
        let line = parser.parse("21:15 G4XYZ Dave > cq cq on 144.300")
        guard case .message(let from, let name, let to, let text) = line.kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "G4XYZ")
        XCTAssertEqual(name, "Dave")
        XCTAssertNil(to)
        XCTAssertEqual(text, "cq cq on 144.300")
        XCTAssertEqual(line.stamp, "21:15")
    }

    func testParsesDirectedMessage() {
        let line = parser.parse("21:16 I4XCC Claudio > (VU2CPL) Hi Manoj try 3cm?")
        guard case .message(let from, _, let to, let text) = line.kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "I4XCC")
        XCTAssertEqual(to, "VU2CPL")
        XCTAssertEqual(text, "Hi Manoj try 3cm?")
    }

    func testUnknownLineSurvivesVerbatim() {
        let banner = "This telnet access is reserved to HAM only"
        let line = parser.parse(banner)
        guard case .other = line.kind else { return XCTFail("expected .other") }
        XCTAssertEqual(line.raw, banner)
    }

    func testFindsLocator() {
        XCTAssertEqual(parser.locator(in: "21:15 G4XYZ Dave > qrv in IO91wm now"), "IO91wm")
        XCTAssertEqual(parser.locator(in: "21:15 G4XYZ Dave > qrv JO20"), "JO20")
        XCTAssertNil(parser.locator(in: "nothing gridlike here"))
    }
}

final class MaidenheadTests: XCTestCase {

    func testKnownSquares() throws {
        // Centre of JO20 — the classic reference square (Brussels area).
        let jo20 = try XCTUnwrap(Maidenhead.coordinates("JO20"))
        XCTAssertEqual(jo20.latitude,  50.5, accuracy: 0.01)
        XCTAssertEqual(jo20.longitude,  5.0, accuracy: 0.01)   // centre, not SW corner

        // Six-character subsquare stays inside its parent square.
        let jo20dh = try XCTUnwrap(Maidenhead.coordinates("JO20dh"))
        XCTAssertTrue((50.0...51.0).contains(jo20dh.latitude))
        XCTAssertTrue((4.0...6.0).contains(jo20dh.longitude))
        XCTAssertNotEqual(jo20dh.longitude, jo20.longitude)
    }

    func testRejectsGarbage() {
        XCTAssertNil(Maidenhead.coordinates(""))
        XCTAssertNil(Maidenhead.coordinates("ZZ99"))
        XCTAssertNil(Maidenhead.coordinates("JO2"))
        XCTAssertNil(Maidenhead.coordinates("JO20dh12x"))
    }

    func testPathIsSymmetricInDistance() throws {
        let there = try XCTUnwrap(Maidenhead.path(from: "MK68", to: "JO20"))
        let back  = try XCTUnwrap(Maidenhead.path(from: "JO20", to: "MK68"))
        XCTAssertEqual(there.distanceKm, back.distanceKm, accuracy: 0.5)
        // MK68 (~18.5N 73E) → JO20 (~50.5N 5E) is a little under 6900 km.
        XCTAssertEqual(there.distanceKm, 6884, accuracy: 50)
    }

    func testBearingDirections() throws {
        // The digits are longitude-then-latitude, so JO20 → JO30 is a step
        // east at the same latitude: bearing ~90°.
        let east = try XCTUnwrap(Maidenhead.path(from: "JO20", to: "JO30"))
        XCTAssertEqual(east.bearing, 90, accuracy: 2)

        // JO20 → JO21 is a step north at the same longitude: bearing ~0°.
        let north = try XCTUnwrap(Maidenhead.path(from: "JO20", to: "JO21"))
        XCTAssertTrue(north.bearing < 1 || north.bearing > 359, "got \(north.bearing)")
    }
}

/// Regression tests for the stall that kept two capture runs pinned at
/// exactly 480 bytes: CRLF-terminated prompts were consumed by the line
/// splitter, so the prompt detector never saw them.
final class LineAccumulatorTests: XCTestCase {

    /// The real banner, byte-for-byte, ending in a CRLF-terminated prompt.
    private let banner =
        "This telnet access is reserved to HAM only\r\n"
        + "Your IP address is 10.0.0.1\r\n"
        + "Login:\r\n"

    func testCRLFTerminatedPromptIsStillFound() {
        var acc = LineAccumulator()
        let lines = acc.feed(banner)
        XCTAssertEqual(lines.count, 3)
        // The prompt was consumed as a complete line — the candidate must
        // fall back to it rather than to the empty remainder.
        XCTAssertEqual(acc.promptCandidate, "Login:")
        XCTAssertTrue(LoginPrompt.login.matches(acc.promptCandidate))
    }

    func testBarePromptIsStillFound() {
        var acc = LineAccumulator()
        _ = acc.feed("Welcome\r\nLogin:")      // no trailing newline
        XCTAssertEqual(acc.promptCandidate, "Login:")
        XCTAssertTrue(LoginPrompt.login.matches(acc.promptCandidate))
    }

    /// The original bug was a race on packet segmentation: whether the
    /// prompt was answered depended on where TCP split the stream. Every
    /// split of the same banner must now behave identically.
    func testEveryPacketSplitYieldsTheSamePrompt() {
        let chars = Array(banner)
        for cut in 1..<chars.count {
            var acc = LineAccumulator()
            _ = acc.feed(String(chars[0..<cut]))
            _ = acc.feed(String(chars[cut...]))
            XCTAssertTrue(LoginPrompt.login.matches(acc.promptCandidate),
                          "split at \(cut) gave candidate \(acc.promptCandidate.debugDescription)")
        }
    }

    func testChatMenuPromptIsRecognised() {
        var acc = LineAccumulator()
        _ = acc.feed("""
        Chat selection ?\r
        50/70 MHz..............1\r
        144/432 MHz IARU R 3...9\r
        Your choice           :\r

        """)
        XCTAssertTrue(LoginPrompt.room.matches(acc.promptCandidate))
        XCTAssertFalse(LoginPrompt.login.matches(acc.promptCandidate))
        XCTAssertFalse(LoginPrompt.password.matches(acc.promptCandidate))
    }

    func testClearForgetsTheAnsweredPrompt() {
        var acc = LineAccumulator()
        _ = acc.feed(banner)
        acc.clear()
        XCTAssertEqual(acc.promptCandidate, "")
        XCTAssertFalse(LoginPrompt.login.matches(acc.promptCandidate))
    }

    /// A banner line that merely mentions a word must not be mistaken for
    /// the prompt — the prompt shape (trailing colon) is required.
    func testNonPromptLineIsNotAPrompt() {
        XCTAssertFalse(LoginPrompt.login.matches("This telnet access is reserved to HAM only"))
        XCTAssertFalse(LoginPrompt.room.matches("144/432 MHz IARU R 3...9"))
        XCTAssertTrue(LoginPrompt.password.matches("Password:"))
    }
}

final class RosterParserTests: XCTestCase {

    /// The real `/SHow USer` row, byte-for-byte: callsign left-justified
    /// in 17 columns, then locator, then name.
    func testParsesCapturedRow() throws {
        let s = try XCTUnwrap(RosterParser.parse("VU2CPL           MK83TE Manoj"))
        XCTAssertEqual(s.callsign, "VU2CPL")
        XCTAssertEqual(s.locator, "MK83te")
        XCTAssertEqual(s.name, "Manoj")
    }

    /// A callsign long enough to overrun the 17-column field must still
    /// parse — which is why this splits on whitespace, not by offset.
    func testLongCallsignOverrunningTheColumn() throws {
        let s = try XCTUnwrap(RosterParser.parse("SV1DH/P   KM17uw Costas"))
        XCTAssertEqual(s.callsign, "SV1DH/P")
        XCTAssertEqual(s.locator, "KM17uw")
        XCTAssertEqual(s.name, "Costas")
    }

    func testMissingLocator() throws {
        let s = try XCTUnwrap(RosterParser.parse("G4XYZ            Dave"))
        XCTAssertEqual(s.callsign, "G4XYZ")
        XCTAssertNil(s.locator)
        XCTAssertEqual(s.name, "Dave")
    }

    func testMultiWordName() throws {
        let s = try XCTUnwrap(RosterParser.parse("F6ABC            JN18cx Jean Pierre"))
        XCTAssertEqual(s.locator, "JN18cx")
        XCTAssertEqual(s.name, "Jean Pierre")
    }

    func testRejectsNonRosterLines() {
        XCTAssertNil(RosterParser.parse("Inline commands available on this chat (by ON4KST):"))
        XCTAssertNil(RosterParser.parse("/Quit              Exit from the chat."))
        XCTAssertNil(RosterParser.parse("DX OFF, ANN OFF, WWC OFF"))
        XCTAssertNil(RosterParser.parse(""))
    }

    /// `/SHow CONFig` prints the same three fields in a *different* order
    /// (`CALL Name LOC`). Parsed blind it yields a wrong locator, which is
    /// exactly why the connection only parses roster rows while a
    /// `/SHow USer` is outstanding.
    func testConfigLineIsWhyContextMatters() throws {
        let s = try XCTUnwrap(RosterParser.parse("VU2CPL Manoj MK83TE"))
        XCTAssertEqual(s.callsign, "VU2CPL")
        XCTAssertNil(s.locator, "second field is the name here, not a locator")
        XCTAssertEqual(s.name, "Manoj MK83TE")
    }

    func testLocatorTokenMustBeWholeToken() {
        XCTAssertEqual(LineParser.normalisedLocator("MK83TE"), "MK83te")
        XCTAssertEqual(LineParser.normalisedLocator("JO20"), "JO20")
        XCTAssertNil(LineParser.normalisedLocator("MK83TExx"))
        XCTAssertNil(LineParser.normalisedLocator("Manoj"))
    }
}

/// Every line below is copied verbatim from a 144/432 EU capture on
/// 2026-08-28. Before that capture the parser had never seen a real
/// message and got the timestamp wrong, so it classified all of them as
/// unrecognised text.
final class CapturedTrafficTests: XCTestCase {

    private let parser = LineParser()

    func testDirectedMessage() throws {
        let line = parser.parse("0846Z OZ5QF Jens 2m> (F6IFX/P)  Tnx qso Bert. Best 340/5 73")
        guard case .message(let from, let name, let to, let text) = line.kind else {
            return XCTFail("expected a message, got \(line.kind)")
        }
        XCTAssertEqual(line.stamp, "0846Z")
        XCTAssertEqual(from, "OZ5QF")
        XCTAssertEqual(name, "Jens 2m")        // the name carries station notes
        XCTAssertEqual(to, "F6IFX/P")
        XCTAssertEqual(text, "Tnx qso Bert. Best 340/5 73")
    }

    func testUndirectedMessage() throws {
        let line = parser.parse("0844Z SM5DWF Peder 2m> 160/1")
        guard case .message(let from, _, let to, let text) = line.kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "SM5DWF")
        XCTAssertNil(to)
        XCTAssertEqual(text, "160/1")
    }

    /// A portable callsign, and a name with a double space inside it.
    func testPortableCallsignSender() throws {
        let line = parser.parse("0845Z F6IFX/P Bert  2/70>  tnx fast qso 73 Jens")
        guard case .message(let from, let name, _, let text) = line.kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "F6IFX/P")
        XCTAssertEqual(name, "Bert  2/70")
        XCTAssertEqual(text, "tnx fast qso 73 Jens")
    }

    /// Message text starting with a hyphen must not be eaten as a flag.
    func testTextBeginningWithHyphen() throws {
        let line = parser.parse("0836Z YO7CGS Dumitru> - 083430, copy rrrr 420/5db. Tnx, Luigi! 73!")
        guard case .message(let from, let name, _, let text) = line.kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "YO7CGS")
        XCTAssertEqual(name, "Dumitru")
        XCTAssertTrue(text.hasPrefix("- 083430"), "got \(text)")
    }

    /// A name full of digits and hyphens must not be mistaken for anything.
    func testNameWithDigitsAndHyphens() throws {
        let line = parser.parse("0831Z IK7UXW Paolo 2-70-23-13> stop cq cul tnx")
        guard case .message(_, let name, _, let text) = line.kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(name, "Paolo 2-70-23-13")
        XCTAssertEqual(text, "stop cq cul tnx")
    }

    /// The command prompt is the same shape as a message and must win.
    func testPromptIsNotAMessage() throws {
        let line = parser.parse("0846Z VU2CPL 144/432 MHz chat>")
        guard case .prompt(let call, let chat) = line.kind else {
            return XCTFail("expected a prompt, got \(line.kind)")
        }
        XCTAssertEqual(call, "VU2CPL")
        XCTAssertEqual(chat, "144/432 MHz")
        XCTAssertEqual(line.stamp, "0846")
    }

    // MARK: Roster rows from the same capture

    func testAwayStationIsBracketed() throws {
        let s = try XCTUnwrap(RosterParser.parse("(DF7KF)          JO30FK Dithmar"))
        XCTAssertEqual(s.callsign, "DF7KF")
        XCTAssertTrue(s.isAway)
        XCTAssertEqual(s.locator, "JO30fk")
        XCTAssertEqual(s.name, "Dithmar")
    }

    func testPresentStationIsNotAway() throws {
        let s = try XCTUnwrap(RosterParser.parse("DL1BEC           JO33SC Achim"))
        XCTAssertFalse(s.isAway)
    }

    func testSSIDSuffixCallsign() throws {
        let s = try XCTUnwrap(RosterParser.parse("DN9APW-2         JO50LQ TESTING"))
        XCTAssertEqual(s.callsign, "DN9APW-2")
        XCTAssertEqual(s.name, "TESTING")
    }

    func testPortableSuffixCallsign() throws {
        let s = try XCTUnwrap(RosterParser.parse("F6IFX/P          IN87XC Bert  2/70"))
        XCTAssertEqual(s.callsign, "F6IFX/P")
        XCTAssertEqual(s.name, "Bert 2/70")
    }

    func testNamesAreHTMLUnescaped() throws {
        let amp = try XCTUnwrap(RosterParser.parse("DL6BF            JO32QI Heinz 2 &amp; 4m"))
        XCTAssertEqual(amp.name, "Heinz 2 & 4m")
        let tm = try XCTUnwrap(RosterParser.parse("GD0TEP           IO74SD Andy &#8482;"))
        XCTAssertEqual(tm.name, "Andy ™")
    }

    /// A name whose trailing token looks like a locator must not have it
    /// stolen — only the field immediately after the callsign is one.
    func testTrailingGridInNameIsLeftAlone() throws {
        let s = try XCTUnwrap(RosterParser.parse("(F1NZC)          JN15MR Jean-Louis JN15"))
        XCTAssertEqual(s.locator, "JN15mr")
        XCTAssertEqual(s.name, "Jean-Louis JN15")
    }
}

final class HTMLTextTests: XCTestCase {
    func testNamedEntities() {
        XCTAssertEqual(HTMLText.decode("Heinz 2 &amp; 4m"), "Heinz 2 & 4m")
        XCTAssertEqual(HTMLText.decode("a &lt;b&gt; c"), "a <b> c")
    }
    func testNumericEntities() {
        XCTAssertEqual(HTMLText.decode("Andy &#8482;"), "Andy ™")
        XCTAssertEqual(HTMLText.decode("&#x2122;"), "™")
    }
    func testBareAmpersandSurvives() {
        XCTAssertEqual(HTMLText.decode("Jack & Jill"), "Jack & Jill")
        XCTAssertEqual(HTMLText.decode("R&D"), "R&D")
    }
    func testUnknownEntityIsLeftIntact() {
        XCTAssertEqual(HTMLText.decode("&zzz; x"), "&zzz; x")
    }
    func testPlainStringIsUntouched() {
        XCTAssertEqual(HTMLText.decode("Manoj"), "Manoj")
    }
}

final class ChatRoomTests: XCTestCase {

    /// `/HELP` lists exactly these thirteen values for /CHAT. Every room
    /// must map to one of them, and no two rooms may share one.
    func testChatTokensMatchTheCapturedHelpText() {
        let documented = Set("28 40 50 50R2 50R3 144 144R2 144R3 GHZ EME HF KHZ WARC"
            .split(separator: " ").map(String.init))
        let tokens = ChatRoom.allCases.map(\.chatToken)

        XCTAssertEqual(Set(tokens), documented)
        XCTAssertEqual(tokens.count, Set(tokens).count, "two rooms share a /CHAT token")
        XCTAssertEqual(ChatRoom.allCases.count, 13)
    }

    /// The menu digits are the ones transcribed from the live server —
    /// note 6 exists, and the list runs to 13.
    func testMenuDigits() {
        XCTAssertEqual(ChatRoom.allCases.map(\.rawValue), Array(1...13))
        XCTAssertEqual(ChatRoom.vhfUhf.rawValue, 2)
        XCTAssertEqual(ChatRoom.vhfUhfRegion3.rawValue, 9)
        XCTAssertEqual(ChatRoom.vhfUhfRegion3.chatToken, "144R3")
    }
}

/// The server answers a too-soon command with a wait notice. It is the
/// authority on when the next one may go out, so the client parses it
/// rather than relying on its own estimate.
final class RateLimitNoticeTests: XCTestCase {

    private let parser = LineParser()

    /// Captured verbatim.
    func testCapturedNotice() {
        XCTAssertEqual(ServerNotice.waitSeconds(in: "Please wait 55 second(s) between two commands."), 55)
    }

    func testSingularAndOtherDelays() {
        XCTAssertEqual(ServerNotice.waitSeconds(in: "Please wait 1 second between two commands."), 1)
        XCTAssertEqual(ServerNotice.waitSeconds(in: "please wait 12 seconds"), 12)
    }

    /// The notice must be anchored: an operator saying this in the chat is
    /// a message, and the connection only tests non-message lines anyway.
    func testMessageTextIsNotANotice() {
        let line = "0846Z OZ5QF Jens 2m> please wait 30 seconds, turning the beam"
        guard case .message = parser.parse(line).kind else {
            return XCTFail("expected a message — the throttle would eat it")
        }
        XCTAssertNil(ServerNotice.waitSeconds(in: line),
                     "unanchored match would let chat text reconfigure the throttle")
    }

    func testOrdinaryLinesAreNotNotices() {
        XCTAssertNil(ServerNotice.waitSeconds(in: "Welcome Manoj VU2CPL on this 144/432 MHz amateur chat"))
        XCTAssertNil(ServerNotice.waitSeconds(in: "Please wait for the sked"))
    }
}

/// The welcome banner repeats verbatim on every join *and* every `/CHAT`
/// switch, so a session that hops rooms accumulates it. These lines are
/// all captured verbatim.
final class BannerTests: XCTestCase {

    private let parser = LineParser()

    func testWelcomeBecomesARoomDivider() {
        for (line, expected) in [
            ("Welcome Manoj VU2CPL on this 144/432 MHz amateur chat (by ON4KST)", "144/432 MHz"),
            ("Welcome Manoj VU2CPL on this 144/432 MHz IARU R 3 amateur chat (by ON4KST)", "144/432 MHz IARU R 3"),
            ("Welcome Manoj VU2CPL on this 50 MHz IARU Region 2 amateur chat (by ON4KST)", "50 MHz IARU Region 2"),
        ] {
            guard case .joined(let chat) = parser.parse(line).kind else {
                return XCTFail("expected .joined for \(line)")
            }
            XCTAssertEqual(chat, expected)
        }
    }

    func testFixedBannerTextIsSuppressed() {
        for line in [
            "Use the inline ON4KST-2 CLX DX cluster for your spot.",
            "More info type \"/HELP\"",
            "Web http://www.on4kst.com",
        ] {
            guard case .boilerplate = parser.parse(line).kind else {
                return XCTFail("expected .boilerplate for \(line)")
            }
        }
    }

    /// Suppression must be narrow: a message that merely mentions the
    /// cluster is traffic, and the /HELP listing is still shown.
    func testRealTrafficIsNotSuppressed() {
        guard case .message = parser.parse("0846Z OZ5QF Jens 2m> use the inline cluster then").kind else {
            return XCTFail("a message mentioning the banner text must stay a message")
        }
        guard case .other = parser.parse("Inline commands available on this chat (by ON4KST):").kind else {
            return XCTFail("the /HELP header should still be shown")
        }
    }
}

/// Emphasis precedence is modelled on KST2Me, which colours to-me,
/// from-me and watched traffic differently. The rules live in the app
/// target, but the parse they depend on is here — these guard the inputs.
final class EmphasisInputTests: XCTestCase {

    private let parser = LineParser()

    /// A line we sent has us as the *sender*, never as `to`.
    func testOwnMessageHasUsAsSender() {
        guard case .message(let from, _, let to, _) =
                parser.parse("0850Z VU2CPL Manoj MK83> anyone on 6m?").kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "VU2CPL")
        XCTAssertNil(to)
    }

    /// A directed reply to us has us as `to` and someone else as sender —
    /// the distinction the mention rule turns on.
    func testDirectedReplyHasUsAsRecipient() {
        guard case .message(let from, _, let to, _) =
                parser.parse("0851Z SM5DWF Peder 2m> (VU2CPL) GM Manoj").kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "SM5DWF")
        XCTAssertEqual(to, "VU2CPL")
    }

    /// Our own message quoting our callsign must not read as a mention of
    /// us — the sender check has to come first.
    func testOwnMessageQuotingOwnCallsign() {
        guard case .message(let from, _, _, let text) =
                parser.parse("0852Z VU2CPL Manoj MK83> this is VU2CPL calling cq").kind else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(from, "VU2CPL")
        XCTAssertTrue(text.uppercased().contains("VU2CPL"),
                      "text does contain our call — only the sender check saves us")
    }
}

/// The preamble convention, per the KST2Me manual §3.2.9 / §4.6: a
/// station addresses you by putting your callsign at the very start of an
/// ordinary message, with no `/CQ` involved.
final class PreambleTests: XCTestCase {

    func testCallsignAsFirstWordAddressesUs() {
        XCTAssertTrue(Preamble.addresses("VU2CPL", in: "VU2CPL tnx qso 73"))
        XCTAssertTrue(Preamble.addresses("vu2cpl", in: "VU2CPL GM Manoj"))
    }

    /// Trailing punctuation is common; a callsign's own slash and hyphen
    /// are not punctuation and must survive.
    func testTrailingPunctuationIsIgnored() {
        XCTAssertTrue(Preamble.addresses("VU2CPL", in: "VU2CPL: are you there"))
        XCTAssertTrue(Preamble.addresses("VU2CPL", in: "VU2CPL, 73"))
        XCTAssertTrue(Preamble.addresses("F6IFX/P", in: "F6IFX/P running now"))
        XCTAssertTrue(Preamble.addresses("DN9APW-2", in: "DN9APW-2 hello"))
    }

    /// Our callsign later in the sentence is someone talking *about* us,
    /// which the manual handles as a watch, not as a message to us.
    func testCallsignElsewhereIsNotAPreamble() {
        XCTAssertFalse(Preamble.addresses("VU2CPL", in: "anyone heard VU2CPL today?"))
        XCTAssertFalse(Preamble.addresses("VU2CPL", in: "tnx VU2CPL"))
    }

    func testOtherStationsPreambleIsNotOurs() {
        XCTAssertFalse(Preamble.addresses("VU2CPL", in: "SM5DWF tnx qso"))
    }

    func testEmptyInputs() {
        XCTAssertFalse(Preamble.addresses("", in: "VU2CPL hello"))
        XCTAssertFalse(Preamble.addresses("VU2CPL", in: ""))
    }

    /// A prefix match must not count — VU2CPLX is a different station.
    func testLongerCallsignIsNotAMatch() {
        XCTAssertFalse(Preamble.addresses("VU2CPL", in: "VU2CPLX hello"))
    }
}
