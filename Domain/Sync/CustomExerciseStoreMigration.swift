import Foundation
import SwiftData

enum CustomExerciseStoreMigration {
    private static let completionKey = "customExerciseStoreMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { BackfillLog.note("not needed"); return }

        let key = "custom_exercises_v2"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CatalogExercise].self, from: data),
              !decoded.isEmpty else {
            UserDefaults.standard.set(true, forKey: completionKey)
            BackfillLog.note("nothing to migrate (no legacy custom exercises)")
            return
        }

        // Only ids the store does not hold yet (the legacy list is a mirror the app rebuilds from the store on every restore, so over
        // existing rows it would add a second row per id), and each id of the list once: running this on any state, any number of
        // times, leaves the same rows.
        let existing = Set(((try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []).map(\.id))
        var seen = existing
        var inserted = 0
        for ex in decoded where seen.insert(ex.id).inserted {
            context.insert(CustomExercise(
                id: ex.id,
                name: ex.name,
                primaryMuscleRaw: ex.primaryMuscle.rawValue,
                isCompound: ex.isCompound
            ))
            inserted += 1
        }

        do {
            if inserted > 0 { try context.save() }
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(true, forKey: completionKey)
            BackfillLog.note("✅ CustomExerciseStoreMigration: migrated \(inserted) custom exercises to SwiftData (\(decoded.count - inserted) of \(decoded.count) legacy entries were already in the store).")
        } catch {
            BackfillLog.note("⚠️ CustomExerciseStoreMigration failed: \(error)")
        }
    }
}
