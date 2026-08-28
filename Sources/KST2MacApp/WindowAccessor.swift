import SwiftUI
import AppKit

/// Reaches the `NSWindow` behind a SwiftUI scene.
///
/// Needed because the title-bar text is drawn by AppKit and cannot be
/// styled from SwiftUI — no font, no colour, no size. Hiding the system
/// title lets the window draw its own, which is the only way to make the
/// app name and callsign legible at a glance across a shack.
struct WindowAccessor: NSViewRepresentable {

    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { configure(window) }
    }
}
