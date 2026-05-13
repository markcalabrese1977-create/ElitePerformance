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
        guard session.status == .inProgress || session.status == .completed else { return }
        // 1.4 — Fetch UserProfile for load increment preference
        let profileDescriptor = FetchDescriptor<UserProfile>()
        let profileIncrement: Double? = try? context.fetch(profileDescriptor).first?.minLoadIncrement
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

            // 0.4 + 1.2 — CoachingEngine load suggestion + RIR-adjusted carry-forward
            let sourceMesoPhase = session.mesoPhase

            let baseLoad: Double = {
                if let recommendation = CoachingEngine.recommend(for: sourceItem, minLoadIncrement: profileIncrement, mesoPhase: sourceMesoPhase),
                   let nextLoad = recommendation.nextSuggestedLoad,
                   nextLoad > 0 {
                    return nextLoad
                }
                return sourceItem.suggestedLoad
            }()

            guard baseLoad > 0 else { continue }

            // 1.2 — RIR delta adjustment using e1RM
            let sourceRIR = sourceItem.targetRIR
            let targetRIR = targetItem.targetRIR
            let sourceReps = sourceItem.targetReps
            let targetReps = targetItem.targetReps

            let adjustedLoad: Double = {
                // Only adjust if RIR or reps differ between sessions
                guard sourceRIR != targetRIR || sourceReps != targetReps else {
                    return baseLoad
                }
                // Compute e1RM from the coached/carried load at source conditions
                let e1rm = E1RMCalculator.e1RM(load: baseLoad, reps: sourceReps)
                guard e1rm > 0 else { return baseLoad }
                // Compute target load at new RIR and rep target
                let rawLoad = E1RMCalculator.load(for: e1rm, reps: targetReps, targetRIR: targetRIR)
                guard rawLoad > 0 else { return baseLoad }
                let increment = profileIncrement ?? 2.5
                return E1RMCalculator.rounded(rawLoad, increment: increment)
            }()

            let finalLoad = min(adjustedLoad, baseLoad * 2.0) // sanity cap

            targetItem.suggestedLoad = finalLoad
                        targetItem.plannedLoadsBySet = Array(
                            repeating: finalLoad,
                            count: targetItem.plannedLoadsBySet.count
                        )

                        // Pain carry-forward — write warning to next session if pain was flagged
                        let sourcePainFlagged = sourceItem.setFeedbackBySet.contains {
                            $0 == SetFeedback.pain.rawValue
                        }
                        if sourcePainFlagged {
                            targetItem.coachNote = "⚠️ Pain was flagged in your last session for this exercise. Reassess before loading."
                        }

                        // Soreness/disruption carry-forward — softer advisory
                        let sourceFatigueFlagged = sourceItem.setFeedbackBySet.contains {
                            $0 == SetFeedback.soreness.rawValue || $0 == SetFeedback.disruption.rawValue
                        }
                        if sourceFatigueFlagged && !sourcePainFlagged {
                            targetItem.coachNote = "ℹ️ Soreness or disruption was flagged last session. Monitor how this feels before pushing load."
                        }
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

