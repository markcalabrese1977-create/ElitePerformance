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

        for ex in decoded {
            let custom = CustomExercise(
                id: ex.id,
                name: ex.name,
                primaryMuscleRaw: ex.primaryMuscle.rawValue,
                isCompound: ex.isCompound
            )
            context.insert(custom)
        }

        do {
            try context.save()
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(true, forKey: completionKey)
            BackfillLog.note("✅ CustomExerciseStoreMigration: migrated \(decoded.count) custom exercises to SwiftData.")
        } catch {
            BackfillLog.note("⚠️ CustomExerciseStoreMigration failed: \(error)")
        }
    }
}
