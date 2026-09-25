import Foundation

// COACHING AUTHORITY — TRUTH PASS v1
// Canonical target: CoachingEngine (message path)
// Current user-visible authority: SessionScreenViewModel.coachMessage() — LEGACY
// Status: live in production — recommend()'s message is wired into exercise.coachMessage
// (SessionView.swift) and rendered in SessionExerciseCardView on every set logged.
// (SessionRecapView's separate recommend() calls remain dead — zero instantiation sites.)
// Phase 1 scope: wire CoachingEngine.message into exercise.coachMessage only
// nextSuggestedLoad: NOT wired in Phase 1 — load authority is a separate truth pass
// Frozen: Progression.swift, coachMessage()
// Deletion target: coachV5Line dead branch, coachMessage() after Phase 1 tests pass

/// What the coach says and does for a single exercise:
/// - `message`: text shown in recap / coaching note
/// - `nextSuggestedLoad`: what to seed as the next-session planned load (if any)
struct CoachingRecommendation {
    let message: String
    let nextSuggestedLoad: Double?
}

struct CoachingEngine {

    // CUT 2 (input-only): project()'s data fields are plumbed in as optional
    // parameters so a future cut can let CoachingEngine consume project() as its
    // data provider. They are NOT read by any cascade path in this cut — recommend()
    // returns exactly the same message/nextSuggestedLoad it would without them.
    // Optional with nil defaults so every existing caller compiles unchanged.
    /// Where this exercise's result will actually land, as resolved by the CALLER.
    ///
    /// PlanMemoryEngine.nextTargetItem owns the targeting rule (same block, same
    /// dayLabel, same wave); duplicating it here would create a second source of
    /// truth that can drift from the one that does the writing. So the caller tells
    /// us only whether a target exists — the wave LETTER we read off the item itself.
    enum CarryForwardTarget {
        /// A materialized target exists, so a number may be promised.
        case exists
        /// No later same-letter, same-day session remains in this block. The load is
        /// still returned in `nextSuggestedLoad`, but nothing in this block will
        /// receive it, so the message must not promise it.
        case endOfChain
        /// Caller did not resolve a target. Phrased exactly like `.exists` — the
        /// wave letter comes from the item, so a waved item still reads "Next Week
        /// A" and a wave-less one still reads "Next session". Only the end-of-chain
        /// case needs the caller to speak up, because only that case is invisible
        /// from the item alone.
        case unresolved
    }

    /// The phrase naming the session a promised load lands in, or nil when no number
    /// may be promised at all.
    ///
    /// Wave letters are a WEEK property, so "Next Week A" is the honest description:
    /// under per-letter anchoring the load lands three weeks out in a 3-wave rotation,
    /// not in the literal next session. Wave-less items are not in a rotation and keep
    /// the original wording.
    private static func landingPhrase(
        for item: SessionItem,
        target: CarryForwardTarget
    ) -> String? {
        if case .endOfChain = target { return nil }
        guard let wave = item.waveRaw?.lowercased(), !wave.isEmpty else {
            return "Next session"
        }
        // A deload source never reaches the promise sites below (RULE 2 returns
        // first), so no deload spelling is needed here.
        return "Next Week \(wave.uppercased())"
    }

    /// What to say instead of a number when the chain has ended.
    private static let carriesForwardClause =
        "That carries into your next block."

