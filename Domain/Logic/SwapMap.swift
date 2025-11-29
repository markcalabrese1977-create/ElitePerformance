import Foundation

/// Provides simple swap options for a given exercise based on the catalog.
///
/// v1.0:
/// - If we have explicit overrides for an exercise id, use those.
/// - Otherwise, return other exercises with the same primary muscle,
///   excluding the exercise itself.
struct SwapMap {

    /// Returns swap candidates for the given exercise id.
    static func swapOptions(for exerciseId: String) -> [CatalogExercise] {
        guard let current = ExerciseCatalog.all.first(where: { $0.id == exerciseId }) else {
            return []
        }

        // 1) Explicit overrides for certain movements
        if let overrides = explicitOverrides[exerciseId], !overrides.isEmpty {
            return overrides
        }

        // 2) Default: same primary muscle, excluding this exact exercise
        let sameMuscle = ExerciseCatalog.all.filter {
            $0.id != current.id && $0.primaryMuscle == current.primaryMuscle
        }

        return sameMuscle
    }

    /// Explicit overrides for common "problem" exercises.
    /// These let us steer toward joint-friendly swaps.
    private static let explicitOverrides: [String: [CatalogExercise]] = [
        // Example: EZ Bar Reverse Curl bothering the elbow
        // Prioritize neutral-grip options and then standard curls.
        "ez_bar_reverse_curl": [
            ExerciseCatalog.cableRopeHammerCurl,
            ExerciseCatalog.hammerCurl,
            ExerciseCatalog.ezBarCurl
        ]
    ]
}
