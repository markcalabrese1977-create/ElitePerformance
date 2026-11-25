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
/// - An already-planned future SessionItem is overwritten only by the propagate path,
///   and only when the user has not edited it (planEdited == false).
struct PlanMemoryEngine {

    let context: ModelContext
    /// The progression rules this engine reads. Always `.shipped` in the app; the lifter simulation injects the variants.
    var policy: CoachingPolicy = .shipped

    /// The profile / user settings every load decision reads. Shared by carry-forward and the
    /// one-time catch-up so both resolve exactly the same inputs.
    struct LoadPolicyInputs {
        let profile: UserProfile?
        let loadIncrement: Double
        /// The unit `loadIncrement` is in (loads themselves are stored lb).
        let unit: LoadUnit
        let bodyWeight: Double?
        let customExercises: [CustomExercise]
        let progressionEnabled: Bool
        let activeMesoIDs: Set<PersistentIdentifier>
    }

    func loadPolicyInputs() -> LoadPolicyInputs {
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        return LoadPolicyInputs(
            profile: profile,
            loadIncrement: profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: profile?.loadUnit ?? .lb),
            unit: profile?.loadUnit ?? .lb,
            bodyWeight: profile?.bodyWeight,
            customExercises: (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? [],
            progressionEnabled: (try? context.fetch(FetchDescriptor<User>()).first?.progressionEnabled) ?? true,
            activeMesoIDs: LoadProjectionService.activeMesoSessionIDs(from: context)
        )
    }

