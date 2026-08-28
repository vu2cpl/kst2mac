import Foundation

/// Appends raw server bytes to a file from whatever thread the connection
/// happens to be on.
///
/// Separate from `AppModel` because the raw monitor is a `@Sendable`
/// closure invoked on the connection's own queue, and reaching back into
/// a `@MainActor` model from there does not compile — correctly, since it
/// would be a data race.
final class TranscriptWriter: @unchecked Sendable {

    private let lock = NSLock()
    private var handle: FileHandle?

    init?(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
