import Foundation
import SwiftData

// COACHING AUTHORITY — TRUTH PASS v1
// Canonical target: CoachingEngine (message path)
// Current user-visible authority: SessionScreenViewModel.coachMessage() — LEGACY
// Status: live in production — recommend()'s message is wired into exercise.coachMessage
// (SessionView.swift) and rendered in SessionExerciseCardView on every set logged.
// (The old SessionRecapView, whose separate recommend() calls were dead, has been deleted.)
// Phase 1 scope: wire CoachingEngine.message into exercise.coachMessage only
// nextSuggestedLoad: NOT wired in Phase 1 — load authority is a separate truth pass
// Frozen: Progression.swift, coachMessage()
// Deletion target: coachV5Line dead branch, coachMessage() after Phase 1 tests pass

/// What the coach says and does for a single exercise:
/// - `message`: text shown in recap / coaching note
/// - `nextSuggestedLoad`: what to seed as the next-session planned load (if any)
struct CoachingRecommendation {
    let message: String
    /// The back-off (or only) load to carry forward.
    let nextSuggestedLoad: Double?
    /// The top-set load to carry forward; nil on an item without a top set or with no top set logged.
    let nextTopLoad: Double?

    init(message: String, nextSuggestedLoad: Double?, nextTopLoad: Double? = nil) {
        self.message = message
        self.nextSuggestedLoad = nextSuggestedLoad
        self.nextTopLoad = nextTopLoad
    }
}

struct CoachingEngine {

    /// A per-exercise max load as the CALLER resolved it (`UserProfile.effectiveMaxLoad`): nil is passed for no
    /// cap, a fixed-load exercise or a bodyweight one. The engine never reads the profile.
    struct LoadCap: Equatable {
        let max: Double
        /// Earlier consecutive same-letter sessions that topped the rep range at the cap
        /// (`LoadCap.priorToppedStreak`). Two in a row (this one included) earns the "different rep range" hint.
        var priorToppedStreak: Int = 0

        /// "At your max load (N). Progress with reps or tempo." (+ the hint after two consecutive sessions).
        func message(streakHint: Bool, unit: LoadUnit = .lb) -> String {
            let n = LoadFormatter(unit: unit).compact(max)
            let base = "At your max load (\(n)). Progress with reps or tempo."
            return streakHint && priorToppedStreak >= 1 ? base + " Consider a higher rep range or a different exercise." : base
        }
    }

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
        /// A materialized target exists but the user edited its plan (`planEdited`), so
        /// carry-forward will not write to it. The message may say so, never promise a number.
        case existsEdited
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

    /// Name of the session a load lands in ("Next Week B" / "Next session"), ignoring target state.
    private static func landingName(for item: SessionItem) -> String {
        landingPhrase(for: item, target: .exists) ?? "Next session"
    }

    /// "300" for a whole load, "317.5" otherwise — the landing text reads as a number, not a gauge.
    private static func compactLoad(_ value: Double, unit: LoadUnit) -> String {
        LoadFormatter(unit: unit).compact(value)
    }

    private enum Forward {
        case lands(String)        // "Next Week B" — the write will land there
        case editedKept(String)   // the user's edited plan stays as set
        case endOfChain           // nothing left in the block to receive it
        case silent               // a write is blocked (incomplete evidence / flagged source): no claim
    }

    private static func forward(for item: SessionItem, target: CarryForwardTarget, writeBlocked: Bool) -> Forward {
        switch target {
        case .endOfChain:
            return .endOfChain
        case .existsEdited:
            return .editedKept("Your edited plan for \(landingName(for: item)) stays as set.")
        case .exists, .unresolved:
            return writeBlocked ? .silent : .lands(landingName(for: item))
        }
    }

    /// Back-off rows (every row that is not a top row) with both load and reps > 0, before the
    /// warm-up cull. On an item with no top set this is every logged row.
    private static func loggedRowIndices(for item: SessionItem) -> [Int] {
        let count = min(item.actualReps.count, item.actualLoads.count)
        return (0..<count).filter { item.actualReps[$0] > 0 && item.actualLoads[$0] > 0 && !item.isTopRow($0) }
    }

