import SwiftUI

/// Colour, used to carry information rather than to decorate.
///
/// The one colour that earns its place in a chat window is **identity**: a
/// callsign keeps the same colour everywhere it appears, so a conversation
/// can be followed down the log and tied back to its row in the station
/// table without reading every callsign character by character.
enum Palette {

    /// Hues chosen to stay legible on both the dark and the light system
    /// background — nothing so pale it washes out on white, nothing so
    /// dark it disappears on black. Deliberately not a rainbow: adjacent
    /// entries differ enough to be told apart at a glance in 11pt mono.
    private static let callsignHues: [Color] = [
        Color(red: 0.40, green: 0.72, blue: 1.00),   // sky
        Color(red: 0.98, green: 0.60, blue: 0.35),   // amber
        Color(red: 0.45, green: 0.82, blue: 0.60),   // green
        Color(red: 0.85, green: 0.55, blue: 0.95),   // orchid
        Color(red: 0.95, green: 0.50, blue: 0.55),   // rose
        Color(red: 0.40, green: 0.80, blue: 0.82),   // teal
        Color(red: 0.80, green: 0.75, blue: 0.40),   // brass
        Color(red: 0.62, green: 0.66, blue: 0.98),   // periwinkle
        Color(red: 0.95, green: 0.68, blue: 0.75),   // blush
        Color(red: 0.55, green: 0.85, blue: 0.45),   // lime
        Color(red: 0.90, green: 0.62, blue: 0.45),   // clay
        Color(red: 0.55, green: 0.75, blue: 0.92),   // steel
    ]

    /// Stable colour for a callsign. FNV-1a over the bytes — any stable
    /// hash would do; the requirement is only that it never changes
    /// between sessions, or the colours stop meaning anything.
    static func color(for callsign: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in callsign.uppercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return callsignHues[Int(hash % UInt64(callsignHues.count))]
    }

    /// Distance shading, warm (near) through cool (far).
    ///
    /// Intentionally a plain perceptual ramp and not a claim about what is
    /// workable — that depends entirely on the band, and this same table
    /// serves 160 m and 10 GHz.
    static func distance(_ km: Double) -> Color {
        switch km {
        case ..<500:   return Color(red: 0.95, green: 0.65, blue: 0.35)
        case ..<1500:  return Color(red: 0.85, green: 0.75, blue: 0.40)
        case ..<3000:  return Color(red: 0.55, green: 0.82, blue: 0.55)
        case ..<6000:  return Color(red: 0.45, green: 0.78, blue: 0.80)
        case ..<9000:  return Color(red: 0.50, green: 0.70, blue: 0.95)
        default:       return Color(red: 0.70, green: 0.62, blue: 0.95)
        }
    }

    /// Row emphasis. KST2Me uses saturated fills for these; on a modern
    /// display a quiet wash plus a solid edge bar reads as clearly and
    /// keeps the text legible, which saturated backgrounds do not.
    static let mentionFill = Color.accentColor.opacity(0.16)
    static let mentionBar  = Color.accentColor

    static let watchedFill = Color(red: 0.35, green: 0.75, blue: 0.45).opacity(0.13)
    static let watchedBar  = Color(red: 0.35, green: 0.78, blue: 0.48)

    static let ownFill     = Color(red: 0.55, green: 0.60, blue: 0.75).opacity(0.11)
    static let ownBar      = Color(red: 0.58, green: 0.64, blue: 0.80)
}
