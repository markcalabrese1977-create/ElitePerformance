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

    static func isoDay(_ d: Date) -> String {
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
    /// The note shown under the exercise: nil = unchanged, "" (or only whitespace) = clear it, anything else
    /// replaces it. See `NoteFields` for which stored field it lands in.
    var note: String?

    static let setBounds = 1...6      // the logger shows at most 6 working sets
    static let repBounds = 1...50
    static let rirBounds = 0...5

    init(setDelta: Int? = nil, repRange: ClosedRange<Int>? = nil, rirRange: ClosedRange<Int>? = nil, note: String? = nil) {
        self.setDelta = setDelta; self.repRange = repRange; self.rirRange = rirRange; self.note = note
    }

    /// At least one part, and every part inside its bounds.
    var isValid: Bool {
        guard setDelta != nil || repRange != nil || rirRange != nil || note != nil else { return false }
        if let setDelta, setDelta == 0 { return false }
        if let r = repRange, !(Self.repBounds.contains(r.lowerBound) && Self.repBounds.contains(r.upperBound)) { return false }
        if let r = rirRange, !(Self.rirBounds.contains(r.lowerBound) && Self.rirBounds.contains(r.upperBound)) { return false }
        return true
    }
}

// MARK: - The note under an exercise

extension SessionItem {
    /// The line the session screen shows under the exercise name: `intensifierNotes` if it has text, else
    /// `prescriptionNotes` (both trimmed). Defined once in `NoteFields.displayed`, which
    /// `SessionView.executionNoteLine` also uses.
    var executionNoteText: String? { NoteFields(self).displayed }
}

/// The two stored note fields of an item, and the rule for changing the note it displays.
///
/// RULE: a new note is written to the field the item currently DISPLAYS (`intensifierNotes` when that has text,
/// otherwise `prescriptionNotes`), and the other field is cleared, so the display can never fall back to older
/// text. Clearing empties both. Leading and trailing whitespace is trimmed.
struct NoteFields: Equatable {
    var intensifier: String?
    var prescription: String?

    init(intensifier: String?, prescription: String?) { self.intensifier = intensifier; self.prescription = prescription }
    init(_ item: SessionItem) { intensifier = item.intensifierNotes; prescription = item.prescriptionNotes }

    /// What the session screen would show for these fields.
    var displayed: String? {
        for raw in [intensifier, prescription] {
            if let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    static func applying(_ note: String, to item: SessionItem) -> NoteFields {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return NoteFields(intensifier: nil, prescription: nil) }
        let showsIntensifier = !(item.intensifierNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return showsIntensifier ? NoteFields(intensifier: text, prescription: nil)
                                : NoteFields(intensifier: nil, prescription: text)
    }

    func write(to item: SessionItem) { item.intensifierNotes = intensifier; item.prescriptionNotes = prescription }
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
        /// The note the item shows now and what it will show (nil = no line); only meaningful when `changesNote`.
        let beforeNote: String?
        let afterNote: String?
        /// True when the change carries a note (replace or clear), even if the result shows no line.
        let changesNote: Bool
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
            let noteChanges = change.note.map { NoteFields.applying($0, to: item) != NoteFields(item) } ?? false
            if after == before && !noteChanges {
                refusals.append(Refusal(session: session, reason: .noChange)); continue
            }
            targets.append(PrescriptionTarget(
                session: session, item: item, date: session.date, weekIndex: session.weekIndex,
                waveRaw: item.waveRaw, before: before, after: after,
                beforeNote: item.executionNoteText,
                afterNote: change.note.flatMap { NoteFields.applying($0, to: item).displayed },
                changesNote: change.note != nil
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

            if let note = change.note { NoteFields.applying(note, to: item).write(to: item) }

            let line = "SessionItemEdit: \(isoDay(target.date)) \(target.session.dayLabel ?? "?") "
                + "wk\(target.weekIndex) wave=\(target.waveRaw ?? "-") \(plan.exerciseId) "
                + "\(target.before.text) -> \(target.after.text)"
                + (target.changesNote ? " note \(target.beforeNote ?? "-") -> \(target.afterNote ?? "-")" : "")
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
        // Notes: unchanged unless the change carries one; then the display reads exactly the new text and the
        // other field holds nothing to fall back to.
        if target.changesNote {
            check("displayed note", target.afterNote, i.executionNoteText)
            let shown = i.intensifierNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let otherField = shown ? i.prescriptionNotes : i.intensifierNotes
            check("fallback note field", nil, otherField)
        } else {
            check("intensifierNotes", b.intensifierNotes, i.intensifierNotes)
            check("prescriptionNotes", b.prescriptionNotes, i.prescriptionNotes)
        }
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


// MARK: - Insert a deload week

/// Inserts a deload week into the active block at the first week that has not started, and pushes
/// every later planned session back one week. Same shape as the other edits: a pure `plan…` for the
/// preview, then `insertDeloadWeek`, which re-plans against live state, writes, verifies the
/// carry-forward chains and the shifted schedule, and saves once (or restores every field and throws).
extension SessionItemEditService {

    /// Deload prescription: half the sets (at least one), the same rep range, 3-4 RIR.
    static let deloadRIRRange = 3...4
    static let deloadWaveRaw = "deload"

    enum InsertDeloadRefusal: Equatable {
        /// The block is not the active one.
        case inactiveMeso
        /// A session in the block is being trained.
        case sessionInProgress
        /// No week is entirely planned, untouched and dated today or later.
        case noEligibleWeek
        /// The week asked for is started, logged, in the past, already a deload, or not in the block.
        case weekNotEligible
        /// A session in or after the insertion week is already completed, so the weeks cannot shift cleanly.
        case laterSessionCompleted
        /// A shifted session would land on a day another session already occupies (see `collisions`).
        case dateCollision
    }

    enum InsertDeloadError: Error, Equatable {
        case refused(InsertDeloadRefusal)
        /// The live schedule no longer matches the plan.
        case planStale
        case verificationFailed([String])
        case saveFailed(String)
    }

    struct DeloadItemPlan {
        let source: SessionItem
        let order: Int
        let exerciseId: String
        let sets: Int
        let repMin: Int
        let repMax: Int
        let load: Double
        /// "2 x 8-10 @ RIR 3-4"
        var prescription: String {
            "\(sets) x \(repMin == repMax ? "\(repMin)" : "\(repMin)-\(repMax)") @ RIR \(deloadRIRRange.lowerBound)-\(deloadRIRRange.upperBound)"
        }
    }

    struct DeloadSessionPlan {
        let source: Session
        let date: Date
        let dayLabel: String?
        let items: [DeloadItemPlan]
    }

    struct ShiftedSession {
        let session: Session
        let oldDate: Date
        let newDate: Date
        let oldWeek: Int
        let newWeek: Int
    }

    struct DateCollision {
        /// The session that would move.
        let moved: Session
        /// The session already on the destination day.
        let occupant: Session
        let date: Date
    }

    struct InsertDeloadPlan {
        let meso: MesoBlock
        let now: Date
        /// The week the deload takes (the first week that has not started). Nil when refused for lack of one.
        let weekIndex: Int?
        let deloadSessions: [DeloadSessionPlan]
        let shifted: [ShiftedSession]
        let collisions: [DateCollision]
        let refusal: InsertDeloadRefusal?
        let blockEndBefore: Date?
        let blockEndAfter: Date?

        var isApplicable: Bool { refusal == nil && weekIndex != nil && !deloadSessions.isEmpty }
    }

    struct InsertDeloadResult {
        let deloadSessionsCreated: Int
        let sessionsShifted: Int
        let summary: [String]
    }

    private struct ForcedInsertSaveFailure: Error {}

    // MARK: Plan (no writes)

    /// Weeks a deload can go in front of: every session planned, untouched, dated today or later, and not a deload.
    static func eligibleDeloadWeeks(meso: MesoBlock, now: Date = Date()) -> [Int] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        func isDeloadSession(_ s: Session) -> Bool {
            s.insertedDeload == true || s.items.contains { $0.waveRaw?.lowercased() == deloadWaveRaw }
        }
        let byWeek = Dictionary(grouping: meso.sessions, by: \.weekIndex)
        return byWeek.keys.sorted().filter { w in
            byWeek[w]!.allSatisfy { SessionEditSafety.isSafeToModify($0) && $0.date >= startOfToday && !isDeloadSession($0) }
        }
    }

    /// `week` nil = the first eligible week; an explicit week must be one of `eligibleDeloadWeeks`.
    static func planInsertDeloadWeek(meso: MesoBlock, context: ModelContext, now: Date = Date(), week requested: Int? = nil) -> InsertDeloadPlan {
        let calendar = Calendar.current
        let all = meso.sessions
        let blockEndBefore = all.map(\.date).max()

        func refused(_ reason: InsertDeloadRefusal, week: Int? = nil, collisions: [DateCollision] = []) -> InsertDeloadPlan {
            InsertDeloadPlan(meso: meso, now: now, weekIndex: week, deloadSessions: [], shifted: [],
                             collisions: collisions, refusal: reason,
                             blockEndBefore: blockEndBefore, blockEndAfter: blockEndBefore)
        }

        if meso.status != .active { return refused(.inactiveMeso) }
        if all.contains(where: { $0.status == .inProgress }) { return refused(.sessionInProgress) }

        let eligible = eligibleDeloadWeeks(meso: meso, now: now)
        let byWeek = Dictionary(grouping: all, by: \.weekIndex)
        let chosen: Int?
        if let requested {
            guard eligible.contains(requested) else { return refused(.weekNotEligible, week: requested) }
            chosen = requested
        } else {
            chosen = eligible.first
        }
        guard let week = chosen else { return refused(.noEligibleWeek) }

        if all.contains(where: { $0.weekIndex >= week && $0.status != .planned }) {
            return refused(.laterSessionCompleted, week: week)
        }

        // Every planned session from the insertion week on moves one week later.
        let moving = all.filter { $0.weekIndex >= week }
            .sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        let shifted: [ShiftedSession] = moving.map { s in
            ShiftedSession(session: s, oldDate: s.date,
                           newDate: calendar.date(byAdding: .day, value: 7, to: s.date) ?? s.date,
                           oldWeek: s.weekIndex, newWeek: s.weekIndex + 1)
        }

        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let collisions = shiftCollisions(shifted, among: allSessions, calendar: calendar)
        if !collisions.isEmpty { return refused(.dateCollision, week: week, collisions: collisions) }

        // The deload week: W's sessions, same dates, half the volume.
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let increment = profile?.minLoadIncrement ?? 2.5
        let sources = (byWeek[week] ?? []).sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        let deloadSessions: [DeloadSessionPlan] = sources.map { s in
            let items: [DeloadItemPlan] = s.items.sorted { $0.order < $1.order }.map { i in
                let repMin = i.repMin ?? i.targetReps
                let repMax = i.repMax ?? i.targetReps
                let load: Double
                if ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: custom) {
                    load = 0
                } else if UserProfile.isProgressionExempt(exerciseId: i.exerciseId, profile: profile) {
                    load = lastCompletedLoad(for: i.exerciseId, in: allSessions) ?? 0
                } else {
                    load = HistorySeedLoad.load(
                        for: i.exerciseId, goalReps: repMax, targetRIR: deloadRIRRange.upperBound, in: allSessions,
                        loadIncrement: increment, bodyWeight: profile?.bodyWeight, customExercises: custom,
                        referenceDate: now
                    ) ?? 0
                }
                return DeloadItemPlan(source: i, order: i.order, exerciseId: i.exerciseId,
                                      sets: max(1, (i.targetSets + 1) / 2), repMin: repMin, repMax: repMax, load: load)
            }
            return DeloadSessionPlan(source: s, date: s.date, dayLabel: s.dayLabel, items: items)
        }

        let blockEndAfter = (all.map(\.date) + shifted.map(\.newDate)).max()
        return InsertDeloadPlan(
            meso: meso, now: now, weekIndex: week, deloadSessions: deloadSessions, shifted: shifted,
            collisions: [], refusal: nil, blockEndBefore: blockEndBefore,
            blockEndAfter: moving.isEmpty ? blockEndBefore : blockEndAfter
        )
    }

    /// Sessions already on a day a moving session is headed to (other than the moving sessions themselves).
    private static func shiftCollisions(_ shifted: [ShiftedSession], among all: [Session], calendar: Calendar) -> [DateCollision] {
        let movingIDs = Set(shifted.map { $0.session.persistentModelID })
        let occupied = Dictionary(grouping: all.filter { !movingIDs.contains($0.persistentModelID) },
                                  by: { calendar.startOfDay(for: $0.date) })
        var out: [DateCollision] = []
        for move in shifted {
            for other in occupied[calendar.startOfDay(for: move.newDate)] ?? [] {
                out.append(DateCollision(moved: move.session, occupant: other, date: move.newDate))
            }
        }
        return out
    }

    /// The most recent logged working load of a fixed-load exercise (deload items excluded), if any.
    static func lastCompletedLoad(for exerciseId: String, in sessions: [Session]) -> Double? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        for s in sessions.filter({ $0.status == .completed }).sorted(by: { $0.date > $1.date }) {
            guard let item = s.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
                    && $0.waveRaw?.lowercased() != deloadWaveRaw
            }) else { continue }
            if let load = item.actualLoads.last(where: { $0 > 0 }) { return load }
        }
        return nil
    }

