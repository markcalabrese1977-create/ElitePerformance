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

            guard let targetItem = Self.nextTargetItem(
                for: sourceItem,
                after: session,
                in: allSessions
            ) else { continue }

            // Already-materialized future plan (not empty): the seed path below only
            // fills empty plans, so an earned bump would never reach an anchored/
            // carried future session (the Cut-3 write-back gap). Instead propagate the
            // bump directly onto the stored plan — but only when the user has NOT
            // manually edited it (planEdited == false) and only for a real increase
            // (hold/nil/BW/deload never write). Immediate-next occurrence scope: this
            // loop already targets the first future session containing the exercise.
            if !isPlanEffectivelyEmpty(targetItem) {
                propagateEarnedBumpToMaterializedItem(
                    sourceItem: sourceItem,
                    targetItem: targetItem,
                    session: session,
                    allSessions: allSessions,
                    activeMesoIDs: activeMesoIDs,
                    loadIncrement: loadIncrement,
                    bodyWeight: bodyWeight,
                    customExercises: customExercises,
                    progressionEnabled: progressionEnabled
                )
                continue
            }

            // FIX B — Bodyweight exercises never carry a numeric load forward. After the
            // one-time migration their suggestedLoad/plannedLoadsBySet are already 0, but
            // this guard makes sure a stray nonzero phantom (from any pre-fix path) can't
            // be propagated. project() also returns nil for BW, so the progression block
            // below is inert for them either way. Uses the customExercises-aware overload
            // (customExercises fetched at the top of this function). Loaded exercises are
            // unaffected.
            let isBodyweight = ExerciseCatalog.isBodyweight(
                exerciseId: sourceItem.exerciseId,
                customExercises: customExercises
            )

            // Carry forward load only — never overwrite prescription fields.
            // targetReps, targetRIR, repMin, repMax are set by the materializer
            // at seed time and belong to the target session's wave, not the source's.
            targetItem.suggestedLoad = isBodyweight ? 0 : sourceItem.suggestedLoad

            // BUG#1 fix: resize to targetItem.targetSets, not sourceItem's array length —
            // a wave transition that changes the prescribed set count (e.g. wave A → B:
            // 3 → 4 sets) used to leave plannedLoadsBySet undersized/oversized relative
            // to targetSets. See resizedToTargetSets's doc comment for the extend/
            // truncate rule.
            targetItem.plannedLoadsBySet = isBodyweight
                ? Array(repeating: 0, count: targetItem.targetSets)
                : resizedToTargetSets(
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

            // This is the EMPTY-TARGET SEED path: a target that already carried a
            // plan was routed to propagateEarnedBumpToMaterializedItem above and
            // `continue`d, so `isPlanEffectivelyEmpty(targetItem)` was true on
            // entry. (It is NOT true here any more — the carry-forward above has
            // already written sourceItem.suggestedLoad into targetItem, so reading
            // targetItem.suggestedLoad at this point tells you nothing about what
            // the target originally held.)
            //
            // Floor cap — the same rule as CoachingEngine.qualifyingBump. project()
            // returns the e1RM floor AS its suggestedLoad whenever the floor wins
            // (LoadProjectionService :386), and that floor is derived from all-time,
            // cross-block, cross-letter history, so it can sit far above the most
            // recent working load. On this path the projection is the only writer
            // whenever recommend() declines to return a load — a pain flag, or no
            // logged actuals, both of which are ordinary UNFLAGGED sessions — so an
            // uncapped floor would seed e.g. 250 off a 180 session. Never seed above
            // the last working load + one increment.
            //
            // lastLoad is nil only on project()'s early exits, where no prior
            // working load was resolved at all — nothing to step off, nothing to cap.
            if let projection = projection, projection.suggestedLoad > 0 {
                let floorCapped: Double = {
                    guard let lastLoad = projection.lastLoad, lastLoad > 0 else {
                        return projection.suggestedLoad
                    }
                    return min(projection.suggestedLoad, lastLoad + loadIncrement)
                }()
                let finalLoad = min(floorCapped, sourceItem.suggestedLoad * 2.0)
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
                consecutiveCleanCount: consecutiveCleanCount,
                // CUT 2 (input-only): hand project()'s already-computed data to
                // CoachingEngine. Not consumed by any decision yet — plumbing for
                // the single-authority cut. `projection` is nil-safe here.
                e1rmFloorLoad: projection?.e1rmFloorLoad,
                peakE1RM: projection?.peakE1RM,
                lastKnownLoad: projection?.lastLoad,
                // A targetItem exists by construction here (guarded above), so the
                // message may name it. Only nextSuggestedLoad is consumed below —
                // this keeps the message correct for any future caller of it.
                carryForwardTarget: .exists
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

    // MARK: - Canonical target resolution

    /// The materialized session item this exercise's result carries into.
    ///
    /// PER-LETTER ANCHORING. A wave letter is a WEEK property here (the
    /// materializer stamps every item in a session with the week rule's wave —
    /// DUPSessionMaterializer.makeSession), and the user's program requires each
    /// lift to progress per letter: week 4's A anchors from week 1's A, never
    /// from the B or C weeks in between. So the target is the next session in the
    /// SAME block, on the SAME day slot, in the SAME wave — three weeks out in a
    /// 3-wave rotation, not "whatever session comes next".
    ///
    /// Both the day and the wave axis are required, and neither is redundant:
    /// - Wave alone still lets Friday's A result land on Sunday's A item, because
    ///   every day of an A week shares the letter. Several exerciseIds legitimately
    ///   appear on two days in the same week with identical per-wave prescriptions
    ///   (see TemplateSlotKeyInvariantTests — repeating a lift across days is
    ///   deliberate programming, not a template defect).
    /// - Day alone still lets an A result land on the next week's B item.
    ///
    /// There is deliberately NO fallback to the chronological next occurrence when
    /// no same-letter/same-day session exists. Such a fallback reintroduces exactly
    /// the cross-wave write this resolves, at the END of every letter's chain: the
    /// last A week (week 7 in a 10-week block) would find no later A and fall
    /// through to week 8's B, writing an A-wave load onto a B-wave prescription.
    /// Returning nil there is correct — the chain has ended, and there is nothing
    /// left in the block to anchor.
    ///
    /// Sessions whose items carry no wave (`waveRaw` nil or empty) are not part of
    /// any letter rotation — non-DUP/legacy/hand-built sessions — so they keep the
    /// original chronological behavior unchanged.
    ///
    /// SINGLE SOURCE OF TRUTH for "the session this exercise's result targets."
    /// carry-forward uses it to pick the write target; the SessionView message path
    /// uses it to `project()` the SAME target session's wave, so the floor/peak the
    /// message shows are identical to the ones the write-back applies (message ==
    /// stored value in all cases). Returns nil when no eligible future session is
    /// materialized for this exercise — in which case the write-back no-ops too.
    static func nextTargetItem(
        for sourceItem: SessionItem,
        after session: Session,
        in sessions: [Session]
    ) -> SessionItem? {
        // Canonical exerciseId matching (never raw) — mirrors the hardened coaching
        // path (LoadProjectionService, lastKnownLoad). Raw `==` misses/mismatches
        // when a swap or custom exercise sits between source and target sessions
        // (the D5-class risk). canonicalExerciseId is a pure String->String resolver,
        // so no customExercises context is needed here.
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: sourceItem.exerciseId)
        let ordered = sessions.sorted { $0.date < $1.date }
        guard let currentIndex = ordered.firstIndex(where: {
            $0.persistentModelID == session.persistentModelID
        }) else { return nil }
        let future = ordered.suffix(from: currentIndex + 1)

        func matchingItem(in candidate: Session) -> SessionItem? {
            candidate.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            })
        }

        // No wave on the source → not in a letter rotation; legacy chronological path.
        guard let sourceWave = sourceItem.waveRaw?.lowercased(), !sourceWave.isEmpty else {
            return future.lazy.compactMap(matchingItem).first
        }

        // Block identity by persistent id so a nil meso matches only another nil
        // meso — an unassigned session never anchors into a real block's rotation.
        let sourceMesoID = session.meso?.persistentModelID
        let sourceDayLabel = session.dayLabel

        for candidate in future {
            guard candidate.meso?.persistentModelID == sourceMesoID else { continue }
            guard candidate.dayLabel == sourceDayLabel else { continue }
            guard let item = matchingItem(in: candidate) else { continue }
            // Wave read from the matched ITEM, symmetric with `sourceItem.waveRaw`.
            guard item.waveRaw?.lowercased() == sourceWave else { continue }
            return item
        }
        return nil
    }

    // MARK: - Write-back to already-materialized future sessions (Cut 3)

    /// Writes an EARNED bump onto an already-materialized next-occurrence plan.
    ///
    /// Only fires when:
    /// - progression is enabled,
    /// - the target plan was NOT user-edited (`planEdited == false`) — a manual
    ///   edit is preserved, never clobbered,
    /// - the target is not a deload/bodyweight item (those never take a numeric bump),
    /// - and `recommend` returns a real INCREASE over the target's current load
    ///   (hold / decrease / nil do not write, so BW/deload/first-session no-op).
    ///
    /// The value is written raw — `CoachingEngine.recommend` self-caps at
    /// baseLoad * 2.0, mirroring the empty-seed path. `planEdited` stays false
    /// (this is an auto write). Scope is the immediate next occurrence only.
    private func propagateEarnedBumpToMaterializedItem(
        sourceItem: SessionItem,
        targetItem: SessionItem,
        session: Session,
        allSessions: [Session],
        activeMesoIDs: Set<PersistentIdentifier>,
        loadIncrement: Double,
        bodyWeight: Double?,
        customExercises: [CustomExercise],
        progressionEnabled: Bool
    ) {
        guard progressionEnabled else { return }
        guard !targetItem.planEdited else { return }                       // preserve user edit
        // Flagged source: a temporarily/deliberately reduced load never earns a
        // write-back. CoachingEngine RULE 4b already returns a nil load here, so
        // this is belt-and-braces — it also covers any non-bump recommendation.
        if sourceItem.loadOverrideReason?.suppressesEarnedProgression == true { return }
        guard targetItem.waveRaw?.lowercased() != "deload" else { return } // deload holds
        if ExerciseCatalog.isBodyweight(exerciseId: targetItem.exerciseId, customExercises: customExercises) {
            return                                                          // BW never takes a numeric bump
        }

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

        let consecutiveCleanCount = LoadProjectionService.consecutiveCleanCount(
            exerciseId: sourceItem.exerciseId,
            waveRaw: sourceItem.waveRaw,
            repMin: sourceItem.repMin ?? sourceItem.targetReps,
            allSessions: allSessions,
            referenceDate: session.date
        )

        guard let recommendation = CoachingEngine.recommend(
            for: sourceItem,
            minLoadIncrement: loadIncrement,
            mesoPhase: session.mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount,
            e1rmFloorLoad: projection?.e1rmFloorLoad,
            peakE1RM: projection?.peakE1RM,
            lastKnownLoad: projection?.lastLoad,
            carryForwardTarget: .exists   // targetItem is non-nil by construction
        ), let recommendedLoad = recommendation.nextSuggestedLoad else { return }

        // Only an ACTUAL increase propagates. Hold (== current) or decrease is left
        // untouched, so the already-materialized plan is never lowered.
        guard recommendedLoad > targetItem.suggestedLoad else { return }

        targetItem.suggestedLoad = recommendedLoad
        targetItem.plannedLoadsBySet = Array(
            repeating: recommendedLoad,
            count: max(targetItem.plannedLoadsBySet.count, targetItem.targetSets)
        )
        // planEdited intentionally left false — this is an automatic write.
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
