import Foundation
import SwiftData

/// Carries PLAN data (target reps/sets/RIR and per-set planned load/rep arrays)
/// forward from a completed session into the *next* future session that
/// contains the same exercise(s).
///
/// v1 behavior (conservative):
/// - Only runs when a session is marked `.completed`.
/// - For each exercise in that session:
///   - Find the next future Session (by date) that has the same `exerciseId`.
///   - If that future SessionItem has an "empty" plan (no per-set plan and 0 load),
///     copy the plan fields from the completed session's item.
/// - Never overwrites an already-planned future SessionItem.
struct PlanMemoryEngine {

    let context: ModelContext

    /// Carry today's plan forward into the next future session(s)
    /// where plan is still empty.
    func carryForwardPlans(from session: Session) {
        // Fetch all sessions in chronological order
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )

        guard let allSessions = try? context.fetch(descriptor),
              let currentIndex = allSessions.firstIndex(where: { $0.persistentModelID == session.persistentModelID })
        else {
            return
        }

        let futureSessions = allSessions.suffix(from: currentIndex + 1)
        guard !futureSessions.isEmpty else { return }

        // For each exercise in the completed session, push its plan to the
        // *next* session in the future that contains the same exerciseId.
        for sourceItem in session.items {
            // If the current exercise has no meaningful plan, skip it.
            guard hasMeaningfulPlan(sourceItem) else { continue }

            // Find the next future session that includes this exercise
            guard let nextSession = futureSessions.first(where: { future in
                future.items.contains(where: { $0.exerciseId == sourceItem.exerciseId })
            }) else {
                continue
            }

            guard let targetItem = nextSession.items.first(where: { $0.exerciseId == sourceItem.exerciseId }) else {
                continue
            }

            // Only fill if that future item doesn't already have its own plan.
            guard isPlanEffectivelyEmpty(targetItem) else { continue }

            // Copy aggregate targets
            targetItem.targetReps    = sourceItem.targetReps
            targetItem.targetSets    = sourceItem.targetSets
            targetItem.targetRIR     = sourceItem.targetRIR
            targetItem.suggestedLoad = sourceItem.suggestedLoad

            // Copy per-set plan arrays
            targetItem.plannedRepsBySet  = sourceItem.plannedRepsBySet
            targetItem.plannedLoadsBySet = sourceItem.plannedLoadsBySet
        }
    }

    // MARK: - Helpers

    /// Treat a plan as "empty" if:
    /// - All planned loads are 0, AND
    /// - The aggregate suggestedLoad is 0.
    ///
    /// We intentionally ignore reps here because the program generator
    /// pre-fills target reps/RIR across the meso. We still want Plan Memory
    /// to fill in *loads* for those sessions.
    private func isPlanEffectivelyEmpty(_ item: SessionItem) -> Bool {
        let allLoadsZero = item.plannedLoadsBySet.allSatisfy { $0 == 0 }
        return allLoadsZero && item.suggestedLoad == 0
    }

    /// Treat a source plan as "meaningful" if it has either:
    /// - Any non-zero planned reps/load, OR
    /// - A non-zero suggestedLoad.
    private func hasMeaningfulPlan(_ item: SessionItem) -> Bool {
        let anyPlannedReps  = item.plannedRepsBySet.contains(where: { $0 > 0 })
        let anyPlannedLoads = item.plannedLoadsBySet.contains(where: { $0 > 0 })
        return anyPlannedReps || anyPlannedLoads || item.suggestedLoad > 0
    }
}