    // MARK: Apply

    @discardableResult
    static func insertDeloadWeek(_ plan: InsertDeloadPlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> InsertDeloadResult {
        guard plan.isApplicable, plan.weekIndex != nil else {
            throw InsertDeloadError.refused(plan.refusal ?? .noEligibleWeek)
        }
        let meso = plan.meso

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        // The plan is a preview; trust only live state.
        let live = planInsertDeloadWeek(meso: meso, context: context, now: plan.now, week: plan.weekIndex)
        // The week the preview showed is no longer eligible: the schedule moved under it.
        if live.refusal == .weekNotEligible { throw InsertDeloadError.planStale }
        guard live.isApplicable, let week = live.weekIndex else {
            throw InsertDeloadError.refused(live.refusal ?? .noEligibleWeek)
        }
        guard week == plan.weekIndex,
              live.shifted.map({ $0.session.persistentModelID }) == plan.shifted.map({ $0.session.persistentModelID }),
              live.deloadSessions.map({ $0.source.persistentModelID }) == plan.deloadSessions.map({ $0.source.persistentModelID })
        else { throw InsertDeloadError.planStale }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let calendar = Calendar.current

        // Carry-forward chains before: every item already in the block, and where its result flows.
        func everySession() -> [Session] {
            var seen = Set<PersistentIdentifier>()
            return ((try? context.fetch(FetchDescriptor<Session>())) ?? []).filter { seen.insert($0.persistentModelID).inserted }
                + meso.sessions.filter { seen.insert($0.persistentModelID).inserted }
        }
        // A deload-wave source carries nothing forward (propagation skips deload targets), and its
        // deload -> next-deload link legitimately gains the inserted week, so only working items are checked.
        let chainSources: [(session: Session, item: SessionItem)] =
            meso.sessions.sorted { $0.date < $1.date }
                .flatMap { s in s.items.filter { $0.waveRaw?.lowercased() != deloadWaveRaw }.map { (s, $0) } }
        func chainTargets(_ sessions: [Session]) -> [ObjectIdentifier?] {
            chainSources.map { PlanMemoryEngine.nextTargetItem(for: $0.item, after: $0.session, in: sessions).map(ObjectIdentifier.init) }
        }
        let chainsBefore = chainTargets(everySession())
        let weeksBefore = Set(meso.sessions.map(\.weekIndex))

        // Everything this method overwrites on live objects, so a failure can put it back by hand
        // (rollback() drops inserts but does not revert property edits).
        struct SessionRestore {
            let session: Session; let date: Date; let week: Int?; let programIndex: Int?
            init(_ s: Session) { session = s; date = s.date; week = s.weekInMeso; programIndex = s.programIndex }
        }
        let otherSessions = meso.sessions.filter { s in !live.shifted.contains { $0.session === s } }
        let restores = (otherSessions + live.shifted.map(\.session)).map(SessionRestore.init)
        let totalWeeksBefore = meso.totalWeeks
        let mesoSessionsBefore = meso.sessions
        var created: [Session] = []
        func abandon() {
            for r in restores { r.session.date = r.date; r.session.weekInMeso = r.week; r.session.programIndex = r.programIndex }
            meso.totalWeeks = totalWeeksBefore
            meso.sessions = mesoSessionsBefore
            for s in created { context.delete(s) }
            context.rollback()
        }

        // 1. The deload sessions, on the insertion week's own dates.
        for dp in live.deloadSessions {
            let items: [SessionItem] = dp.items.map { ip in
                let src = ip.source
                let n = ip.sets
                let item = SessionItem(
                    order: ip.order, exerciseId: ip.exerciseId,
                    exerciseNameSnapshot: src.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: ip.exerciseId),
                    targetReps: ip.repMin, targetSets: n, targetRIR: deloadRIRRange.upperBound, suggestedLoad: ip.load,
                    waveRaw: deloadWaveRaw, priorityRaw: src.priorityRaw,
                    setMin: src.setMin.map { min($0, n) }, setMax: src.setMax.map { max($0, n) },
                    repMin: ip.repMin, repMax: ip.repMax,
                    targetRIRMin: deloadRIRRange.lowerBound, targetRIRMax: deloadRIRRange.upperBound,
                    intensifierRaw: IntensifierType.none.rawValue,
                    plannedRepsBySet: Array(repeating: ip.repMin, count: n),
                    plannedLoadsBySet: Array(repeating: ip.load, count: n),
                    plannedRIRsBySet: Array(repeating: deloadRIRRange.upperBound, count: n),
                    actualReps: Array(repeating: 0, count: n),
                    actualLoads: Array(repeating: 0.0, count: n),
                    actualRIRs: Array(repeating: 0, count: n),
                    usedRestPauseFlags: Array(repeating: false, count: n),
                    restPausePatternsBySet: Array(repeating: "", count: n),
                    dropSetPatternsBySet: Array(repeating: "", count: n),
                    setFeedbackBySet: Array(repeating: "", count: n),
                    pumpRatingsBySet: Array(repeating: 0, count: n)
                )
                return item
            }
            let session = Session(
                date: dp.date, status: .planned,
                sessionNotes: "\(dp.dayLabel ?? "Session") · Deload wave (inserted)",
                weekIndex: week, dayLabel: dp.dayLabel, items: items, programIndex: dp.source.programIndex
            )
            session.insertedDeload = true
            session.meso = meso
            context.insert(session)
            meso.sessions.append(session)
            created.append(session)
        }

        // 2. Everything from that week on moves a week later.
        for move in live.shifted {
            move.session.date = move.newDate
            move.session.weekInMeso = move.newWeek
        }
        if let total = totalWeeksBefore { meso.totalWeeks = total + 1 }

        // 3. programIndex follows date order across the new and moved sessions.
        let affected = (created + live.shifted.map(\.session))
        var renumbered = false
        if let base = (live.shifted.map(\.session) + live.deloadSessions.map(\.source)).compactMap(\.programIndex).min(),
           affected.allSatisfy({ $0.programIndex != nil }) {
            let order = affected.sorted {
                ($0.date, $0.programIndex ?? 0, $0.insertedDeload == true ? 0 : 1)
                    < ($1.date, $1.programIndex ?? 0, $1.insertedDeload == true ? 0 : 1)
            }
            for (offset, s) in order.enumerated() { s.programIndex = base + offset }
            renumbered = true
        }

        // 4. Verify before anything is saved.
        var problems: [String] = []
        func check<T: Equatable>(_ what: String, _ expected: T, _ actual: T) {
            if expected != actual { problems.append("\(what): expected \(expected), found \(actual)") }
        }
        let after = everySession()

        for (dp, s) in zip(live.deloadSessions, created) {
            let tag = "\(isoDay(dp.date)) \(dp.dayLabel ?? "?")"
            check("\(tag) date", dp.date, s.date)
            check("\(tag) week", week, s.weekIndex)
            check("\(tag) insertedDeload", true, s.insertedDeload == true)
            check("\(tag) status", SessionStatus.planned, s.status)
            check("\(tag) item count", dp.items.count, s.items.count)
            for (ip, i) in zip(dp.items, s.items.sorted { $0.order < $1.order }) {
                let t = "\(tag) \(ip.exerciseId)"
                check("\(t) wave", deloadWaveRaw, i.waveRaw?.lowercased() ?? "")
                check("\(t) sets", ip.sets, i.targetSets)
                check("\(t) reps", [ip.repMin, ip.repMax, ip.repMin], [i.repMin ?? -1, i.repMax ?? -1, i.targetReps])
                check("\(t) RIR", [3, 4, 4], [i.targetRIRMin ?? -1, i.targetRIRMax ?? -1, i.targetRIR])
                check("\(t) load", ip.load, i.suggestedLoad)
                check("\(t) planned loads", Array(repeating: ip.load, count: ip.sets), i.plannedLoadsBySet)
                check("\(t) array sizes", [ip.sets, ip.sets, ip.sets, ip.sets, ip.sets, ip.sets],
                      [i.plannedRepsBySet.count, i.plannedRIRsBySet.count, i.actualLoads.count,
                       i.actualReps.count, i.actualRIRs.count, i.setFeedbackBySet.count])
                if let lo = i.setMin, lo > ip.sets { problems.append("\(t): setMin \(lo) above sets \(ip.sets)") }
                if let hi = i.setMax, hi < ip.sets { problems.append("\(t): setMax \(hi) below sets \(ip.sets)") }
            }
        }
        for move in live.shifted {
            check("\(isoDay(move.oldDate)) \(move.session.dayLabel ?? "?") new date", move.newDate, move.session.date)
            check("\(isoDay(move.oldDate)) \(move.session.dayLabel ?? "?") new week", move.newWeek, move.session.weekIndex)
        }
        // Weeks: the old set, with the inserted week added and the later ones moved up by one.
        let expectedWeeks = Set(weeksBefore.filter { $0 < week } + [week] + weeksBefore.filter { $0 >= week }.map { $0 + 1 })
        check("weeks", expectedWeeks.sorted(), Set(meso.sessions.map(\.weekIndex)).sorted())
        if let before = totalWeeksBefore { check("totalWeeks", before + 1, meso.totalWeeks ?? -1) }
        // Nothing that was not a planned session at or after the insertion week was touched.
        for r in restores where !live.shifted.contains(where: { $0.session === r.session }) {
            if r.session.date != r.date || r.session.weekInMeso != r.week || r.session.programIndex != r.programIndex {
                problems.append("\(isoDay(r.date)) \(r.session.dayLabel ?? "?"): an untouched session changed")
            }
        }
        // Dates: no moved or new session shares a day with anyone else's.
        for c in shiftCollisions(live.shifted, among: after, calendar: calendar).filter({ c in !created.contains { $0 === c.occupant } }) {
            problems.append("date collision on \(isoDay(c.date)): \(c.moved.dayLabel ?? "?") vs \(c.occupant.dayLabel ?? "?")")
        }
        if renumbered {
            let indices = affected.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }.compactMap(\.programIndex)
            check("programIndex contiguous in date order", Array(indices.first.map { $0..<($0 + indices.count) } ?? 0..<0), indices)
        }
        // Chains: every existing result still flows to the same target, and never into a deload item.
        let insertedItems = Set(created.flatMap(\.items).map(ObjectIdentifier.init))
        let chainsAfter = chainTargets(after)
        for (idx, (b, a)) in zip(chainsBefore, chainsAfter).enumerated() {
            let src = chainSources[idx]
            if b != a {
                problems.append("carry-forward chain changed for \(src.item.exerciseId) \(isoDay(src.session.date)) \(src.session.dayLabel ?? "?")")
            } else if let a, insertedItems.contains(a) {
                problems.append("carry-forward lands on an inserted deload item for \(src.item.exerciseId)")
            }
        }
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw InsertDeloadError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedInsertSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw InsertDeloadError.saveFailed("\(error)")
        }

        // The saved schedule moved a week, so a scheduled next block moves with it.
        if let next = MesoLifecycle.scheduledStartDate,
           let moved = calendar.date(byAdding: .day, value: 7, to: next) {
            MesoLifecycle.scheduleNextMeso(on: moved)
        }

        var summary = live.deloadSessions.map { dp in
            "SessionItemEdit: insert deload wk\(week) \(isoDay(dp.date)) \(dp.dayLabel ?? "?") "
                + dp.items.map { "\($0.exerciseId) \($0.prescription) @ \($0.load)" }.joined(separator: "; ")
        }
        summary.append("SessionItemEdit: \(live.shifted.count) sessions moved one week later")
        summary.forEach { print($0) }
        return InsertDeloadResult(deloadSessionsCreated: created.count, sessionsShifted: live.shifted.count, summary: summary)
    }
}

