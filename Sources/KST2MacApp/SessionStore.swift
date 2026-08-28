import SwiftUI

/// Owns the chat sessions; windows only *display* them.
///
/// This exists so a pane can be torn out into its own window, or docked
/// back, without dropping its connection. If a window owned its
/// `AppModel`, moving the pane would destroy and recreate it — logging
/// out of the room and back in, losing the scrollback and spending two of
/// the operator's one-per-minute command slots.
///
/// So sessions live here, keyed by id, and a window holds nothing but a
/// list of ids. Floating a pane is then a list operation: drop the id
/// from one window, hand it to another, and the TCP connection never
/// notices.
@MainActor
final class SessionStore: ObservableObject {

    static let shared = SessionStore()
    private init() {}

    @Published private var models: [UUID: AppModel] = [:]

    /// The session for `id`, created on first use. Creating on demand is
    /// what lets a window be restored from ids alone.
    func model(for id: UUID) -> AppModel {
        if let existing = models[id] { return existing }
        let created = AppModel()
        models[id] = created
        return created
    }

    func newSession() -> UUID {
        let id = UUID()
        _ = model(for: id)
        return id
    }

    /// Closes a session for good. Only call when the pane is being
    /// removed, never when it is merely moving between windows.
    func discard(_ id: UUID) {
        models[id]?.disconnect()
        models.removeValue(forKey: id)
    }

    func exists(_ id: UUID) -> Bool { models[id] != nil }
}
