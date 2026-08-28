import SwiftUI

/// Text sizing, adjustable by the operator.
///
/// Sizes were being picked by guesswork and kept landing too small. This
/// is a shack app read at arm's length from a radio, sometimes on a big
/// monitor across the room — the right size is not something to guess, so
/// it is a setting with View ▸ Bigger / Smaller text behind ⌘+ and ⌘-.
enum Typography {

    static let key = "fontScale"
    static let range = 0.85...2.0
    /// Bigger than macOS default out of the box, deliberately.
    static let defaultScale = 1.15

    static func mono(_ size: CGFloat, _ scale: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: size * clamped(scale), weight: weight, design: .monospaced)
    }

    static func text(_ size: CGFloat, _ scale: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: size * clamped(scale), weight: weight)
    }

    static func clamped(_ scale: Double) -> Double {
        min(max(scale <= 0 ? defaultScale : scale, range.lowerBound), range.upperBound)
    }
}

/// View ▸ Bigger / Smaller text.
struct TextSizeCommands: View {
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale

    var body: some View {
        Button("Bigger text") { scale = Typography.clamped(scale + 0.1) }
            .keyboardShortcut("+", modifiers: .command)
        Button("Smaller text") { scale = Typography.clamped(scale - 0.1) }
            .keyboardShortcut("-", modifiers: .command)
        Button("Actual size") { scale = Typography.defaultScale }
            .keyboardShortcut("0", modifiers: .command)
    }
}
