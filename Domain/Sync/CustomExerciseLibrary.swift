import Foundation
import SwiftData

/// Rename / edit / delete rules for custom exercises (Settings → Exercises). Pure data logic, no UI.
///
/// - Names are compared with `ExerciseNameRules` (fixed locale). A name is taken when it equals a built-in name or
///   ANOTHER custom exercise's name; the exercise's own name never blocks itself, so a case-only change is allowed.
/// - A rename rewrites every place the name is stored next to the id: the mirror, `SessionItem.exerciseNameSnapshot`
///   (planned and completed), `SessionHistoryExercise.name` (matched by the OLD name, only inside histories of sessions
///   that contain the exercise). One save; any failure rolls everything back.
/// - Delete is refused while any session still has the exercise.
/// No persisted field is added, so the backup format is unchanged.
enum CustomExerciseLibrary {

    static let maxNameLength = 60

    // MARK: Name check

    enum NameCheck: Equatable {
        case ok(String)                  // the trimmed name to store
        case empty
        case tooLong
        case collidesWithBuiltIn(String) // the built-in's name
        case collidesWithCustom(String)  // the other custom exercise's name

        var message: String? {
            switch self {
            case .ok: return nil
            case .empty: return "Enter a name."
            case .tooLong: return "Keep the name under \(CustomExerciseLibrary.maxNameLength) characters."
            case .collidesWithBuiltIn(let n): return "“\(n)” is already a built-in exercise."
            case .collidesWithCustom(let n): return "You already have a custom exercise named “\(n)”."
            }
        }
        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    /// `id` is the exercise being renamed (nil for a new one): its own name is skipped.
    static func checkName(_ raw: String, forId id: String?, in context: ModelContext) -> NameCheck {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= maxNameLength else { return .tooLong }
        let key = ExerciseNameRules.normalized(trimmed)
        if let b = ExerciseCatalog.builtIn.first(where: { ExerciseNameRules.normalized($0.name) == key }) {
            return .collidesWithBuiltIn(b.name)
        }
        let rows = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        if let other = rows.first(where: { $0.id != id && ExerciseNameRules.normalized($0.name) == key }) {
            return .collidesWithCustom(other.name)
        }
        return .ok(trimmed)
    }

    // MARK: Usage

    struct Usage: Equatable {
        /// Sessions (any status) that contain the exercise.
        var sessions = 0
        /// Of those, sessions not completed yet (planned or in progress).
        var planned = 0
        /// Logged working sets (reps > 0) across all of them.
        var loggedSets = 0
        var isUnused: Bool { sessions == 0 }

        /// The text shown when a delete is refused.
        var deleteBlockMessage: String {
            "Used in \(sessions) session\(sessions == 1 ? "" : "s") (\(planned) planned). Swap it out of your program first."
        }
    }

    static func usage(of id: String, in context: ModelContext) -> Usage {
        var u = Usage()
        for s in (try? context.fetch(FetchDescriptor<Session>())) ?? [] {
            let mine = s.items.filter { $0.exerciseId == id }
            guard !mine.isEmpty else { continue }
            u.sessions += 1
            if s.status != .completed { u.planned += 1 }
            u.loggedSets += mine.reduce(0) { $0 + max($1.actualReps.filter { $0 > 0 }.count, $1.logs.filter { $0.actualReps > 0 }.count) }
        }
        return u
    }

    // MARK: Edit / rename

    struct Edit {
        var name: String
        var primaryMuscle: MuscleGroup
        var isCompound: Bool
        var isBodyweight: Bool
    }

    enum EditResult: Equatable {
        case saved
        case invalidName(NameCheck)
        case notFound
        case saveFailed
    }

    /// Applies name / coarse muscle / compound / bodyweight in one save. Flags are forward-only: stored sets keep their values.
    @discardableResult
    static func update(id: String, edit: Edit, in context: ModelContext) -> EditResult {
        guard !ExerciseCatalog.builtIn.contains(where: { $0.id == id }),
              ExerciseCatalog.ensureCustomRecord(id: id, in: context) else { return .notFound }
        let check = checkName(edit.name, forId: id, in: context)
        guard case .ok(let newName) = check else { return .invalidName(check) }

        let rows = ((try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []).filter { $0.id == id }
        guard !rows.isEmpty else { return .notFound }
        let oldNames = Set(rows.map(\.name))

        for r in rows {
            r.name = newName
            r.primaryMuscleRaw = edit.primaryMuscle.rawValue
            r.isCompound = edit.isCompound
            r.isBodyweight = edit.isBodyweight
        }

        if !oldNames.contains(newName) { renameSnapshots(id: id, oldNames: oldNames, newName: newName, in: context) }

        guard (try? context.save()) != nil else {
            context.rollback()
            ExerciseCatalog.rebuildCustomMirror(from: context)
            return .saveFailed
        }
        ExerciseCatalog.rebuildCustomMirror(from: context)
        return .saved
    }

    private static func renameSnapshots(id: String, oldNames: Set<String>, newName: String, in context: ModelContext) {
        let oldKeys = Set(oldNames.map(ExerciseNameRules.normalized))
        var sessionIds = Set<UUID>()
        for s in (try? context.fetch(FetchDescriptor<Session>())) ?? [] {
            var has = false
            for item in s.items where item.exerciseId == id {
                item.exerciseNameSnapshot = newName
                has = true
            }
            if has, let sid = s.id { sessionIds.insert(sid) }
        }
        for h in (try? context.fetch(FetchDescriptor<SessionHistory>())) ?? [] {
            guard let sid = h.sessionId, sessionIds.contains(sid) else { continue }
            for e in h.exercises where oldKeys.contains(ExerciseNameRules.normalized(e.name)) { e.name = newName }
        }
    }

    // MARK: Delete

    enum DeleteResult: Equatable {
        case deleted
        case blocked(Usage)
        case notFound
        case saveFailed
    }

    /// Deletes a custom exercise only when no session uses it, and removes what hangs off its id (note, per-exercise
    /// load settings, recent pick, mirror entry).
    @discardableResult
    static func delete(id: String, in context: ModelContext, recents: ExercisePickerRecents = ExercisePickerRecents()) -> DeleteResult {
        guard !ExerciseCatalog.builtIn.contains(where: { $0.id == id }) else { return .notFound }
        let u = usage(of: id, in: context)
        guard u.isUnused else { return .blocked(u) }

        let rows = ((try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []).filter { $0.id == id }
        let inMirror = ExerciseCatalog.all.contains { $0.id == id }
        guard !rows.isEmpty || inMirror else { return .notFound }

        rows.forEach { context.delete($0) }
        for n in (try? context.fetch(FetchDescriptor<ExerciseNote>())) ?? [] where n.exerciseId == id { context.delete(n) }
        for p in (try? context.fetch(FetchDescriptor<UserProfile>())) ?? [] {
            if p.loadStepByExerciseStored?[id] != nil { p.loadStepByExerciseStored?[id] = nil }
            if p.maxLoadByExerciseStored?[id] != nil { p.maxLoadByExerciseStored?[id] = nil }
            if let ex = p.exemptExerciseIdsStored, ex.contains(id) { p.exemptExerciseIdsStored = ex.filter { $0 != id } }
        }
        guard (try? context.save()) != nil else {
            context.rollback()
            ExerciseCatalog.rebuildCustomMirror(from: context)
            return .saveFailed
        }
        ExerciseCatalog.rebuildCustomMirror(from: context)
        recents.remove(id)
        return .deleted
    }
}