// MARK: - Remove an inserted deload week

/// The inverse of `insertDeloadWeek`: deletes the sessions that carry `insertedDeload == true` for one
/// week and pulls every later planned session back a week. Generated deloads (no marker) are never touched.
extension SessionItemEditService {

    enum RemoveDeloadRefusal: Equatable {
        case inactiveMeso
        case sessionInProgress
        /// The block has no inserted deload week.
        case noInsertedDeload
        /// An inserted deload session is started, logged or completed — it stays.
        case deloadStarted
        /// Something other than the inserted deload sits in that week, so removing it would merge weeks.
        case mixedWeek
        /// A session after the deload is already completed, so the weeks cannot shift back cleanly.
        case laterSessionCompleted
        /// A shifted session would land on a day another session already occupies.
        case dateCollision
    }

    enum RemoveDeloadError: Error, Equatable {
        case refused(RemoveDeloadRefusal)
        case planStale
        case verificationFailed([String])
        case saveFailed(String)
    }

    struct RemoveDeloadPlan {
        let meso: MesoBlock
        let now: Date
        /// The inserted week that goes. Nil when there is none.
        let weekIndex: Int?
        let removals: [Session]
        let shifted: [ShiftedSession]
        let collisions: [DateCollision]
        let refusal: RemoveDeloadRefusal?
        let blockEndBefore: Date?
        let blockEndAfter: Date?

        var isApplicable: Bool { refusal == nil && weekIndex != nil && !removals.isEmpty }
    }

    struct RemoveDeloadResult {
        let deloadSessionsRemoved: Int
        let sessionsShifted: Int
        let summary: [String]
    }

    private struct ForcedRemoveSaveFailure: Error {}

    // MARK: Plan (no writes)

    /// `week` nil = the first inserted week that can go; an explicit week must be an inserted one.
    static func planRemoveInsertedDeloadWeek(meso: MesoBlock, context: ModelContext, now: Date = Date(), week requested: Int? = nil) -> RemoveDeloadPlan {
        let calendar = Calendar.current
        let all = meso.sessions
        let blockEndBefore = all.map(\.date).max()

        func refused(_ reason: RemoveDeloadRefusal, week: Int? = nil, collisions: [DateCollision] = []) -> RemoveDeloadPlan {
            RemoveDeloadPlan(meso: meso, now: now, weekIndex: week, removals: [], shifted: [], collisions: collisions,
                             refusal: reason, blockEndBefore: blockEndBefore, blockEndAfter: blockEndBefore)
        }

        if meso.status != .active { return refused(.inactiveMeso) }
        if all.contains(where: { $0.status == .inProgress }) { return refused(.sessionInProgress) }

        let insertedWeeks = Dictionary(grouping: all.filter { $0.insertedDeload == true }, by: \.weekIndex)
        guard !insertedWeeks.isEmpty else { return refused(.noInsertedDeload) }

        // The first inserted week that can go; if none can, report why the first one cannot.
        func blocker(_ week: Int) -> RemoveDeloadRefusal? {
            let inserted = insertedWeeks[week] ?? []
            if inserted.contains(where: { !SessionEditSafety.isSafeToModify($0) }) { return .deloadStarted }
            if all.contains(where: { $0.weekIndex == week && $0.insertedDeload != true }) { return .mixedWeek }
            if all.contains(where: { $0.weekIndex > week && $0.status != .planned }) { return .laterSessionCompleted }
            return nil
        }
        let weeks = insertedWeeks.keys.sorted()
        let chosen: Int
        if let requested {
            guard insertedWeeks[requested] != nil else { return refused(.noInsertedDeload, week: requested) }
            if let reason = blocker(requested) { return refused(reason, week: requested) }
            chosen = requested
        } else if let first = weeks.first(where: { blocker($0) == nil }) {
            chosen = first
        } else {
            return refused(blocker(weeks[0]) ?? .deloadStarted, week: weeks[0])
        }
        let week = chosen

        let removals = (insertedWeeks[week] ?? []).sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        let moving = all.filter { $0.weekIndex > week }
            .sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        let shifted: [ShiftedSession] = moving.map { s in
            ShiftedSession(session: s, oldDate: s.date,
                           newDate: calendar.date(byAdding: .day, value: -7, to: s.date) ?? s.date,
                           oldWeek: s.weekIndex, newWeek: s.weekIndex - 1)
        }

        let removedIDs = Set(removals.map(\.persistentModelID))
        let remaining = ((try? context.fetch(FetchDescriptor<Session>())) ?? []).filter { !removedIDs.contains($0.persistentModelID) }
        let collisions = shiftCollisions(shifted, among: remaining, calendar: calendar)
        if !collisions.isEmpty { return refused(.dateCollision, week: week, collisions: collisions) }

        let survivors = all.filter { !removedIDs.contains($0.persistentModelID) }
        let shiftedByID = Dictionary(uniqueKeysWithValues: shifted.map { ($0.session.persistentModelID, $0.newDate) })
        let blockEndAfter = survivors.map { shiftedByID[$0.persistentModelID] ?? $0.date }.max()
        return RemoveDeloadPlan(meso: meso, now: now, weekIndex: week, removals: removals, shifted: shifted,
                                collisions: [], refusal: nil, blockEndBefore: blockEndBefore, blockEndAfter: blockEndAfter)
    }

