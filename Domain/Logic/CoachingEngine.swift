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

/// The progression rules that are open to comparison in the lifter simulation. An injected VALUE (never process-wide state): every
/// decision function takes one, defaulting to `.shipped`, which is today's behaviour. The app only ever uses `.shipped`
/// (`CoachingPolicySourceGuardTests` fails on any other use in app code).
struct CoachingPolicy: Equatable {
    /// How the repeat-performance valve judges the repeat exposure.
    enum ValveRule: Equatable {
        /// Every counted set at the top of the range, no set more than 1 RIR below target. (shipped)
        case allSetsAtTop
        /// Raw total at the threshold (sets x top - 1), no set more than 1 RIR below target.
        case totalAtThresholdNoSetBelowOne
    }
    /// How many prescribed sets the progression decision reads.
    enum CountCap: Equatable {
        /// Every prescribed working set. (shipped)
        case allPrescribed
        /// The first three (the rule before 1.4 (27)).
        case firstThree
    }
    /// How a set logged harder than planned loses reps.
    enum RIRTolerance: Equatable {
        /// reps - max(0, target - recorded). (shipped)
        case strict
        /// One RIR of slack per set: reps - max(0, target - recorded - 1).
        case oneRIRPerSet
    }
    /// Whether a lifter whose recent ratings carry no information is judged on reps alone.
    enum UninformativeRule: Equatable {
        /// Ratings are always read (the rule before 1.4 (28)).
        case off
        /// Every compound rating in the last 2 completed sessions (at least 6 rated sets) is 0: RIR is treated as unset everywhere it is read
        /// (progression, the e1RM estimates, the cross-letter and hold-from-high-rep estimates) until any non-zero rating is logged. (shipped)
        case lifterLevel
    }
    var valveRule: ValveRule = .allSetsAtTop
    var uninformativeRule: UninformativeRule = .lifterLevel
    var countCap: CountCap = .allPrescribed
    var rirTolerance: RIRTolerance = .strict

    static let shipped = CoachingPolicy()

