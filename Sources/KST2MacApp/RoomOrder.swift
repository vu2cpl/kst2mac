import SwiftUI
import KSTCore

/// Which rooms come first in the picker.
///
/// The server's menu order is fixed and arbitrary from any one operator's
/// point of view — the two rooms you actually use can be at positions 5
/// and 1 with eleven you never touch in between. Pinned rooms rise to the
/// top; the rest keep the server's order below them, so a pinned list is
/// a shortcut rather than a different mental model.
@MainActor
final class RoomOrder: ObservableObject {

    static let shared = RoomOrder()

    private static let key = "pinnedRooms"
    /// Sensible for a VU operator: the low bands and 6/4m.
    private static let fallback: [ChatRoom] = [.lowBand, .fiftySeventy]

    @Published private(set) var pinned: [ChatRoom]

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        if let raw, !raw.isEmpty {
            pinned = raw.split(separator: ",")
                .compactMap { Int($0) }
                .compactMap(ChatRoom.init(rawValue:))
        } else {
            pinned = Self.fallback
        }
    }

    /// Pinned first, in pin order; everything else in the server's order.
    var ordered: [ChatRoom] {
        pinned + ChatRoom.allCases.filter { !pinned.contains($0) }
    }

    var unpinned: [ChatRoom] {
        ChatRoom.allCases.filter { !pinned.contains($0) }
    }

    func isPinned(_ room: ChatRoom) -> Bool { pinned.contains(room) }

    func togglePin(_ room: ChatRoom) {
        if let index = pinned.firstIndex(of: room) {
            pinned.remove(at: index)
        } else {
            pinned.append(room)
        }
        save()
    }

    func move(_ room: ChatRoom, by offset: Int) {
        guard let index = pinned.firstIndex(of: room) else { return }
        let target = index + offset
        guard pinned.indices.contains(target) else { return }
        pinned.swapAt(index, target)
        save()
    }

    private func save() {
        UserDefaults.standard.set(pinned.map { String($0.rawValue) }.joined(separator: ","),
                                  forKey: Self.key)
    }
}