    // MARK: Apply

    @discardableResult
    static func removeInsertedDeloadWeek(_ plan: RemoveDeloadPlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> RemoveDeloadResult {
        guard plan.isApplicable, plan.weekIndex != nil else {
            throw RemoveDeloadError.refused(plan.refusal ?? .noInsertedDeload)
        }
        let meso = plan.meso

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let live = planRemoveInsertedDeloadWeek(meso: meso, context: context, now: plan.now, week: plan.weekIndex)
        guard live.isApplicable, let week = live.weekIndex else {
            throw RemoveDeloadError.refused(live.refusal ?? .noInsertedDeload)
        }
        guard week == plan.weekIndex,
              live.removals.map({ $0.persistentModelID }) == plan.removals.map({ $0.persistentModelID }),
              live.shifted.map({ $0.session.persistentModelID }) == plan.shifted.map({ $0.session.persistentModelID })
        else { throw RemoveDeloadError.planStale }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let calendar = Calendar.current
        let removedIDs = Set(live.removals.map(\.persistentModelID))

        func survivingSessions() -> [Session] {
            var seen = Set<PersistentIdentifier>()
            return (((try? context.fetch(FetchDescriptor<Session>())) ?? []) + meso.sessions)
                .filter { !removedIDs.contains($0.persistentModelID) && seen.insert($0.persistentModelID).inserted }
        }
        let chainSources: [(session: Session, item: SessionItem)] =
            meso.sessions.sorted { $0.date < $1.date }.filter { !removedIDs.contains($0.persistentModelID) }
                .flatMap { s in s.items.filter { $0.waveRaw?.lowercased() != deloadWaveRaw }.map { (s, $0) } }
        func chainTargets(_ sessions: [Session]) -> [ObjectIdentifier?] {
            chainSources.map { PlanMemoryEngine.nextTargetItem(for: $0.item, after: $0.session, in: sessions).map(ObjectIdentifier.init) }
        }
        let chainsBefore = chainTargets(survivingSessions())
        let weeksBefore = Set(meso.sessions.map(\.weekIndex))
        let insertedBefore = meso.sessions.filter { $0.insertedDeload == true }.count

        struct SessionRestore {
            let session: Session; let date: Date; let week: Int?; let programIndex: Int?
            init(_ s: Session) { session = s; date = s.date; week = s.weekInMeso; programIndex = s.programIndex }
        }
        let untouched = meso.sessions.filter { s in
            !removedIDs.contains(s.persistentModelID) && !live.shifted.contains { $0.session === s }
        }
        let restores = (untouched + live.shifted.map(\.session)).map(SessionRestore.init)
        let totalWeeksBefore = meso.totalWeeks
        let mesoSessionsBefore = meso.sessions
        func abandon() {
            for r in restores { r.session.date = r.date; r.session.weekInMeso = r.week; r.session.programIndex = r.programIndex }
            meso.totalWeeks = totalWeeksBefore
            meso.sessions = mesoSessionsBefore
            context.rollback()
        }

        // programIndex base: the lowest index in the removed + moved block, taken before anything moves.
        let base = (live.removals + live.shifted.map(\.session)).compactMap(\.programIndex).min()
        let canRenumber = live.shifted.allSatisfy { $0.session.programIndex != nil }

        // 1. Delete the inserted sessions.
        meso.sessions.removeAll { removedIDs.contains($0.persistentModelID) }
        for s in live.removals { context.delete(s) }

        // 2. Later sessions come back a week.
        for move in live.shifted {
            move.session.date = move.newDate
            move.session.weekInMeso = move.newWeek
        }
        if let total = totalWeeksBefore { meso.totalWeeks = max(1, total - 1) }

        // 3. programIndex follows date order across the moved sessions.
        var renumbered = false
        if let base, canRenumber {
            let order = live.shifted.map(\.session).sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
            for (offset, s) in order.enumerated() { s.programIndex = base + offset }
            renumbered = true
        }

        // 4. Verify before anything is saved.
        var problems: [String] = []
        func check<T: Equatable>(_ what: String, _ expected: T, _ actual: T) {
            if expected != actual { problems.append("\(what): expected \(expected), found \(actual)") }
        }
        let after = survivingSessions()

        check("inserted sessions left in the block", 0, meso.sessions.filter { removedIDs.contains($0.persistentModelID) }.count)
        check("inserted sessions remaining", insertedBefore - live.removals.count, meso.sessions.filter { $0.insertedDeload == true }.count)
        for move in live.shifted {
            check("\(isoDay(move.oldDate)) \(move.session.dayLabel ?? "?") new date", move.newDate, move.session.date)
            check("\(isoDay(move.oldDate)) \(move.session.dayLabel ?? "?") new week", move.newWeek, move.session.weekIndex)
        }
        let expectedWeeks = Set(weeksBefore.filter { $0 < week } + weeksBefore.filter { $0 > week }.map { $0 - 1 })
        check("weeks", expectedWeeks.sorted(), Set(meso.sessions.map(\.weekIndex)).sorted())
        if let before = totalWeeksBefore { check("totalWeeks", max(1, before - 1), meso.totalWeeks ?? -1) }
        for r in restores where !live.shifted.contains(where: { $0.session === r.session }) {
            if r.session.date != r.date || r.session.weekInMeso != r.week || r.session.programIndex != r.programIndex {
                problems.append("\(isoDay(r.date)) \(r.session.dayLabel ?? "?"): an untouched session changed")
            }
        }
        for c in shiftCollisions(live.shifted, among: after, calendar: calendar) {
            problems.append("date collision on \(isoDay(c.date)): \(c.moved.dayLabel ?? "?") vs \(c.occupant.dayLabel ?? "?")")
        }
        if renumbered {
            let indices = live.shifted.map(\.session).sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }.compactMap(\.programIndex)
            check("programIndex contiguous in date order", Array(indices.first.map { $0..<($0 + indices.count) } ?? 0..<0), indices)
        }
        for (idx, (b, a)) in zip(chainsBefore, chainTargets(after)).enumerated() where b != a {
            let src = chainSources[idx]
            problems.append("carry-forward chain changed for \(src.item.exerciseId) \(isoDay(src.session.date)) \(src.session.dayLabel ?? "?")")
        }
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw RemoveDeloadError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedRemoveSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw RemoveDeloadError.saveFailed("\(error)")
        }

        if let next = MesoLifecycle.scheduledStartDate,
           let moved = calendar.date(byAdding: .day, value: -7, to: next) {
            MesoLifecycle.scheduleNextMeso(on: moved)
        }

        var summary = live.removals.map { "SessionItemEdit: removed inserted deload wk\(week) \(isoDay($0.date)) \($0.dayLabel ?? "?")" }
        summary.append("SessionItemEdit: \(live.shifted.count) sessions moved one week earlier")
        summary.forEach { print($0) }
        return RemoveDeloadResult(deloadSessionsRemoved: live.removals.count, sessionsShifted: live.shifted.count, summary: summary)
    }
}

// MARK: - Rest today

/// "Rest today": today becomes a rest day, so today's meso moves its remaining planned sessions of this
/// week forward one day. Same shape as the other edits: a pure plan for the preview, then an apply that
/// re-plans, writes, verifies and saves once (restoring every date on failure). Only dates change.
extension SessionItemEditService {

    enum RestTodayRefusal: Equatable {
        /// A session in the block is being trained.
        case sessionInProgress
        /// The block has no planned session today.
        case nothingToMove
        /// A session that would move already has logged work.
        case unsafeSession
        /// A moved session would land on a day another session already occupies (see `collisions`).
        case dateCollision
    }

    enum RestTodayWarning: Equatable {
        /// A moved session reaches the first day of the following week's training.
        case reachesNextWeek(date: Date, dayLabel: String?)
        /// A moved session reaches or passes the scheduled start of the next block.
        case pastNextMesoStart(date: Date, nextStart: Date)
    }

    enum RestTodayError: Error, Equatable {
        case refused(RestTodayRefusal)
        case planStale
        case verificationFailed([String])
        case saveFailed(String)
    }

