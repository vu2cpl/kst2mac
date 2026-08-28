import SwiftUI
import AppKit

/// Reaches the `NSWindow` behind a SwiftUI scene and keeps it configured.
///
/// The title-bar text is drawn by AppKit and takes no font, colour or size
/// from SwiftUI, so hiding it is the only way to show the app name at a
/// readable size in our own strip without printing it twice.
///
/// Hiding it once does not hold. SwiftUI re-applies its own title handling
/// whenever the toolbar rebuilds, and a toolbar with live state in it
/// rebuilds constantly — the doubled name came back three times on
/// increasingly stubborn versions of "apply it again, but later".
///
/// So this observes `NSWindow.didUpdateNotification` for its own window
/// and re-applies on every update. `configure` is written to no-op when
/// the window is already right, so this cannot loop: setting nothing
/// posts nothing.
struct WindowAccessor: NSViewRepresentable {

    let configure: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(configure: configure) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.attach(to: view.window)
    }

    final class Coordinator {
        private let configure: (NSWindow) -> Void
        private var observer: NSObjectProtocol?
        private weak var window: NSWindow?

        init(configure: @escaping (NSWindow) -> Void) {
            self.configure = configure
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            configure(window)
            guard self.window !== window else { return }
            detach()
            self.window = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.configure(window)
            }
        }

        private func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        deinit { detach() }
    }
}