    static func recommend(
        for item: SessionItem,
        minLoadIncrement: Double? = nil,
        mesoPhase: MesoPhase = .early,
        consecutiveCleanCount: Int = 0,
        e1rmFloorLoad: Double? = nil,
        peakE1RM: Double? = nil,
        lastKnownLoad: Double? = nil,
        carryForwardTarget: CarryForwardTarget = .unresolved
    ) -> CoachingRecommendation? {
        let reps = item.actualReps
        let loads = item.actualLoads

        let count = min(reps.count, loads.count)
        guard count > 0 else { return nil }

        // Guard 1 — Deload/maintenance week: no progression calls, hold-biased message only
                if item.waveRaw?.lowercased() == "deload" {
                    guard item.suggestedLoad > 0 else { return nil }
                    let hasAnyActualData = (0..<count).contains { reps[$0] > 0 || loads[$0] > 0 }
                    guard hasAnyActualData else { return nil }
                    let pumpNote: String = {
                        let ratings = (0..<min(count, item.pumpRatingsBySet.count)).compactMap {
                            PumpRating(rawValue: item.pumpRatingsBySet[$0])
                        }.filter { $0 != .none }
                        guard !ratings.isEmpty else { return "" }
                        let avg = ratings.map { $0.rawValue }.reduce(0, +) / ratings.count
                        switch PumpRating(rawValue: avg) ?? .none {
                        case .good:      return " Pump was good — the stimulus is there at reduced volume."
                        case .excellent: return " Pump was excellent — your body is responding well to the lighter load."
                        case .poor:      return " Pump was poor — that's fine at this volume. Focus is retention, not stimulus."
                        default:         return ""
                        }
                    }()
                    let msg = "Maintenance session. Goal is retention — hold this load, manage fatigue, and carry it into the next block.\(pumpNote)"
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: item.suggestedLoad)
                }

        // Guard 2 — No baseline: if suggestedLoad is 0 there's nothing to progress from
        if item.suggestedLoad <= 0 {
            return nil
        }

        // Guard 3 — First session baseline: if no actual data has been logged yet, return nil
        let hasAnyActualData = (0..<count).contains { reps[$0] > 0 || loads[$0] > 0 }
        guard hasAnyActualData else { return nil }

        // Guard 4 — Pain flag: immediate stop, no progression call
        let hasPainFlag = (0..<min(count, item.setFeedbackBySet.count)).contains {
            item.setFeedbackBySet[$0] == SetFeedback.pain.rawValue
        }
        if hasPainFlag {
            return CoachingRecommendation(
                message: "Pain was flagged on at least one set. No progression call will be made. Reassess before your next session.",
                nextSuggestedLoad: nil
            )
        }

        // Guard 5 — Soreness/disruption flag: captured here, applied as override below
        let hasFatigueFlag = (0..<min(count, item.setFeedbackBySet.count)).contains {
            let fb = item.setFeedbackBySet[$0]
            return fb == SetFeedback.soreness.rawValue || fb == SetFeedback.disruption.rawValue
        }

        // Working sets = any set with both load and reps > 0
        var workingIndices: [Int] = []
        for idx in 0..<count {
            if reps[idx] > 0 && loads[idx] > 0 {
                workingIndices.append(idx)
            }
        }

        // Warmup pollution guard: exclude sets below 50% of session max load
        if let maxLoad = workingIndices.map({ loads[$0] }).max(), maxLoad > 0 {
            workingIndices = workingIndices.filter { loads[$0] >= maxLoad * 0.5 }
        }
        guard !workingIndices.isEmpty else { return nil }

        let plannedWorkingSetCount = max(1, item.targetSets)
        let growthSetTarget = min(plannedWorkingSetCount, 3)

        // Progression evaluates only the first up to 3 working sets
        let primaryIndices = Array(workingIndices.prefix(growthSetTarget))
        guard !primaryIndices.isEmpty else { return nil }

        let primaryLoads = primaryIndices.map { loads[$0] }
        let primaryReps = primaryIndices.map { reps[$0] }

        let baseLoad: Double = primaryLoads.last ?? 0

        // Guard 6 — Sanity cap: never suggest more than 2x the previous load
        let loadSanityCap = baseLoad * 2.0

        // (Cut 3 fix) The former ProgressionEngine `progressionDecision` sizing is no
        // longer consulted for bumps: the cluster increment it added equals loadStep's
        // cluster increment, and the unified bump now guarantees baseLoad + increment
        // with the e1rm floor raising it. Removed to avoid a dead computation.

        let plannedTopReps = item.repMax ?? item.plannedRepsBySet.max() ?? item.targetReps
        let plannedBottomReps = item.repMin ?? item.plannedRepsBySet.min() ?? item.targetReps
        let targetReps = item.targetReps
        let targetRIR = item.targetRIR

        let firstReps = primaryReps.first ?? 0
        let lastReps = primaryReps.last ?? 0
        let repDrop = firstReps - lastReps
        let bestReps = primaryReps.max() ?? 0