    struct RestTodayPlan {
        let meso: MesoBlock
        let now: Date
        let weekIndex: Int?
        /// Sessions to move, in date order (`newWeek == oldWeek`: only the date changes).
        let moves: [ShiftedSession]
        let collisions: [DateCollision]
        let warnings: [RestTodayWarning]
        let refusal: RestTodayRefusal?

        var isApplicable: Bool { refusal == nil && !moves.isEmpty }
    }

    struct RestTodayResult {
        let sessionsMoved: Int
        let summary: [String]
    }

    private struct ForcedRestSaveFailure: Error {}

    // MARK: Plan (no writes)

    static func planRestToday(meso: MesoBlock, context: ModelContext, now: Date = Date()) -> RestTodayPlan {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let all = meso.sessions

        func refused(_ reason: RestTodayRefusal, week: Int? = nil, moves: [ShiftedSession] = [], collisions: [DateCollision] = []) -> RestTodayPlan {
            RestTodayPlan(meso: meso, now: now, weekIndex: week, moves: moves, collisions: collisions, warnings: [], refusal: reason)
        }

        if all.contains(where: { $0.status == .inProgress }) { return refused(.sessionInProgress) }

        // Today's session in THIS block fixes the week; sessions of any other block are never candidates.
        guard let today = all.filter({ calendar.startOfDay(for: $0.date) == startOfToday && $0.status == .planned })
            .min(by: { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) })
        else { return refused(.nothingToMove) }
        let week = today.weekIndex

        let moving = all
            .filter { $0.weekIndex == week && $0.status == .planned && calendar.startOfDay(for: $0.date) >= startOfToday }
            .sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        let moves: [ShiftedSession] = moving.map { s in
            ShiftedSession(session: s, oldDate: s.date,
                           newDate: calendar.date(byAdding: .day, value: 1, to: s.date) ?? s.date,
                           oldWeek: week, newWeek: week)
        }
        if moving.contains(where: { !SessionEditSafety.isSafeToModify($0) }) { return refused(.unsafeSession, week: week) }

        // Every other session, any block and any status.
        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let collisions = shiftCollisions(moves, among: allSessions, calendar: calendar)
        if !collisions.isEmpty { return refused(.dateCollision, week: week, moves: moves, collisions: collisions) }

        var warnings: [RestTodayWarning] = []
        if let nextWeekFirst = all.filter({ $0.weekIndex > week }).min(by: { $0.date < $1.date }).map({ calendar.startOfDay(for: $0.date) }) {
            for m in moves where calendar.startOfDay(for: m.newDate) >= nextWeekFirst {
                warnings.append(.reachesNextWeek(date: m.newDate, dayLabel: m.session.dayLabel))
            }
        }
        if let next = MesoLifecycle.scheduledStartDate {
            let nextDay = calendar.startOfDay(for: next)
            for m in moves where calendar.startOfDay(for: m.newDate) >= nextDay {
                warnings.append(.pastNextMesoStart(date: m.newDate, nextStart: next))
            }
        }
        return RestTodayPlan(meso: meso, now: now, weekIndex: week, moves: moves, collisions: [], warnings: warnings, refusal: nil)
    }

    // MARK: Apply

    @discardableResult
    static func restToday(_ plan: RestTodayPlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> RestTodayResult {
        guard plan.isApplicable else { throw RestTodayError.refused(plan.refusal ?? .nothingToMove) }
        let meso = plan.meso

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let live = planRestToday(meso: meso, context: context, now: plan.now)
        guard live.isApplicable else { throw RestTodayError.refused(live.refusal ?? .nothingToMove) }
        guard live.weekIndex == plan.weekIndex,
              live.moves.map({ $0.session.persistentModelID }) == plan.moves.map({ $0.session.persistentModelID })
        else { throw RestTodayError.planStale }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let calendar = Calendar.current
        func everySession() -> [Session] {
            var seen = Set<PersistentIdentifier>()
            return (((try? context.fetch(FetchDescriptor<Session>())) ?? []) + meso.sessions)
                .filter { seen.insert($0.persistentModelID).inserted }
        }
        let chainSources: [(session: Session, item: SessionItem)] =
            meso.sessions.sorted { $0.date < $1.date }.flatMap { s in s.items.map { (s, $0) } }
        func chainTargets() -> [PersistentIdentifier?] {
            let sessions = everySession()
            return chainSources.map { PlanMemoryEngine.nextTargetItem(for: $0.item, after: $0.session, in: sessions)?.persistentModelID }
        }
        let chainsBefore = chainTargets()

        struct DateRestore {
            let session: Session; let date: Date; let week: Int?; let programIndex: Int?
            init(_ s: Session) { session = s; date = s.date; week = s.weekInMeso; programIndex = s.programIndex }
        }
        let restores = live.moves.map { DateRestore($0.session) }
        func abandon() {
            for r in restores { r.session.date = r.date; r.session.weekInMeso = r.week; r.session.programIndex = r.programIndex }
            context.rollback()
        }

        for move in live.moves { move.session.date = move.newDate }

        var problems: [String] = []
        for (move, r) in zip(live.moves, restores) {
            let tag = "\(isoDay(move.oldDate)) \(move.session.dayLabel ?? "?")"
            if move.session.date != move.newDate { problems.append("\(tag): date is not the planned one") }
            if calendar.dateComponents([.day], from: calendar.startOfDay(for: r.date), to: calendar.startOfDay(for: move.session.date)).day != 1 {
                problems.append("\(tag): did not move exactly one day")
            }
            if move.session.weekInMeso != r.week || move.session.programIndex != r.programIndex {
                problems.append("\(tag): week or index changed")
            }
        }
        for (idx, (b, a)) in zip(chainsBefore, chainTargets()).enumerated() where b != a {
            let src = chainSources[idx]
            problems.append("carry-forward chain changed for \(src.item.exerciseId) \(isoDay(src.session.date)) \(src.session.dayLabel ?? "?")")
        }
        for c in shiftCollisions(live.moves, among: everySession(), calendar: calendar) {
            problems.append("date collision on \(isoDay(c.date)): \(c.moved.dayLabel ?? "?") vs \(c.occupant.dayLabel ?? "?")")
        }
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw RestTodayError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedRestSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw RestTodayError.saveFailed("\(error)")
        }

        let summary = live.moves.map {
            "SessionItemEdit: rest today wk\(live.weekIndex ?? 0) \($0.session.dayLabel ?? "?") \(isoDay($0.oldDate)) -> \(isoDay($0.newDate))"
        }
        summary.forEach { print($0) }
        return RestTodayResult(sessionsMoved: live.moves.count, summary: summary)
    }
}

// MARK: - Start the next meso from this one

/// Builds a new meso that keeps a meso's CURRENT program (latest roster, prescriptions and cues per day
/// type and wave letter, and its week-by-week set counts) on new dates, with loads seeded from the
/// lifter's history. Same shape as the other edits: `planNextMeso` is a pure read for the preview;
/// `startNextMeso` (apply) re-plans against live state, writes, verifies and saves once, or restores.
///
/// TEMPLATE. The old meso's early weeks may hold exercises or prescriptions that were later replaced or
/// changed (those edits only touch remaining sessions), so weeks are not cloned as stored. Instead, for
/// every day type x wave letter the LATEST session of that letter (completed or planned) supplies the
/// roster, order, prescription fields, cue and wave; the old meso's week -> letter pattern lays out the
/// weeks. Inserted deload weeks are not part of the program and are skipped (weeks are renumbered
/// contiguously). Set counts are not stored as a ramp, so each new week's set count is read back from
/// the old meso's same week and slot (earned +1 sets, hand edits and the template ramp all reproduce);
/// the set band is widened to include it, never narrowed. A block with no wave letters (maintenance,
/// legacy) has one template per day type: its latest session.
extension SessionItemEditService {

    /// Peak-based seed scale (the "95" in peak95). Phase 4.4 gating can pass a different factor.
    static let nextMesoPeakFactor = 0.95

    enum NextMesoRefusal: Equatable {
        /// The meso has no sessions to copy from.
        case nothingToCopy
        /// A session in the old meso is being trained.
        case sessionInProgress
        /// The start date is before today.
        case startInPast
        /// The old meso still has sessions dated today or later and `endOldMesoNow` is false (see `remainingOldSessions`).
        case oldMesoHasRemainingSessions
        /// `endOldMesoNow` would remove a remaining session that already has something logged on it.
        case remainingSessionHasLoggedData
        /// One week of the old meso has two sessions of the same day type, so the weekday pattern is ambiguous.
        case duplicateDayLabelInWeek
        /// A new session would land on a day that already has a session (see `collisions`).
        case dateCollision
    }

    enum NextMesoError: Error, Equatable {
        case refused([NextMesoRefusal])
        /// The live state no longer matches the plan.
        case planStale
        case verificationFailed([String])
        case saveFailed(String)
    }

    struct NextMesoCollision {
        let date: Date
        let dayLabel: String?
        /// The existing session on that day; nil when two sessions of the new meso share it.
        let occupant: Session?
    }

    struct NextMesoItem {
        let order: Int
        let exerciseId: String
        let exerciseName: String?
        let targetReps: Int
        let targetSets: Int
        let targetRIR: Int
        let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?
        let waveRaw: String?
        let priorityRaw: String?
        let intensifierRaw: String?
        let intensifierNotes: String?
        let prescriptionNotes: String?
        let plannedReps: [Int]
        let plannedRIRs: [Int]
        let seed: Double
        let seedSource: HistorySeedLoad.SeedSource
        let isBodyweight: Bool
        /// The latest session item this one was taken from.
        let templateItem: SessionItem