    /// Carry today's plan forward into the next future session(s)
    /// where plan is still empty.
    func carryForwardPlans(from session: Session) {
        guard session.status == .inProgress || session.status == .completed else { return }

        let inputs = loadPolicyInputs()
        let profile = inputs.profile
        let unit = inputs.unit
        let bodyWeight = inputs.bodyWeight
        let customExercises = inputs.customExercises
        let progressionEnabled = inputs.progressionEnabled
        let activeMesoIDs = inputs.activeMesoIDs

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
            // A plan with no load at all (a block the lifter wrote, a lift swapped in mid-block) has no baseline for the coach to
            // judge against: the load actually lifted becomes it, so the next session is written from what was done.
            let adoptedBaseline = Self.adoptPerformedLoadAsBaseline(
                sourceItem, isExempt: UserProfile.isProgressionExempt(exerciseId: sourceItem.exerciseId, profile: profile))
            // The step is per exercise: the lifter's own step for this lift, else the default load step.
            let loadIncrement = UserProfile.loadStep(for: sourceItem.exerciseId, profile: profile, unit: unit)
            guard hasMeaningfulPlan(sourceItem) else { continue }

            // Fixed-load exercise (per-exercise exemption): this source never writes an
            // increase anywhere. Resolved once per item from the profile fetched above.
            let isProgressionExempt = UserProfile.isProgressionExempt(
                exerciseId: sourceItem.exerciseId,
                profile: profile
            )

            guard let targetItem = Self.nextTargetItem(
                for: sourceItem,
                after: session,
                in: allSessions
            ) else { continue }
            // Whatever this iteration writes onto the target, it stamps (`updatedAt`, and `loadEverWritten` when a planned load moved).
            let targetFingerprint = targetItem.writeFingerprint()
            defer { targetItem.stampIfChanged(since: targetFingerprint) }

            // A write that exists only because of the adopted baseline never lands on a target the lifter edited by hand
            // (an edited plan with no load is a choice, not a gap).
            if adoptedBaseline && targetItem.planEdited { continue }

            // Already-materialized future plan (not empty): the seed path below only
            // fills empty plans, so an earned bump would never reach an anchored/
            // carried future session (the Cut-3 write-back gap). Instead propagate the
            // bump directly onto the stored plan — but only when the user has NOT
            // manually edited it (planEdited == false). Bump, hold and reduce all write;
            // nil/BW/deload/exempt/incomplete evidence never do. Immediate-next occurrence scope: this
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
                    progressionEnabled: progressionEnabled,
                    isProgressionExempt: isProgressionExempt
                )
                continue
            }

            // Max load: every load this path writes onto the (empty) target stays within the lifter's cap.
            // Runs when this iteration ends, after all the writes below (fixed-load and bodyweight: no cap).
            defer {
                Self.enforceMax(on: targetItem, profile: profile, customExercises: customExercises)
                PlaceholderRefresh.clearStaleNoHistoryNote(targetItem)   // a load now exists: "No recent history — set a load." no longer holds
            }
            let loadCap = CoachingEngine.LoadCap.resolve(
                for: sourceItem, in: session, allSessions: allSessions, profile: profile, customExercises: customExercises
            )

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
                ? Array(repeating: 0, count: targetItem.targetSets + targetItem.topCount)
                : carriedPlan(from: sourceItem, to: targetItem)

            guard progressionEnabled else { continue }

            // Maintenance/deload items hold their carried-forward load — no progression
            // suggestion, no volume auto-regulation. Mirrors the hold applied by
            // ProgramDayDetailView.autoGenerateSuggestedLoadsFromHistoryForThisDay's
            // isMaintenanceSession check, but via waveRaw since this runs automatically
            // on every session completion, not just when the user taps Auto+.
            if targetItem.waveRaw?.lowercased() == "deload" {
                // The one shared deload rule (DeloadRule): min(RIR-4 sizing at repMin, 0.95 x the latest non-deload
                // working load). Sets, RIR and the rep band stay as the template wrote them.
                let sizing = DeloadRule.sizing(
                    exerciseId: targetItem.exerciseId, repMin: targetItem.repMin ?? targetItem.targetReps,
                    in: allSessions, profile: profile, unit: unit, customExercises: customExercises,
                    referenceDate: session.date)
                // No logged non-deload working set to size from (a block that is deload-wave from its first session, such
                // as a maintenance program): the carried-forward load stands, already at deload level. It is never scaled again.
                if sizing.basis != .noHistory || isBodyweight {
                    targetItem.suggestedLoad = isBodyweight ? 0 : sizing.load
                    targetItem.plannedLoadsBySet = Array(repeating: targetItem.suggestedLoad, count: targetItem.plannedLoadsBySet.count)
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
                unit: unit,
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
                // Fixed-load exercise: the seed may not step ABOVE the last lifted
                // load at all (cap = lastLoad exactly, no increment). With no resolved
                // lastLoad there is nothing to cap against, so the carried-forward load
                // written above stands and the projection is not applied.
                let floorCapped: Double? = {
                    guard let lastLoad = projection.lastLoad, lastLoad > 0 else {
                        return isProgressionExempt ? nil : projection.suggestedLoad
                    }
                    let step = isProgressionExempt ? 0 : UnitAwareRounding.stepLb(loadIncrement, unit: unit)
                    return min(projection.suggestedLoad, lastLoad + step)
                }()
                if let floorCapped {
                    let finalLoad = min(floorCapped, sourceItem.suggestedLoad * 2.0)
                    targetItem.suggestedLoad = finalLoad
                    targetItem.plannedLoadsBySet = Self.propagatedPlan(finalLoad, for: targetItem)
                }
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
                policy: policy,
                minLoadIncrement: loadIncrement,
                unit: unit,
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
                carryForwardTarget: .exists,
                priorExposureWasRIRHold: CoachingEngine.priorExposureWasRIRHold(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
                releaseHintDue: CoachingEngine.releaseHintDue(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
                isProgressionExempt: isProgressionExempt,
                loadCap: loadCap
            ), let recommendedLoad = recommendation.nextSuggestedLoad {
                targetItem.suggestedLoad = recommendedLoad
                targetItem.plannedLoadsBySet = Self.propagatedPlan(
                    recommendedLoad,
                    top: targetItem.hasTopSet ? recommendation.nextTopLoad : nil,
                    for: targetItem
                )
            } else if targetItem.hasTopSet, let recommendation = CoachingEngine.recommend(
                for: sourceItem,
                policy: policy,
                minLoadIncrement: loadIncrement,
                unit: unit,
                mesoPhase: session.mesoPhase,
                consecutiveCleanCount: consecutiveCleanCount,
                e1rmFloorLoad: projection?.e1rmFloorLoad,
                peakE1RM: projection?.peakE1RM,
                lastKnownLoad: projection?.lastLoad,
                carryForwardTarget: .exists,
                priorExposureWasRIRHold: CoachingEngine.priorExposureWasRIRHold(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
                releaseHintDue: CoachingEngine.releaseHintDue(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
                isProgressionExempt: isProgressionExempt,
                loadCap: loadCap
            ), let topLoad = recommendation.nextTopLoad {
                // No back-off verdict (e.g. a skipped back-off) but the top set was logged: it writes
                // its own slot and leaves the back-off slots as carried.
                targetItem.plannedLoadsBySet = Self.propagatedPlan(nil, top: topLoad, for: targetItem)
            }

            // Incomplete evidence (fewer working sets than planned, capped at three): the seed is the last load lifted,
            // never a bump. The floor projection and the coach can each step above it from a partial session (60 x 20 on one
            // of three sets seeded 65), so whatever they wrote is held at that load. A hold or a reduce stands.
            if !CoachingEngine.hasSufficientPrimaryEvidence(sourceItem, policy: policy) {
                let logged = CoachingEngine.workingSetIndices(for: sourceItem).map { sourceItem.actualLoads[$0] }.max() ?? 0
                let lastLifted = logged > 0 ? logged : sourceItem.suggestedLoad
                if lastLifted > 0, targetItem.suggestedLoad > lastLifted {
                    targetItem.suggestedLoad = lastLifted
                    targetItem.plannedLoadsBySet = Self.propagatedPlan(lastLifted, for: targetItem)
                }
            }

            // A note left by an earlier pass that cites a load this plan no longer has is dropped here, so the
            // progression note below can be regenerated for the load just written.
            CoachNoteHygiene.clearIfStale(targetItem, unit: unit)

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
                let newCount = max(2, targetItem.targetSets + signal.setDelta)
                let fill = targetItem.suggestedLoad > 0 ? targetItem.suggestedLoad : sourceItem.suggestedLoad
                if targetItem.hasTopSet {
                    targetItem.resizeBackOffs(to: newCount, backOffLoad: fill)   // keeps the top tail and roles
                } else {
                    let oldCount = targetItem.targetSets
                    targetItem.setPrescribedSets(newCount)
                    targetItem.seedNewPlannedSets(from: oldCount)   // a new set's reps and RIR copy the set before it
                    targetItem.plannedLoadsBySet = Array(repeating: fill, count: targetItem.targetSets)
                }
            }

            // Volume regulation note
                        if let reason = signal.reason, targetItem.coachNote == nil {
                            targetItem.coachNote = reason
                        }

                        // Progression coaching note — only if no higher-priority note already set
                        if let projection = projection, targetItem.coachNote == nil, !isProgressionExempt {
                            let loadStr = LoadFormatter(unit: unit).oneDecimal(projection.suggestedLoad)
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

    /// An item whose plan carries no load (suggested and every planned slot 0) but whose sets were performed takes the held
    /// load (the last performed primary back-off set) as its baseline. Never for: a deload item, a bodyweight item, an item the
    /// lifter edited by hand (`planEdited`), a fixed-load exercise, or an item with a pain flag (pain makes no call), nor for
    /// one that already has a planned load.
    @discardableResult
    static func adoptPerformedLoadAsBaseline(_ item: SessionItem, isExempt: Bool = false) -> Bool {
        guard item.suggestedLoad <= 0, item.plannedLoadsBySet.allSatisfy({ $0 <= 0 }),
              !item.planEdited, !isExempt,
              item.waveRaw?.lowercased() != "deload",
              !item.setFeedbackBySet.contains(SetFeedback.pain.rawValue),
              !ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId),
              let held = CoachingEngine.heldLoad(for: item), held > 0 else { return false }
        let fingerprint = item.writeFingerprint()
        item.suggestedLoad = held
        PlaceholderRefresh.clearStaleNoHistoryNote(item)
        item.stampIfChanged(since: fingerprint)
        return true
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

        // No wave on the source → not in a letter rotation (a program the lifter wrote, or an older block). Deload items never
        // anchor a working session's result: skip them so the next working occurrence (past the deload) is the target.
        // When the session belongs to a block and has a day name, the chain is that block + that day: week 1's Upper A bench
        // feeds week 2's Upper A bench, never another day's bench. Without a block or a day name (hand-built sessions) it stays
        // the chronological next occurrence, as it always was.
        guard let sourceWave = sourceItem.waveRaw?.lowercased(), !sourceWave.isEmpty else {
            let chainMeso = session.meso?.persistentModelID
            let chainDay = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let byBlockAndDay = session.meso != nil && !chainDay.isEmpty
            return future.lazy.compactMap { candidate -> SessionItem? in
                if byBlockAndDay {
                    guard candidate.meso?.persistentModelID == chainMeso,
                          SessionDayLabelMatcher.matches(candidate.dayLabel, session.dayLabel) else { return nil }
                }
                guard let item = matchingItem(in: candidate),
                      item.waveRaw?.lowercased() != "deload" else { return nil }
                return item
            }.first
        }

        // Block identity by persistent id so a nil meso matches only another nil
        // meso — an unassigned session never anchors into a real block's rotation.
        let sourceMesoID = session.meso?.persistentModelID
        let sourceDayLabel = session.dayLabel

        for candidate in future {
            guard candidate.meso?.persistentModelID == sourceMesoID else { continue }
            guard SessionDayLabelMatcher.matches(candidate.dayLabel, sourceDayLabel) else { continue }
            guard let item = matchingItem(in: candidate) else { continue }
            // Wave read from the matched ITEM, symmetric with `sourceItem.waveRaw`.
            guard item.waveRaw?.lowercased() == sourceWave else { continue }
            return item
        }
        return nil
    }

    // MARK: - Write-back to already-materialized future sessions (Cut 3)

    /// Writes the source's recommendation (bump, hold or reduce) onto an already-materialized
    /// next-occurrence plan.
    ///
    /// Only fires when:
    /// - progression is enabled,
    /// - the target plan was NOT user-edited (`planEdited == false`) — a manual
    ///   edit is preserved, never clobbered,
    /// - the target is not a deload/bodyweight item (those never take a numeric bump),
    /// - enough primary working sets were logged (min(sets, 3)),
    /// - and `recommend` returns a load (nil — pain, no baseline — does not write).
    ///   A hold or reduce overwrites a higher seed: the stored plan follows the evidence.
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
        progressionEnabled: Bool,
        isProgressionExempt: Bool
    ) {
        var backOff: Double?
        if case .write(let load) = propagationDecision(
            sourceItem: sourceItem, targetItem: targetItem, session: session,
            allSessions: allSessions, activeMesoIDs: activeMesoIDs, loadIncrement: loadIncrement,
            bodyWeight: bodyWeight, customExercises: customExercises,
            progressionEnabled: progressionEnabled, isProgressionExempt: isProgressionExempt
        ) { backOff = load }
        var top: Double?
        if case .write(let load) = topPropagationDecision(
            sourceItem: sourceItem, targetItem: targetItem, session: session,
            allSessions: allSessions, activeMesoIDs: activeMesoIDs, loadIncrement: loadIncrement,
            bodyWeight: bodyWeight, customExercises: customExercises,
            progressionEnabled: progressionEnabled, isProgressionExempt: isProgressionExempt
        ) { top = load }
        guard backOff != nil || top != nil else { return }
        Self.applyPropagatedLoad(backOff, top: top, to: targetItem)
        Self.enforceMax(on: targetItem, profile: currentProfile(), customExercises: customExercises)
        // planEdited intentionally left false — this is an automatic write.
    }

    /// What the propagate path would do for the TOP set of one source/target pair. Its own evidence
    /// (a logged top row), its own load; the back-off guards (sufficient back-off rows) do not apply.
    func topPropagationDecision(
        sourceItem: SessionItem,
        targetItem: SessionItem,
        session: Session,
        allSessions: [Session],
        activeMesoIDs: Set<PersistentIdentifier>,
        loadIncrement: Double,
        bodyWeight: Double?,
        customExercises: [CustomExercise],
        progressionEnabled: Bool,
        isProgressionExempt: Bool
    ) -> PropagationDecision {
        guard progressionEnabled else { return .skip("progression disabled") }
        guard !isProgressionExempt else { return .skip("exempt (fixed-load) exercise") }
        guard sourceItem.hasTopSet, targetItem.hasTopSet else { return .skip("no top set on source or target") }
        guard !targetItem.planEdited else { return .skip("target plan edited by the user") }
        guard CoachingEngine.hasTopEvidence(sourceItem) else { return .skip("top set not logged") }
        if sourceItem.loadOverrideReason?.suppressesEarnedProgression == true {
            return .skip("source flagged with a suppressing override reason")
        }
        guard targetItem.waveRaw?.lowercased() != "deload" else { return .skip("deload target holds") }
        if ExerciseCatalog.isBodyweight(exerciseId: targetItem.exerciseId, customExercises: customExercises) {
            return .skip("bodyweight target")
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
            unit: currentProfile()?.loadUnit ?? .lb,
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
            policy: policy,
            minLoadIncrement: loadIncrement,
            unit: currentProfile()?.loadUnit ?? .lb,
            mesoPhase: session.mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount,
            e1rmFloorLoad: projection?.e1rmFloorLoad,
            peakE1RM: projection?.peakE1RM,
            lastKnownLoad: projection?.lastLoad,
            carryForwardTarget: .exists,
            priorExposureWasRIRHold: CoachingEngine.priorExposureWasRIRHold(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
                releaseHintDue: CoachingEngine.releaseHintDue(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
            isProgressionExempt: isProgressionExempt,
            loadCap: CoachingEngine.LoadCap.resolve(
                for: sourceItem, in: session, allSessions: allSessions, profile: currentProfile(), customExercises: customExercises
            )
        ), let topLoad = recommendation.nextTopLoad else {
            return .skip("no top-set load (pain flag, no baseline or flagged top-of-range)")
        }
        return .write(topLoad)
    }

    /// What the propagate path would do for one source/target pair — without doing it.
    enum PropagationDecision: Equatable {
        case write(Double)
        /// The guard that left the target alone (human-readable; logged by the catch-up).
        case skip(String)
    }

    /// The single definition of the propagate path's guards and value. `propagate...` writes
    /// what this returns; the one-time catch-up logs and writes the same thing.
    func propagationDecision(
        sourceItem: SessionItem,
        targetItem: SessionItem,
        session: Session,
        allSessions: [Session],
        activeMesoIDs: Set<PersistentIdentifier>,
        loadIncrement: Double,
        bodyWeight: Double?,
        customExercises: [CustomExercise],
        progressionEnabled: Bool,
        isProgressionExempt: Bool
    ) -> PropagationDecision {
        guard progressionEnabled else { return .skip("progression disabled") }
        // Fixed-load exercise: an exempt source never writes an increase anywhere.
        guard !isProgressionExempt else { return .skip("exempt (fixed-load) exercise") }
        guard !targetItem.planEdited else { return .skip("target plan edited by the user") }
        // Incomplete evidence: fewer than min(sets, 3) primary working sets were logged, so
        // there is nothing reliable to write (a 4-set item with 3 logged still qualifies).
        guard CoachingEngine.hasSufficientPrimaryEvidence(sourceItem, policy: policy) else {
            return .skip("incomplete evidence (\(CoachingEngine.countedSets(for: sourceItem, policy: policy).rows.count) of \(CoachingEngine.requiredPrimarySets(for: sourceItem, policy: policy)) primary sets logged)")
        }
        // Flagged source: a temporarily/deliberately reduced load never earns a
        // write-back. CoachingEngine RULE 4b already returns a nil load here, so
        // this is belt-and-braces — it also covers any non-bump recommendation.
        if sourceItem.loadOverrideReason?.suppressesEarnedProgression == true {
            return .skip("source flagged with a suppressing override reason")
        }
        guard targetItem.waveRaw?.lowercased() != "deload" else { return .skip("deload target holds") }
        if ExerciseCatalog.isBodyweight(exerciseId: targetItem.exerciseId, customExercises: customExercises) {
            return .skip("bodyweight target")
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
            unit: currentProfile()?.loadUnit ?? .lb,
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
            policy: policy,
            minLoadIncrement: loadIncrement,
            unit: currentProfile()?.loadUnit ?? .lb,
            mesoPhase: session.mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount,
            e1rmFloorLoad: projection?.e1rmFloorLoad,
            peakE1RM: projection?.peakE1RM,
            lastKnownLoad: projection?.lastLoad,
            carryForwardTarget: .exists,  // targetItem is non-nil by construction
            priorExposureWasRIRHold: CoachingEngine.priorExposureWasRIRHold(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
                releaseHintDue: CoachingEngine.releaseHintDue(for: sourceItem, in: session, allSessions: allSessions, policy: policy),
            isProgressionExempt: isProgressionExempt,
            loadCap: CoachingEngine.LoadCap.resolve(
                for: sourceItem, in: session, allSessions: allSessions, profile: currentProfile(), customExercises: customExercises
            )
        ), let recommendedLoad = recommendation.nextSuggestedLoad else {
            return .skip("no recommendation load (pain flag, no baseline or flagged top-of-range)")
        }

        // Every recommendation with a load propagates — bump, hold or reduce — onto an
        // unedited target: the target tracks the latest same-letter evidence.
        return .write(recommendedLoad)
    }

    private func currentProfile() -> UserProfile? {
        try? context.fetch(FetchDescriptor<UserProfile>()).first
    }

    /// Caps every plan-written load of `target` (suggested + every per-set slot, both roles) at the lifter's max
    /// for that exercise. A no-op without a max, and for fixed-load and bodyweight exercises.
    static func enforceMax(on target: SessionItem, profile: UserProfile?, customExercises: [CustomExercise]) {
        guard let cap = UserProfile.effectiveMaxLoad(for: target.exerciseId, profile: profile,
                                                     customExercises: customExercises) else { return }
        if target.suggestedLoad > cap { target.suggestedLoad = cap }
        if target.plannedLoadsBySet.contains(where: { $0 > cap }) {
            target.plannedLoadsBySet = target.plannedLoadsBySet.map { Swift.min($0, cap) }
        }
    }

    /// The per-set plan a propagated load produces for `targetItem`. Back-off slots (the first
    /// `targetSets` non-top rows) take `load`, top slots take `top`; a nil keeps that role's current
    /// slot values. Slots that are neither (array padding past the planned rows) stay 0, so an
    /// unplanned row never shows a suggested load.
    static func propagatedPlan(_ load: Double?, top: Double? = nil, for targetItem: SessionItem) -> [Double] {
        let current = targetItem.plannedLoadsBySet
        let planned = max(0, targetItem.targetSets)
        let count = max(current.count, planned + targetItem.topCount)
        return (0..<count).map { i in
            if targetItem.isTopRow(i) { return top ?? (i < current.count ? current[i] : 0) }
            if i < planned { return load ?? (i < current.count ? current[i] : 0) }
            return 0
        }
    }

    static func applyPropagatedLoad(_ load: Double?, top: Double? = nil, to targetItem: SessionItem) {
        if let load { targetItem.suggestedLoad = load }
        targetItem.plannedLoadsBySet = propagatedPlan(load, top: top, for: targetItem)
        PlaceholderRefresh.clearStaleNoHistoryNote(targetItem)
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
    /// The plan a source item hands an EMPTY target: back-off loads resized to the target's back-off
    /// count, then the target's top slots from the source's top loads (0 when the source has none).
    /// For items with no top set on either side this is exactly `resizedToTargetSets`.
    private func carriedPlan(from source: SessionItem, to target: SessionItem) -> [Double] {
        let back = resizedToTargetSets(source.backOffValues(source.plannedLoadsBySet), targetCount: target.targetSets)
        guard target.hasTopSet else { return back }
        let sourceTops = source.topValues(source.plannedLoadsBySet, fallback: 0.0)
        let tops = (0..<target.topCount).map { $0 < sourceTops.count ? sourceTops[$0] : 0.0 }
        return back + tops
    }

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

    func isPlanEffectivelyEmpty(_ item: SessionItem) -> Bool {
        let allLoadsZero = item.plannedLoadsBySet.allSatisfy { $0 == 0 }
        return allLoadsZero && item.suggestedLoad == 0
    }

    func hasMeaningfulPlan(_ item: SessionItem) -> Bool {
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
