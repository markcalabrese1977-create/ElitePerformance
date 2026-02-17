import Foundation

enum LoadDisplay {
    static func string(load: Double, exerciseId: String) -> String {
        // Only show BW for known bodyweight movements
        if load == 0, isBodyweightExercise(exerciseId) {
            return "BW"
        }

        if load == floor(load) { return String(format: "%.0f", load) }
        return String(format: "%.1f", load)
    }

    private static func isBodyweightExercise(_ id: String) -> Bool {
        // Expand this list as needed
        let bwIds: Set<String> = [
            "pull_up",
            "chin_up",
            "dip",
            "push_up",
            "inverted_row",
            "plank",
            "hanging_knee_raise"
        ]
        return bwIds.contains(id)
    }
}

