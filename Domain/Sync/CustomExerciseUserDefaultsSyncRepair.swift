// Domain/Sync/CustomExerciseUserDefaultsSyncRepair.swift
import Foundation
import SwiftData

/// One-time repair: repopulates UserDefaults custom_exercises_v2 from SwiftData.
/// Needed after CustomExerciseStoreMigration removed exercises from UserDefaults —
/// ExerciseCatalog.all now reads from UserDefaults to resolve names without a
/// ModelContext, so the cache must be kept in sync with SwiftData.
enum CustomExerciseUserDefaultsSyncRepair {
    private static let completionKey = "customExerciseUserDefaultsSync.v1.completed"
    private static let storeKey = "custom_exercises_v2"

    static func runIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        let descriptor = FetchDescriptor<CustomExercise>()
        guard let exercises = try? context.fetch(descriptor), !exercises.isEmpty else {
            UserDefaults.standard.set(true, forKey: completionKey)
            return
        }

        let catalog = exercises.map { ex in
            CatalogExercise(
                id: ex.id ?? UUID().uuidString,
                name: ex.name,
                primaryMuscle: MuscleGroup(rawValue: ex.primaryMuscleRaw ?? "") ?? .chest,
                isCompound: ex.isCompound
            )
        }

        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: storeKey)
            NotificationCenter.default.post(name: .exerciseCatalogDidChange, object: nil)
            print("✅ CustomExerciseUserDefaultsSyncRepair: synced \(catalog.count) exercise(s) to UserDefaults")
        }

        UserDefaults.standard.set(true, forKey: completionKey)
    }
}
