import Foundation
import SwiftData

/// Replaces one exercise with another in the remaining planned sessions of one day type,
/// keeping every wave prescription exactly as it was.
///
/// Two steps, so a UI can show a preview before anything is written:
/// 1. `planReplace` — pure read; lists the sessions that will change, the sessions that will not
///    (with the reason), and a seed load per wave letter.
/// 2. `apply` — re-plans against live state, aborts if the target set moved, writes in one save,
///    verifies the carry-forward chains and the preserved prescription, and rolls back on failure.
///
/// Only the exercise identity and the per-exercise state (loads, logged data, notes) change; the
/// prescription (`waveRaw`, sets, rep/RIR ranges, planned reps/RIR arrays, priority, order,
/// intensifier) is never touched, so `PlanMemoryEngine.nextTargetItem` keeps chaining on the same
/// wave letter and now finds the replacement exercise down the chain.
enum SessionItemEditService {

    enum ReplaceScope {
        case thisSession(Session)
        case allRemaining
    }

    enum RefusalReason: Equatable {
        /// Not `.planned`, or something on it has been logged (see `SessionEditSafety`).
        case unsafe
        /// The session already has the replacement exercise.
        case alreadyContainsReplacement
        /// The block is not the active one.
        case inactiveMeso
        /// `from` and `to` are the same exercise.
        case sameExercise
        /// `.thisSession` was asked for a session that is not on this day type, or has no `from` item.
        case notApplicable
        /// Prescription change: a deload-week item (left alone unless explicitly included).
        case deload
        /// Prescription change: the change would leave this session as it is (already at the bound).
        case noChange
    }

    struct Refusal {
        let session: Session
        let reason: RefusalReason
    }

    struct Target {
        let session: Session
        let item: SessionItem
        let date: Date
        let weekIndex: Int
        let waveRaw: String?
        /// "4 x 8-12 @ RIR 2-3" — straight from the item's own prescription.
        let prescription: String
        /// Load the replacement starts at, from completed history. Nil: nothing to seed from (the item starts at 0).
        let seedLoad: Double?
    }

    struct ReplacePlan {
        let meso: MesoBlock
        let dayLabel: String?
        let fromExerciseId: String      // canonical
        let toExerciseId: String        // canonical
        let scope: ReplaceScope
        let now: Date
        let targets: [Target]
        let refusals: [Refusal]
        /// First target's seed per wave letter (lowercased; "" for items with no wave), for the preview.
        let seedLoadByWave: [String: Double?]

        var isApplicable: Bool { !targets.isEmpty }
    }

    enum ReplaceError: Error, Equatable {
        case nothingToReplace
        /// A session in the block is being trained; nothing is edited underneath it.
        case sessionInProgress
        /// The live set of target sessions no longer matches the plan.
        case planStale(planned: Int, live: Int)
        case verificationFailed([String])
        case saveFailed(String)
    }

    /// Test seams (same pattern as `DUPMesoLengthConversion.ApplyHooks`): force the two rollback paths.
    struct ApplyHooks {
        var forceVerificationFailure = false
        var forceSaveFailure = false
        init(forceVerificationFailure: Bool = false, forceSaveFailure: Bool = false) {
            self.forceVerificationFailure = forceVerificationFailure
            self.forceSaveFailure = forceSaveFailure
        }
    }

    private struct ForcedSaveFailure: Error {}

    struct ApplyResult {
        let sessionsChanged: Int
        /// One line per changed session.
        let summary: [String]
    }

    // MARK: - Plan (no writes)