    /// Logged top rows (reps and load > 0), by row. The role is the row's, never the logging order.
    static func topWorkingIndices(for item: SessionItem) -> [Int] {
        let count = min(item.actualReps.count, item.actualLoads.count)
        return item.topRowIndices.filter { $0 < count && item.actualReps[$0] > 0 && item.actualLoads[$0] > 0 }
    }

    /// A top set was logged and can be written forward on its own evidence.
    static func hasTopEvidence(_ item: SessionItem) -> Bool {
        !topWorkingIndices(for: item).isEmpty
    }

    /// The step for this exercise, in `unit` (`minLoadIncrement` is in `unit` too). Add it to a stored lb load only
    /// through `UnitAwareRounding.stepLb`.
    static func loadIncrement(for item: SessionItem, base: Double, minLoadIncrement: Double?, unit: LoadUnit = .lb) -> Double {
        if let increment = minLoadIncrement, increment > 0 { return increment }
        if let cluster = ExerciseCatalog.cluster(for: item.exerciseId) {
            return UnitAwareRounding.increment(fromLb: ChestArmsLowBackMesoProfile.config(for: cluster).primaryLoadIncrement, unit: unit)
        }
        return UnitAwareRounding.fallbackIncrement(forBaseLb: base, unit: unit)
    }

