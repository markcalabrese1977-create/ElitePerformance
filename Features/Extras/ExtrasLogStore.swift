import Foundation

// MARK: - ExtrasLogStore
// UserDefaults-backed storage for ExtrasEntry (no SwiftData / migration risk).
// Keyed as a single `[ExtrasEntry]` blob for simplicity + speed.

enum ExtrasLogStore {

    private static let key = "extrasLog.v1"

    // Use shared encoder/decoder so behavior is consistent.
    // (Default Date encoding/decoding is fine as long as this stays internal to the app.)
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    // MARK: - Public API

    static func load() -> [ExtrasEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }

        do {
            let decoded = try decoder.decode([ExtrasEntry].self, from: data)
            return decoded.sorted { $0.date > $1.date }
        } catch {
            #if DEBUG
            print("⚠️ ExtrasLogStore.load decode failed: \(error)")
            #endif
            // Fail safe to empty rather than crashing.
            return []
        }
    }

    static func save(_ entries: [ExtrasEntry]) {
        do {
            let data = try encoder.encode(entries)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            #if DEBUG
            print("⚠️ ExtrasLogStore.save encode failed: \(error)")
            #endif
            // Fail silently in release; UX > crash.
        }
    }

    static func add(_ entry: ExtrasEntry) {
        var entries = load()
        entries.append(entry)
        // Keep newest first
        entries.sort { $0.date > $1.date }
        save(entries)
    }

    static func delete(id: UUID) {
        var entries = load()
        entries.removeAll { $0.id == id }
        save(entries)
    }

    static func count(kind: ExtrasEntry.Kind, inSameWeekAs date: Date) -> Int {
        let cal = Calendar.current
        let needle = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)

        return load().reduce(into: 0) { total, entry in
            guard entry.kind == kind else { return }
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.date)
            if comps == needle { total += 1 }
        }
    }

    // Optional convenience if you ever want to nuke the log (debug tools / reset button)
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