    static func planReplace(
        meso: MesoBlock,
        dayLabel: String?,
        from fromExerciseId: String,
        to toExerciseId: String,
        scope: ReplaceScope,
        context: ModelContext,
        now: Date = Date()
    ) -> ReplacePlan {
        let from = ExerciseCatalog.canonicalExerciseId(for: fromExerciseId)
        let to = ExerciseCatalog.canonicalExerciseId(for: toExerciseId)
        let startOfToday = Calendar.current.startOfDay(for: now)

        func plan(_ targets: [Target], _ refusals: [Refusal]) -> ReplacePlan {
            var seeds: [String: Double?] = [:]
            for t in targets {
                let key = t.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if seeds[key] == nil { seeds[key] = .some(t.seedLoad) }
            }
            return ReplacePlan(meso: meso, dayLabel: dayLabel, fromExerciseId: from, toExerciseId: to,
                               scope: scope, now: now, targets: targets, refusals: refusals, seedLoadByWave: seeds)
        }

        // Sessions of this day type that carry the outgoing exercise.
        let selected = selectCandidates(
            meso: meso, dayLabel: dayLabel, exercise: from, scope: scope, startOfToday: startOfToday
        )
        let candidates = selected.candidates
        var refusals = selected.refusals

        if from == to {
            return plan([], candidates.map { Refusal(session: $0.session, reason: .sameExercise) } + refusals)
        }

        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let increment = profile?.minLoadIncrement ?? 2.5

        var targets: [Target] = []
        for (session, item) in candidates {
            if let reason = safetyRefusal(meso: meso, session: session) {
                refusals.append(Refusal(session: session, reason: reason)); continue
            }
            if session.items.contains(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == to }) {
                refusals.append(Refusal(session: session, reason: .alreadyContainsReplacement)); continue
            }
            let seed = HistorySeedLoad.load(
                for: to, goalReps: item.targetReps, targetRIR: item.targetRIR, in: allSessions,
                loadIncrement: increment, bodyWeight: profile?.bodyWeight, customExercises: custom, referenceDate: now
            )
            targets.append(Target(
                session: session, item: item, date: session.date, weekIndex: session.weekIndex,
                waveRaw: item.waveRaw, prescription: prescriptionSummary(item), seedLoad: seed
            ))
        }
        return plan(targets, refusals)
    }

    // MARK: - Shared target selection

    /// Sessions of one day type holding `exercise` (canonical id) that are still "remaining": for
    /// `.allRemaining`, everything except completed sessions and missed (planned, before today, nothing
    /// logged) ones; for `.thisSession`, just that session. Safety is checked separately.
    private static func selectCandidates(
        meso: MesoBlock,
        dayLabel: String?,
        exercise: String,
        scope: ReplaceScope,
        startOfToday: Date
    ) -> (candidates: [(session: Session, item: SessionItem)], refusals: [Refusal]) {
        var candidates: [(session: Session, item: SessionItem)] = []
        var refusals: [Refusal] = []

        func item(in s: Session) -> SessionItem? {
            s.items.sorted { $0.order < $1.order }
                .first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == exercise }
        }

        switch scope {
        case .thisSession(let session):
            if let found = item(in: session),
               session.meso?.persistentModelID == meso.persistentModelID,
               SessionDayLabelMatcher.matches(session.dayLabel, dayLabel) {
                candidates = [(session, found)]
            } else {
                refusals.append(Refusal(session: session, reason: .notApplicable))
            }
        case .allRemaining:
            for s in meso.sessions.sorted(by: { $0.date < $1.date })
            where SessionDayLabelMatcher.matches(s.dayLabel, dayLabel) {
                guard let found = item(in: s) else { continue }
                // History is not "remaining": completed sessions, and planned ones from before today
                // with nothing logged (missed), are simply left alone. Today's session is remaining
                // whatever time of day it is dated.
                if s.status == .completed { continue }
                if s.status == .planned && s.date < startOfToday && !SessionEditSafety.hasLoggedData(s) { continue }
                candidates.append((s, found))
            }
        }
        return (candidates, refusals)
    }

    /// Why a candidate may not be edited: the block is not the active one, or the session is not a
    /// clean planned session.
    private static func safetyRefusal(meso: MesoBlock, session: Session) -> RefusalReason? {
        if meso.status != .active { return .inactiveMeso }
        if !SessionEditSafety.isSafeToModify(session) { return .unsafe }
        return nil
    }

    // MARK: - Apply

    @discardableResult
    static func apply(_ plan: ReplacePlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> ApplyResult {
        guard plan.isApplicable else { throw ReplaceError.nothingToReplace }
        guard !plan.meso.sessions.contains(where: { $0.status == .inProgress }) else {
            throw ReplaceError.sessionInProgress
        }

        // rollback() discards every unsaved change, so nothing may be pending when the writes start.
        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        // The plan is a preview; trust only live state. Same inputs, same `now`.
        let live = planReplace(
            meso: plan.meso, dayLabel: plan.dayLabel, from: plan.fromExerciseId, to: plan.toExerciseId,
            scope: plan.scope, context: context, now: plan.now
        )
        let plannedIDs = plan.targets.map { $0.session.persistentModelID }
        let liveIDs = live.targets.map { $0.session.persistentModelID }
        guard plannedIDs == liveIDs else {
            throw ReplaceError.planStale(planned: plannedIDs.count, live: liveIDs.count)
        }

        // Anything pending belongs to the caller; commit it so a rollback below is exact.
        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let toName = ExerciseCatalog.displayName(for: plan.toExerciseId)
        var before: [PrescriptionSnapshot] = []
        var restorePoints: [ItemRestorePoint] = []
        var summary: [String] = []

        /// `ModelContext.rollback()` discards inserts and deletes but does NOT revert property edits
        /// on live objects (see DUPMesoLengthConversion.Snapshot), so every field this method
        /// overwrites is recorded first and put back by hand before rolling back.
        func abandon() {
            for point in restorePoints { point.restore() }
            context.rollback()
        }

        for target in live.targets {
            let item = target.item
            before.append(PrescriptionSnapshot(item))
            restorePoints.append(ItemRestorePoint(item))

            item.exerciseId = plan.toExerciseId
            item.exerciseNameSnapshot = toName

            let sets = max(0, item.targetSets)
            let seed = target.seedLoad ?? 0
            item.suggestedLoad = seed
            item.plannedLoadsBySet = Array(repeating: seed, count: sets)

            item.actualLoads = Array(repeating: 0.0, count: sets)
            item.actualReps = Array(repeating: 0, count: sets)
            item.actualRIRs = Array(repeating: 0, count: sets)
            item.usedRestPauseFlags = Array(repeating: false, count: sets)
            item.restPausePatternsBySet = Array(repeating: "", count: sets)
            item.dropSetPatternsBySet = Array(repeating: "", count: sets)
            item.setFeedbackBySet = Array(repeating: "", count: sets)
            item.pumpRatingsBySet = Array(repeating: 0, count: sets)
            for log in item.logs { context.delete(log) }
            item.logs = []

            item.isPR = false
            item.isCompleted = false
            item.loadOverrideReasonRaw = nil
            item.nextSuggestedLoad = nil
            item.planEdited = false
            item.coachNote = nil
            item.prescriptionNotes = nil
            item.intensifierNotes = nil

            let line = "SessionItemEdit: \(isoDay(target.date)) \(target.session.dayLabel ?? "?") "
                + "wk\(target.weekIndex) wave=\(target.waveRaw ?? "-") "
                + "\(plan.fromExerciseId) -> \(plan.toExerciseId) seed=\(target.seedLoad.map { String($0) } ?? "none")"
            summary.append(line)
            print(line)
        }

        var problems: [String] = []
        for (snap, target) in zip(before, live.targets) {
            problems += snap.differences(from: target.item)
        }
        problems += chainProblems(live.targets, meso: plan.meso, context: context)
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw ReplaceError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw ReplaceError.saveFailed("\(error)")
        }
        return ApplyResult(sessionsChanged: live.targets.count, summary: summary)
    }

    // MARK: - Verification

    /// For each wave letter, the carry-forward lookup from every target must land on the next target
    /// of that letter, so a result logged on the replacement flows to the next occurrence of it.
    private static func chainProblems(_ targets: [Target], meso: MesoBlock, context: ModelContext) -> [String] {
        guard targets.count > 1 else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        var byLetter: [String: [Target]] = [:]
        for t in targets {
            byLetter[t.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? "", default: []].append(t)
        }
        var problems: [String] = []
        for (letter, group) in byLetter {
            let chain = group.sorted { $0.date < $1.date }
            for (current, next) in zip(chain, chain.dropFirst()) {
                let resolved = PlanMemoryEngine.nextTargetItem(for: current.item, after: current.session, in: all)
                if resolved !== next.item {
                    problems.append("chain \(letter.isEmpty ? "(no wave)" : letter) wk\(current.weekIndex) -> expected wk\(next.weekIndex), resolved wk\(resolved.flatMap { r in all.first { $0.items.contains { $0 === r } }?.weekIndex } ?? -1)")
                }
            }
        }
        return problems
    }

    // MARK: - Helpers

    /// Everything the replace must leave alone.
    private struct PrescriptionSnapshot {
        let item: SessionItem
        let waveRaw: String?, priorityRaw: String?, intensifierRaw: String?
        let order: Int, targetReps: Int, targetSets: Int, targetRIR: Int
        let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?
        let plannedReps: [Int], plannedRIRs: [Int]

        init(_ i: SessionItem) {
            item = i
            waveRaw = i.waveRaw; priorityRaw = i.priorityRaw; intensifierRaw = i.intensifierRaw
            order = i.order; targetReps = i.targetReps; targetSets = i.targetSets; targetRIR = i.targetRIR
            setMin = i.setMin; setMax = i.setMax; repMin = i.repMin; repMax = i.repMax
            rirMin = i.targetRIRMin; rirMax = i.targetRIRMax
            plannedReps = i.plannedRepsBySet; plannedRIRs = i.plannedRIRsBySet
        }

        func differences(from i: SessionItem) -> [String] {
            var d: [String] = []
            func check<T: Equatable>(_ name: String, _ a: T, _ b: T) { if a != b { d.append("\(name) changed") } }
            check("waveRaw", waveRaw, i.waveRaw); check("priorityRaw", priorityRaw, i.priorityRaw)
            check("intensifierRaw", intensifierRaw, i.intensifierRaw); check("order", order, i.order)
            check("targetReps", targetReps, i.targetReps); check("targetSets", targetSets, i.targetSets)
            check("targetRIR", targetRIR, i.targetRIR); check("setMin", setMin, i.setMin)
            check("setMax", setMax, i.setMax); check("repMin", repMin, i.repMin); check("repMax", repMax, i.repMax)
            check("targetRIRMin", rirMin, i.targetRIRMin); check("targetRIRMax", rirMax, i.targetRIRMax)
            check("plannedRepsBySet", plannedReps, i.plannedRepsBySet)
            check("plannedRIRsBySet", plannedRIRs, i.plannedRIRsBySet)
            let n = max(0, i.targetSets)
            if i.plannedLoadsBySet.count != n { d.append("plannedLoadsBySet not sized to targetSets") }
            return d.map { "\(i.exerciseId): \($0)" }
        }
    }

    /// Every field `apply` overwrites, as it was before the write.
    private struct ItemRestorePoint {
        let item: SessionItem
        let exerciseId: String, name: String?
        let suggestedLoad: Double, plannedLoads: [Double]
        let actualLoads: [Double], actualReps: [Int], actualRIRs: [Int]
        let restPauseFlags: [Bool], restPausePatterns: [String], dropSetPatterns: [String]
        let setFeedback: [String], pumpRatings: [Int]
        let logs: [SetLog]
        let isPR: Bool, isCompleted: Bool, planEdited: Bool
        let loadOverrideReasonRaw: String?, nextSuggestedLoad: Double?
        let coachNote: String?, prescriptionNotes: String?, intensifierNotes: String?
        // Prescription fields (written by changePrescription), and identity fields it must not touch.
        let targetSets: Int, targetReps: Int, targetRIR: Int
        let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?
        let plannedReps: [Int], plannedRIRs: [Int]
        let order: Int, waveRaw: String?, priorityRaw: String?, intensifierRaw: String?

        init(_ i: SessionItem) {
            item = i
            targetSets = i.targetSets; targetReps = i.targetReps; targetRIR = i.targetRIR
            setMin = i.setMin; setMax = i.setMax; repMin = i.repMin; repMax = i.repMax
            rirMin = i.targetRIRMin; rirMax = i.targetRIRMax
            plannedReps = i.plannedRepsBySet; plannedRIRs = i.plannedRIRsBySet
            order = i.order; waveRaw = i.waveRaw; priorityRaw = i.priorityRaw; intensifierRaw = i.intensifierRaw
            exerciseId = i.exerciseId; name = i.exerciseNameSnapshot
            suggestedLoad = i.suggestedLoad; plannedLoads = i.plannedLoadsBySet
            actualLoads = i.actualLoads; actualReps = i.actualReps; actualRIRs = i.actualRIRs
            restPauseFlags = i.usedRestPauseFlags; restPausePatterns = i.restPausePatternsBySet
            dropSetPatterns = i.dropSetPatternsBySet; setFeedback = i.setFeedbackBySet; pumpRatings = i.pumpRatingsBySet
            logs = i.logs
            isPR = i.isPR; isCompleted = i.isCompleted; planEdited = i.planEdited
            loadOverrideReasonRaw = i.loadOverrideReasonRaw; nextSuggestedLoad = i.nextSuggestedLoad
            coachNote = i.coachNote; prescriptionNotes = i.prescriptionNotes; intensifierNotes = i.intensifierNotes
        }

        func restore() {
            item.exerciseId = exerciseId; item.exerciseNameSnapshot = name
            item.suggestedLoad = suggestedLoad; item.plannedLoadsBySet = plannedLoads
            item.actualLoads = actualLoads; item.actualReps = actualReps; item.actualRIRs = actualRIRs
            item.usedRestPauseFlags = restPauseFlags; item.restPausePatternsBySet = restPausePatterns
            item.dropSetPatternsBySet = dropSetPatterns; item.setFeedbackBySet = setFeedback; item.pumpRatingsBySet = pumpRatings
            item.logs = logs
            item.isPR = isPR; item.isCompleted = isCompleted; item.planEdited = planEdited
            item.loadOverrideReasonRaw = loadOverrideReasonRaw; item.nextSuggestedLoad = nextSuggestedLoad
            item.coachNote = coachNote; item.prescriptionNotes = prescriptionNotes; item.intensifierNotes = intensifierNotes
            item.targetSets = targetSets; item.targetReps = targetReps; item.targetRIR = targetRIR
            item.setMin = setMin; item.setMax = setMax; item.repMin = repMin; item.repMax = repMax
            item.targetRIRMin = rirMin; item.targetRIRMax = rirMax
            item.plannedRepsBySet = plannedReps; item.plannedRIRsBySet = plannedRIRs
        }
    }

    private static func prescriptionSummary(_ i: SessionItem) -> String {
        func range(_ lo: Int?, _ hi: Int?, _ fallback: Int) -> String {
            guard let lo, let hi else { return "\(fallback)" }
            return lo == hi ? "\(lo)" : "\(lo)-\(hi)"
        }
        return "\(i.targetSets) x \(range(i.repMin, i.repMax, i.targetReps)) @ RIR \(range(i.targetRIRMin, i.targetRIRMax, i.targetRIR))"
    }

    private static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}


