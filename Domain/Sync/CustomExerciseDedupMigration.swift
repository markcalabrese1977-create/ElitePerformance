import Foundation
import SwiftData

enum CustomExerciseDedupMigration {
    private static let completionKey = "customExerciseDedupMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        // Rows that share an id are collapsed on EVERY launch, flag or no flag: CustomExerciseStoreMigration (re-run after a restore
        // that left its flag unset) inserts a second row for each legacy entry, and nothing may trap on that afterwards.
        collapseDuplicateRows(in: context)

        if UserDefaults.standard.bool(forKey: completionKey) {
            BackfillLog.note("ℹ️ Custom exercise dedup migration not needed.")
            return
        }

        let customExercises = ExerciseCatalog.customExercises(in: context)
        // Non-trapping merges (a duplicate key is a fact about the data, not a crash): the first entry wins, and the rows are in a
        // fixed order (oldest createdAt first, then the same tie-break as `isCanonical`), so the choice is deterministic.
        let builtInByNormalizedName: [String: CatalogExercise] = Dictionary(
            ExerciseCatalog.builtIn.map { (normalizedName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let duplicateCustomToBuiltIn: [String: String] = Dictionary(
            customExercises.compactMap { custom -> (String, String)? in
                let key = normalizedName(custom.name)
                guard let builtIn = builtInByNormalizedName[key] else { return nil }
                return (custom.id, builtIn.id)
            },
            uniquingKeysWith: { first, _ in first }
        )

        guard !duplicateCustomToBuiltIn.isEmpty else {
            BackfillLog.note("ℹ️ Custom exercise dedup migration found no duplicate custom exercises.")
            UserDefaults.standard.set(true, forKey: completionKey)
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            BackfillLog.note("⚠️ Custom exercise dedup migration failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        for session in sessions {
            for item in session.items {
                let canonicalCurrent = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                if let replacementId = duplicateCustomToBuiltIn[canonicalCurrent] {
                    guard replacementId != item.exerciseId else { continue }
                    item.exerciseId = replacementId

                    if item.exerciseNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        item.exerciseNameSnapshot = ExerciseCatalog.displayName(for: replacementId)
                    }

                    changedCount += 1
                }
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                BackfillLog.note("✅ Custom exercise dedup migration completed. Updated \(changedCount) items.")
            } else {
                BackfillLog.note("ℹ️ Custom exercise dedup migration found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            BackfillLog.note("⚠️ Custom exercise dedup migration save failed: \(error)")
        }
    }

    // MARK: - Rows that share an id

    /// True when `a` is the row to keep over `b`: the oldest `createdAt`, then (the ids being equal, which is what makes them
    /// duplicates) the lowest persistent identifier, a stable total order within one store.
    static func isCanonical(_ a: CustomExercise, over b: CustomExercise) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        if a.id != b.id { return a.id < b.id }
        return String(describing: a.persistentModelID) < String(describing: b.persistentModelID)
    }

    /// One row per id: the canonical one (`isCanonical`). Never traps on a duplicate.
    static func canonicalRows(_ rows: [CustomExercise]) -> [CustomExercise] {
        var best: [String: CustomExercise] = [:]
        for r in rows {
            if let cur = best[r.id], !isCanonical(r, over: cur) { continue }
            best[r.id] = r
        }
        return best.values.sorted { isCanonical($0, over: $1) }
    }

    /// Deletes every non-canonical row of an id that has more than one and returns how many were deleted. A session item names its
    /// exercise by id, and every duplicate carries that same id, so every item keeps pointing at the surviving row. Idempotent.
    @discardableResult
    static func collapseDuplicateRows(in context: ModelContext) -> Int {
        guard let rows = try? context.fetch(FetchDescriptor<CustomExercise>()) else { return 0 }
        let keep = Set(canonicalRows(rows).map(\.persistentModelID))
        let extras = rows.filter { !keep.contains($0.persistentModelID) }
        guard !extras.isEmpty else { return 0 }
        for r in extras { context.delete(r) }
        do {
            try context.save()
            ExerciseCatalog.rebuildCustomMirror(from: context)
            BackfillLog.note("✅ Custom exercise dedup: collapsed \(extras.count) duplicate custom exercise row(s) to one per id.")
            return extras.count
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ Custom exercise dedup: could not collapse duplicate rows: \(error)")
            return 0
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
