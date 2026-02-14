import Foundation

enum ExerciseNotesStore {
    private static let prefix = "exerciseNotes.v1"

    private static func key(exerciseId: String) -> String {
        "\(prefix).\(exerciseId)"
    }

    static func load(exerciseId: String) -> String {
        UserDefaults.standard.string(forKey: key(exerciseId: exerciseId)) ?? ""
    }

    static func save(exerciseId: String, note: String) {
        UserDefaults.standard.set(note, forKey: key(exerciseId: exerciseId))
    }

    static func hasNote(exerciseId: String) -> Bool {
        !load(exerciseId: exerciseId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func clear(exerciseId: String) {
        UserDefaults.standard.removeObject(forKey: key(exerciseId: exerciseId))
    }
}