// MARK: - Change prescription for remaining sessions

/// What to change on an exercise's remaining sessions. Nothing here touches loads' values, the
/// exercise, its wave, order, `planEdited` or anything logged.
struct PrescriptionChange: Equatable {
    /// Sets to add (+1) or remove (-1) from each session's `targetSets`; clamped to `setBounds`.
    var setDelta: Int?
    /// New rep range; `targetReps` becomes its lower bound (the template's convention).
    var repRange: ClosedRange<Int>?
    /// New RIR range; `targetRIR` becomes its upper bound (the template's convention).
    var rirRange: ClosedRange<Int>?

    static let setBounds = 1...6      // the logger shows at most 6 working sets
    static let repBounds = 1...50
    static let rirBounds = 0...5

    init(setDelta: Int? = nil, repRange: ClosedRange<Int>? = nil, rirRange: ClosedRange<Int>? = nil) {
        self.setDelta = setDelta; self.repRange = repRange; self.rirRange = rirRange
    }

    /// At least one part, and every part inside its bounds.
    var isValid: Bool {
        guard setDelta != nil || repRange != nil || rirRange != nil else { return false }
        if let setDelta, setDelta == 0 { return false }
        if let r = repRange, !(Self.repBounds.contains(r.lowerBound) && Self.repBounds.contains(r.upperBound)) { return false }
        if let r = rirRange, !(Self.rirBounds.contains(r.lowerBound) && Self.rirBounds.contains(r.upperBound)) { return false }
        return true
    }
}

