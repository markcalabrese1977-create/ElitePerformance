import Foundation
import SwiftData

enum CustomExerciseDedupMigration {
    private static let completionKey = "customExerciseDedupMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Custom exercise dedup migration not needed.")
            return
        }

        let customExercises = ExerciseCatalog.customExercises()
        let builtInByNormalizedName: [String: CatalogExercise] = Dictionary(
            uniqueKeysWithValues: ExerciseCatalog.builtIn.map {
                (normalizedName($0.name), $0)
            }
        )

        let duplicateCustomToBuiltIn: [String: String] = Dictionary(
            uniqueKeysWithValues: customExercises.compactMap { custom in
                let key = normalizedName(custom.name)
                guard let builtIn = builtInByNormalizedName[key] else { return nil }
                return (custom.id, builtIn.id)
            }
        )

        guard !duplicateCustomToBuiltIn.isEmpty else {
            print("ℹ️ Custom exercise dedup migration found no duplicate custom exercises.")
            UserDefaults.standard.set(true, forKey: completionKey)
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ Custom exercise dedup migration failed: could not fetch sessions.")
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
                print("✅ Custom exercise dedup migration completed. Updated \(changedCount) items.")
            } else {
                print("ℹ️ Custom exercise dedup migration found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Custom exercise dedup migration save failed: \(error)")
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
