import AppKit
import SwiftUI

/// Audible alerts for the three things worth interrupting you.
///
/// Notifications only fire when the app is *not* frontmost, which leaves
/// the case this app is actually used in — the window visible on a second
/// monitor while you work the radio — completely silent. Sound covers
/// that, so it deliberately plays whether or not the app is frontmost.
///
/// Modelled on the KST2Me manual §3.5, which gives `/CQ`, preamble and
/// watch each their own sound.
@MainActor
final class Sounds: ObservableObject {

    static let shared = Sounds()
    private init() {}

    enum Event: String, CaseIterable, Identifiable {
        case directed, preamble, watched
        var id: String { rawValue }

        var title: String {
            switch self {
            case .directed: return "Message to you (/CQ)"
            case .preamble: return "Message to you (preamble)"
            case .watched:  return "Watched callsign or word"
            }
        }

        var defaultSound: String {
            switch self {
            case .directed: return "Morse"      // a ham app may as well
            case .preamble: return "Ping"
            case .watched:  return "Tink"
            }
        }

        var key: String { "sound.\(rawValue)" }
    }

    static let off = "Off"

    /// Every sound macOS ships, plus anything the operator has dropped in
    /// `~/Library/Sounds`. Read at runtime rather than hardcoded so a
    /// personal .aiff shows up without a code change.
    static let available: [String] = {
        let dirs = ["/System/Library/Sounds",
                    NSHomeDirectory() + "/Library/Sounds"]
        let names = dirs.flatMap { dir -> [String] in
            (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { $0.hasSuffix(".aiff") || $0.hasSuffix(".wav") }
                .map { ($0 as NSString).deletingPathExtension } ?? []
        }
        return [off] + Array(Set(names)).sorted()
    }()

    /// A burst of alerts is worse than none — `/SHOW MSG` can backfill
    /// fifteen lines at once, several of which may name you.
    private var lastPlayed = Date.distantPast
    private let minimumGap: TimeInterval = 2

    /// Set while a backlog is arriving, so joining a busy room does not
    /// open with a volley of alerts about messages sent before you got there.
    private var quietUntil = Date.distantPast

    func beQuiet(for seconds: TimeInterval) {
        quietUntil = Date().addingTimeInterval(seconds)
    }

    func play(_ event: Event) {
        let now = Date()
        guard now >= quietUntil, now.timeIntervalSince(lastPlayed) >= minimumGap else { return }

        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: event.key) ?? event.defaultSound
        guard name != Self.off, let sound = NSSound(named: name) else { return }

        let volume = defaults.object(forKey: "sound.volume") as? Double ?? 0.7
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
        lastPlayed = now
    }

    /// Play one regardless of throttling — for the Test buttons.
    func preview(_ name: String) {
        guard name != Self.off, let sound = NSSound(named: name) else { return }
        sound.volume = Float(UserDefaults.standard.object(forKey: "sound.volume") as? Double ?? 0.7)
        sound.play()
    }
}
