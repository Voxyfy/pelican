import AppKit
import Observation

/// What Pelican did with servers, newest last: connections, transfers and file changes.
/// Users can copy it into a support email when something goes wrong.
@MainActor @Observable
final class ActivityLog {
    static let shared = ActivityLog()

    struct Entry: Identifiable {
        enum Level { case info, success, error }
        let id = UUID()
        let date = Date()
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 500

    func info(_ message: String) { add(.info, message) }
    func success(_ message: String) { add(.success, message) }
    func error(_ message: String) { add(.error, message) }

    var errorCount: Int { entries.filter { $0.level == .error }.count }

    func clear() { entries.removeAll() }

    /// Plain text, one "HH:mm:ss message" line per entry.
    func copy(_ shown: [Entry]) {
        let text = shown.map { "\($0.date.formatted(.dateTime.hour().minute().second())) \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func add(_ level: Entry.Level, _ message: String) {
        entries.append(Entry(level: level, message: message))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}