        let actualRIRs = item.actualRIRs
        var primaryRIRs: [Int] = []
        if !actualRIRs.isEmpty {
            for idx in primaryIndices where idx < actualRIRs.count {
                primaryRIRs.append(actualRIRs[idx])
            }
        }

        var avgRIR: Double? = nil
        var minRIR: Int? = nil
        if !primaryRIRs.isEmpty {
            let sum = primaryRIRs.reduce(0, +)
            avgRIR = Double(sum) / Double(primaryRIRs.count)
            minRIR = primaryRIRs.min()
        }

        // Rest-pause is intentionally NOT computed as a gate here (Cut 3 decision):
        // a rest-pause session is legitimate technique and is eligible to bump.
        // Drop-set "quality" detection likewise removed — it gated the old 3.6 rung.

        // Pump awareness — average pump rating across primary sets
        let avgPump: PumpRating = {
            let ratings = primaryIndices.compactMap { idx -> PumpRating? in
                guard idx < item.pumpRatingsBySet.count else { return nil }
                let r = PumpRating(rawValue: item.pumpRatingsBySet[idx]) ?? .none
                return r == .none ? nil : r
            }
            guard !ratings.isEmpty else { return .none }
            let avg = ratings.map { $0.rawValue }.reduce(0, +) / ratings.count
            return PumpRating(rawValue: avg) ?? .none
        }()

        func loadStep(for base: Double) -> Double {
            if let increment = minLoadIncrement, increment > 0 {
                return increment
            }
            if let cluster = ExerciseCatalog.cluster(for: item.exerciseId) {
                let config = ChestArmsLowBackMesoProfile.config(for: cluster)
                return config.primaryLoadIncrement
            }
            if base >= 200 { return 5.0 }
            if base >= 100 { return 2.5 }
            return 2.0
        }

        let primaryWorkPhrase: String = {
            switch growthSetTarget {
            case 1: return "working set"
            case 2: return "first 2 working sets"
            default: return "first 3 working sets"
            }
        }()

        // MARK: - Unified Load Policy (Cut 3)
        //
        // One stated policy replacing the former 13-rung cascade
        // (A/B/C/D/E/4/F/3.5/3.6/5/5.5/G). CoachingEngine is the authority and now
        // consumes project()'s data (e1rmFloorLoad, Cut 1). Trigger is double
        // progression: ALL primary working sets hit repMax at target RIR. Balanced
        // default → one qualifying session earns the bump (coaching-style tuning is
        // Cut 6; consecutiveCleanCount is intentionally not consulted here).
        //
        // Ordering note: deload (RULE 2), no-baseline / no-data (RULE 2/3) and pain
        // (RULE 1a) already returned above as leading preconditions — hold-vs-bump
        // cannot be assessed without a baseline load on a non-deload wave. The
        // remaining safety gates run here, all before any bump can be reached.

