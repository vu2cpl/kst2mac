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
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    /// Applied twice: once now, once after the current run loop pass.
    ///
    /// SwiftUI re-applies its own title handling when the toolbar rebuilds
    /// — which happens on every published change, so several times a
    /// second on a busy chat — and that undid `titleVisibility = .hidden`,
    /// bringing the app name back a second time. Re-applying after
    /// SwiftUI's pass wins; applying only during the pass does not.
    private func apply(to view: NSView) {
        if let window = view.window { configure(window) }
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
    }
}
