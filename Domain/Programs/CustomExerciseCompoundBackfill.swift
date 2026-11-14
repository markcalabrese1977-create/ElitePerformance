import Foundation
import SwiftData

/// Customs the lifter never decided on (`isCompound == nil`, e.g. from a file that carries no value) take the suggestion
/// from their closest built-in (exact or close match); anything weaker is false. Only nil values are written, so a lifter's
/// own choice is never overridden. Logs the names it set compound. Idempotent: once decided, a custom is not a candidate.
/// The catalog mirror (read by context-free lookups such as `RIREntry.isCompound`) is rebuilt whenever anything changed.
enum CustomExerciseCompoundBackfill {

    /// (custom, suggested value) for every undecided custom.
    static func plan(in context: ModelContext) -> [(custom: CustomExercise, compound: Bool)] {
        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        return customs.filter { $0.isCompound == nil }.map {
            ($0, MuscleSuggester.suggestedCompound(name: $0.name, coarse: MuscleGroup(rawValue: $0.primaryMuscleRaw) ?? .chest))
        }
    }

    static func runIfNeeded(in context: ModelContext) {
        let todo = plan(in: context)
        guard !todo.isEmpty else {
            BackfillLog.note("ℹ️ custom exercise compound backfill not needed.")
            return
        }
        for (custom, compound) in todo { custom.isCompound = compound }
        do {
            try context.save()
            ExerciseCatalog.rebuildCustomMirror(from: context)
            let names = todo.filter(\.compound).map { $0.custom.name }.sorted()
            BackfillLog.note("✅ custom exercise compound backfill completed. Decided \(todo.count): compound \(names.count)" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))") + ", not compound \(todo.count - names.count).")
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ custom exercise compound backfill save failed: \(error)")
        }
    }
}
