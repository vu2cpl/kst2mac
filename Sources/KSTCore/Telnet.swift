import Foundation

/// Strips RFC 854 telnet in-band signalling out of a byte stream and answers
/// option negotiation.
///
/// ON4KST's chat is "telnet" only in the sense that it listens on a raw TCP
/// socket and a telnet client can reach it — it is really a line-oriented
/// text protocol. But real telnet clients *do* negotiate on connect, so the
/// server may send IAC DO/WILL sequences, and those bytes must never reach
/// the chat log. Our policy is maximally boring: refuse everything (DONT to
/// every WILL, WONT to every DO). We want a plain 8-bit character stream and
/// nothing else.
public struct TelnetCodec {

    private enum State {
        case data
        case iac            // saw 0xFF
        case command(UInt8) // saw IAC <DO|DONT|WILL|WONT>, awaiting option
        case subneg         // inside IAC SB ... IAC SE
        case subnegIAC      // saw IAC while inside subnegotiation
    }

    private static let IAC: UInt8  = 255
    private static let SE: UInt8   = 240
    private static let SB: UInt8   = 250
    private static let WILL: UInt8 = 251
    private static let WONT: UInt8 = 252
    private static let DO: UInt8   = 253
    private static let DONT: UInt8 = 254

    private var state: State = .data

    public init() {}

    /// Feed raw socket bytes. Returns the payload bytes with all telnet
    /// signalling removed, plus any negotiation reply that must be written
    /// back to the socket.
    public mutating func decode(_ input: Data) -> (payload: Data, reply: Data) {
        var payload = Data()
        var reply = Data()
        payload.reserveCapacity(input.count)

        for byte in input {
            switch state {
            case .data:
                if byte == Self.IAC {
                    state = .iac
                } else {
                    payload.append(byte)
                }

            case .iac:
                switch byte {
                case Self.IAC:
                    // Escaped 0xFF — a literal data byte.
                    payload.append(Self.IAC)
                    state = .data
                case Self.DO, Self.DONT, Self.WILL, Self.WONT:
                    state = .command(byte)
                case Self.SB:
                    state = .subneg
                default:
                    // Two-byte command (NOP, AYT, GA, …) — nothing to do.
                    state = .data
                }

            case .command(let verb):
                // Refuse every option, whatever it is.
                switch verb {
                case Self.WILL, Self.WONT:
                    reply.append(contentsOf: [Self.IAC, Self.DONT, byte])
                case Self.DO, Self.DONT:
                    reply.append(contentsOf: [Self.IAC, Self.WONT, byte])
                default:
                    break
                }
                state = .data

            case .subneg:
                if byte == Self.IAC { state = .subnegIAC }

            case .subnegIAC:
                // IAC SE ends the subnegotiation; IAC IAC is escaped data
                // we discard along with the rest of the subnegotiation.
                state = (byte == Self.SE) ? .data : .subneg
            }
        }

        return (payload, reply)
    }
}
