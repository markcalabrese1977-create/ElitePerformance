import Foundation
import SwiftData

/// Backfill logging: a backfill reports what it did through `note` (as many times as it likes while it works); the startup
/// runner turns those notes into EXACTLY ONE log line per backfill: "<TypeName>: <result>", where the result is "not needed"
/// or what it changed. A backfill run on its own (a test) just prints its notes.
enum BackfillLog {
    /// Notes collected for the backfill that is currently running; nil outside `StartupBackfills.run`.
    static var collector: [String]?
    /// Every line `StartupBackfills.run` emits, for tests.
    static var lineSink: ((String) -> Void)?

    static func note(_ message: String) {
        if collector != nil { collector?.append(message) } else { print("\(message)") }
    }

    /// "ℹ️ Foo backfill not needed." / "✅ Foo completed. Updated 3 items." -> a result without the emoji and trailing period.
    static func result(from notes: [String]) -> String {
        guard !notes.isEmpty else { return "ran (no output)" }
        if notes.contains(where: { $0.contains("not needed") }) { return "not needed" }
        return notes.map { n -> String in
            var t = n
            for prefix in ["ℹ️ ", "✅ ", "⚠️ "] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
            while t.hasSuffix(".") { t.removeLast() }
            return t
        }.joined(separator: "; ")
    }
}
