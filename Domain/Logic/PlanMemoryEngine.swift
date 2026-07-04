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

    // Flat 60% reduction for deload weeks. TODO (Phase 1.2 roadmap): replace with RIR-derived
    // reduction via LoadProjectionService once deload-week RIR targets are reliably seeded.
    private let deloadLoadReductionFactor: Double = 0.6

    /// Carry today's plan forward into the next future session(s)
    /// where plan is still empty.
    func carryForwardPlans(from session: Session) {
        guard session.status == .inProgress || session.status == .completed else { return }

        // Fetch UserProfile for load increment preference
        let profileDescriptor = FetchDescriptor<UserProfile>()
        let profile = try? context.fetch(profileDescriptor).first
        let loadIncrement: Double = profile?.minLoadIncrement ?? 2.5
        let bodyWeight = profile?.bodyWeight
        let customExercises = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []

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

            // BUG#1 fix: resize to targetItem.targetSets, not sourceItem's array length —
            // a wave transition that changes the prescribed set count (e.g. wave A → B:
            // 3 → 4 sets) used to leave plannedLoadsBySet undersized/oversized relative
            // to targetSets. See resizedToTargetSets's doc comment for the extend/
            // truncate rule.
            targetItem.plannedLoadsBySet = resizedToTargetSets(
                sourceItem.plannedLoadsBySet,
                targetCount: targetItem.targetSets
            )

            guard progressionEnabled else { continue }

            // Maintenance/deload items hold their carried-forward load — no progression
            // suggestion, no volume auto-regulation. Mirrors the hold applied by
            // ProgramDayDetailView.autoGenerateSuggestedLoadsFromHistoryForThisDay's
            // isMaintenanceSession check, but via waveRaw since this runs automatically
            // on every session completion, not just when the user taps Auto+.
            if targetItem.waveRaw?.lowercased() == "deload" {
                targetItem.suggestedLoad = E1RMCalculator.rounded(
                    targetItem.suggestedLoad * deloadLoadReductionFactor,
                    increment: loadIncrement
                )
                targetItem.plannedLoadsBySet = targetItem.plannedLoadsBySet.map {
                    E1RMCalculator.rounded($0 * deloadLoadReductionFactor, increment: loadIncrement)
                }
                continue
            }

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
                bodyWeight: bodyWeight,
                customExercises: customExercises
            )

            if let projection = projection, projection.suggestedLoad > 0 {
                let finalLoad = min(projection.suggestedLoad, sourceItem.suggestedLoad * 2.0)
                targetItem.suggestedLoad = finalLoad
                targetItem.plannedLoadsBySet = Array(
                    repeating: finalLoad,
                    count: targetItem.plannedLoadsBySet.count
                )
            }

            // Phase 0.4 — CoachingEngine is the authoritative load layer.
            // recommend() reads the SOURCE item's actuals; when it returns a
            // non-nil nextSuggestedLoad it overwrites project()'s value (holds
            // included). When it returns nil (pain, no baseline; deload is
            // already handled by the deload continue above), project()'s value
            // persists as a conservative floor. The value is written raw —
            // recommend() self-caps at baseLoad * 2.0, so no second clamp.
            let consecutiveCleanCount = LoadProjectionService.consecutiveCleanCount(
                exerciseId: sourceItem.exerciseId,
                waveRaw: sourceItem.waveRaw,
                repMin: sourceItem.repMin ?? sourceItem.targetReps,
                allSessions: allSessions,
                referenceDate: session.date
            )
            if let recommendation = CoachingEngine.recommend(
                for: sourceItem,
                minLoadIncrement: loadIncrement,
                mesoPhase: session.mesoPhase,
                consecutiveCleanCount: consecutiveCleanCount
            ), let recommendedLoad = recommendation.nextSuggestedLoad {
                targetItem.suggestedLoad = recommendedLoad
                targetItem.plannedLoadsBySet = Array(
                    repeating: recommendedLoad,
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

    /// Resizes `array` to exactly `targetCount` elements.
    /// - If `array.count < targetCount`: extends by repeating the array's LAST element
    ///   for the additional sets — a coach naturally continues a wave's last working
    ///   set into newly-added sets, rather than leaving them at 0 or some arbitrary
    ///   value. Falls back to zeros if `array` is empty (nothing to repeat).
    /// - If `array.count > targetCount`: truncates to the first `targetCount` elements.
    ///   plannedLoadsBySet is consumed by index in set order (index 0 == set 1,
    ///   confirmed via SessionView.swift's `let setIndex = idx + 1`), so keeping the
    ///   first N sets and dropping the trailing ones is correct.
    /// - If equal: returned unchanged.
    private func resizedToTargetSets(_ array: [Double], targetCount: Int) -> [Double] {
        guard targetCount >= 0 else { return array }
        if array.count == targetCount {
            return array
        } else if array.count < targetCount {
            guard let last = array.last else {
                return Array(repeating: 0, count: targetCount)
            }
            return array + Array(repeating: last, count: targetCount - array.count)
        } else {
            return Array(array.prefix(targetCount))
        }
    }

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
