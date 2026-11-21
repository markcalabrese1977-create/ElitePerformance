import Foundation

/// The single place exercise names are compared. Fixed locale (`en_US_POSIX`) so a name that collides on one
/// device collides on every device, and a restore onto a phone with a different region setting cannot change
/// which names count as equal. Used by the custom-exercise editor, `addCustomExercise`, canonical built-in
/// lookup and `CustomExerciseDedupMigration`.
enum ExerciseNameRules {
    static let locale = Locale(identifier: "en_US_POSIX")

    /// Trim, then fold case and diacritics ("Café Curl" == "cafe curl").
    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    static func areEqual(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }
}