        // RULE 1b — Safety: soreness/disruption fatigue → hold [was path F / guard :87]
        if hasFatigueFlag {
            let flags = (0..<min(count, item.setFeedbackBySet.count)).map { item.setFeedbackBySet[$0] }
            let hasSoreness = flags.contains(SetFeedback.soreness.rawValue)
            let hasDisruption = flags.contains(SetFeedback.disruption.rawValue)
            let msg: String
            if hasSoreness && hasDisruption {
                msg = "Soreness and disruption were flagged this session. Hold this load and focus on quality before considering an increase."
            } else if hasSoreness {
                msg = "Soreness was flagged this session. Hold this load — muscle soreness mid-session is a signal to avoid pushing progression."
            } else {
                msg = "Disruption was flagged this session. This wasn't a reliable performance indicator — hold this load and reassess next session."
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // RULE 1c — Safety: failure + big rep crash (minRIR ≤ 0 AND repDrop ≥ 3) → hold [was path C]
        if let minRIR = minRIR, minRIR <= 0, repDrop >= 3 {
            let msg = "You hit failure and reps fell from \(firstReps) to \(lastReps) — the load exceeded your repeatable capacity. Hold here. Focus on keeping reps consistent set to set before considering an increase."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // RULE 1d — Safety: intra-session load drop ≥10% (opened above the repeatable
        // baseline) → re-baseline to the minimum working load [was path A].
        // Rest-pause is no longer a factor; a dropped LAST set that is a drop-set is
        // still excluded (that's programmed volume, not a failed opener).
        let lastWorkingIdx = workingIndices.last ?? 0
        let lastSetHadDropSet = lastWorkingIdx < item.dropSetPatternsBySet.count &&
            !item.dropSetPatternsBySet[lastWorkingIdx].isEmpty
        let workingLoads = workingIndices.map { loads[$0] }
        if !lastSetHadDropSet,
           workingIndices.count >= 2,
           let maxLoad = workingLoads.max(),
           let minLoad = workingLoads.min(),
           maxLoad > 0,
           minLoad > 0 {
            let dropPercent = (maxLoad - minLoad) / maxLoad
            let firstLoad = loads[workingIndices.first!]
            let lastLoad = loads[workingIndices.last!]
            if dropPercent >= 0.10, firstLoad == maxLoad, lastLoad == minLoad, minLoad < maxLoad {
                // The from/to numbers describe what just happened and always stay;
                // only the forward-looking number is gated on a target existing.
                let observed = "Load dropped from \(Int(maxLoad)) to \(Int(minLoad)) across your working sets — you opened above your repeatable baseline."
                let msg: String
                if let landing = landingPhrase(for: item, target: carryForwardTarget) {
                    msg = "\(observed) \(landing) starts at \(Int(minLoad)). Build from there."
                } else {
                    msg = "\(observed) \(carriesForwardClause)"
                }
                return CoachingRecommendation(message: msg, nextSuggestedLoad: minLoad)
            }
        }

        // RULE 3 — Incomplete: not all planned working sets logged yet → hold with
        // the stage-gate message; nothing to decide [was path B].
        let completedGrowthSetCount = primaryIndices.count
        let completedWorkingSetCount = workingIndices.count
        if completedGrowthSetCount < growthSetTarget || completedWorkingSetCount < plannedWorkingSetCount {
            let remaining = plannedWorkingSetCount - completedWorkingSetCount
            if completedGrowthSetCount == 1 {
                let currentLoadText = String(format: "%.1f", baseLoad)
                let currentReps = primaryReps[0]
                if let avgRIR, avgRIR < Double(targetRIR) - 0.5 {
                    let msg = "Set 1 at \(currentLoadText) × \(currentReps) is already harder than the target RIR. Keep this load and monitor the remaining \(remaining == 1 ? "set" : "sets") — if it stays hard, this is a hold day."
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }
                if currentReps < plannedBottomReps {
                    let msg = "Set 1 came in short of the rep target. Stay at this load — if reps stay low across sets, the load needs to come down next session."
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }
                return nil
            }
            let msg = "\(completedWorkingSetCount) sets in. Finish the session."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // From here: safe + complete. Compute the policy signals.
        let repMax = plannedTopReps
        let repMin = plannedBottomReps
        // RIR on target (existing definition; nil avgRIR treated as on-target).
        let rirOnTarget: Bool = {
            guard let avgRIR = avgRIR else { return true }
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()
        // Double-progression trigger (decision B): EVERY primary working set at/above
        // the top of the range — not the best set. Uses the warmup-culled primary sets.
        let allSetsAtTop = primaryReps.count >= growthSetTarget && primaryReps.allSatisfy { $0 >= repMax }
        // Over-performed: every primary set two or more reps beyond the top.
        let overPerformed = primaryReps.count >= growthSetTarget && primaryReps.allSatisfy { $0 >= repMax + 2 }

        // Bump sizing — a qualifying bump ALWAYS raises by at least one increment.
        // The e1rm floor (Cut 1) may only RAISE the bump above baseLoad + increment,
        // never reduce it below (fixes the Farmer-Carry no-move bug, where a floor
        // ≤ baseLoad collapsed the "increase earned" bump to no increase). 2×-capped.
        //
        // Increment resolution guarantees a NONZERO increment on a qualifying bump:
        // prefer the user's minLoadIncrement; else the cluster/loadStep increment;
        // else a base-scaled default. Some clusters (lowBackStability) carry a 0.0
        // primaryLoadIncrement, so loadStep can be 0 — the base-scaled fallback below
        // ensures the load still moves when a bump is earned.
        let bumpIncrement: Double = {
            if let m = minLoadIncrement, m > 0 { return m }
            let step = loadStep(for: baseLoad)
            if step > 0 { return step }
            if baseLoad >= 200 { return 5.0 }
            if baseLoad >= 100 { return 2.5 }
            return 2.5
        }()
        func qualifyingBump() -> Double {
            let incrementedLoad = baseLoad + bumpIncrement                       // guaranteed minimum raise
            let roundedFloor = e1rmFloorLoad.map { E1RMCalculator.rounded($0, increment: bumpIncrement) }
            let bumpTarget = max(incrementedLoad, roundedFloor ?? incrementedLoad) // floor can only raise
            return min(bumpTarget, baseLoad * 2.0)                                // RULE 6: 2× cap preserved
        }
        let pumpNote: String = {
            switch avgPump {
            case .good: return " Pump was good — this lift is responding well."
            case .excellent: return " Pump was excellent — strong stimulus confirmed."
            case .poor: return " Pump was poor — consider whether load, technique, or fatigue affected stimulus."
            default: return ""
            }
        }()

        // RULE 4 — Under the bottom of the range: best set below repMin → hold; ≥2
        // badly-missed primary sets → reduce 5% [was path D + project fatigue cut].
        if bestReps < repMin {
            let badMisses = primaryReps.filter { $0 < (repMin - 1) }.count
            if badMisses >= 2 {
                let reduced = E1RMCalculator.rounded(baseLoad * 0.95, increment: minLoadIncrement ?? 2.5)
                let msg = "Reps came in well under the bottom of the range across multiple sets. Backing the load down to \(String(format: "%.1f", reduced)) next session to rebuild in range."
                return CoachingRecommendation(message: msg, nextSuggestedLoad: reduced)
            }
            let msg = "Your best \(primaryWorkPhrase) came in below the planned range (\(repMin)–\(repMax) reps). Hold this load and focus on hitting the bottom of the range before considering an increase."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // RULE 5 — Progression (double progression). Reached only when safe, complete,
        // and at least at the bottom of the range.

        // 5a) Over-performed: all sets ≥ repMax+2 at target RIR → bump (floor-aware) [was path 4]
        if overPerformed && rirOnTarget {
            let target = qualifyingBump()
            let lead = "Reps came in well above the top of your range with room to spare."
            let msg: String
            if let landing = landingPhrase(for: item, target: carryForwardTarget) {
                msg = "\(lead) \(landing): \(String(format: "%.1f", target)).\(pumpNote)"
            } else {
                msg = "\(lead) \(carriesForwardClause)\(pumpNote)"
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: target)
        }

        // 5b) ALL primary sets at the top at target RIR → increase earned (floor-aware).
        //     The core double-progression bump [replaces paths 3.5 / 5.5].
        if allSetsAtTop && rirOnTarget {
            let target = qualifyingBump()
            let lead = "Every working set hit the top of your range at the target difficulty — increase earned."
            let msg: String
            if let landing = landingPhrase(for: item, target: carryForwardTarget) {
                msg = "\(lead) \(landing): \(String(format: "%.1f", target)).\(pumpNote)"
            } else {
                msg = "\(lead) \(carriesForwardClause)\(pumpNote)"
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: target)
        }

        // 5c) Clean but not yet at the top: in range and on-target RIR, but not every
        //     set at repMax → HOLD and climb reps toward the top next session. This is
        //     the key behavior change — partial progress no longer bumps [was path 5].
        if bestReps >= repMin && rirOnTarget {
            let msg = "On target and in range — hold \(String(format: "%.1f", baseLoad)). Hit the top of your range (\(repMax)) on all working sets to earn the increase; climb your reps next session."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 5d) Not clean (in range but off-target RIR) → hold [was catch-all G]
        let msg = "Performance didn't clearly support an increase. Hold this load and look for more consistent output next session before moving up."
        return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
    }

    private static func formatLoad(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.1f", value)
    }
}