    /// The recommendation with the lifter's own step and unit, as carry-forward uses them. The recap reads this so the
    /// "next" it shows is the load carry-forward writes (it used to omit the increment and fall back to a base-scaled step).
    static func recommend(for item: SessionItem, profile: UserProfile?) -> CoachingRecommendation? {
        let unit = profile?.loadUnit ?? .lb
        return recommend(for: item,
                         minLoadIncrement: profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit),
                         unit: unit)
    }

    /// `base` plus one `step` (in `unit`). lb: the plain sum, unrounded, exactly as before. kg: snapped to the kg step, so
    /// a base that is not on a kg step (an old lb value) still produces a load a kg lifter can put on the bar.
    static func steppedUp(_ base: Double, step: Double, unit: LoadUnit) -> Double {
        let sum = base + UnitAwareRounding.stepLb(step, unit: unit)
        return unit == .lb ? sum : UnitAwareRounding.round(sum, increment: step, unit: unit)
    }

    /// Back-off working sets = any back-off set with both load and reps > 0, minus warmups (< 50% of
    /// the max back-off load). Top rows are never part of this: they are read separately. Shared with
    /// PlanMemoryEngine's incomplete-evidence guard.
    static func workingSetIndices(for item: SessionItem) -> [Int] {
        var indices = loggedRowIndices(for: item)
        if let maxLoad = indices.map({ item.actualLoads[$0] }).max(), maxLoad > 0 {
            indices = indices.filter { item.actualLoads[$0] >= maxLoad * 0.5 }
        }
        return indices
    }

    /// Working rows inside the planned set count. A row past targetSets is an extra set: it is
    /// logged and counts toward history, but it is never evidence for the planned prescription
    /// (not a primary set, not toward "all sets logged"). A logged warm-up opener sits in a row
    /// of its own on top of the plan, so each culled warm-up row widens the planned window by one.
    static func plannedWorkingSetIndices(for item: SessionItem) -> [Int] {
        let working = workingSetIndices(for: item)
        let warmupRows = loggedRowIndices(for: item).count - working.count
        let limit = max(1, item.targetSets) + warmupRows
        return working.filter { $0 < limit }
    }

    /// Primary working sets the progression decision needs: min(planned sets, 3).
    static func requiredPrimarySets(for item: SessionItem) -> Int {
        min(max(1, item.targetSets), 3)
    }

    /// True when enough primary working sets were logged for a load to be written onto a
    /// future plan. A 4-set item with 3 logged qualifies.
    static func hasSufficientPrimaryEvidence(_ item: SessionItem) -> Bool {
        plannedWorkingSetIndices(for: item).count >= requiredPrimarySets(for: item)
    }

    /// What to say instead of a number when the chain has ended.
    private static let carriesForwardClause =
        "That carries into your next block."

    /// The coach's read of one exercise. An item without a top set is judged exactly as before; with
    /// one, the top rows get their own read (against topRepMin/Max and topRIR) and every back-off
    /// decision uses back-off rows only.
    static func recommend(
        for item: SessionItem,
        minLoadIncrement: Double? = nil,
        unit: LoadUnit = .lb,
        mesoPhase: MesoPhase = .early,
        consecutiveCleanCount: Int = 0,
        e1rmFloorLoad: Double? = nil,
        peakE1RM: Double? = nil,
        lastKnownLoad: Double? = nil,
        carryForwardTarget: CarryForwardTarget = .unresolved,
        isProgressionExempt: Bool = false,
        loadCap: LoadCap? = nil
    ) -> CoachingRecommendation? {
        let rec = recommendRoles(
            for: item, minLoadIncrement: minLoadIncrement, unit: unit, mesoPhase: mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount, e1rmFloorLoad: e1rmFloorLoad,
            peakE1RM: peakE1RM, lastKnownLoad: lastKnownLoad,
            carryForwardTarget: carryForwardTarget, isProgressionExempt: isProgressionExempt, loadCap: loadCap
        )
        // Whatever path produced a load, a plan-written load never exceeds the cap (an earned bump that would
        // is already turned into a hold at the cap, with its message, further down).
        guard let rec, let cap = loadCap, !isProgressionExempt else { return rec }
        func clamp(_ v: Double?) -> Double? { v.map { Swift.min($0, cap.max) } }
        return CoachingRecommendation(message: rec.message, nextSuggestedLoad: clamp(rec.nextSuggestedLoad),
                                      nextTopLoad: clamp(rec.nextTopLoad))
    }

    private static func recommendRoles(
        for item: SessionItem,
        minLoadIncrement: Double?,
        unit: LoadUnit,
        mesoPhase: MesoPhase,
        consecutiveCleanCount: Int,
        e1rmFloorLoad: Double?,
        peakE1RM: Double?,
        lastKnownLoad: Double?,
        carryForwardTarget: CarryForwardTarget,
        isProgressionExempt: Bool,
        loadCap: LoadCap?
    ) -> CoachingRecommendation? {
        let back = recommendBackOffs(
            for: item, minLoadIncrement: minLoadIncrement, unit: unit, mesoPhase: mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount, e1rmFloorLoad: e1rmFloorLoad,
            peakE1RM: peakE1RM, lastKnownLoad: lastKnownLoad,
            carryForwardTarget: carryForwardTarget, isProgressionExempt: isProgressionExempt, loadCap: loadCap
        )
        guard item.hasTopSet else { return back }
        // Deload keeps its maintenance message; a pain flag stops every call, top set included.
        if item.waveRaw?.lowercased() == "deload" { return back }
        let painFlagged = item.setFeedbackBySet.contains { $0 == SetFeedback.pain.rawValue }
        if painFlagged { return back }
        guard let top = topRead(for: item, minLoadIncrement: minLoadIncrement, unit: unit, isProgressionExempt: isProgressionExempt,
                                loadCap: loadCap) else {
            return back
        }
        let message = [top.message, back?.message].compactMap { $0 }.joined(separator: " ")
        return CoachingRecommendation(message: message, nextSuggestedLoad: back?.nextSuggestedLoad, nextTopLoad: top.nextTopLoad)
    }

    private struct TopRead { let message: String; let nextTopLoad: Double? }

    /// Judges the logged top rows: reps against topRepMin/Max, RIR against topRIR. Hold, or a
    /// one-increment bump when every top row is at the top of its range at the target difficulty.
    private static func topRead(for item: SessionItem, minLoadIncrement: Double?, unit: LoadUnit, isProgressionExempt: Bool,
                                loadCap: LoadCap? = nil) -> TopRead? {
        let rows = topWorkingIndices(for: item)
        guard let lastRow = rows.last else { return nil }
        let reps = rows.map { item.actualReps[$0] }
        let load = item.actualLoads[lastRow]
        let lo = item.topRepMin ?? item.repMin ?? item.targetReps
        let hi = max(lo, item.topRepMax ?? item.repMax ?? item.targetReps)
        let targetRIR = item.topRIR ?? item.targetRIR
        let rirs = rows.compactMap { $0 < item.actualRIRs.count ? item.actualRIRs[$0] : nil }
        let avgRIR: Double? = rirs.isEmpty ? nil : Double(rirs.reduce(0, +)) / Double(rirs.count)
        let what = "Top set: \(compactLoad(load, unit: unit)) x \(reps.map(String.init).joined(separator: ", "))"
        let range = lo == hi ? "\(lo)" : "\(lo)–\(hi)"

        let fatigue = rows.contains { idx in
            guard idx < item.setFeedbackBySet.count else { return false }
            let fb = item.setFeedbackBySet[idx]
            return fb == SetFeedback.soreness.rawValue || fb == SetFeedback.disruption.rawValue
        }
        if fatigue {
            return TopRead(message: "\(what) — soreness or disruption flagged, hold this load.", nextTopLoad: load)
        }
        if (reps.min() ?? 0) < lo {
            return TopRead(message: "\(what), under the range (\(range)) — hold this load.", nextTopLoad: load)
        }
        if let avgRIR, avgRIR < Double(targetRIR) - 0.5 {
            return TopRead(message: "\(what), harder than the target RIR — hold this load.", nextTopLoad: load)
        }
        if reps.allSatisfy({ $0 >= hi }) {
            if isProgressionExempt {
                return TopRead(message: "\(what), top of the range. Load is fixed on this exercise.", nextTopLoad: load)
            }
            if item.loadOverrideReason?.suppressesEarnedProgression == true {
                return TopRead(message: "\(what), top of the range at a reduced load — no increase earned.", nextTopLoad: nil)
            }
            let step = loadIncrement(for: item, base: load, minLoadIncrement: minLoadIncrement, unit: unit)
            let next = min(steppedUp(load, step: step, unit: unit), load * 2.0)
            if let cap = loadCap, next > cap.max {
                // The earned increase would pass the max: hold at the max.
                return TopRead(message: "\(what), top of the range. \(cap.message(streakHint: false, unit: unit))", nextTopLoad: cap.max)
            }
            return TopRead(message: "\(what), top of the range — increase earned. Next top set: \(compactLoad(next, unit: unit)).", nextTopLoad: next)
        }
        return TopRead(message: "\(what), on target — hold.", nextTopLoad: load)
    }

    private static func recommendBackOffs(
        for item: SessionItem,
        minLoadIncrement: Double? = nil,
        unit: LoadUnit = .lb,
        mesoPhase: MesoPhase = .early,
        consecutiveCleanCount: Int = 0,
        e1rmFloorLoad: Double? = nil,
        peakE1RM: Double? = nil,
        lastKnownLoad: Double? = nil,
        carryForwardTarget: CarryForwardTarget = .unresolved,
        isProgressionExempt: Bool = false,
        loadCap: LoadCap? = nil
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

        let workingIndices = workingSetIndices(for: item)
        guard !workingIndices.isEmpty else { return nil }

        let plannedWorkingSetCount = max(1, item.targetSets)
        let growthSetTarget = min(plannedWorkingSetCount, 3)

        // Only rows inside the planned set count are evidence for the prescription. An extra
        // row (index >= targetSets) was judged against the wrong range and counted toward
        // "sets in"; with nothing but extra rows logged there is nothing to say.
        let plannedRows = plannedWorkingSetIndices(for: item)
        guard !plannedRows.isEmpty else { return nil }

        // Progression evaluates only the first up to 3 planned working sets
        let primaryIndices = Array(plannedRows.prefix(growthSetTarget))

        // Will carry-forward actually write onto a materialized target? Not with incomplete
        // evidence (fewer than min(sets, 3) primary sets logged) or a flagged source whose
        // reduced load never earns a write. Messages claim a landing only when it will land.
        let writeBlocked = primaryIndices.count < growthSetTarget
            || item.loadOverrideReason?.suppressesEarnedProgression == true

        /// Suffix for a HOLD message: promises the landing only when the write will happen.
        /// Exempt (fixed-load) holds never claim one.
        func holdLanding(_ load: Double) -> String {
            guard !isProgressionExempt else { return "" }
            switch carryForwardTarget {
            case .exists where !writeBlocked:
                return " \(landingName(for: item)): \(compactLoad(load, unit: unit)), same load, reps-first."
            case .existsEdited:
                return " Your edited plan for \(landingName(for: item)) stays as set."
            default:
                return ""
            }
        }

        let primaryLoads = primaryIndices.map { loads[$0] }
        let primaryReps = primaryIndices.map { reps[$0] }

        let baseLoad: Double = primaryLoads.last ?? 0

        // (Cut 3 fix) The former ProgressionEngine `progressionDecision` sizing is no
        // longer consulted for bumps: the cluster increment it added equals loadStep's
        // cluster increment, and the unified bump now guarantees baseLoad + increment
        // with the e1rm floor raising it. Removed to avoid a dead computation.

        let plannedTopReps = item.repMax ?? item.plannedRepsBySet.max() ?? item.targetReps
        let plannedBottomReps = item.repMin ?? item.plannedRepsBySet.min() ?? item.targetReps
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
            loadIncrement(for: item, base: base, minLoadIncrement: minLoadIncrement, unit: unit)
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
                // Exempt (fixed-load) variants drop the progression language; non-exempt
                // text is byte-identical.
                msg = isProgressionExempt
                    ? "Soreness and disruption were flagged this session. Hold this load and focus on quality."
                    : "Soreness and disruption were flagged this session. Hold this load and focus on quality before considering an increase."
            } else if hasSoreness {
                msg = isProgressionExempt
                    ? "Soreness was flagged this session. Hold this load."
                    : "Soreness was flagged this session. Hold this load — muscle soreness mid-session is a signal to avoid pushing progression."
            } else {
                msg = "Disruption was flagged this session. This wasn't a reliable performance indicator — hold this load and reassess next session."
            }
            return CoachingRecommendation(message: msg + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
        }

        // RULE 1c — Safety: failure + big rep crash (minRIR ≤ 0 AND repDrop ≥ 3) → hold [was path C]
        if let minRIR = minRIR, minRIR <= 0, repDrop >= 3 {
            let msg = isProgressionExempt
                ? "You hit failure and reps fell from \(firstReps) to \(lastReps) — the load exceeded your repeatable capacity. Hold here. Focus on keeping reps consistent set to set."
                : "You hit failure and reps fell from \(firstReps) to \(lastReps) — the load exceeded your repeatable capacity. Hold here. Focus on keeping reps consistent set to set before considering an increase."
            return CoachingRecommendation(message: msg + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
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
                let observed = "Load dropped from \(LoadFormatter(unit: unit).truncated(maxLoad)) to \(LoadFormatter(unit: unit).truncated(minLoad)) across your working sets — you opened above your repeatable baseline."
                let msg: String
                if isProgressionExempt {
                    // Fixed-load: no "Next Week X starts at N" promise; observed facts only.
                    msg = "\(observed) Load is fixed on this exercise: change it yourself when you're ready."
                } else {
                    switch forward(for: item, target: carryForwardTarget, writeBlocked: writeBlocked) {
                    case .lands(let landing):
                        msg = "\(observed) \(landing) starts at \(LoadFormatter(unit: unit).truncated(minLoad)). Build from there."
                    case .editedKept(let kept):
                        msg = "\(observed) \(kept)"
                    case .endOfChain:
                        msg = "\(observed) \(carriesForwardClause)"
                    case .silent:
                        msg = "\(observed) Build from there."
                    }
                }
                return CoachingRecommendation(message: msg, nextSuggestedLoad: minLoad)
            }
        }

        // RULE 3 — Incomplete: not all planned working sets logged yet → hold with
        // the stage-gate message; nothing to decide [was path B].
        let completedGrowthSetCount = primaryIndices.count
        let completedWorkingSetCount = plannedRows.count
        if completedGrowthSetCount < growthSetTarget || completedWorkingSetCount < plannedWorkingSetCount {
            let remaining = plannedWorkingSetCount - completedWorkingSetCount
            if completedGrowthSetCount == 1 {
                let setLabel = (item.hasTopSet ? "Back-off set " : "Set ") + "\(primaryIndices[0] + 1)"
                let currentLoadText = LoadFormatter(unit: unit).oneDecimal(baseLoad)
                let currentReps = primaryReps[0]
                if let avgRIR, avgRIR < Double(targetRIR) - 0.5 {
                    let msg = "\(setLabel) at \(currentLoadText) × \(currentReps) is already harder than the target RIR. Keep this load and monitor the remaining \(remaining == 1 ? "set" : "sets") — if it stays hard, this is a hold day."
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }
                if currentReps < plannedBottomReps {
                    let msg = "\(setLabel) came in short of the rep target. Stay at this load — if reps stay low across sets, the load needs to come down next session."
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }
                return nil
            }
            let msg = remaining > 0
                ? (item.hasTopSet
                    ? "Back-offs: \(completedWorkingSetCount) of \(plannedWorkingSetCount) logged."
                    : "\(completedWorkingSetCount) of \(plannedWorkingSetCount) planned sets logged.")
                : "\(completedWorkingSetCount) sets in. Finish the session."
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

        // Bump sizing — a qualifying bump ALWAYS raises by exactly one increment.
        //
        // The e1rm floor (Cut 1) may RAISE a bump up to baseLoad + increment (it
        // still fixes the Farmer-Carry no-move bug, where a floor ≤ baseLoad
        // collapsed the "increase earned" bump to no increase) but it may never
        // push PAST that ceiling. The floor is derived from historical e1RM, which
        // can sit far above what was just lifted: leg_extension at 180 with a ~225
        // history projected a 220 "next week", a 40 kg jump off a 180 session. An
        // earned bump is a reward for today's performance, so today's load is what
        // it steps off — conservative by default. 2×-capped as well.
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
            return UnitAwareRounding.bumpFallbackIncrement(forBaseLb: baseLoad, unit: unit)
        }()
        func qualifyingBump() -> Double {
            let ceiling = Self.steppedUp(baseLoad, step: bumpIncrement, unit: unit)                                // one increment, no more
            let roundedFloor = e1rmFloorLoad.map { E1RMCalculator.rounded($0, increment: bumpIncrement, unit: unit) }
            let bumpTarget = max(ceiling, roundedFloor ?? ceiling)                // floor can only raise
            return min(bumpTarget, ceiling, baseLoad * 2.0)                       // capped at the ceiling; RULE 6 2× cap preserved
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
                let reduced = E1RMCalculator.rounded(baseLoad * 0.95, increment: minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit), unit: unit)
                let msg: String
                let lead = "Reps came in well under the bottom of the range across multiple sets."
                if isProgressionExempt {
                    // Fixed-load: no load number and no claim of a lowering or a landing, for
                    // any target state — carry-forward never writes an exempt exercise's plan.
                    msg = "\(lead) Load is fixed on this exercise; change it yourself if you want to rebuild in range."
                } else if case .unresolved = carryForwardTarget {
                    msg = "\(lead) Backing the load down to \(LoadFormatter(unit: unit).oneDecimal(reduced)) next session to rebuild in range."
                } else {
                    switch forward(for: item, target: carryForwardTarget, writeBlocked: writeBlocked) {
                    case .lands(let landing):
                        msg = "\(lead) Backing the load down to rebuild in range. \(landing): \(compactLoad(reduced, unit: unit))."
                    case .editedKept(let kept):
                        msg = "\(lead) Backing the load down to rebuild in range. \(kept)"
                    case .endOfChain:
                        msg = "\(lead) Backing the load down to rebuild in range. \(carriesForwardClause)"
                    case .silent:
                        msg = "\(lead) Backing the load down to rebuild in range."
                    }
                }
                return CoachingRecommendation(message: msg, nextSuggestedLoad: reduced)
            }
            let msg = isProgressionExempt
                ? "Your best \(primaryWorkPhrase) came in below the planned range (\(repMin)–\(repMax) reps). Hold this load and focus on hitting the bottom of the range."
                : "Your best \(primaryWorkPhrase) came in below the planned range (\(repMin)–\(repMax) reps). Hold this load and focus on hitting the bottom of the range before considering an increase."
            return CoachingRecommendation(message: msg + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
        }

        // RULE 4b — Flagged load: the source session's load was TEMPORARILY or
        // DELIBERATELY reduced (joint tenderness, general fatigue, programmed
        // deload). Clearing the top of the range at that reduced load says nothing
        // about readiness to progress the real plan, so no bump is earned and
        // nothing is written — nextSuggestedLoad is nil so the already-planned
        // load is left exactly as it stands. equipmentConstraint is NOT suppressed:
        // the rack rung dictated the number, not the lifter's state.
        //
        // Placed after RULE 4 so a genuine under-performance at the reduced load
        // still holds or reduces normally; only the upward paths are blocked.
        if let overrideReason = item.loadOverrideReason,
           overrideReason.suppressesEarnedProgression,
           rirOnTarget,
           allSetsAtTop || overPerformed {
            let msg = isProgressionExempt
                ? "This session was flagged as \(overrideReason.displayName.lowercased()), so the load you lifted was already reduced. Hitting the top of the range there doesn't move the plan — your existing plan holds."
                : "This session was flagged as \(overrideReason.displayName.lowercased()), so the load you lifted was already reduced. Hitting the top of the range there doesn't move the plan — your existing plan holds. Log an unflagged session at the planned load to earn an increase."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: nil)
        }

        // RULE 4c — Fixed-load exercise (per-exercise exemption, set by the lifter —
        // e.g. a fixed-load track; the lifter raises it). Same shape
        // as RULE 4b: blocks the UPWARD paths only. Exactly the conditions under which
        // RULE 5a/5b would fire (all primary sets at the top at target RIR) return a
        // fixed message and a nil load, so nothing is written and the plan stands.
        // Pain, fatigue, failure, drop, incomplete and under-range handling all ran
        // above and are untouched; 5c/5d holds below are not upward and are untouched.
        if isProgressionExempt, rirOnTarget, allSetsAtTop || overPerformed {
            return CoachingRecommendation(
                message: "Fixed-load exercise: load doesn't auto-progress. Change it yourself when you're ready.",
                nextSuggestedLoad: nil
            )
        }

        // RULE 5 — Progression (double progression). Reached only when safe, complete,
        // and at least at the bottom of the range.

        // 5a) Over-performed: all sets ≥ repMax+2 at target RIR → bump (floor-aware) [was path 4]
        if overPerformed && rirOnTarget {
            let target = qualifyingBump()
            if let cap = loadCap, target > cap.max {
                return CoachingRecommendation(message: cap.message(streakHint: true, unit: unit), nextSuggestedLoad: cap.max)
            }
            let lead = "Reps came in well above the top of your range with room to spare."
            let msg: String
            switch forward(for: item, target: carryForwardTarget, writeBlocked: writeBlocked) {
            case .lands(let landing):
                msg = "\(lead) \(landing): \(LoadFormatter(unit: unit).oneDecimal(target)).\(pumpNote)"
            case .editedKept(let kept):
                msg = "\(lead) \(kept)\(pumpNote)"
            case .endOfChain:
                msg = "\(lead) \(carriesForwardClause)\(pumpNote)"
            case .silent:
                msg = "\(lead)\(pumpNote)"
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: target)
        }

        // 5b) ALL primary sets at the top at target RIR → increase earned (floor-aware).
        //     The core double-progression bump [replaces paths 3.5 / 5.5].
        if allSetsAtTop && rirOnTarget {
            let target = qualifyingBump()
            if let cap = loadCap, target > cap.max {
                return CoachingRecommendation(message: cap.message(streakHint: true, unit: unit), nextSuggestedLoad: cap.max)
            }
            let lead = "Every working set hit the top of your range at the target difficulty — increase earned."
            let msg: String
            switch forward(for: item, target: carryForwardTarget, writeBlocked: writeBlocked) {
            case .lands(let landing):
                msg = "\(lead) \(landing): \(LoadFormatter(unit: unit).oneDecimal(target)).\(pumpNote)"
            case .editedKept(let kept):
                msg = "\(lead) \(kept)\(pumpNote)"
            case .endOfChain:
                msg = "\(lead) \(carriesForwardClause)\(pumpNote)"
            case .silent:
                msg = "\(lead)\(pumpNote)"
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: target)
        }

        // 5c) Clean but not yet at the top: in range and on-target RIR, but not every
        //     set at repMax → HOLD and climb reps toward the top next session. This is
        //     the key behavior change — partial progress no longer bumps [was path 5].
        if bestReps >= repMin && rirOnTarget {
            let msg = isProgressionExempt
                ? "In range at the target effort. Load is fixed on this exercise: keep it where it is, and change it yourself when you're ready."
                : "On target and in range — hold \(LoadFormatter(unit: unit).oneDecimal(baseLoad)). Hit the top of your range (\(repMax)) on all working sets to earn the increase; climb your reps next session."
            return CoachingRecommendation(message: msg + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
        }

        // 5d) Not clean (in range but off-target RIR) → hold [was catch-all G]
        let msg = isProgressionExempt
            ? "Effort was off the target. Hold this load; it is fixed on this exercise, so change it yourself when you're ready."
            : "Performance didn't clearly support an increase. Hold this load and look for more consistent output next session before moving up."
        return CoachingRecommendation(message: msg + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
    }
}

