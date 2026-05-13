import Foundation
import SwiftData

enum CustomExerciseStoreMigration {
    private static let completionKey = "customExerciseStoreMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        let key = "custom_exercises_v2"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CatalogExercise].self, from: data),
              !decoded.isEmpty else {
            UserDefaults.standard.set(true, forKey: completionKey)
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
            print("✅ CustomExerciseStoreMigration: migrated \(decoded.count) custom exercises to SwiftData.")
        } catch {
            print("⚠️ CustomExerciseStoreMigration failed: \(error)")
        }
    }
}
