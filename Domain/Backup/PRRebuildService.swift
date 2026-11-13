import Foundation
import SwiftData

/// PRIndex is derived from completed sessions, so it is not part of the backup. After an import (and its wipe) it is
/// rebuilt here, replacing whatever was there: a stale index must not outlive the data it was derived from, and an
/// empty one would make the first lift after a restore a false PR.
enum PRRebuildService {

    /// Rebuilds the index with the single PR definition (`PersonalRecords`): the best working-set e1RM per canonical
    /// exercise over every completed session, maintenance and deload included, with a bodyweight lift measured at the
    /// lifter's body weight (no body weight, no PR for it). `bestDate` is the date of the session that set the best.
    static func rebuild(in context: ModelContext) throws {
        for existing in try context.fetch(FetchDescriptor<PRIndex>()) {
            context.delete(existing)
        }

        let sessions = try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )
        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let bodyWeight = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.bodyWeight
        let records = SetRecordBuilder.build(sessions: sessions, customExercises: customs, bodyWeight: bodyWeight)

        var names: [String: String] = [:]
        for session in sessions { for item in session.items {
            let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
            if names[id] == nil, let n = item.exerciseNameSnapshot, !n.isEmpty { names[id] = n }
        } }
        for best in PersonalRecords.bests(from: records.sets).values.sorted(by: { $0.exerciseId < $1.exerciseId }) {
            let name = ExerciseCatalog.all.first(where: { $0.id == best.exerciseId })?.name ?? names[best.exerciseId] ?? "Unknown"
            context.insert(PRIndex(
                exerciseId: best.exerciseId, exerciseName: name, bestSetVolume: best.load * Double(best.reps),
                bestLoad: best.load, bestReps: best.reps, bestDate: best.date
            ))
        }
        try context.save()
    }
}