extension SessionItemEditService {

    /// One session's prescription, as the preview shows it.
    struct PrescriptionValues: Equatable {
        let sets: Int
        let repMin: Int, repMax: Int
        let rirMin: Int, rirMax: Int

        init(sets: Int, repMin: Int, repMax: Int, rirMin: Int, rirMax: Int) {
            self.sets = sets; self.repMin = repMin; self.repMax = repMax; self.rirMin = rirMin; self.rirMax = rirMax
        }

        init(_ item: SessionItem) {
            sets = item.targetSets
            repMin = item.repMin ?? item.targetReps; repMax = item.repMax ?? item.targetReps
            rirMin = item.targetRIRMin ?? item.targetRIR; rirMax = item.targetRIRMax ?? item.targetRIR
        }

        func applying(_ change: PrescriptionChange) -> PrescriptionValues {
            var next = self
            if let d = change.setDelta {
                let bounds = PrescriptionChange.setBounds
                next = PrescriptionValues(sets: min(max(sets + d, bounds.lowerBound), bounds.upperBound),
                                          repMin: repMin, repMax: repMax, rirMin: rirMin, rirMax: rirMax)
            }
            if let r = change.repRange {
                next = PrescriptionValues(sets: next.sets, repMin: r.lowerBound, repMax: r.upperBound,
                                          rirMin: next.rirMin, rirMax: next.rirMax)
            }
            if let r = change.rirRange {
                next = PrescriptionValues(sets: next.sets, repMin: next.repMin, repMax: next.repMax,
                                          rirMin: r.lowerBound, rirMax: r.upperBound)
            }
            return next
        }

