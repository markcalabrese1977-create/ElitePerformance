import Foundation
import SwiftData

/// Stores the best single working set ever hit for an exercise.
@Model
final class PRIndex {
    /// Catalog ID for the exercise (matches `CatalogExercise.id` and `SessionItem.exerciseId`).
    var exerciseId: String
    /// Human-readable exercise name (for debug / display).
    var exerciseName: String

    /// Best single-set volume (load * reps) ever done.
    var bestSetVolume: Double
    /// Load and reps for that best set.
    var bestLoad: Double
    var bestReps: Int

    /// When this PR was achieved.
    var bestDate: Date

    init(
        exerciseId: String,
        exerciseName: String,
        bestSetVolume: Double,
        bestLoad: Double,
        bestReps: Int,
        bestDate: Date = Date()
    ) {
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.bestSetVolume = bestSetVolume
        self.bestLoad = bestLoad
        self.bestReps = bestReps
        self.bestDate = bestDate
    }
}
