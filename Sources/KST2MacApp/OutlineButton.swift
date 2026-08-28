import SwiftUI

/// An outlined button whose colour reports state.
///
/// Outlined rather than filled because Connect is pressed once a session —
/// a solid fill shouts for something you rarely touch, and with several
/// panes stacked the filled buttons dominated the window.
///
/// The fixed width is the point of the thing: "Connect" and "Disconnect"
/// are different lengths, so a naturally-sized button changes width every
/// time a pane's state changes, and the controls to its right stop lining
/// up between panes. Pinning it to the longest label keeps the columns.
struct OutlineButtonStyle: ButtonStyle {
    let color: Color
    var width: CGFloat = 108

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: width)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(color, lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(color.opacity(configuration.isPressed ? 0.22 : 0.06))
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