        /// "4 x 8-12 @ RIR 2-3"
        var text: String {
            func r(_ a: Int, _ b: Int) -> String { a == b ? "\(a)" : "\(a)-\(b)" }
            return "\(sets) x \(r(repMin, repMax)) @ RIR \(r(rirMin, rirMax))"
        }
    }

    struct PrescriptionTarget {
        let session: Session
        let item: SessionItem
        let date: Date
        let weekIndex: Int
        let waveRaw: String?
        let before: PrescriptionValues
        let after: PrescriptionValues
    }

    struct ChangePlan {
        let meso: MesoBlock
        let dayLabel: String?
        let exerciseId: String                 // canonical
        /// Lower-cased wave letters to change ("" = items with no wave); nil = every letter.
        let letters: Set<String>?
        let includeDeload: Bool
        let scope: ReplaceScope
        let change: PrescriptionChange
        let now: Date
        let targets: [PrescriptionTarget]
        let refusals: [Refusal]

        var isApplicable: Bool { !targets.isEmpty }
    }

    // MARK: Plan (no writes)

    /// Same target selection and safety as `planReplace`, plus the letter filter and the deload rule.
    /// Deload-week items are refused unless `includeDeload`; a maintenance block has no deload week (its
    /// items carry the deload wave on every session), so the rule does not apply there.
    static func planChangePrescription(
        meso: MesoBlock,
        dayLabel: String?,
        exerciseId: String,
        letters: Set<String>? = nil,
        includeDeload: Bool = false,
        scope: ReplaceScope = .allRemaining,
        change: PrescriptionChange,
        now: Date = Date()
    ) -> ChangePlan {
        let exercise = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let normalizedLetters = letters.map { Set($0.map { $0.lowercased() }) }
        let selected = selectCandidates(
            meso: meso, dayLabel: dayLabel, exercise: exercise, scope: scope,
            startOfToday: Calendar.current.startOfDay(for: now)
        )
        var refusals = selected.refusals
        var targets: [PrescriptionTarget] = []

        for (session, item) in selected.candidates where change.isValid {
            let key = letterKey(item)
            if let normalizedLetters, !normalizedLetters.contains(key) { continue }
            if key == "deload", !includeDeload, !meso.isMaintenance {
                refusals.append(Refusal(session: session, reason: .deload)); continue
            }
            if let reason = safetyRefusal(meso: meso, session: session) {
                refusals.append(Refusal(session: session, reason: reason)); continue
            }
            let before = PrescriptionValues(item)
            let after = before.applying(change)
            if after == before {
                refusals.append(Refusal(session: session, reason: .noChange)); continue
            }
            targets.append(PrescriptionTarget(
                session: session, item: item, date: session.date, weekIndex: session.weekIndex,
                waveRaw: item.waveRaw, before: before, after: after
            ))
        }
        return ChangePlan(meso: meso, dayLabel: dayLabel, exerciseId: exercise, letters: normalizedLetters,
                          includeDeload: includeDeload, scope: scope, change: change, now: now,
                          targets: targets, refusals: refusals)
    }

