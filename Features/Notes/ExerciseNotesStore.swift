import Foundation

enum ExerciseNotesStore {
    private static let prefix = "exerciseNotes.v1"

    /// Every legacy key starts with this; the exercise id is the rest.
    static let keyPrefix = prefix + "."

    private static func key(exerciseId: String) -> String {
        "\(prefix).\(exerciseId)"
    }

    /// All notes still held in the legacy UserDefaults store, as (exerciseId, raw value).
    static func legacyEntries() -> [(exerciseId: String, note: String)] {
        UserDefaults.standard.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix(keyPrefix), let note = value as? String else { return nil }
            return (String(key.dropFirst(keyPrefix.count)), note)
        }
        .sorted { $0.exerciseId < $1.exerciseId }
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
