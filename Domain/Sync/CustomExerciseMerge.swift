import Foundation
import SwiftData

/// A custom exercise that has the same name as a built-in one (the built-in arrived after the lifter made their own) is merged into the
/// built-in: every item, note, setting and recent-pick moves to the built-in's canonical id and the custom row goes. The same fold as
/// the name rules (`ExerciseNameRules.normalized`: case and diacritics ignored), the same policy as `CustomExerciseDedupMigration`,
/// which only ever ran once, before the built-in existed.
///
/// What moves, for the custom id C and the built-in B:
///   - every `SessionItem` (planned and completed) with exerciseId C: `exerciseId = B`, `exerciseNameSnapshot` = the built-in's name;
///   - every `ExerciseNote` on C: moved to B (B's own note is kept and C's text is appended when it differs);
///   - `UserProfile` per-exercise settings keyed by C (max load, load step, fixed-load exemption): re-keyed to B unless B already has one;
///   - the picker's recent list (UserDefaults `exercisePicker.recentIds.v1`): C replaced by B;
///   - the `CustomExercise` row is deleted and the UserDefaults mirror rebuilt.
/// `SessionHistoryExercise` rows name the exercise by NAME, which is the same, so they need no change. Muscle shares: the built-in's apply.
/// One save; a failure rolls everything back. Idempotent: once merged there is no custom row left to find.
enum CustomExerciseMerge {

    struct Plan {
        let custom: CustomExercise
        let builtInId: String
        let builtInName: String
        let items: [SessionItem]
        let notes: [ExerciseNote]
        /// "maxLoad 100", "loadStep 5", "fixed-load", for the report.
        let settings: [String]
        let inRecents: Bool

        var completedItems: Int { items.filter { $0.isCompleted || !$0.actualReps.isEmpty && $0.actualReps.contains { $0 > 0 } }.count }
        var summary: String {
            "\"\(custom.name)\" (\(custom.id)) -> built-in \(builtInId): \(items.count) item(s) (\(completedItems) logged), \(notes.count) note(s), "
                + "settings [\(settings.joined(separator: ", "))], in recents \(inRecents)"
        }
    }

    static func plans(in context: ModelContext) -> [Plan] {
        guard let customs = try? context.fetch(FetchDescriptor<CustomExercise>()) else { return [] }
        let builtIns = Dictionary(ExerciseCatalog.builtIn.map { (ExerciseNameRules.normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let notes = (try? context.fetch(FetchDescriptor<ExerciseNote>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let recents = UserDefaults.standard.stringArray(forKey: ExercisePickerRecents.key) ?? []
        var out: [Plan] = []
        for custom in customs {
            guard let builtIn = builtIns[ExerciseNameRules.normalized(custom.name)] else { continue }
            let items = sessions.flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == custom.id }
            var settings: [String] = []
            if let v = profile?.maxLoadByExercise[custom.id] { settings.append("maxLoad \(v)") }
            if let v = profile?.loadStepByExercise[custom.id] { settings.append("loadStep \(v)") }
            if profile?.exemptExerciseIds.contains(custom.id) == true { settings.append("fixed-load") }
            out.append(Plan(custom: custom, builtInId: builtIn.id, builtInName: builtIn.name, items: items,
                            notes: notes.filter { $0.exerciseId == custom.id }, settings: settings, inRecents: recents.contains(custom.id)))
        }
        return out
    }

    /// Applies every plan in one save. Returns the number of custom exercises merged.
    @discardableResult
    static func apply(_ plans: [Plan], in context: ModelContext) -> Int {
        guard !plans.isEmpty else { return 0 }
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let allNotes = (try? context.fetch(FetchDescriptor<ExerciseNote>())) ?? []
        for plan in plans {
            let c = plan.custom.id, b = plan.builtInId
            for item in plan.items {
                item.exerciseId = b
                item.exerciseNameSnapshot = plan.builtInName
                item.updatedAt = Date()
            }
            for note in plan.notes {
                if let keep = allNotes.first(where: { $0.exerciseId == b }), keep !== note {
                    let extra = note.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !extra.isEmpty, !keep.note.contains(extra) { keep.note += (keep.note.isEmpty ? "" : "\n") + extra; keep.updatedAt = Date() }
                    context.delete(note)
                } else {
                    note.exerciseId = b; note.updatedAt = Date()
                }
            }
            if let profile {
                if let v = profile.maxLoadByExercise[c] { var m = profile.maxLoadByExercise; m[c] = nil; if m[b] == nil { m[b] = v }; profile.maxLoadByExercise = m }
                if let v = profile.loadStepByExercise[c] { var m = profile.loadStepByExercise; m[c] = nil; if m[b] == nil { m[b] = v }; profile.loadStepByExercise = m }
                if profile.exemptExerciseIds.contains(c) {
                    var ids = profile.exemptExerciseIds.filter { $0 != c }
                    if !ids.contains(b) { ids.append(b) }
                    profile.exemptExerciseIds = ids
                }
            }
            context.delete(plan.custom)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ Custom exercise merge save failed: \(error)")
            return 0
        }
        let mapping = Dictionary(plans.map { ($0.custom.id, $0.builtInId) }, uniquingKeysWith: { first, _ in first })
        let recents = UserDefaults.standard.stringArray(forKey: ExercisePickerRecents.key) ?? []
        if recents.contains(where: { mapping[$0] != nil }) {
            var seen = Set<String>()
            UserDefaults.standard.set(recents.map { mapping[$0] ?? $0 }.filter { seen.insert($0).inserted }, forKey: ExercisePickerRecents.key)
        }
        ExerciseCatalog.rebuildCustomMirror(from: context)
        return plans.count
    }
}

/// Startup backfill: merges the custom exercises that duplicate a built-in. Idempotent (nothing to find once merged).
enum CustomExerciseMergeBackfill {
    static func runIfNeeded(in context: ModelContext) {
        let plans = CustomExerciseMerge.plans(in: context)
        guard !plans.isEmpty else { BackfillLog.note("ℹ️ Custom exercise merge not needed."); return }
        let n = CustomExerciseMerge.apply(plans, in: context)
        BackfillLog.note("✅ Custom exercise merge: \(n) custom exercise(s) merged into the built-in (\(plans.map { "\($0.custom.name): \($0.items.count) items" }.joined(separator: "; "))).")
    }
}