    /// Reps a set loses to effort under this policy's tolerance.
    func shortfall(targetRIR: Int, recordedRIR: Int) -> Int {
        max(0, targetRIR - recordedRIR - (rirTolerance == .oneRIRPerSet ? 1 : 0))
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

    /// A set the lifter PERFORMED: reps and load logged, or a failed attempt (load > 0, no reps, not skipped). Skipped sets
    /// (the "SKIP" marker, with their pain / soreness / disruption / fatigue reason) and sets never touched (load 0) are
    /// not. This is how a 0-rep failure is told from an unlogged set (OPEN Q17): the attempted load is what marks it.
    static func isPerformedRow(_ item: SessionItem, row i: Int) -> Bool {
        guard item.actualLoads.indices.contains(i), item.actualReps.indices.contains(i), item.actualLoads[i] > 0 else { return false }
        if item.actualReps[i] > 0 { return true }
        return !WorkingSetFilter.isSkipped(item, row: i)
    }

    /// Back-off rows (every row that is not a top row) the lifter performed (`isPerformedRow`), before the
    /// warm-up cull. On an item with no top set this is every performed row.
    private static func loggedRowIndices(for item: SessionItem) -> [Int] {
        let count = min(item.actualReps.count, item.actualLoads.count)
        return (0..<count).filter { isPerformedRow(item, row: $0) && !item.isTopRow($0) }
    }

    /// The load the coach holds when it cannot call a progression: the last performed primary back-off set (the first up
    /// to 3 planned working sets, as every progression rule reads them). nil when nothing was performed.
    static func heldLoad(for item: SessionItem, policy: CoachingPolicy = .shipped) -> Double? {
        guard let last = countedSets(for: item, policy: policy).rows.last else { return nil }
        return item.actualLoads[last]
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
    /// Resolution order: the lifter's per-exercise step (`perExerciseStep`) > the default load step (`minLoadIncrement`) > the
    /// cluster default > a base-scaled fallback. Callers that hold a profile pass `UserProfile.loadStepOverride`.
    static func loadIncrement(for item: SessionItem, base: Double, minLoadIncrement: Double?, unit: LoadUnit = .lb,
                              perExerciseStep: Double? = nil) -> Double {
        if let own = perExerciseStep, own > 0 { return own }
        if let increment = minLoadIncrement, increment > 0 { return increment }
        if let cluster = ExerciseCatalog.cluster(for: item.exerciseId) {
            return UnitAwareRounding.increment(fromLb: ChestArmsLowBackMesoProfile.config(for: cluster).primaryLoadIncrement, unit: unit)
        }
        return UnitAwareRounding.fallbackIncrement(forBaseLb: base, unit: unit)
    }

    /// The recommendation with the lifter's own step and unit, as carry-forward uses them. The recap reads this so the
    /// "next" it shows is the load carry-forward writes (it used to omit the increment and fall back to a base-scaled step).
    static func recommend(for item: SessionItem, profile: UserProfile?, policy: CoachingPolicy = .shipped, ratingsUninformative: Bool = false) -> CoachingRecommendation? {
        let unit = profile?.loadUnit ?? .lb
        return recommend(for: item, policy: policy,
                         minLoadIncrement: UserProfile.loadStep(for: item.exerciseId, profile: profile, unit: unit),
                         unit: unit, ratingsUninformative: ratingsUninformative)
    }

    /// `base` plus one `step` (in `unit`). lb: the plain sum, unrounded, exactly as before. kg: snapped to the kg step, so
    /// a base that is not on a kg step (an old lb value) still produces a load a kg lifter can put on the bar.
    static func steppedUp(_ base: Double, step: Double, unit: LoadUnit) -> Double {
        let sum = base + UnitAwareRounding.stepLb(step, unit: unit)
        return unit == .lb ? sum : UnitAwareRounding.round(sum, increment: step, unit: unit)
    }

    /// RIR-adjusted reps: `reps - max(0, targetRIR - recordedRIR)`. A set logged harder than planned loses the reps it cost; one logged
    /// easier gets no credit. `recordedRIR` nil (unset, effort tracking Off, or an isolation lift, which `RIREntry.decisionRIR` never reads)
    /// means NO adjustment, and a recorded 0 is a real 0. One formula for progression and for PlaceholderRefresh's hold-from-high-rep rule.
    static func adjustedReps(_ reps: Int, targetRIR: Int, recordedRIR: Int?, policy: CoachingPolicy = .shipped) -> Int {
        guard let recordedRIR else { return reps }
        return reps - policy.shortfall(targetRIR: targetRIR, recordedRIR: recordedRIR)
    }

    /// True when the previous exposure of this lift (same block, day type and wave letter, the latest completed one before `session`)
    /// was an RIR-adjustment hold: its reps alone would have earned an increase, its effort-adjusted reps did not. Feeds the repeat-performance valve.
    static func priorExposureWasRIRHold(for item: SessionItem, in session: Session?, allSessions: [Session], policy: CoachingPolicy = .shipped) -> Bool {
        guard let session, RIREntry.isCompound(item.exerciseId), EffortTracking.mode != .off else { return false }
        let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let letter = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let mesoID = session.meso?.persistentModelID
        let previousItems = allSessions
            .filter { $0 !== session && $0.status == .completed && $0.date < session.date && $0.meso?.persistentModelID == mesoID
                && SessionDayLabelMatcher.matches($0.dayLabel, session.dayLabel) }
            .sorted { $0.date > $1.date }
            .lazy.compactMap { s in s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
                && ($0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") == letter } }
        guard let previous = previousItems.first, previous.waveRaw?.lowercased() != "deload" else { return false }
        return isRIRAdjustmentHold(previous, policy: policy)
    }

    // MARK: - `.lifterLevel`: "ratings not informative" for the whole lifter

    /// `.lifterLevel`: every compound rating in the last 2 completed sessions up to `session` (at least 6 rated working sets) is 0. Reads the RAW
    /// ratings (so a non-zero one clears it at once); false when effort tracking is Off (nothing to ignore).
    static func lifterRatingsUninformative(asOf session: Session?, allSessions: [Session], policy: CoachingPolicy) -> Bool {
        guard policy.uninformativeRule == .lifterLevel, EffortTracking.mode != .off, let session else { return false }
        let recent = allSessions
            .filter { ($0 === session || $0.status == .completed) && $0.date <= session.date }
            .sorted { $0.date > $1.date }.prefix(2)
        var rated = 0
        for s in recent {
            for item in s.items where RIREntry.isCompound(item.exerciseId) && item.waveRaw?.lowercased() != "deload" {
                for idx in workingSetIndices(for: item) {
                    guard let r = RIREntry.recorded(item, at: idx) else { continue }
                    if r != 0 { return false }
                    rated += 1
                }
            }
        }
        return rated >= 6
    }

    /// The one-time effort note for `.lifterLevel`, once per LIFTER and shown at session level (the recap), never on a lift's coach line.
    static func lifterNote(mode: EffortMode = EffortTracking.mode) -> String {
        switch mode {
        case .simple: return "Every set was tapped All out, so progression is judged on your reps for now. If you had reps left, try Hard or Solid, or set effort to Off in Settings."
        case .detailed: return "Every set was rated 0 RIR, so progression is judged on your reps for now. If you had reps left, log 1–3 RIR, or set effort to Off in Settings."
        case .off: return ""
        }
    }

    /// Non-nil only for the session at which the lifter-level mark first holds (no earlier completed session had it).
    static func lifterNoteDue(asOf session: Session?, allSessions: [Session], policy: CoachingPolicy, mode: EffortMode = EffortTracking.mode) -> String? {
        guard mode != .off, let session, lifterRatingsUninformative(asOf: session, allSessions: allSessions, policy: policy) else { return nil }
        for s in allSessions where s !== session && s.status == .completed && s.date < session.date {
            if lifterRatingsUninformative(asOf: s, allSessions: allSessions, policy: policy) { return nil }
        }
        return lifterNote(mode: mode)
    }

    /// Reps alone (effort ignored) would increase the load; with effort counted it does not.
    static func isRIRAdjustmentHold(_ item: SessionItem, policy: CoachingPolicy = .shipped) -> Bool {
        guard RIREntry.isCompound(item.exerciseId) else { return false }
        let working = workingSetIndices(for: item)
        guard let base = working.map({ item.actualLoads[$0] }).last, base > 0 else { return false }
        func increases(_ rec: CoachingRecommendation?) -> Bool {
            guard let next = rec?.nextSuggestedLoad ?? rec?.nextTopLoad else { return false }
            return next > base + 0.001
        }
        return increases(recommend(for: item, policy: policy, ignoreEffort: true)) && !increases(recommend(for: item, policy: policy))
    }

    /// "set 3 was 1 rep harder than planned (RIR 1 vs 2)" / "sets 2–3 were 1 rep harder than planned (RIR 1 vs 2)" (Detailed) or
    /// "set 3 was Hard, plan Solid" (Simple): which sets the RIR adjustment took reps from, and by how much. Sets with the same shortfall
    /// (Detailed) or the same effort word (Simple) are listed together, consecutive numbers as a range. Nil when nothing was adjusted.
    /// `noun` names a row ("set", "top set"); `sole` says there is only one row of that kind ("the top set").
    static func adjustmentClause(_ adjusted: [(number: Int, rir: Int)], targetRIR: Int, noun: String = "set", sole: Bool = false,
                                 mode: EffortMode = EffortTracking.mode) -> String? {
        guard !adjusted.isEmpty, mode != .off else { return nil }
        var groups: [(key: String, nums: [Int], rir: Int, shortfall: Int)] = []
        for a in adjusted.sorted(by: { $0.number < $1.number }) {
            let shortfall = max(0, targetRIR - a.rir)
            let key = mode == .simple ? (EffortTracking.simpleLabel(for: a.rir) ?? EffortTracking.plannedWord(a.rir)) : "\(shortfall)|\(a.rir)"
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].nums.append(a.number) }
            else { groups.append((key, [a.number], a.rir, shortfall)) }
        }
        func list(_ nums: [Int]) -> String {
            if nums.count == 1 { return sole ? "the \(noun)" : "\(noun) \(nums[0])" }
            var ranges: [String] = []
            var start = nums[0], prev = nums[0]
            func close() { ranges.append(start == prev ? "\(start)" : "\(start)–\(prev)") }
            for n in nums.dropFirst() { if n == prev + 1 { prev = n } else { close(); start = n; prev = n } }
            close()
            return "\(noun)s " + ranges.joined(separator: ", ")
        }
        let parts = groups.map { g -> String in
            let verb = g.nums.count == 1 ? "was" : "were"
            if mode == .simple { return "\(list(g.nums)) \(verb) \(g.key), plan \(EffortTracking.plannedWord(targetRIR))" }
            return "\(list(g.nums)) \(verb) \(g.shortfall) rep\(g.shortfall == 1 ? "" : "s") harder than planned (RIR \(g.rir) vs \(targetRIR))"
        }
        return parts.joined(separator: "; ")
    }

    /// The note on a COMPLETED item with fewer logged sets than planned: "1 of 3 planned sets logged (2 flagged disruption) — load held next
    /// time." `skips` are the reasons of the skipped planned sets (`.none` = skipped with no reason). Nil when every planned set was logged.
    /// It cites no load, so the stale-note hygiene never hides it.
    static func shortItemNote(planned: Int, logged: Int, skips: [SetFeedback]) -> String? {
        guard planned > 0, logged < planned else { return nil }
        var order: [SetFeedback] = []
        for s in skips where !order.contains(s) { order.append(s) }
        let parts = order.map { reason -> String in
            let n = skips.filter { $0 == reason }.count
            return reason == .none ? "\(n) skipped" : "\(n) flagged \(reason.rawValue)"
        }
        let tail = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "ℹ️ \(logged) of \(planned) planned sets logged\(tail) — load held next time."
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

    /// The sets the progression decision reads: EVERY prescribed working set (`prescribedSets`, capped by the sets this session runs), except
    ///   - top-set rows (never back-offs: they are read on their own),
    ///   - rows beyond the prescribed sets (a set the lifter added, or one the program marks as earnable),
    ///   - on an item without set roles, ONE row heavier than all the others by more than one load step when all the others share one
    ///     load (a top set logged as a back-off row). Any other spread of loads is a ramp or pyramid: every prescribed set counts.
    struct CountedSets {
        /// The counted rows, in order.
        let rows: [Int]
        /// How many sets the decision needs: the prescribed sets, less the heavy rows taken out.
        let required: Int
        /// Rows logged heavier than the working load (no set roles): counted as top sets, not working sets.
        let heavy: [Int]
        /// Working rows beyond the prescribed sets.
        let extras: [Int]
    }

    static func countedSets(for item: SessionItem, minLoadIncrement: Double? = nil, unit: LoadUnit = .lb, policy: CoachingPolicy = .shipped) -> CountedSets {
        let working = workingSetIndices(for: item)
        let warmupRows = loggedRowIndices(for: item).count - working.count
        let prescribedWindow = max(1, min(item.effectivePrescribedSets, max(1, item.targetSets)))
        let window = policy.countCap == .firstThree ? min(prescribedWindow, 3) : prescribedWindow
        let limit = window + warmupRows
        let inWindow = working.filter { $0 < limit }
        let extras = working.filter { $0 >= limit }
        var heavy: [Int] = []
        if item.setRolesBySet == nil, inWindow.count >= 3 {
            // One row is a top set only when every OTHER row shares one load and it is heavier than that load by more than a step.
            // Anything else (an ascending ramp, a pyramid, mixed loads) is not a top set: every prescribed set counts.
            if let heaviest = inWindow.max(by: { item.actualLoads[$0] < item.actualLoads[$1] }) {
                let others = inWindow.filter { $0 != heaviest }.map { item.actualLoads[$0] }
                if let flat = others.first, others.allSatisfy({ abs($0 - flat) < 0.0001 }) {
                    let step = loadIncrement(for: item, base: flat, minLoadIncrement: minLoadIncrement, unit: unit)
                    if item.actualLoads[heaviest] > flat + step + 0.0001 { heavy = [heaviest] }
                }
            }
        }
        return CountedSets(rows: inWindow.filter { !heavy.contains($0) }, required: max(1, window - heavy.count), heavy: heavy, extras: extras)
    }

    /// Primary working sets the progression decision needs (see `countedSets`).
    static func requiredPrimarySets(for item: SessionItem, policy: CoachingPolicy = .shipped) -> Int {
        countedSets(for: item, policy: policy).required
    }

    /// True when enough primary working sets were logged for a load to be written onto a
    /// future plan. A 4-set item with 3 logged qualifies.
    static func hasSufficientPrimaryEvidence(_ item: SessionItem, policy: CoachingPolicy = .shipped) -> Bool {
        let c = countedSets(for: item, policy: policy)
        return c.rows.count >= c.required
    }

    /// What to say instead of a number when the chain has ended.
    private static let carriesForwardClause =
        "That carries into your next block."

    /// The coach's read of one exercise. An item without a top set is judged exactly as before; with
    /// one, the top rows get their own read (against topRepMin/Max and topRIR) and every back-off
    /// decision uses back-off rows only.
    static func recommend(
        for item: SessionItem,
        policy: CoachingPolicy = .shipped,
        minLoadIncrement: Double? = nil,
        unit: LoadUnit = .lb,
        mesoPhase: MesoPhase = .early,
        consecutiveCleanCount: Int = 0,
        e1rmFloorLoad: Double? = nil,
        peakE1RM: Double? = nil,
        lastKnownLoad: Double? = nil,
        carryForwardTarget: CarryForwardTarget = .unresolved,
        priorExposureWasRIRHold: Bool = false,
        ratingsUninformative: Bool = false,
        isProgressionExempt: Bool = false,
        loadCap: LoadCap? = nil,
        ignoreEffort: Bool = false
    ) -> CoachingRecommendation? {
        let rec = recommendRoles(
            for: item, policy: policy, minLoadIncrement: minLoadIncrement, unit: unit, mesoPhase: mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount, e1rmFloorLoad: e1rmFloorLoad,
            peakE1RM: peakE1RM, lastKnownLoad: lastKnownLoad,
            carryForwardTarget: carryForwardTarget, isProgressionExempt: isProgressionExempt, loadCap: loadCap,
            priorExposureWasRIRHold: ratingsUninformative ? false : priorExposureWasRIRHold, ignoreEffort: ignoreEffort || ratingsUninformative
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
        policy: CoachingPolicy,
        minLoadIncrement: Double?,
        unit: LoadUnit,
        mesoPhase: MesoPhase,
        consecutiveCleanCount: Int,
        e1rmFloorLoad: Double?,
        peakE1RM: Double?,
        lastKnownLoad: Double?,
        carryForwardTarget: CarryForwardTarget,
        isProgressionExempt: Bool,
        loadCap: LoadCap?,
        priorExposureWasRIRHold: Bool,
        ignoreEffort: Bool
    ) -> CoachingRecommendation? {
        let back = recommendBackOffs(
            for: item, policy: policy, minLoadIncrement: minLoadIncrement, unit: unit, mesoPhase: mesoPhase,
            consecutiveCleanCount: consecutiveCleanCount, e1rmFloorLoad: e1rmFloorLoad,
            peakE1RM: peakE1RM, lastKnownLoad: lastKnownLoad,
            carryForwardTarget: carryForwardTarget, isProgressionExempt: isProgressionExempt, loadCap: loadCap,
            priorExposureWasRIRHold: priorExposureWasRIRHold, ignoreEffort: ignoreEffort
        )
        guard item.hasTopSet else { return back }
        // Deload keeps its maintenance message; a pain flag stops every call, top set included.
        if item.waveRaw?.lowercased() == "deload" { return back }
        let painFlagged = item.setFeedbackBySet.contains { $0 == SetFeedback.pain.rawValue }
        if painFlagged { return back }
        guard let top = topRead(for: item, policy: policy, minLoadIncrement: minLoadIncrement, unit: unit, isProgressionExempt: isProgressionExempt,
                                loadCap: loadCap, ignoreEffort: ignoreEffort) else {
            return back
        }
        let message = [top.message, back?.message].compactMap { $0 }.joined(separator: " ")
        return CoachingRecommendation(message: message, nextSuggestedLoad: back?.nextSuggestedLoad, nextTopLoad: top.nextTopLoad)
    }

    private struct TopRead { let message: String; let nextTopLoad: Double? }

    /// Judges the logged top rows: reps against topRepMin/Max, RIR against topRIR. Hold, or a
    /// one-increment bump when every top row is at the top of its range at the target difficulty.
    private static func topRead(for item: SessionItem, policy: CoachingPolicy, minLoadIncrement: Double?, unit: LoadUnit, isProgressionExempt: Bool,
                                loadCap: LoadCap? = nil, ignoreEffort: Bool = false) -> TopRead? {
        let rows = topWorkingIndices(for: item)
        guard let lastRow = rows.last else { return nil }
        let reps = rows.map { item.actualReps[$0] }
        let load = item.actualLoads[lastRow]
        let lo = item.topRepMin ?? item.repMin ?? item.targetReps
        let hi = max(lo, item.topRepMax ?? item.repMax ?? item.targetReps)
        let targetRIR = item.topRIR ?? item.targetRIR
        let adjusted = rows.map { adjustedReps(item.actualReps[$0], targetRIR: targetRIR, recordedRIR: ignoreEffort ? nil : RIREntry.decisionRIR(item, at: $0), policy: policy) }
        // Top rows the RIR adjustment took reps from, numbered among the top rows.
        let adjustedTops: [(number: Int, rir: Int)] = rows.enumerated().compactMap { n, idx in
            guard !ignoreEffort, let r = RIREntry.decisionRIR(item, at: idx), policy.shortfall(targetRIR: targetRIR, recordedRIR: r) > 0 else { return nil }
            return (n + 1, r)
        }
        let neededText = rows.count == 1 ? "\(hi)" : "\(hi) on each"
        let what = "Top set: \(compactLoad(load, unit: unit)) x \(reps.map(String.init).joined(separator: ", "))"
        let range = lo == hi ? "\(lo)" : "\(lo)–\(hi)"

        let fatigue = rows.contains { idx in
            guard idx < item.setFeedbackBySet.count else { return false }
            return SetFeedback.holdsLoad(raw: item.setFeedbackBySet[idx])
        }
        if fatigue {
            return TopRead(message: "\(what) — soreness, disruption or fatigue flagged, hold this load.", nextTopLoad: load)
        }
        if (reps.min() ?? 0) < lo {
            return TopRead(message: "\(what), under the range (\(range)) — hold this load.", nextTopLoad: load)
        }
        if adjusted.allSatisfy({ $0 >= hi }) {
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
            let counted = adjustedTops.isEmpty ? "" : ", counted as \(adjusted.map(String.init).joined(separator: ", ")): \(adjustmentClause(adjustedTops, targetRIR: targetRIR, noun: "top set", sole: rows.count == 1) ?? "")."
            let needed = adjustedTops.isEmpty ? ", needed \(neededText) — increase earned." : " Needed \(neededText) — increase earned."
            return TopRead(message: "\(what)\(counted)\(needed) Next top set: \(compactLoad(next, unit: unit)).", nextTopLoad: next)
        }
        if reps.allSatisfy({ $0 >= hi }), let clause = adjustmentClause(adjustedTops, targetRIR: targetRIR, noun: "top set", sole: rows.count == 1) {
            // At the top on the bar, but not at the planned effort: the adjusted count is what falls short.
            return TopRead(message: "\(what), counted as \(adjusted.map(String.init).joined(separator: ", ")): \(clause). Needed \(neededText) — hold this load.", nextTopLoad: load)
        }
        return TopRead(message: "\(what), needed \(neededText) — hold.", nextTopLoad: load)
    }

    private static func recommendBackOffs(
        for item: SessionItem,
        policy: CoachingPolicy = .shipped,
        minLoadIncrement: Double? = nil,
        unit: LoadUnit = .lb,
        mesoPhase: MesoPhase = .early,
        consecutiveCleanCount: Int = 0,
        e1rmFloorLoad: Double? = nil,
        peakE1RM: Double? = nil,
        lastKnownLoad: Double? = nil,
        carryForwardTarget: CarryForwardTarget = .unresolved,
        isProgressionExempt: Bool = false,
        loadCap: LoadCap? = nil,
        priorExposureWasRIRHold: Bool = false,
        ignoreEffort: Bool = false
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

        // Guard 5 — Soreness/disruption/fatigue flag: captured here, applied as override below
        let hasFatigueFlag = (0..<min(count, item.setFeedbackBySet.count)).contains {
            SetFeedback.holdsLoad(raw: item.setFeedbackBySet[$0])
        }

        let workingIndices = workingSetIndices(for: item)
        guard !workingIndices.isEmpty else { return nil }

        let plannedWorkingSetCount = max(1, item.targetSets)
        let counted = countedSets(for: item, minLoadIncrement: minLoadIncrement, unit: unit, policy: policy)
        let growthSetTarget = counted.required

        // Only rows inside the planned set count are evidence for the prescription. An extra
        // row (index >= targetSets) was judged against the wrong range and counted toward
        // "sets in"; with nothing but extra rows logged there is nothing to say.
        let plannedRows = plannedWorkingSetIndices(for: item)
        guard !plannedRows.isEmpty else { return nil }

        // Progression evaluates every prescribed working set (see `countedSets`)
        let primaryIndices = counted.rows

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

        // RIR is evidence only when the lifter recorded it on a compound lift. An unset RIR, or any isolation set, leaves
        // these empty: the set is judged on reps against the target alone and is never assumed "on target".
        var primaryRIRs: [Int] = []
        for idx in primaryIndices {
            if !ignoreEffort, let rir = RIREntry.decisionRIR(item, at: idx) { primaryRIRs.append(rir) }
        }

        let minRIR: Int? = primaryRIRs.min()
        // The primary sets the RIR adjustment took reps from (1-based set numbers), for the coach line.
        let adjustedSets: [(number: Int, rir: Int)] = primaryIndices.compactMap { idx in
            guard !ignoreEffort, let r = RIREntry.decisionRIR(item, at: idx), policy.shortfall(targetRIR: targetRIR, recordedRIR: r) > 0 else { return nil }
            return (idx + 1, r)
        }
        // RIR-adjusted reps of the primary sets (no adjustment where RIR is unset, Off, or an isolation lift).
        let primaryAdjusted = primaryIndices.map { adjustedReps(reps[$0], targetRIR: targetRIR, recordedRIR: ignoreEffort ? nil : RIREntry.decisionRIR(item, at: $0), policy: policy) }

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
            case 3: return "first 3 working sets"
            default: return "\(growthSetTarget) working sets"
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
            if !hasSoreness && !hasDisruption {
                // Fatigue only (a set skipped or flagged as tired).
                msg = isProgressionExempt
                    ? "Fatigue was flagged this session. Hold this load."
                    : "Fatigue was flagged this session. Hold this load — a tired session isn't a reliable read for an increase."
            } else if hasSoreness && hasDisruption {
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
        // No separate RIR gate: effort is folded into the reps themselves (RIR-adjusted reps, `adjustedReps`), so a set that cost more
        // than planned counts for fewer reps and everything below reads the adjusted counts.
        // Double-progression trigger (decision B): EVERY primary working set at/above
        // the top of the range — not the best set. Uses the warmup-culled primary sets.
        let allSetsAtTop = primaryReps.count >= growthSetTarget && primaryAdjusted.allSatisfy { $0 >= repMax }
        // Compound lifts earn an increase on TOTAL reps over the primary working sets (the first up to 3, as every other
        // progression rule reads them; a 4th or later row is not evidence): the ADJUSTED reps add up to at least sets x top-of-range
        // minus one (21/24 holds, 23/24 earns). Isolation lifts keep the every-set-at-the-top rule, on adjusted reps too.
        let isCompoundLift = RIREntry.isCompound(item.exerciseId)
        let totalReps = primaryReps.reduce(0, +)
        let adjustedTotal = primaryAdjusted.reduce(0, +)
        let totalGoal = primaryReps.count * repMax
        let totalRepsEarned = adjustedTotal >= totalGoal - 1
        // The compound coach line: the raw reps, what they count as when effort took some off, which sets and by how much, and the
        // threshold actually needed (sets x top - 1).
        // Working sets the lifter did beyond the sets the verdict reads (the first up to 3): the line says so, with their reps, so the
        // total is not mistaken for everything that was done ("30 reps on 3 prescribed sets (+1 extra set: 10)").
        let extraReps: [Int] = counted.extras.map { reps[$0] }
        let heavyNotes: [String] = counted.heavy.map { "set \($0 + 1) at \(LoadFormatter(unit: unit).truncated(loads[$0])) counted as a top set, not a working set" }
        let setsBasis: String = {
            let n = primaryIndices.count
            guard n > 0, !(extraReps.isEmpty && heavyNotes.isEmpty) else { return "" }
            var parts: [String] = []
            if !extraReps.isEmpty { parts.append("+\(extraReps.count) extra set\(extraReps.count == 1 ? "" : "s"): \(extraReps.map(String.init).joined(separator: ", "))") }
            parts += heavyNotes
            return " on \(n) prescribed set\(n == 1 ? "" : "s") (\(parts.joined(separator: "; ")))"
        }()
        func totalsLine(_ verdict: String) -> String {
            let needed = totalGoal - 1
            if let clause = Self.adjustmentClause(adjustedSets, targetRIR: targetRIR) {
                return "\(totalReps) reps\(setsBasis), counted as \(adjustedTotal): \(clause). Needed \(needed) — \(verdict)."
            }
            return "\(totalReps) reps\(setsBasis), needed \(needed) — \(verdict)."
        }
        let earnedByAdjustedReps = isCompoundLift ? totalRepsEarned : allSetsAtTop
        // Repeat-performance valve: the previous exposure of this lift (same letter) was held only because effort took reps off its count, and
        // this one again has EVERY set at the top of the range with no recorded set more than 1 RIR below target: the same reps at about the
        // planned effort twice running earn the increase. Never on a first exposure (the caller says whether the previous one was such a hold).
        let repeatPerformance = priorExposureWasRIRHold && isCompoundLift && !earnedByAdjustedReps
            && primaryReps.count >= growthSetTarget
            && (policy.valveRule == .totalAtThresholdNoSetBelowOne ? totalReps >= totalGoal - 1 : primaryReps.allSatisfy { $0 >= repMax })
            && primaryRIRs.allSatisfy { $0 >= targetRIR - 1 }
        let earnedByReps = earnedByAdjustedReps || repeatPerformance
        // Over-performed: every primary set two or more reps beyond the top.
        let overPerformed = primaryReps.count >= growthSetTarget && primaryAdjusted.allSatisfy { $0 >= repMax + 2 }

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
           earnedByReps || overPerformed {
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
        if isProgressionExempt, earnedByReps || overPerformed {
            return CoachingRecommendation(
                message: "Fixed-load exercise: load doesn't auto-progress. Change it yourself when you're ready.",
                nextSuggestedLoad: nil
            )
        }

        // RULE 5 — Progression (double progression). Reached only when safe, complete,
        // and at least at the bottom of the range.

        // 5a) Over-performed: all sets ≥ repMax+2 at target RIR → bump (floor-aware) [was path 4]
        if overPerformed {
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
        if earnedByReps {
            let target = qualifyingBump()
            if let cap = loadCap, target > cap.max {
                return CoachingRecommendation(message: cap.message(streakHint: true, unit: unit), nextSuggestedLoad: cap.max)
            }
            let lead = repeatPerformance
                ? "Same reps again at about planned effort — increase earned."
                : isCompoundLift
                ? totalsLine("increase earned")
                : "Every working set hit the top of your range — increase earned."
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
        if bestReps >= repMin {
            if isCompoundLift && !isProgressionExempt {
                return CoachingRecommendation(message: totalsLine("hold") + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
            }
            let msg = isProgressionExempt
                ? "In range at the target effort. Load is fixed on this exercise: keep it where it is, and change it yourself when you're ready."
                : "On target and in range — hold \(LoadFormatter(unit: unit).oneDecimal(baseLoad)). Hit the top of your range (\(repMax)) on all working sets to earn the increase; climb your reps next session."
            return CoachingRecommendation(message: msg + holdLanding(baseLoad), nextSuggestedLoad: baseLoad)
        }

        // 5d) Catch-all hold (unreachable while 5c covers every in-range case) [was catch-all G]
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
        let counted = CoachingEngine.countedSets(for: item, unit: unit)
        let rows = counted.rows
        guard rows.count >= counted.required else { return false }
        let topReps = item.repMax ?? item.targetReps
        let primary = rows
        return primary.allSatisfy { item.actualReps[$0] >= topReps && item.actualLoads[$0] >= cap - tolerance }
    }
}
