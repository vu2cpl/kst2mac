import Foundation

/// Decodes the HTML entities the chat puts in operator names.
///
/// The roster carries names exactly as typed into the web form, still
/// escaped: `Heinz 2 &amp; 4m`, `Andy &#8482;`. Doing this with
/// `NSAttributedString(html:)` would work but drags in WebKit and must run
/// on the main thread — far too much for unescaping a name field on a
/// background socket queue.
public enum HTMLText {

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "deg": "°",
    ]

    public static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }

        var out = ""
        out.reserveCapacity(input.count)
        var rest = Substring(input)

        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let after = rest.index(after: amp)
            // An entity is short; a bare "&" in a name is common, so only
            // scan a little way for the terminating semicolon.
            guard let semi = rest[after...].prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = rest[after...]
                continue
            }

            let body = rest[after..<semi]
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let scalar: Unicode.Scalar? = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
                    : UInt32(digits).flatMap(Unicode.Scalar.init)
                if let scalar {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += rest[amp...semi]
                }
            } else if let character = named[body.lowercased()] {
                out.append(character)
            } else {
                out += rest[amp...semi]     // unknown entity: leave it alone
            }
            rest = rest[rest.index(after: semi)...]
        }

        return out + rest
    }
}
