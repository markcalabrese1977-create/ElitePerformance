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

        // Fetch UserProfile for load increment preference
        let profileDescriptor = FetchDescriptor<UserProfile>()
        let profile = try? context.fetch(profileDescriptor).first
        let loadIncrement: Double = profile?.minLoadIncrement ?? 2.5
        let bodyWeight = profile?.bodyWeight

        // Auto-progression gate
        let progressionEnabled: Bool = {
            let descriptor = FetchDescriptor<User>()
            return (try? context.fetch(descriptor).first?.progressionEnabled) ?? true
        }()

        // Active meso session IDs for current meso peak calculation
        let activeMesoIDs = LoadProjectionService.activeMesoSessionIDs(from: context)

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

        for sourceItem in session.items {
            guard hasMeaningfulPlan(sourceItem) else { continue }

            guard let nextSession = futureSessions.first(where: { future in
                future.items.contains(where: { $0.exerciseId == sourceItem.exerciseId })
            }) else { continue }

            guard let targetItem = nextSession.items.first(where: {
                $0.exerciseId == sourceItem.exerciseId
            }) else { continue }

            guard isPlanEffectivelyEmpty(targetItem) else { continue }

            // Carry forward load only — never overwrite prescription fields.
            // targetReps, targetRIR, repMin, repMax are set by the materializer
            // at seed time and belong to the target session's wave, not the source's.
            targetItem.suggestedLoad = sourceItem.suggestedLoad

            targetItem.plannedLoadsBySet = sourceItem.plannedLoadsBySet

            guard progressionEnabled else { continue }

            // MARK: - Load Projection via LoadProjectionService

            let projection = LoadProjectionService.project(
                exerciseId: targetItem.exerciseId,
                targetReps: targetItem.targetReps,
                targetRIR: targetItem.targetRIR,
                repMin: targetItem.repMin ?? targetItem.targetReps,
                repMax: targetItem.repMax ?? targetItem.targetReps,
                currentWaveRaw: targetItem.waveRaw,
                allSessions: allSessions,
                activeMesoSessionIDs: activeMesoIDs,
                loadIncrement: loadIncrement,
                bodyWeight: bodyWeight
            )

            if let projection = projection, projection.suggestedLoad > 0 {
                let finalLoad = min(projection.suggestedLoad, sourceItem.suggestedLoad * 2.0)
                targetItem.suggestedLoad = finalLoad
                targetItem.plannedLoadsBySet = Array(
                    repeating: finalLoad,
                    count: targetItem.plannedLoadsBySet.count
                )
            }
            
            // Pain carry-forward
            let sourcePainFlagged = sourceItem.setFeedbackBySet.contains {
                $0 == SetFeedback.pain.rawValue
            }
            if sourcePainFlagged {
                targetItem.coachNote = "⚠️ Pain was flagged in your last session for this exercise. Reassess before loading."
            }

            // Soreness/disruption carry-forward
            let sourceFatigueFlagged = sourceItem.setFeedbackBySet.contains {
                $0 == SetFeedback.soreness.rawValue || $0 == SetFeedback.disruption.rawValue
            }
            if sourceFatigueFlagged && !sourcePainFlagged {
                targetItem.coachNote = "ℹ️ Soreness or disruption was flagged last session. Monitor how this feels before pushing load."
            }

            // Volume auto-regulation
            let recentItems: [SessionItem] = allSessions
                .prefix(currentIndex)
                .filter { $0.status == .completed }
                .suffix(3)
                .compactMap { $0.items.first { $0.exerciseId == sourceItem.exerciseId } }

            let signal = PlanMemoryEngine.volumeRegulationSignal(from: recentItems)

            if signal.setDelta != 0 {
                targetItem.targetSets = max(2, targetItem.targetSets + signal.setDelta)
                let fill = targetItem.suggestedLoad > 0 ? targetItem.suggestedLoad : sourceItem.suggestedLoad
                targetItem.plannedLoadsBySet = Array(repeating: fill, count: targetItem.targetSets)
            }

            // Volume regulation note
                        if let reason = signal.reason, targetItem.coachNote == nil {
                            targetItem.coachNote = reason
                        }

                        // Progression coaching note — only if no higher-priority note already set
                        if let projection = projection, targetItem.coachNote == nil {
                            let loadStr = String(format: "%.1f", projection.suggestedLoad)
                            switch projection.basis {
                            case .consecutiveCleanProgression:
                                targetItem.coachNote = "✅ Two clean sessions confirmed. Load stepping up to \(loadStr)."
                            case .sameWaveProgression where projection.consecutiveCleanCount == 1:
                                targetItem.coachNote = "ℹ️ One more clean session at \(loadStr) earns the increase."
                            case .currentMesoPeak, .crossMesoBaseline:
                                targetItem.coachNote = "ℹ️ Load set from your best performance this meso."
                            default:
                                break
                            }
                        }
        }
    }

    // MARK: - Helpers

    private func isPlanEffectivelyEmpty(_ item: SessionItem) -> Bool {
        let allLoadsZero = item.plannedLoadsBySet.allSatisfy { $0 == 0 }
        return allLoadsZero && item.suggestedLoad == 0
    }

    private func hasMeaningfulPlan(_ item: SessionItem) -> Bool {
        let anyPlannedReps  = item.plannedRepsBySet.contains(where: { $0 > 0 })
        let anyPlannedLoads = item.plannedLoadsBySet.contains(where: { $0 > 0 })
        return anyPlannedReps || anyPlannedLoads || item.suggestedLoad > 0
    }

    // MARK: - Volume Auto-Regulation

    static func volumeRegulationSignal(from recentItems: [SessionItem]) -> VolumeRegulationSignal {
        guard !recentItems.isEmpty else { return .neutral }

        let anyPain = recentItems.contains { item in
            item.setFeedbackBySet.contains { $0 == SetFeedback.pain.rawValue }
        }
        if anyPain {
            return VolumeRegulationSignal(
                action: .reduce,
                reason: "⚠️ Pain flagged in a recent session for this exercise. Volume reduced — reassess before loading.",
                setDelta: -1
            )
        }

        let fatigueSessionCount = recentItems.filter { item in
            item.setFeedbackBySet.contains {
                $0 == SetFeedback.soreness.rawValue || $0 == SetFeedback.disruption.rawValue
            }
        }.count

        if fatigueSessionCount >= 2 {
            return VolumeRegulationSignal(
                action: .reduce,
                reason: "ℹ️ Repeated fatigue signals across recent sessions. Set count reduced by 1 — rebuild before adding volume.",
                setDelta: -1
            )
        }

        if fatigueSessionCount == 1 {
            return VolumeRegulationSignal(
                action: .hold,
                reason: "ℹ️ Fatigue flagged in a recent session. Holding set count this session.",
                setDelta: 0
            )
        }

        let poorPumpSessionCount = recentItems.filter { item in
            item.pumpRatingsBySet.contains { PumpRating(rawValue: $0) == .poor }
        }.count

        if poorPumpSessionCount >= 2 {
            return VolumeRegulationSignal(
                action: .hold,
                reason: "ℹ️ Consistently poor pump signal across recent sessions. Holding volume before increasing.",
                setDelta: 0
            )
        }

        return .neutral
    }
}
