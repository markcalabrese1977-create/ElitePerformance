import Foundation

/// Provides simple swap options for a given exercise based on the catalog.
///
/// For now, swaps are:
/// - Any other exercise with the same primary muscle
/// - Excluding the exercise itself
struct SwapMap {

    /// Returns swap candidates for the given exercise id.
    static func swapOptions(for exerciseId: String) -> [CatalogExercise] {
        guard let current = ExerciseCatalog.all.first(where: { $0.id == exerciseId }) else {
            return []
        }

        // DEV PHASE: allow swapping to ANY other exercise in the catalog.
        // We can reintroduce smarter filtering later.
        return ExerciseCatalog.all.filter { $0.id != current.id }
    }
    }