// MARK: - Resolving a load cap

extension CoachingEngine.LoadCap {

    /// The cap for `item`'s exercise, or nil when none applies (no max set, a fixed-load exercise, a bodyweight one).
    /// `priorToppedStreak` counts, most recent first, the consecutive earlier completed sessions of the SAME block,
    /// day type and wave letter whose back-off sets all reached the top of the rep range at the cap load.
    static func resolve(
        for item: SessionItem,
        in session: Session?,
        allSessions: [Session],
        profile: UserProfile?,
        customExercises: [CustomExercise] = []
    ) -> CoachingEngine.LoadCap? {
        guard let cap = UserProfile.effectiveMaxLoad(for: item.exerciseId, profile: profile, customExercises: customExercises) else {
            return nil
        }
        var streak = 0
        if let session {
            let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
            let wave = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let mesoID = session.meso?.persistentModelID
            let earlier = allSessions
                .filter { $0 !== session && $0.status == .completed && $0.date < session.date
                    && $0.meso?.persistentModelID == mesoID
                    && SessionDayLabelMatcher.matches($0.dayLabel, session.dayLabel) }
                .sorted { $0.date > $1.date }
            for s in earlier {
                guard let match = s.items.first(where: {
                    ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
                        && ($0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") == wave
                }) else { continue }
                guard toppedRangeAtCap(match, cap: cap, unit: profile?.loadUnit ?? .lb) else { break }
                streak += 1
            }
        }
        return CoachingEngine.LoadCap(max: cap, priorToppedStreak: streak)
    }

    /// Equal-to-the-cap check with a tolerance in lb: 0.001 for lb (as before); for kg, half of the 0.01 kg a
    /// kg display can hide (0.005 kg is 0.011 lb), so a logged "45.36" still counts as the cap.
    private static func toppedRangeAtCap(_ item: SessionItem, cap: Double, unit: LoadUnit = .lb) -> Bool {
        let tolerance = unit == .lb ? 0.001 : 0.012
        let rows = CoachingEngine.plannedWorkingSetIndices(for: item)
        guard rows.count >= CoachingEngine.requiredPrimarySets(for: item) else { return false }
        let topReps = item.repMax ?? item.targetReps
        let primary = rows.prefix(min(Swift.max(1, item.targetSets), 3))
        return primary.allSatisfy { item.actualReps[$0] >= topReps && item.actualLoads[$0] >= cap - tolerance }
    }
}
