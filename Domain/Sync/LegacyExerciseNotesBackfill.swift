import Foundation
import SwiftData

/// Moves every note still held in the legacy `exerciseNotes.v1.<exerciseId>` UserDefaults keys into ExerciseNote,
/// so the backup (which exports ExerciseNote rows only) includes them. Previously a legacy note only moved when its
/// note sheet was opened.
///
/// - Never overwrites: an exercise that already has an ExerciseNote keeps it, and its legacy key is left alone.
/// - A legacy key is deleted only after the save that stored it succeeded.
/// - No completion flag: the scan is cheap and idempotent, so a legacy key that shows up later is still picked up.
enum LegacyExerciseNotesBackfill {

    static func runIfNeeded(in context: ModelContext) {
        let legacy = ExerciseNotesStore.legacyEntries()
        guard !legacy.isEmpty else {
            BackfillLog.note("ℹ️ Legacy exercise notes backfill not needed.")
            return
        }

        guard let existing = try? context.fetch(FetchDescriptor<ExerciseNote>()) else {
            BackfillLog.note("⚠️ Legacy exercise notes backfill failed: could not fetch notes.")
            return
        }
        var haveNote = Set(existing.map(\.exerciseId))

        var migrated: [String] = []
        var blank: [String] = []
        var kept = 0
        for entry in legacy {
            let trimmed = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                blank.append(entry.exerciseId)
            } else if !haveNote.contains(entry.exerciseId) {
                context.insert(ExerciseNote(exerciseId: entry.exerciseId, note: trimmed))
                haveNote.insert(entry.exerciseId)
                migrated.append(entry.exerciseId)
            } else {
                kept += 1
            }
        }

        do {
            if !migrated.isEmpty { try context.save() }
            for exerciseId in migrated + blank { ExerciseNotesStore.clear(exerciseId: exerciseId) }
            BackfillLog.note("\(migrated.isEmpty ? "ℹ️" : "✅") Legacy exercise notes backfill moved \(migrated.count) notes, kept \(kept) legacy keys (existing notes).")
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ Legacy exercise notes backfill save failed: \(error)")
        }
    }
}
