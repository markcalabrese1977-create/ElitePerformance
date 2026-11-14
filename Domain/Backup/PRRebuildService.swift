import Foundation
import SwiftData

/// PRIndex is derived from completed sessions, so it is not part of the backup. After an import (and its wipe) it is
/// rebuilt here, replacing whatever was there: a stale index must not outlive the data it was derived from, and an
/// empty one would make the first lift after a restore a false PR.
enum PRRebuildService {

    /// Rebuilds the index with the single PR definition (`PersonalRecords`): the best working-set e1RM per canonical
    /// exercise over every completed session, maintenance and deload included, with a bodyweight lift measured at the
    /// lifter's body weight (no body weight, no PR for it). `bestDate` is the date of the session that set the best.
    ///
    /// `recomputeFlags`: also rewrite every completed session's `SessionItem.isPR` from the same records (the one-time
    /// `PRIndexRuleBackfill` does). A backup import leaves it false: `isPR` is part of the backup and must round-trip as carried.
    static func rebuild(in context: ModelContext, recomputeFlags: Bool = false) throws {
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
        if recomputeFlags { Self.recomputeFlags(sessions: sessions, records: records) }
        try context.save()
    }

    /// `SessionItem.isPR` is derived data: true exactly on the item whose session beat the lift's earlier record (a record
    /// EVENT of `PersonalRecords`, a lift's first-ever session being a baseline, not a record). Every completed session's
    /// items are rewritten so the flags always match the rebuilt index; planned and in-progress items are left alone.
    /// Only the flag changes (no `updatedAt`). Returns (flagged items, sessions with a flagged item).
    @discardableResult
    static func recomputeFlags(sessions: [Session], records: AnalyticsSnapshot) -> (items: Int, sessions: Int) {
        var recordKeys = Set<String>()
        for e in PersonalRecords.events(from: records.sets) where !e.isBaseline { recordKeys.insert("\(e.sessionKey)|\(e.exerciseId)") }
        var flaggedItems = 0, flaggedSessions = 0
        for s in sessions where s.status == .completed {
            let key = s.id?.uuidString ?? "\(s.persistentModelID)"
            // the best item of a lift in a session carries the flag (a session can hold the same lift twice)
            var carrier: [String: SessionItem] = [:]
            for item in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                guard recordKeys.contains("\(key)|\(id)") else { continue }
                let bw = ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId)
                let mine = BestSetRule.best(of: item, bodyWeight: nil)?.e1RM ?? (bw ? 0 : 0)
                let theirs = carrier[id].flatMap { BestSetRule.best(of: $0, bodyWeight: nil)?.e1RM } ?? -1
                if carrier[id] == nil || mine > theirs { carrier[id] = item }
            }
            var any = false
            for item in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let flag = carrier[id] === item
                if item.isPR != flag { item.isPR = flag }
                if flag { flaggedItems += 1; any = true }
            }
            if any { flaggedSessions += 1 }
        }
        return (flaggedItems, flaggedSessions)
    }
}
