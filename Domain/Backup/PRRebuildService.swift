import Foundation
import SwiftData

/// PRIndex is derived from completed sessions, so it is not part of the backup. After an import (and its wipe) it is
/// rebuilt here, replacing whatever was there: a stale index must not outlive the data it was derived from, and an
/// empty one would make the first lift after a restore a false PR.
enum PRRebuildService {

    /// Replays completed sessions oldest first with the same metric as `PRService.updatePR` (best single-set volume,
    /// a strictly greater set replaces the best). `bestDate` is the date of the session that set the best.
    static func rebuild(in context: ModelContext) throws {
        for existing in try context.fetch(FetchDescriptor<PRIndex>()) {
            context.delete(existing)
        }

        let sessions = try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )

        var bestByExercise: [String: PRIndex] = [:]
        for session in sessions where session.status == .completed {
            for item in session.items.sorted(by: { $0.order < $1.order }) {
                guard let best = PRService.bestSet(in: item) else { continue }

                if let current = bestByExercise[item.exerciseId] {
                    guard best.volume > current.bestSetVolume else { continue }
                    current.bestSetVolume = best.volume
                    current.bestLoad = best.load
                    current.bestReps = best.reps
                    current.bestDate = session.date
                } else {
                    let name = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })?.name
                        ?? item.exerciseNameSnapshot
                        ?? "Unknown"
                    let pr = PRIndex(
                        exerciseId: item.exerciseId,
                        exerciseName: name,
                        bestSetVolume: best.volume,
                        bestLoad: best.load,
                        bestReps: best.reps,
                        bestDate: session.date
                    )
                    context.insert(pr)
                    bestByExercise[item.exerciseId] = pr
                }
            }
        }

        try context.save()
    }
}
