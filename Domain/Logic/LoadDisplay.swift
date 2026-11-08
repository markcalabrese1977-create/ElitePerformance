import Foundation

enum LoadDisplay {
    static func string(load: Double, exerciseId: String, unit: LoadUnit = .lb) -> String {
        // Only show BW for known bodyweight movements
        if load == 0, isBodyweightExercise(exerciseId) {
            return "BW"
        }

        return LoadFormatter(unit: unit).compact(load)
    }

    private static func isBodyweightExercise(_ id: String) -> Bool {
        ExerciseCatalog.isBodyweight(exerciseId: id)
    }
}

