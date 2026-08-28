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

    /// The stamp may arrive bare rather than colon-separated; both forms
    /// must parse to the same message.
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