        /// "4 x 4-6 @ RIR 2-3"
        var prescription: String {
            func range(_ lo: Int?, _ hi: Int?, _ fallback: Int) -> String {
                guard let lo, let hi else { return "\(fallback)" }
                return lo == hi ? "\(lo)" : "\(lo)-\(hi)"
            }
            return "\(targetSets) x \(range(repMin, repMax, targetReps)) @ RIR \(range(rirMin, rirMax, targetRIR))"
        }
    }

    struct NextMesoSession {
        let date: Date
        let dayLabel: String?
        /// 1-based, contiguous (inserted deload weeks of the old meso are skipped).
        let weekIndex: Int
        /// 1...K in date order across the whole new meso.
        let programIndex: Int
        /// Wave letter of the week ("a", "b", "c", "deload"); "" for a block with no letters.
        let letter: String
        let sessionNotes: String
        let items: [NextMesoItem]
        /// The latest session of this day type and letter, which supplied the roster.
        let templateSession: Session
    }

    struct NextMesoPlan {
        let oldMeso: MesoBlock
        let name: String
        let startDate: Date
        let endOldMesoNow: Bool
        let peakFactor: Double
        let now: Date
        let sessions: [NextMesoSession]
        let weeks: Int
        let endDate: Date?
        /// Old meso sessions removed when `endOldMesoNow` (planned, dated today or later, nothing logged).
        let sessionsToDelete: [Session]
        /// Old meso sessions dated today or later that are not completed.
        let remainingOldSessions: [Session]
        let collisions: [NextMesoCollision]
        let refusals: [NextMesoRefusal]

        var isApplicable: Bool { refusals.isEmpty && !sessions.isEmpty }
        var isMaintenance: Bool { oldMeso.isMaintenance }

        /// The sessions of week 1 (the first week the lifter will train).
        var firstWeek: [NextMesoSession] { sessions.filter { $0.weekIndex == 1 } }

        /// The preview as text: header, one roster per day type x letter (prescription, seed and where it
        /// came from), and the set count by week for every slot.
        func previewLines() -> [String] {
            var out: [String] = []
            func day(_ d: Date?) -> String { d.map(SessionItemEditService.isoDay) ?? "-" }
            out.append("NEXT MESO \"\(name)\": \(weeks) weeks, \(sessions.count) sessions, \(day(startDate)) -> \(day(endDate)); "
                       + "from \"\(oldMeso.name)\"; peak factor \(peakFactor)")
            if endOldMesoNow {
                out.append("old meso ends now: \(sessionsToDelete.count) remaining planned sessions removed")
            }
            var seen = Set<String>()
            for s in sessions {
                let key = "\(s.dayLabel ?? "")|\(s.letter)"
                guard seen.insert(key).inserted else { continue }
                out.append("  \(s.dayLabel ?? "?") / \(s.letter.isEmpty ? "-" : s.letter.uppercased()) (first week \(s.weekIndex), \(day(s.date)))")
                for i in s.items {
                    out.append("    \(ExerciseCatalog.displayName(for: i.exerciseId)): \(i.prescription), seed "
                               + "\(LoadFormatter.number(i.seed)) [\(i.seedSource.label(factor: peakFactor))]"
                               + (SessionItemEditService.noteText(i).map { " — \($0)" } ?? ""))
                }
            }
            var labels: [String] = []
            for s in sessions where !labels.contains(s.dayLabel ?? "") { labels.append(s.dayLabel ?? "") }
            for label in labels {
                out.append("  sets by week, \(label.isEmpty ? "?" : label):")
                let mine = sessions.filter { ($0.dayLabel ?? "") == label }
                let orders = Set(mine.flatMap { $0.items.map(\.order) }).sorted()
                for o in orders {
                    let name = mine.compactMap { $0.items.first { $0.order == o }?.exerciseId }.last.map(ExerciseCatalog.displayName(for:)) ?? "?"
                    let sets = mine.sorted { $0.weekIndex < $1.weekIndex }.map { s in s.items.first { $0.order == o }.map { String($0.targetSets) } ?? "-" }
                    out.append("    \(name): \(sets.joined(separator: ","))")
                }
            }
            return out
        }
    }

    fileprivate static func noteText(_ i: NextMesoItem) -> String? {
        NoteFields(intensifier: i.intensifierNotes, prescription: i.prescriptionNotes).displayed
    }

    /// The day after the meso's last session, at the start of its day; nil for a meso with no sessions.
    static func defaultNextMesoStart(for meso: MesoBlock, calendar: Calendar = .current) -> Date? {
        guard let last = meso.sessions.map(\.date).max() else { return nil }
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    // MARK: Plan (no writes)

    static func planNextMeso(
        meso: MesoBlock,
        name: String,
        startDate: Date? = nil,
        endOldMesoNow: Bool,
        peakFactor: Double = nextMesoPeakFactor,
        context: ModelContext,
        now: Date = Date(),
        calendar cal: Calendar = .current
    ) -> NextMesoPlan {
        let startOfToday = cal.startOfDay(for: now)
        let startDay = cal.startOfDay(for: startDate ?? defaultNextMesoStart(for: meso, calendar: cal) ?? now)
        let all = meso.sessions
        var refusals: [NextMesoRefusal] = []

        let remaining = all.filter { $0.status != .completed && $0.date >= startOfToday }
        let toDelete = endOldMesoNow ? all.filter { $0.status == .planned && $0.date >= startOfToday && SessionEditSafety.isSafeToModify($0) } : []

        func plan(sessions: [NextMesoSession] = [], weeks: Int = 0, collisions: [NextMesoCollision] = []) -> NextMesoPlan {
            NextMesoPlan(oldMeso: meso, name: name, startDate: startDay, endOldMesoNow: endOldMesoNow, peakFactor: peakFactor,
                         now: now, sessions: sessions, weeks: weeks, endDate: sessions.map(\.date).max(),
                         sessionsToDelete: toDelete, remainingOldSessions: remaining, collisions: collisions,
                         refusals: refusals)
        }

        let sources = all.filter { $0.insertedDeload != true }
        guard !sources.isEmpty else { refusals.append(.nothingToCopy); return plan() }

        if all.contains(where: { $0.status == .inProgress }) { refusals.append(.sessionInProgress) }
        if startDay < startOfToday { refusals.append(.startInPast) }
        if endOldMesoNow {
            if remaining.contains(where: { $0.status == .planned && !SessionEditSafety.isSafeToModify($0) }) {
                refusals.append(.remainingSessionHasLoggedData)
            }
        } else if !remaining.isEmpty {
            refusals.append(.oldMesoHasRemainingSessions)
        }

        func label(_ s: Session) -> String { s.dayLabel ?? "" }
        func ordered(_ ss: [Session]) -> [Session] {
            ss.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        }

        // Week -> letter. A wave letter is a property of the whole week (the majority of its items' waves).
        let weekOrder = Array(Set(sources.map(\.weekIndex))).sorted()
        let waveBased = !meso.isMaintenance && sources.contains { $0.items.contains { WavePrescriptionGuard.isWaveLetter($0.waveRaw) } }
        func weekLetter(_ week: Int) -> String {
            guard waveBased else { return "" }
            var counts: [String: Int] = [:]
            for s in sources where s.weekIndex == week {
                for i in s.items {
                    let l = i.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                    if !l.isEmpty { counts[l, default: 0] += 1 }
                }
            }
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        }
        let letters = Dictionary(uniqueKeysWithValues: weekOrder.map { ($0, weekLetter($0)) })

        /// Latest session of this day type and letter; any letter when that letter never occurred for the day.
        func template(_ dayLabel: String, _ letter: String) -> Session? {
            let ofDay = ordered(sources.filter { label($0) == dayLabel })
            return ofDay.last { letters[$0.weekIndex] == letter } ?? ofDay.last
        }

        // Weekday of each day type: the most common one across the old meso (ties: the earlier weekday).
        var weekdayCounts: [String: [Int: Int]] = [:]
        for s in sources { weekdayCounts[label(s), default: [:]][cal.component(.weekday, from: s.date), default: 0] += 1 }
        func modeWeekday(_ dayLabel: String) -> Int {
            let counts = weekdayCounts[dayLabel] ?? [:]
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 2
        }
        func firstDate(onOrAfter d: Date, weekday: Int) -> Date {
            var date = d
            for _ in 0..<7 {
                if cal.component(.weekday, from: date) == weekday { return date }
                date = cal.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return d
        }

        // Day types per old week, in the order the lifter trained them; the first of week 1 starts each new week.
        var labelsByWeek: [Int: [Session]] = [:]
        for w in weekOrder { labelsByWeek[w] = ordered(sources.filter { $0.weekIndex == w }) }
        for w in weekOrder {
            let ls = (labelsByWeek[w] ?? []).map(label)
            if Set(ls).count != ls.count { refusals.append(.duplicateDayLabelInWeek); return plan() }
        }
        guard let firstLabel = labelsByWeek[weekOrder[0]]?.first.map(label) else { refusals.append(.nothingToCopy); return plan() }
        let firstWeekStart = firstDate(onOrAfter: startDay, weekday: modeWeekday(firstLabel))

        // Loads
        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let increment = profile?.minLoadIncrement ?? 2.5
        var seedCache: [String: (load: Double, source: HistorySeedLoad.SeedSource)] = [:]
        func seed(_ exerciseId: String, reps: Int, rir: Int) -> (load: Double, source: HistorySeedLoad.SeedSource) {
            let key = "\(ExerciseCatalog.canonicalExerciseId(for: exerciseId))|\(reps)|\(rir)"
            if let hit = seedCache[key] { return hit }
            let r = HistorySeedLoad.nextMesoSeed(
                for: exerciseId, goalReps: reps, targetRIR: rir, previousMeso: all, allSessions: allSessions,
                loadIncrement: increment, bodyWeight: profile?.bodyWeight,
                isFixedLoad: UserProfile.isProgressionExempt(exerciseId: exerciseId, profile: profile),
                factor: peakFactor, customExercises: custom, referenceDate: now
            )
            seedCache[key] = r
            return r
        }

        // Layout
        var built: [(date: Date, week: Int, label: String, letter: String, old: Session, tpl: Session)] = []
        for (idx, oldWeek) in weekOrder.enumerated() {
            let base = cal.date(byAdding: .day, value: 7 * idx, to: firstWeekStart) ?? firstWeekStart
            let letter = letters[oldWeek] ?? ""
            let rows: [(date: Date, week: Int, label: String, letter: String, old: Session, tpl: Session)] =
                (labelsByWeek[oldWeek] ?? []).compactMap { old in
                    let l = label(old)
                    guard let tpl = template(l, letter) else { return nil }
                    return (firstDate(onOrAfter: base, weekday: modeWeekday(l)), idx + 1, l, letter, old, tpl)
                }
            built += rows.sorted { $0.date < $1.date }
        }

        // Collisions: any existing session (any meso) except the ones this action removes, and the new sessions among themselves.
        let removing = Set(toDelete.map(\.persistentModelID))
        let occupied = Dictionary(grouping: allSessions.filter { !removing.contains($0.persistentModelID) },
                                  by: { cal.startOfDay(for: $0.date) })
        var collisions: [NextMesoCollision] = []
        var claimed = Set<Date>()
        for row in built {
            let day = cal.startOfDay(for: row.date)
            for other in occupied[day] ?? [] { collisions.append(.init(date: day, dayLabel: row.label.isEmpty ? nil : row.label, occupant: other)) }
            if !claimed.insert(day).inserted { collisions.append(.init(date: day, dayLabel: row.label.isEmpty ? nil : row.label, occupant: nil)) }
        }
        if !collisions.isEmpty { refusals.append(.dateCollision) }

        // Sessions and items
        let isMaintenance = meso.isMaintenance
        var sessions: [NextMesoSession] = []
        for (n, row) in built.enumerated() {
            let oldItems = row.old.items
            let items: [NextMesoItem] = row.tpl.items.sorted { $0.order < $1.order }.map { t in
                let canonical = ExerciseCatalog.canonicalExerciseId(for: t.exerciseId)
                // The same exercise in the old week first, else whatever sat in the same slot there.
                let slot = oldItems.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }
                    ?? oldItems.first { $0.order == t.order }
                let sets = max(0, slot?.targetSets ?? t.targetSets)
                let wave: String? = {
                    if let raw = t.waveRaw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty { return t.waveRaw }
                    return waveBased && !row.letter.isEmpty ? row.letter : nil
                }()
                let shown = NoteFields(t).displayed
                let showsIntensifier = !(t.intensifierNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let r = seed(t.exerciseId, reps: t.targetReps, rir: t.targetRIR)
                return NextMesoItem(
                    order: t.order, exerciseId: t.exerciseId,
                    exerciseName: t.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: t.exerciseId),
                    targetReps: t.targetReps, targetSets: sets, targetRIR: t.targetRIR,
                    setMin: t.setMin.map { min($0, sets) }, setMax: t.setMax.map { max($0, sets) },
                    repMin: t.repMin, repMax: t.repMax, rirMin: t.targetRIRMin, rirMax: t.targetRIRMax,
                    waveRaw: wave, priorityRaw: t.priorityRaw, intensifierRaw: t.intensifierRaw,
                    intensifierNotes: showsIntensifier ? shown : nil,
                    prescriptionNotes: showsIntensifier ? nil : shown,
                    plannedReps: resized(t.plannedRepsBySet, to: sets, fallback: t.targetReps),
                    plannedRIRs: resized(t.plannedRIRsBySet, to: sets, fallback: t.targetRIR),
                    seed: r.load, seedSource: r.source,
                    isBodyweight: ExerciseCatalog.isBodyweight(exerciseId: t.exerciseId, customExercises: custom),
                    templateItem: t
                )
            }
            let dayName = row.label.isEmpty ? "Session" : row.label
            let notes: String = {
                if isMaintenance { return "\(dayName) · Maintenance" }
                if row.letter.isEmpty { return dayName }
                return "\(dayName) · \(row.letter == "deload" ? "Deload" : row.letter.uppercased()) wave"
            }()
            sessions.append(NextMesoSession(
                date: row.date, dayLabel: row.label.isEmpty ? nil : row.label, weekIndex: row.week, programIndex: n + 1,
                letter: row.letter, sessionNotes: notes, items: items, templateSession: row.tpl
            ))
        }
        return plan(sessions: sessions, weeks: weekOrder.count, collisions: collisions)
    }
}

// MARK: - Start the next meso: apply

extension SessionItemEditService {

