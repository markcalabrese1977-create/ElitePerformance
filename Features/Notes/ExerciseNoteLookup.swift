import Foundation
import SwiftData

enum ExerciseNoteLookup {
    static func hasNote(exerciseId: String, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<ExerciseNote>()
        guard let notes = try? context.fetch(descriptor) else { return false }

        if notes.contains(where: {
            $0.exerciseId == exerciseId &&
            !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return true
        }

        // Legacy fallback during migration window
        return ExerciseNotesStore.hasNote(exerciseId: exerciseId)
    }
}