    private static func letterKey(_ item: SessionItem) -> String {
        item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }

    // MARK: Apply

    /// Writes the planned change to the live targets, verifies, and saves once; any failure restores
    /// every field and throws, leaving the store as it was.
    @discardableResult
    static func applyChange(_ plan: ChangePlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> ApplyResult {
        guard plan.isApplicable else { throw ReplaceError.nothingToReplace }
        guard !plan.meso.sessions.contains(where: { $0.status == .inProgress }) else {
            throw ReplaceError.sessionInProgress
        }

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let live = planChangePrescription(
            meso: plan.meso, dayLabel: plan.dayLabel, exerciseId: plan.exerciseId, letters: plan.letters,
            includeDeload: plan.includeDeload, scope: plan.scope, change: plan.change, now: plan.now
        )
        let plannedIDs = plan.targets.map { $0.session.persistentModelID }
        let liveIDs = live.targets.map { $0.session.persistentModelID }
        guard plannedIDs == liveIDs else {
            throw ReplaceError.planStale(planned: plannedIDs.count, live: liveIDs.count)
        }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        func chainIdentities() -> [ObjectIdentifier?] {
            live.targets.map { t in
                PlanMemoryEngine.nextTargetItem(for: t.item, after: t.session, in: allSessions).map(ObjectIdentifier.init)
            }
        }
        let chainsBefore = chainIdentities()

        let restorePoints = live.targets.map { ItemRestorePoint($0.item) }
        func abandon() {
            for point in restorePoints { point.restore() }
            context.rollback()
        }

        var summary: [String] = []
        let change = plan.change
        for target in live.targets {
            let item = target.item
            let sets = target.after.sets

            if change.setDelta != nil {
                item.targetSets = sets
                // The wave's set band widens to include the new count and never narrows.
                if let lo = item.setMin { item.setMin = min(lo, sets) }
                if let hi = item.setMax { item.setMax = max(hi, sets) }
                // Grow = repeat the last set's load, shrink = first N, empty = zeros (as carry-forward does).
                item.plannedLoadsBySet = resized(item.plannedLoadsBySet, to: sets, fallback: 0)
            }
            if let reps = change.repRange {
                item.repMin = reps.lowerBound; item.repMax = reps.upperBound
                item.targetReps = reps.lowerBound
                item.plannedRepsBySet = Array(repeating: item.targetReps, count: sets)
            } else if change.setDelta != nil {
                item.plannedRepsBySet = resized(item.plannedRepsBySet, to: sets, fallback: item.targetReps)
            }
            if let rir = change.rirRange {
                item.targetRIRMin = rir.lowerBound; item.targetRIRMax = rir.upperBound
                item.targetRIR = rir.upperBound
                item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: sets)
            } else if change.setDelta != nil {
                item.plannedRIRsBySet = resized(item.plannedRIRsBySet, to: sets, fallback: item.targetRIR)
            }

            let line = "SessionItemEdit: \(isoDay(target.date)) \(target.session.dayLabel ?? "?") "
                + "wk\(target.weekIndex) wave=\(target.waveRaw ?? "-") \(plan.exerciseId) "
                + "\(target.before.text) -> \(target.after.text)"
            summary.append(line)
            print(line)
        }

        var problems: [String] = []
        for (target, point) in zip(live.targets, restorePoints) {
            problems += prescriptionProblems(target, before: point)
        }
        for (idx, (before, after)) in zip(chainsBefore, chainIdentities()).enumerated() where before != after {
            problems.append("carry-forward chain changed for wk\(live.targets[idx].weekIndex)")
        }
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw ReplaceError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw ReplaceError.saveFailed("\(error)")
        }
        return ApplyResult(sessionsChanged: live.targets.count, summary: summary)
    }

    /// Grow by repeating the last element (`fallback` when empty); shrink to the first `count`.
    private static func resized<T>(_ array: [T], to count: Int, fallback: T) -> [T] {
        guard count >= 0 else { return array }
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: array.last ?? fallback, count: count - array.count)
    }

    /// The target has exactly the new prescription, and nothing else about the item moved.
    private static func prescriptionProblems(_ target: PrescriptionTarget, before b: ItemRestorePoint) -> [String] {
        let i = target.item
        var d: [String] = []
        func check<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
            if expected != actual { d.append("\(name): expected \(expected), found \(actual)") }
        }
        // New values.
        check("sets", target.after.sets, i.targetSets)
        check("repMin", target.after.repMin, i.repMin ?? i.targetReps)
        check("repMax", target.after.repMax, i.repMax ?? i.targetReps)
        check("rirMin", target.after.rirMin, i.targetRIRMin ?? i.targetRIR)
        check("rirMax", target.after.rirMax, i.targetRIRMax ?? i.targetRIR)
        // Untouched fields.
        check("exerciseId", b.exerciseId, i.exerciseId); check("name", b.name, i.exerciseNameSnapshot)
        check("waveRaw", b.waveRaw, i.waveRaw); check("priorityRaw", b.priorityRaw, i.priorityRaw)
        check("intensifierRaw", b.intensifierRaw, i.intensifierRaw); check("order", b.order, i.order)
        check("suggestedLoad", b.suggestedLoad, i.suggestedLoad)
        check("planEdited", b.planEdited, i.planEdited)
        check("actualLoads", b.actualLoads, i.actualLoads); check("actualReps", b.actualReps, i.actualReps)
        check("actualRIRs", b.actualRIRs, i.actualRIRs)
        check("isCompleted", b.isCompleted, i.isCompleted); check("isPR", b.isPR, i.isPR)
        check("coachNote", b.coachNote, i.coachNote); check("logs", b.logs.count, i.logs.count)
        // The set band only widens to include the new count (never narrows) when sets changed.
        let newSets = target.after.sets
        let widenSets = target.after.sets != target.before.sets
        check("setMin", widenSets ? b.setMin.map { min($0, newSets) } : b.setMin, i.setMin)
        check("setMax", widenSets ? b.setMax.map { max($0, newSets) } : b.setMax, i.setMax)
        // Load values: the surviving prefix is unchanged, and the array is sized to the new set count when sets changed.
        let kept = min(b.plannedLoads.count, i.plannedLoadsBySet.count)
        check("plannedLoads prefix", Array(b.plannedLoads.prefix(kept)), Array(i.plannedLoadsBySet.prefix(kept)))
        if target.after.sets != target.before.sets {
            check("plannedLoads count", target.after.sets, i.plannedLoadsBySet.count)
        } else {
            check("plannedLoads", b.plannedLoads, i.plannedLoadsBySet)
        }
        return d.map { "\(i.exerciseId) wk\(target.weekIndex): \($0)" }
    }
}