    struct NextMesoResult {
        let meso: MesoBlock
        let sessionsCreated: Int
        let sessionsDeleted: Int
        /// One line per created session.
        let summary: [String]
    }

    private struct ForcedNextMesoSaveFailure: Error {}

    /// Everything about a session the plan or the user could have touched, as one comparable string.
    fileprivate static func sessionFingerprint(_ s: Session) -> String {
        var out = ["S", "\(s.date.timeIntervalSince1970)", s.status.rawValue, "\(s.weekIndex)", s.dayLabel ?? "-",
                   s.programIndex.map(String.init) ?? "-", s.sessionNotes ?? "-", "\(s.insertedDeload.map { "\($0)" } ?? "-")",
                   s.completedAt.map { "\($0.timeIntervalSince1970)" } ?? "-", "\(s.readinessStars)", s.readinessRaw,
                   "\(s.hkWorkoutUUID ?? "-")", "\(s.hkDuration)", "\(s.items.count)"].joined(separator: "|")
        for i in s.items.sorted(by: { ($0.order, $0.exerciseId) < ($1.order, $1.exerciseId) }) {
            func opt(_ v: Int?) -> String { v.map(String.init) ?? "-" }
            out += "\n" + [
                "I", i.id?.uuidString ?? "", "\(i.order)", i.exerciseId, i.exerciseNameSnapshot ?? "-",
                "\(i.targetReps)", "\(i.targetSets)", "\(i.targetRIR)", "\(i.suggestedLoad)",
                i.waveRaw ?? "-", i.priorityRaw ?? "-", opt(i.setMin), opt(i.setMax), opt(i.repMin), opt(i.repMax),
                opt(i.targetRIRMin), opt(i.targetRIRMax), i.intensifierRaw ?? "-", i.intensifierNotes ?? "-", i.prescriptionNotes ?? "-",
                "\(i.logs.count)", "\(i.plannedRepsBySet)", "\(i.plannedLoadsBySet)", "\(i.plannedRIRsBySet)", "\(i.planEdited)",
                "\(i.actualReps)", "\(i.actualLoads)", "\(i.actualRIRs)", "\(i.usedRestPauseFlags)", "\(i.restPausePatternsBySet)",
                "\(i.dropSetPatternsBySet)", "\(i.setFeedbackBySet)", "\(i.pumpRatingsBySet)", "\(i.isCompleted)", "\(i.isPR)",
                i.coachNote ?? "-", i.loadOverrideReasonRaw ?? "-", i.nextSuggestedLoad.map { "\($0)" } ?? "-",
            ].joined(separator: "|")
        }
        return out
    }

