import Foundation
import SwiftData

/// Handles reading/writing PR data from SwiftData.
struct PRService {

    /// Update the PR index based on a single SessionItem's newly saved logs.
    /// Uses best single-set volume (load * reps) as the PR metric.
    static func updatePR(for item: SessionItem, in context: ModelContext) {
        let count = min(item.actualReps.count, item.actualLoads.count)
        guard count > 0 else {
            item.isPR = false
            return
        }

        var bestVolume: Double = 0
        var bestLoad: Double = 0
        var bestReps: Int = 0

        for i in 0..<count {
            let reps = item.actualReps[i]
            let load = item.actualLoads[i]
            guard reps > 0 && load > 0 else { continue }

            let volume = Double(reps) * load
            if volume > bestVolume {
                bestVolume = volume
                bestLoad = load
                bestReps = reps
            }
        }

        // No meaningful work, nothing to do.
        guard bestVolume > 0 else {
            item.isPR = false
            return
        }

        // Capture exerciseId as a plain String so the predicate macro doesn't get cute.
        let exerciseId = item.exerciseId

        let descriptor = FetchDescriptor<PRIndex>(
            predicate: #Predicate<PRIndex> { pr in
                pr.exerciseId == exerciseId
            }
        )

        do {
            let results = try context.fetch(descriptor)
            if let existing = results.first {
                if bestVolume > existing.bestSetVolume {
                    // New PR!
                    existing.bestSetVolume = bestVolume
                    existing.bestLoad = bestLoad
                    existing.bestReps = bestReps
                    existing.bestDate = Date()
                    item.isPR = true
                } else {
                    // Good work, but not a PR.
                    item.isPR = false
                }
            } else {
                // No PR yet for this exercise — this becomes the baseline.
                let exerciseName = ExerciseCatalog.all.first(where: { $0.id == exerciseId })?.name
                    ?? "Unknown"

                let pr = PRIndex(
                    exerciseId: exerciseId,
                    exerciseName: exerciseName,
                    bestSetVolume: bestVolume,
                    bestLoad: bestLoad,
                    bestReps: bestReps,
                    bestDate: Date()
                )
                context.insert(pr)
                item.isPR = true
            }
        } catch {
            // If the fetch fails for some reason, don't crash the app.
            item.isPR = false
        }
    }

    /// Convenience getter if we want to display current PR elsewhere.
    static func currentPR(for exerciseId: String, in context: ModelContext) -> PRIndex? {
        let idCopy = exerciseId
        let descriptor = FetchDescriptor<PRIndex>(
            predicate: #Predicate<PRIndex> { pr in
                pr.exerciseId == idCopy
            }
        )

        return try? context.fetch(descriptor).first
    }
}