    /// What the plan will write, as text, for the "has the live state moved" comparison.
    private static func signature(_ plan: NextMesoPlan) -> String {
        var parts = ["\(plan.oldMeso.persistentModelID)", plan.name, "\(plan.startDate.timeIntervalSince1970)", "\(plan.endOldMesoNow)",
                     "\(plan.peakFactor)", plan.sessionsToDelete.map { "\($0.persistentModelID)" }.sorted().joined(separator: ",")]
        for s in plan.sessions {
            parts.append("\(s.date.timeIntervalSince1970)|\(s.dayLabel ?? "-")|\(s.weekIndex)|\(s.programIndex)|\(s.letter)|\(s.sessionNotes)")
            for i in s.items {
                parts.append("  \(i.order)|\(i.exerciseId)|\(i.targetSets)|\(i.targetReps)|\(i.targetRIR)|\(i.waveRaw ?? "-")|\(i.seed)|\(i.seedSource.rawValue)|\(i.intensifierNotes ?? "-")|\(i.prescriptionNotes ?? "-")")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Creates the planned meso, archives the old one (and removes its remaining planned sessions when the plan
    /// says so), verifies, and saves once. Any failure puts every changed field back and throws, leaving the
    /// store as it was. The meso lifecycle (labeling anchor, scheduled next-meso date) moves only after the save.
    @discardableResult
    static func startNextMeso(_ plan: NextMesoPlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> NextMesoResult {
        guard plan.isApplicable else {
            throw NextMesoError.refused(plan.refusals.isEmpty ? [.nothingToCopy] : plan.refusals)
        }
        let old = plan.oldMeso

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        // The plan is a preview; trust only live state.
        let live = planNextMeso(meso: old, name: plan.name, startDate: plan.startDate, endOldMesoNow: plan.endOldMesoNow,
                                peakFactor: plan.peakFactor, context: context, now: plan.now)
        guard live.refusals.isEmpty, live.isApplicable else { throw NextMesoError.refused(live.refusals.isEmpty ? [.nothingToCopy] : live.refusals) }
        guard signature(live) == signature(plan) else { throw NextMesoError.planStale }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let calendar = Calendar.current
        let completedBefore = Dictionary(uniqueKeysWithValues: old.sessions.filter { $0.status == .completed }
            .map { ($0.persistentModelID, sessionFingerprint($0)) })
        let blocksBefore = (try? context.fetch(FetchDescriptor<MesoBlock>())) ?? []
        let statusBefore = blocksBefore.map { (block: $0, status: $0.status) }
        let removedIDs = Set(live.sessionsToDelete.map(\.persistentModelID))
        let otherSessionsBefore = ((try? context.fetch(FetchDescriptor<Session>())) ?? []).filter { !removedIDs.contains($0.persistentModelID) }

        // rollback() drops inserts and deletes but does not revert property edits (see DUPMesoLengthConversion.Snapshot),
        // so the one edit made to live objects, the status of the blocks it archives, is put back by hand.
        var created: [Session] = []
        var newMeso: MesoBlock?
        func abandon() {
            for entry in statusBefore { entry.block.status = entry.status }
            for s in created { context.delete(s) }
            if let newMeso { context.delete(newMeso) }
            context.rollback()
        }

        // 1. Archive every active block (the old meso among them).
        for block in blocksBefore where block.status == .active { block.status = .archived }
        old.status = .archived

        // 2. Remove the old meso's remaining planned sessions.
        for s in live.sessionsToDelete { context.delete(s) }

        // 3. The new meso, its sessions and items.
        let block = MesoBlock(
            name: plan.name, startDate: live.startDate, status: .active,
            notes: "Next meso from \(old.name) on \(isoDay(live.startDate))",
            totalWeeks: live.weeks, isMaintenance: old.isMaintenance
        )
        context.insert(block)
        newMeso = block
        for sp in live.sessions {
            let items: [SessionItem] = sp.items.map { ip in
                let item = SessionItem(
                    order: ip.order, exerciseId: ip.exerciseId, exerciseNameSnapshot: ip.exerciseName,
                    targetReps: ip.targetReps, targetSets: ip.targetSets, targetRIR: ip.targetRIR, suggestedLoad: ip.seed,
                    waveRaw: ip.waveRaw, priorityRaw: ip.priorityRaw,
                    setMin: ip.setMin, setMax: ip.setMax, repMin: ip.repMin, repMax: ip.repMax,
                    targetRIRMin: ip.rirMin, targetRIRMax: ip.rirMax,
                    intensifierRaw: ip.intensifierRaw, intensifierNotes: ip.intensifierNotes, prescriptionNotes: ip.prescriptionNotes,
                    plannedRepsBySet: ip.plannedReps,
                    plannedLoadsBySet: Array(repeating: ip.seed, count: ip.targetSets),
                    plannedRIRsBySet: ip.plannedRIRs
                )
                item.planEdited = false
                return item
            }
            let session = Session(date: sp.date, status: .planned, sessionNotes: sp.sessionNotes,
                                  weekIndex: sp.weekIndex, dayLabel: sp.dayLabel, items: items, programIndex: sp.programIndex)
            session.meso = block
            context.insert(session)
            created.append(session)
        }

        // 4. Verify before anything is saved.
        var problems: [String] = []
        func check<T: Equatable>(_ what: String, _ expected: T, _ actual: T) {
            if expected != actual { problems.append("\(what): expected \(expected), found \(actual)") }
        }
        check("created sessions in the block", live.sessions.count, block.sessions.count)
        check("block status", MesoStatus.active, block.status)
        check("totalWeeks", live.weeks, block.totalWeeks ?? -1)
        check("old meso status", MesoStatus.archived, old.status)
        check("active blocks", 1, blocksBefore.filter { $0.status == .active }.count + 1)

        let byIndex = created.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }
        check("programIndex contiguous", Array(1...created.count), byIndex.compactMap(\.programIndex))
        check("programIndex follows date order", byIndex.map(\.date), byIndex.map(\.date).sorted())
        let weeks = Set(created.map(\.weekIndex))
        check("weeks contiguous", Array(1...live.weeks), weeks.sorted())
        var weekdayByLabel: [String: Set<Int>] = [:]
        for s in created { weekdayByLabel[s.dayLabel ?? "", default: []].insert(calendar.component(.weekday, from: s.date)) }
        for (label, days) in weekdayByLabel where days.count != 1 { problems.append("day type \(label.isEmpty ? "?" : label) is on \(days.sorted()) weekdays") }

        for (sp, s) in zip(live.sessions, created) {
            let tag = "\(isoDay(sp.date)) \(sp.dayLabel ?? "?") wk\(sp.weekIndex)"
            check("\(tag) date", sp.date, s.date)
            check("\(tag) week", sp.weekIndex, s.weekIndex)
            check("\(tag) status", SessionStatus.planned, s.status)
            check("\(tag) insertedDeload", false, s.insertedDeload == true)
            check("\(tag) item count", sp.items.count, s.items.count)
            for (ip, i) in zip(sp.items, s.items.sorted { $0.order < $1.order }) {
                let t = "\(tag) \(ip.exerciseId)"
                check("\(t) exercise", ip.exerciseId, i.exerciseId)
                check("\(t) sets", ip.targetSets, i.targetSets)
                check("\(t) array sizes", [ip.targetSets, ip.targetSets, ip.targetSets],
                      [i.plannedRepsBySet.count, i.plannedLoadsBySet.count, i.plannedRIRsBySet.count])
                check("\(t) load", ip.seed, i.suggestedLoad)
                check("\(t) planned loads", Array(repeating: ip.seed, count: ip.targetSets), i.plannedLoadsBySet)
                check("\(t) planEdited", false, i.planEdited)
                check("\(t) logged", false, SessionEditSafety.hasLoggedData(i))
                check("\(t) actuals", 0, i.actualReps.count + i.actualLoads.count + i.actualRIRs.count + i.logs.count)
                if ip.isBodyweight { check("\(t) bodyweight load", 0.0, i.suggestedLoad) }
                if let lo = i.setMin, lo > ip.targetSets { problems.append("\(t): setMin \(lo) above sets \(ip.targetSets)") }
                if let hi = i.setMax, hi < ip.targetSets { problems.append("\(t): setMax \(hi) below sets \(ip.targetSets)") }
                if sp.letter.isEmpty == false, WavePrescriptionGuard.isWaveLetter(sp.letter) == false, i.waveRaw?.lowercased() != sp.letter {
                    problems.append("\(t): wave \(i.waveRaw ?? "nil") in a \(sp.letter) week")
                }
            }
        }

        // Dates: none shares a day with a session that stays, or with another new one.
        let stayingDays = Dictionary(grouping: otherSessionsBefore, by: { calendar.startOfDay(for: $0.date) })
        var claimed = Set<Date>()
        for s in created {
            let day = calendar.startOfDay(for: s.date)
            if !claimed.insert(day).inserted { problems.append("date collision on \(isoDay(day)) within the new meso") }
            if let other = stayingDays[day]?.first { problems.append("date collision on \(isoDay(day)) with \(other.dayLabel ?? "?")") }
        }

        // Chains: every new item's carry-forward target is the next occurrence inside the new meso, or nothing.
        let all = otherSessionsBefore + created
        for s in created {
            for i in s.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: i.exerciseId)
                let wave = i.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let later = created.filter { $0.date > s.date }.sorted { $0.date < $1.date }
                var expected: SessionItem?
                for c in later {
                    guard let match = c.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }) else { continue }
                    if wave.isEmpty {
                        if match.waveRaw?.lowercased() != deloadWaveRaw { expected = match; break }
                    } else if SessionDayLabelMatcher.matches(c.dayLabel, s.dayLabel), match.waveRaw?.lowercased() == wave {
                        expected = match; break
                    }
                }
                let resolved = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)
                if resolved !== expected {
                    let at = resolved.flatMap { r in all.first { $0.items.contains { $0 === r } } }
                    problems.append("chain \(isoDay(s.date)) \(s.dayLabel ?? "?") \(i.exerciseId) \(wave.isEmpty ? "(no wave)" : wave): expected "
                                    + "\(expected == nil ? "none" : "next in the new meso"), resolved \(at.map { "\(isoDay($0.date)) wk\($0.weekIndex)" } ?? "none")")
                }
            }
        }

        // The old meso's finished sessions are exactly as they were.
        for s in old.sessions where completedBefore[s.persistentModelID] != nil {
            if sessionFingerprint(s) != completedBefore[s.persistentModelID] { problems.append("completed session \(isoDay(s.date)) \(s.dayLabel ?? "?") changed") }
        }
        check("completed sessions kept", completedBefore.count, old.sessions.filter { $0.status == .completed && !removedIDs.contains($0.persistentModelID) }.count)
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw NextMesoError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedNextMesoSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw NextMesoError.saveFailed("\(error)")
        }

        // Saved: the lifecycle follows.
        MesoLifecycle.clearScheduledNextMeso()
        MesoLifecycle.confirmStartNewMeso(on: live.startDate)
        AppStateBridge.setActiveMesoStartDate(live.startDate, in: context)
        AppStateBridge.setScheduledNextMesoStartDate(nil, in: context)
        AppStateBridge.setMesoPromptSnoozeUntil(nil, in: context)

        let summary = live.sessions.map { s in
            "SessionItemEdit: next meso wk\(s.weekIndex) \(isoDay(s.date)) \(s.dayLabel ?? "?") \(s.letter.isEmpty ? "-" : s.letter) "
                + s.items.map { "\($0.exerciseId) \($0.prescription) @ \($0.seed) [\($0.seedSource.label(factor: live.peakFactor))]" }.joined(separator: "; ")
        }
        summary.forEach { print($0) }
        return NextMesoResult(meso: block, sessionsCreated: created.count, sessionsDeleted: live.sessionsToDelete.count, summary: summary)
    }
}
