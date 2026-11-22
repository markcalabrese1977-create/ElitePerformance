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
        /// Prescription change for all remaining sessions: the lifter edited this plan by hand, so it is left as it is.
        case planEdited
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
        let unit = profile?.loadUnit ?? .lb

        var targets: [Target] = []
        for (session, item) in candidates {
            if let reason = safetyRefusal(meso: meso, session: session) {
                refusals.append(Refusal(session: session, reason: reason)); continue
            }
            if session.items.contains(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == to }) {
                refusals.append(Refusal(session: session, reason: .alreadyContainsReplacement)); continue
            }
            // The seed never exceeds the lifter's max for the replacement (no max / fixed-load / bodyweight: unchanged).
            let seed = HistorySeedLoad.load(
                for: to, goalReps: item.targetReps, targetRIR: item.targetRIR, in: allSessions,
                loadIncrement: UserProfile.loadStep(for: to, profile: profile, unit: unit), unit: unit, bodyWeight: profile?.bodyWeight, customExercises: custom, referenceDate: now
            ).map { UserProfile.clampedLoad($0, exerciseId: to, profile: profile, customExercises: custom) }
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
            // A top set (its role, range and RIR) survives a replace; its load restarts at 0 for the new lift.
            let rows = sets + item.topCount
            let seed = target.seedLoad ?? 0
            item.suggestedLoad = seed
            item.plannedLoadsBySet = Array(repeating: seed, count: sets) + Array(repeating: 0.0, count: item.topCount)

            item.actualLoads = Array(repeating: 0.0, count: rows)
            item.actualReps = Array(repeating: 0, count: rows)
            item.actualRIRs = RIREntry.unsetArray(count: rows)
            item.usedRestPauseFlags = Array(repeating: false, count: rows)
            item.restPausePatternsBySet = Array(repeating: "", count: rows)
            item.dropSetPatternsBySet = Array(repeating: "", count: rows)
            item.setFeedbackBySet = Array(repeating: "", count: rows)
            item.pumpRatingsBySet = Array(repeating: 0, count: rows)
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
            let n = max(0, i.targetSets) + i.topCount
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
        let roles: [String]?, topRepMin: Int?, topRepMax: Int?, topRIR: Int?
        let prescribedSets: Int?

        init(_ i: SessionItem) {
            item = i
            prescribedSets = i.prescribedSets
            roles = i.setRolesBySet; topRepMin = i.topRepMin; topRepMax = i.topRepMax; topRIR = i.topRIR
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
            item.setRolesBySet = roles; item.topRepMin = topRepMin; item.topRepMax = topRepMax; item.topRIR = topRIR
            item.prescribedSets = prescribedSets
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
/// A top set: `count` rows (the first one is the heaviest, shown first) of `repMin...repMax` reps at `rir`.
struct TopSetSpec: Hashable {
    var count: Int = 1
    var repMin: Int
    var repMax: Int
    var rir: Int

    static let countBounds = 1...3

    var isValid: Bool {
        Self.countBounds.contains(count) && repMin <= repMax
            && PrescriptionChange.repBounds.contains(repMin) && PrescriptionChange.repBounds.contains(repMax)
            && PrescriptionChange.rirBounds.contains(rir)
    }
}

/// Adds or updates the top set, or removes it. Back-off rows are never touched by it.
enum TopSetChange: Equatable {
    case set(TopSetSpec)
    case remove
}

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
    /// Add / update / remove the top set (nil = leave it as it is).
    var topSet: TopSetChange?

    static let setBounds = 1...6      // the logger shows at most 6 working sets
    static let repBounds = 1...50
    static let rirBounds = 0...5

    init(setDelta: Int? = nil, repRange: ClosedRange<Int>? = nil, rirRange: ClosedRange<Int>? = nil, note: String? = nil,
         topSet: TopSetChange? = nil) {
        self.setDelta = setDelta; self.repRange = repRange; self.rirRange = rirRange; self.note = note
        self.topSet = topSet
    }

    /// At least one part, and every part inside its bounds.
    var isValid: Bool {
        guard setDelta != nil || repRange != nil || rirRange != nil || note != nil || topSet != nil else { return false }
        if case .set(let spec)? = topSet, !spec.isValid { return false }
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
        var sets: Int
        var repMin: Int, repMax: Int
        var rirMin: Int, rirMax: Int
        /// The top set, or nil when the item has none.
        var top: TopSetSpec?

        init(sets: Int, repMin: Int, repMax: Int, rirMin: Int, rirMax: Int, top: TopSetSpec? = nil) {
            self.sets = sets; self.repMin = repMin; self.repMax = repMax; self.rirMin = rirMin; self.rirMax = rirMax
            self.top = top
        }

        init(_ item: SessionItem) {
            sets = item.targetSets
            repMin = item.repMin ?? item.targetReps; repMax = item.repMax ?? item.targetReps
            rirMin = item.targetRIRMin ?? item.targetRIR; rirMax = item.targetRIRMax ?? item.targetRIR
            top = item.hasTopSet
                ? TopSetSpec(count: item.topCount, repMin: item.topRepMin ?? repMin, repMax: item.topRepMax ?? repMax,
                             rir: item.topRIR ?? item.targetRIR)
                : nil
        }

        func applying(_ change: PrescriptionChange) -> PrescriptionValues {
            var next = self
            if let d = change.setDelta {
                let bounds = PrescriptionChange.setBounds
                next.sets = min(max(sets + d, bounds.lowerBound), bounds.upperBound)
            }
            if let r = change.repRange {
                next.repMin = r.lowerBound; next.repMax = r.upperBound
            }
            if let r = change.rirRange {
                next.rirMin = r.lowerBound; next.rirMax = r.upperBound
            }
            switch change.topSet {
            case .set(let spec)?: next.top = spec
            case .remove?: next.top = nil
            case nil: break
            }
            return next
        }

        /// "4 x 8-12 @ RIR 2-3"; with a top set "1 x 4-6 @ 2 top + 3 x 6-8 @ 2".
        var text: String {
            func r(_ a: Int, _ b: Int) -> String { a == b ? "\(a)" : "\(a)-\(b)" }
            if let top {
                return "\(top.count) x \(r(top.repMin, top.repMax)) @ \(top.rir) top + \(sets) x \(r(repMin, repMax)) @ \(r(rirMin, rirMax))"
            }
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
        /// Sessions skipped because the lifter edited their plan by hand.
        var editedSkipped: Int { refusals.filter { $0.reason == .planEdited }.count }
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
            // A hand-edited plan is the lifter's: "all remaining" leaves it and says so (this-session is an explicit edit).
            if case .allRemaining = scope, item.planEdited {
                refusals.append(Refusal(session: session, reason: .planEdited)); continue
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

    /// The number of sessions a prescription change in this scope would reach, independent of any particular change:
    /// same selection, letter filter, deload rule, hand-edit refusal and safety refusal as `planChangePrescription`.
    static func sessionsInScope(
        meso: MesoBlock, dayLabel: String?, exerciseId: String, letters: Set<String>? = nil,
        includeDeload: Bool = false, scope: ReplaceScope = .allRemaining, now: Date = Date()
    ) -> Int {
        let exercise = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let normalizedLetters = letters.map { Set($0.map { $0.lowercased() }) }
        let selected = selectCandidates(
            meso: meso, dayLabel: dayLabel, exercise: exercise, scope: scope,
            startOfToday: Calendar.current.startOfDay(for: now)
        )
        var count = 0
        for (session, item) in selected.candidates {
            let key = letterKey(item)
            if let normalizedLetters, !normalizedLetters.contains(key) { continue }
            if key == "deload", !includeDeload, !meso.isMaintenance { continue }
            if case .allRemaining = scope, item.planEdited { continue }
            if safetyRefusal(meso: meso, session: session) != nil { continue }
            count += 1
        }
        return count
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

        // One seed per apply: the top load at the top reps/RIR, from completed history (back-offs excluded).
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        var seedCache: [TopSetSpec: Double] = [:]
        func topSeed(_ spec: TopSetSpec) -> Double {
            if let hit = seedCache[spec] { return hit }
            let v = UserProfile.clampedLoad(HistorySeedLoad.load(
                for: plan.exerciseId, goalReps: spec.repMin, targetRIR: spec.rir, in: allSessions,
                loadIncrement: profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: profile?.loadUnit ?? .lb), unit: profile?.loadUnit ?? .lb, bodyWeight: profile?.bodyWeight,
                customExercises: custom, referenceDate: plan.now, role: .top
            ) ?? 0, exerciseId: plan.exerciseId, profile: profile, customExercises: custom)
            seedCache[spec] = v
            return v
        }

        var summary: [String] = []
        let change = plan.change
        for target in live.targets {
            let item = target.item
            let sets = target.after.sets
            let fingerprint = item.writeFingerprint()
            defer { item.stampIfChanged(since: fingerprint) }

            if !item.hasTopSet && target.after.top == nil {
                applyBackOffsOnly(item, sets: sets, change: change)
            } else {
                applyWithTop(item, target: target, change: change)
            }

            if let note = change.note { NoteFields.applying(note, to: item).write(to: item) }

            // A newly added top set starts from what history says the lifter can do at the top reps/RIR.
            if target.before.top == nil, let spec = target.after.top, topSeed(spec) > 0 {
                for idx in item.topRowIndices where idx < item.plannedLoadsBySet.count && item.plannedLoadsBySet[idx] == 0 {
                    item.plannedLoadsBySet[idx] = topSeed(spec)
                }
            }

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

    /// The back-off-only write (an item with no top set before or after): exactly what changePrescription always did.
    private static func applyBackOffsOnly(_ item: SessionItem, sets: Int, change: PrescriptionChange) {
        // The planned arrays keep empty padding slots past the planned sets; a grown count repeats the last PLANNED set (loads, reps, RIR).
        let oldSets = item.targetSets
        func planned<T>(_ a: [T]) -> [T] { oldSets > 0 && a.count > oldSets ? Array(a.prefix(oldSets)) : a }
        if change.setDelta != nil {
            item.setPrescribedSets(sets)
            // The wave's set band widens to include the new count and never narrows.
            if let lo = item.setMin { item.setMin = min(lo, sets) }
            if let hi = item.setMax { item.setMax = max(hi, sets) }
            // Grow = repeat the last set's load, shrink = first N, empty = zeros (as carry-forward does).
            item.plannedLoadsBySet = resized(planned(item.plannedLoadsBySet), to: sets, fallback: 0)
        }
        if let reps = change.repRange {
            item.repMin = reps.lowerBound; item.repMax = reps.upperBound
            item.targetReps = reps.lowerBound
            item.plannedRepsBySet = Array(repeating: item.targetReps, count: sets)
        } else if change.setDelta != nil {
            item.plannedRepsBySet = resized(planned(item.plannedRepsBySet), to: sets, fallback: item.targetReps)
        }
        if let rir = change.rirRange {
            item.targetRIRMin = rir.lowerBound; item.targetRIRMax = rir.upperBound
            item.targetRIR = rir.upperBound
            item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: sets)
        } else if change.setDelta != nil {
            item.plannedRIRsBySet = resized(planned(item.plannedRIRsBySet), to: sets, fallback: item.targetRIR)
        }
    }

    /// The write for an item that has, gains or loses a top set. The back-off segment is the first
    /// `targetSets` non-top rows and is resized exactly as above; the top rows ride at the tail
    /// (`targetSets ..< targetSets + count`) with the roles and the spec in step. Arrays are sized
    /// `sets + topCount`. A top load that already exists is kept (resized); a new top starts at 0 and is
    /// seeded by `seedNewTopLoads`.
    private static func applyWithTop(_ item: SessionItem, target: PrescriptionTarget, change: PrescriptionChange) {
        let oldBackOffs = item.targetSets
        let sets = target.after.sets
        func backOffSegment<T>(_ a: [T]) -> [T] { Array(item.backOffValues(a).prefix(oldBackOffs)) }
        var loads = backOffSegment(item.plannedLoadsBySet)
        var reps = backOffSegment(item.plannedRepsBySet)
        var rirs = backOffSegment(item.plannedRIRsBySet)
        let oldTopLoads = item.topValues(item.plannedLoadsBySet, fallback: 0.0)
        let oldTopReps = item.topValues(item.plannedRepsBySet, fallback: item.topRepMin ?? item.targetReps)
        let oldTopRIRs = item.topValues(item.plannedRIRsBySet, fallback: item.topRIR ?? item.targetRIR)

        if change.setDelta != nil {
            item.setPrescribedSets(sets)
            if let lo = item.setMin { item.setMin = min(lo, sets) }
            if let hi = item.setMax { item.setMax = max(hi, sets) }
            loads = resized(loads, to: sets, fallback: 0)
        }
        if let r = change.repRange {
            item.repMin = r.lowerBound; item.repMax = r.upperBound
            item.targetReps = r.lowerBound
            reps = Array(repeating: item.targetReps, count: sets)
        } else if change.setDelta != nil {
            reps = resized(reps, to: sets, fallback: item.targetReps)
        }
        if let r = change.rirRange {
            item.targetRIRMin = r.lowerBound; item.targetRIRMax = r.upperBound
            item.targetRIR = r.upperBound
            rirs = Array(repeating: item.targetRIR, count: sets)
        } else if change.setDelta != nil {
            rirs = resized(rirs, to: sets, fallback: item.targetRIR)
        }

        guard let spec = target.after.top else {
            // Removed: the top rows, roles and spec go; the back-offs are as above.
            item.plannedLoadsBySet = loads; item.plannedRepsBySet = reps; item.plannedRIRsBySet = rirs
            item.setRolesBySet = nil
            item.topRepMin = nil; item.topRepMax = nil; item.topRIR = nil
            return
        }
        let specChanged = target.before.top != target.after.top
        let n = spec.count
        let topLoads = resized(oldTopLoads, to: n, fallback: 0)
        let topReps = specChanged ? Array(repeating: spec.repMin, count: n) : resized(oldTopReps, to: n, fallback: spec.repMin)
        let topRIRs = specChanged ? Array(repeating: spec.rir, count: n) : resized(oldTopRIRs, to: n, fallback: spec.rir)
        item.plannedLoadsBySet = loads + topLoads
        item.plannedRepsBySet = reps + topReps
        item.plannedRIRsBySet = rirs + topRIRs
        item.setRolesBySet = SessionItem.roles(backOffs: sets, tops: n)
        item.topRepMin = spec.repMin; item.topRepMax = spec.repMax; item.topRIR = spec.rir
    }

    /// Grow by repeating the last element (`fallback` when empty); shrink to the first `count`.
    static func resized<T>(_ array: [T], to count: Int, fallback: T) -> [T] {
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
        if b.roles == nil && target.after.top == nil {
            // Only the PLANNED rows survive unchanged: a padding slot past the old set count is where a grown set lands (it copies the row before).
            let kept = min(b.plannedLoads.count, i.plannedLoadsBySet.count, target.after.sets != target.before.sets ? target.before.sets : Int.max)
            check("plannedLoads prefix", Array(b.plannedLoads.prefix(kept)), Array(i.plannedLoadsBySet.prefix(kept)))
            if target.after.sets != target.before.sets {
                check("plannedLoads count", target.after.sets, i.plannedLoadsBySet.count)
            } else {
                check("plannedLoads", b.plannedLoads, i.plannedLoadsBySet)
            }
        } else {
            // With a top set: back-off loads keep their surviving prefix, the array is back-offs + top rows,
            // the roles say exactly that, and an existing top load is kept when the top set itself is unchanged.
            let wantTops = target.after.top?.count ?? 0
            check("plannedLoads count", target.after.sets + wantTops, i.plannedLoadsBySet.count)
            check("roles", wantTops == 0 ? nil : SessionItem.roles(backOffs: target.after.sets, tops: wantTops), i.setRolesBySet)
            let oldBack = Array(b.plannedLoads.enumerated().filter { !(b.roles?.indices.contains($0.offset) == true && b.roles?[$0.offset] == SessionItem.topRole) }
                .map(\.element).prefix(b.targetSets))
            let keptBack = min(oldBack.count, target.after.sets)
            check("back-off loads prefix", Array(oldBack.prefix(keptBack)), Array(i.plannedLoadsBySet.prefix(keptBack)))
            if let spec = target.after.top {
                check("top spec", [spec.repMin, spec.repMax, spec.rir], [i.topRepMin ?? -1, i.topRepMax ?? -1, i.topRIR ?? -1])
                if target.before.top == target.after.top {
                    let oldTop = b.plannedLoads.enumerated().filter { b.roles?.indices.contains($0.offset) == true && b.roles?[$0.offset] == SessionItem.topRole }.map(\.element)
                    check("top loads kept", oldTop, Array(i.plannedLoadsBySet.suffix(oldTop.count)))
                }
            } else {
                check("top spec cleared", [Int?.none, .none, .none], [i.topRepMin, i.topRepMax, i.topRIR])
            }
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

    /// Deload prescription: half the sets (at least one), the same rep range, 3-4 RIR (the target is RIR 4; see `DeloadRule`).
    static let deloadRIRRange = 3...DeloadRule.rir
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
        /// Which side of the min the load landed on, and the numbers behind it (`DeloadRule.sizing`).
        let sizing: DeloadRule.Sizing
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
        let unit = profile?.loadUnit ?? .lb
        let sources = (byWeek[week] ?? []).sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        let deloadSessions: [DeloadSessionPlan] = sources.map { s in
            let items: [DeloadItemPlan] = s.items.sorted { $0.order < $1.order }.map { i in
                let repMin = i.repMin ?? i.targetReps
                let repMax = i.repMax ?? i.targetReps
                let sizing = DeloadRule.sizing(exerciseId: i.exerciseId, repMin: repMin, in: allSessions, profile: profile,
                                               unit: unit, customExercises: custom, referenceDate: now)
                // A deload is straight sets: the top set is dropped (the new items carry no roles) and the
                // sets and the load come from the back-offs only.
                return DeloadItemPlan(source: i, order: i.order, exerciseId: i.exerciseId,
                                      sets: DeloadRule.sets(forPlanned: i.targetSets), repMin: repMin, repMax: repMax,
                                      load: sizing.load, sizing: sizing)
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
            if let load = item.backOffValues(item.actualLoads).last(where: { $0 > 0 }) { return load }
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
            let session: Session; let date: Date; let plannedDate: Date?; let week: Int?; let programIndex: Int?
            init(_ s: Session) { session = s; date = s.date; plannedDate = s.plannedDate; week = s.weekInMeso; programIndex = s.programIndex }
        }
        let otherSessions = meso.sessions.filter { s in !live.shifted.contains { $0.session === s } }
        let restores = (otherSessions + live.shifted.map(\.session)).map(SessionRestore.init)
        let totalWeeksBefore = meso.totalWeeks
        let mesoSessionsBefore = meso.sessions
        var created: [Session] = []
        func abandon() {
            for r in restores { r.session.date = r.date; r.session.plannedDate = r.plannedDate; r.session.weekInMeso = r.week; r.session.programIndex = r.programIndex }
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
                    actualRIRs: RIREntry.unsetArray(count: n),
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
            if move.session.plannedDate != nil { move.session.plannedDate = move.newDate }   // unknown stays unknown
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
        let shiftedByID = Dictionary(shifted.map { ($0.session.persistentModelID, $0.newDate) }, uniquingKeysWith: { first, _ in first })
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
            let session: Session; let date: Date; let plannedDate: Date?; let week: Int?; let programIndex: Int?
            init(_ s: Session) { session = s; date = s.date; plannedDate = s.plannedDate; week = s.weekInMeso; programIndex = s.programIndex }
        }
        let untouched = meso.sessions.filter { s in
            !removedIDs.contains(s.persistentModelID) && !live.shifted.contains { $0.session === s }
        }
        let restores = (untouched + live.shifted.map(\.session)).map(SessionRestore.init)
        let totalWeeksBefore = meso.totalWeeks
        let mesoSessionsBefore = meso.sessions
        func abandon() {
            for r in restores { r.session.date = r.date; r.session.plannedDate = r.plannedDate; r.session.weekInMeso = r.week; r.session.programIndex = r.programIndex }
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
            if move.session.plannedDate != nil { move.session.plannedDate = move.newDate }   // unknown stays unknown
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
            let session: Session; let date: Date; let plannedDate: Date?; let week: Int?; let programIndex: Int?
            init(_ s: Session) { session = s; date = s.date; plannedDate = s.plannedDate; week = s.weekInMeso; programIndex = s.programIndex }
        }
        let restores = live.moves.map { DateRestore($0.session) }
        func abandon() {
            for r in restores { r.session.date = r.date; r.session.plannedDate = r.plannedDate; r.session.weekInMeso = r.week; r.session.programIndex = r.programIndex }
            context.rollback()
        }

        for move in live.moves {
            move.session.date = move.newDate
            if move.session.plannedDate != nil { move.session.plannedDate = move.newDate }   // unknown stays unknown
        }

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

// MARK: - Lower remaining planned loads to a max

/// A max load was set or lowered: every remaining planned, safe item of that exercise in the active meso whose
/// suggested or per-set load (back-off and top slots) is above it is set to the max. Same shape as the other edits:
/// a pure `planClampToMax` for the preview, then `applyClampToMax`, which re-plans against live state, writes,
/// verifies, and saves once (or restores every field and throws).
///
/// A hand-edited plan (`planEdited`) IS included: the lifter's own number above their own max is still above it. It
/// is marked "(edited by you)" in the preview, and `planEdited` stays exactly as it was. Never touched: completed or
/// in-progress sessions, a planned session with anything logged, fixed-load and bodyweight exercises (a max does not
/// apply to them), and any load already at or below the max.
extension SessionItemEditService {

    struct MaxLoadTarget {
        let session: Session
        let item: SessionItem
        let date: Date
        let weekIndex: Int
        let waveRaw: String?
        let beforeSuggested: Double
        let beforeLoads: [Double]
        /// Row indices (into the per-set arrays) that are above the max.
        let slotsAbove: [Int]
        let suggestedAbove: Bool
        let hasTop: Bool
        /// The lifter hand-edited this plan (`planEdited`); its loads are lowered all the same.
        let edited: Bool

        /// "suggested 320 -> 315, top 335 -> 315" style detail for the preview list.
        func detail(max: Double, unit: LoadUnit = .lb) -> String {
            func n(_ v: Double) -> String { LoadFormatter(unit: unit).compact(v) }
            var parts: [String] = []
            if suggestedAbove { parts.append("load \(n(beforeSuggested)) -> \(n(max))") }
            let topRows = Set(item.topRowIndices)
            let top = slotsAbove.filter { topRows.contains($0) }
            let backOffs = slotsAbove.filter { !topRows.contains($0) }
            if !backOffs.isEmpty && !suggestedAbove {
                parts.append("sets \(backOffs.map { n(beforeLoads[$0]) }.joined(separator: ", ")) -> \(n(max))")
            }
            if let t = top.first { parts.append("top \(n(beforeLoads[t])) -> \(n(max))") }
            if edited { parts.append("(edited by you)") }
            return parts.joined(separator: ", ")
        }
    }

    struct MaxLoadPlan {
        let meso: MesoBlock?
        let exerciseId: String          // canonical
        let max: Double
        let now: Date
        let targets: [MaxLoadTarget]

        var isApplicable: Bool { !targets.isEmpty }
    }

    /// The active (non-maintenance first) block, or nil when none is active.
    static func activeMeso(in context: ModelContext) -> MesoBlock? {
        let blocks = ((try? context.fetch(FetchDescriptor<MesoBlock>())) ?? []).filter { $0.status == .active }
        return blocks.first { !$0.isMaintenance } ?? blocks.first
    }

    /// Plan (no writes). `meso` nil means no active block: nothing to do.
    static func planClampToMax(
        meso: MesoBlock?,
        exerciseId: String,
        max: Double,
        now: Date = Date()
    ) -> MaxLoadPlan {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        func empty() -> MaxLoadPlan { MaxLoadPlan(meso: meso, exerciseId: canonical, max: max, now: now, targets: []) }
        guard let meso, meso.status == .active, max > 0 else { return empty() }
        let startOfToday = Calendar.current.startOfDay(for: now)
        var targets: [MaxLoadTarget] = []
        for session in meso.sessions.sorted(by: { $0.date < $1.date }) {
            guard session.status == .planned, session.date >= startOfToday,
                  SessionEditSafety.isSafeToModify(session) else { continue }
            for item in session.items where ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonical {
                let slots = item.plannedLoadsBySet.indices.filter { item.plannedLoadsBySet[$0] > max }
                let suggestedAbove = item.suggestedLoad > max
                guard !slots.isEmpty || suggestedAbove else { continue }
                targets.append(MaxLoadTarget(
                    session: session, item: item, date: session.date, weekIndex: session.weekIndex, waveRaw: item.waveRaw,
                    beforeSuggested: item.suggestedLoad, beforeLoads: item.plannedLoadsBySet,
                    slotsAbove: slots, suggestedAbove: suggestedAbove, hasTop: item.hasTopSet,
                    edited: item.planEdited
                ))
            }
        }
        return MaxLoadPlan(meso: meso, exerciseId: canonical, max: max, now: now, targets: targets)
    }

    /// "3 planned sessions above 315 will be set to 315"
    static func clampPreviewText(count: Int, max: Double, unit: LoadUnit = .lb) -> String {
        let n = LoadFormatter(unit: unit).compact(max)
        return "\(count) planned session\(count == 1 ? "" : "s") above \(n) will be set to \(n)"
    }

    @discardableResult
    static func applyClampToMax(_ plan: MaxLoadPlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> ApplyResult {
        guard plan.isApplicable else { throw ReplaceError.nothingToReplace }

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        // The plan is a preview; trust only live state.
        let live = planClampToMax(meso: plan.meso, exerciseId: plan.exerciseId, max: plan.max, now: plan.now)
        let plannedIDs = plan.targets.map { $0.item.persistentModelID }
        let liveIDs = live.targets.map { $0.item.persistentModelID }
        guard plannedIDs == liveIDs else {
            throw ReplaceError.planStale(planned: plannedIDs.count, live: liveIDs.count)
        }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let restorePoints = live.targets.map { ItemRestorePoint($0.item) }
        func abandon() {
            for point in restorePoints { point.restore() }
            context.rollback()
        }

        var summary: [String] = []
        for target in live.targets {
            let item = target.item
            if item.suggestedLoad > plan.max { item.suggestedLoad = plan.max }
            item.plannedLoadsBySet = item.plannedLoadsBySet.map { Swift.min($0, plan.max) }
            // planEdited is left alone (verified below): lowering to the max neither sets nor clears it.
            let line = "SessionItemEdit: \(isoDay(target.date)) \(target.session.dayLabel ?? "?") wk\(target.weekIndex) "
                + "wave=\(target.waveRaw ?? "-") \(plan.exerciseId) \(target.detail(max: plan.max, unit: (try? context.fetch(FetchDescriptor<UserProfile>()).first)?.loadUnit ?? .lb))"
            summary.append(line)
            print(line)
        }

        var problems: [String] = []
        for (target, point) in zip(live.targets, restorePoints) {
            let i = target.item
            func check<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
                if expected != actual { problems.append("\(i.exerciseId) wk\(target.weekIndex): \(name): expected \(expected), found \(actual)") }
            }
            check("suggestedLoad", Swift.min(point.suggestedLoad, plan.max), i.suggestedLoad)
            check("plannedLoads", point.plannedLoads.map { Swift.min($0, plan.max) }, i.plannedLoadsBySet)
            if i.suggestedLoad > plan.max || i.plannedLoadsBySet.contains(where: { $0 > plan.max }) {
                problems.append("\(i.exerciseId) wk\(target.weekIndex): a load is still above the max")
            }
            // Nothing else about the item moved.
            check("planEdited", point.planEdited, i.planEdited)
            check("actualLoads", point.actualLoads, i.actualLoads); check("actualReps", point.actualReps, i.actualReps)
            check("actualRIRs", point.actualRIRs, i.actualRIRs); check("isCompleted", point.isCompleted, i.isCompleted)
            check("targetSets", point.targetSets, i.targetSets); check("prescribedSets", point.prescribedSets, i.prescribedSets)
            check("plannedReps", point.plannedReps, i.plannedRepsBySet); check("plannedRIRs", point.plannedRIRs, i.plannedRIRsBySet)
            check("roles", point.roles, i.setRolesBySet); check("exerciseId", point.exerciseId, i.exerciseId)
            check("session status", SessionStatus.planned, target.session.status)
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
}

// MARK: - Round planned loads to the lifter's unit steps (after a unit switch)

extension SessionItemEditService {

    struct RoundTarget {
        let session: Session
        let item: SessionItem
        let date: Date
        let weekIndex: Int
        let waveRaw: String?
        let beforeSuggested: Double
        let beforeLoads: [Double]
        let afterSuggested: Double
        let afterLoads: [Double]
        /// Loads (suggested + per-set) whose value moves.
        let changedLoads: Int
    }

    struct RoundPlan {
        let meso: MesoBlock?
        let unit: LoadUnit
        /// In `unit`.
        let increment: Double
        let now: Date
        let targets: [RoundTarget]

        var isApplicable: Bool { !targets.isEmpty }
        /// Distinct loads that move (the "N" of "Round N planned loads").
        var loadCount: Int { targets.reduce(0) { $0 + $1.changedLoads } }
        /// Upcoming sessions that hold at least one of them (the "M" of "across M upcoming sessions").
        var sessionCount: Int { Set(targets.map { $0.session.persistentModelID }).count }
    }

    /// "Round 18 planned loads to kg steps — across 6 upcoming sessions." (the confirm title).
    static func roundPreviewTitle(_ plan: RoundPlan) -> String {
        "Round \(plan.loadCount) planned load\(plan.loadCount == 1 ? "" : "s") to \(plan.unit.label) steps"
            + " — across \(plan.sessionCount) upcoming session\(plan.sessionCount == 1 ? "" : "s")."
    }

    /// "To the nearest 1.25 kg. Completed and started sessions are not touched."
    static func roundPreviewDetail(_ plan: RoundPlan) -> String {
        "To the nearest \(LoadFormatter(unit: plan.unit).textInUnit(plan.increment)). Completed and started sessions are not touched."
    }

    /// The round offer to show now, or nil. It is open from a unit switch until answered: Round (which leaves nothing
    /// off-step) or Keep as is (`dismissRoundOffer`). An offer with nothing left to round closes itself. A lifter who
    /// never switched has no open offer, so loads that are simply typed off-step never prompt.
    static func pendingRoundOffer(profile: UserProfile, in context: ModelContext, now: Date = Date()) -> RoundPlan? {
        guard profile.roundOfferPending == true else { return nil }
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let plan = planRoundToUnit(meso: activeMeso(in: context), unit: profile.loadUnit,
                                   increment: profile.minLoadIncrement, profile: profile, customExercises: custom, now: now)
        if plan.isApplicable { return plan }
        profile.roundOfferPending = nil
        try? context.save()
        return nil
    }

    /// "Keep as is": the offer stays closed until the next unit switch.
    static func dismissRoundOffer(profile: UserProfile, in context: ModelContext) {
        profile.roundOfferPending = nil
        try? context.save()
    }

    /// The load after rounding: nearest `increment` in `unit`, never above the exercise's max load. Zero (bodyweight,
    /// unset) stays zero.
    private static func roundedForUnit(_ load: Double, item: SessionItem, plan unit: LoadUnit, increment: Double,
                                       profile: UserProfile?, custom: [CustomExercise]) -> Double {
        guard load > 0 else { return load }
        let rounded = UnitAwareRounding.round(load, increment: increment, unit: unit, mode: .nearest)
        return UserProfile.clampedLoad(rounded, exerciseId: item.exerciseId, profile: profile, customExercises: custom)
    }

    /// Plan (no writes): the active block's planned, untouched sessions dated today or later. Fixed-load lifts keep the
    /// load the lifter set. `meso` nil: nothing to do.
    static func planRoundToUnit(
        meso: MesoBlock?, unit: LoadUnit, increment: Double, profile: UserProfile?,
        customExercises: [CustomExercise] = [], now: Date = Date()
    ) -> RoundPlan {
        func empty() -> RoundPlan { RoundPlan(meso: meso, unit: unit, increment: increment, now: now, targets: []) }
        guard let meso, meso.status == .active, increment > 0 else { return empty() }
        let startOfToday = Calendar.current.startOfDay(for: now)
        var targets: [RoundTarget] = []
        for session in meso.sessions.sorted(by: { $0.date < $1.date }) {
            guard session.status == .planned, session.date >= startOfToday,
                  SessionEditSafety.isSafeToModify(session) else { continue }
            for item in session.items {
                if UserProfile.isProgressionExempt(exerciseId: item.exerciseId, profile: profile) { continue }
                if ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customExercises) { continue }
                func r(_ v: Double) -> Double {
                    roundedForUnit(v, item: item, plan: unit, increment: increment, profile: profile, custom: customExercises)
                }
                let afterSuggested = r(item.suggestedLoad)
                let afterLoads = item.plannedLoadsBySet.map(r)
                var changed = 0
                if abs(afterSuggested - item.suggestedLoad) > 1e-9 { changed += 1 }
                for (a, b) in zip(afterLoads, item.plannedLoadsBySet) where abs(a - b) > 1e-9 { changed += 1 }
                guard changed > 0 else { continue }
                targets.append(RoundTarget(
                    session: session, item: item, date: session.date, weekIndex: session.weekIndex, waveRaw: item.waveRaw,
                    beforeSuggested: item.suggestedLoad, beforeLoads: item.plannedLoadsBySet,
                    afterSuggested: afterSuggested, afterLoads: afterLoads, changedLoads: changed
                ))
            }
        }
        return RoundPlan(meso: meso, unit: unit, increment: increment, now: now, targets: targets)
    }

    /// Applies the plan to live state only; verifies each item (loads are the rounded ones, planEdited and everything
    /// else untouched) and restores everything on any problem.
    @discardableResult
    static func applyRoundToUnit(
        _ plan: RoundPlan, profile: UserProfile?, customExercises: [CustomExercise] = [],
        in context: ModelContext, hooks: ApplyHooks = ApplyHooks()
    ) throws -> ApplyResult {
        guard plan.isApplicable else { throw ReplaceError.nothingToReplace }

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let live = planRoundToUnit(meso: plan.meso, unit: plan.unit, increment: plan.increment, profile: profile,
                                   customExercises: customExercises, now: plan.now)
        let plannedIDs = plan.targets.map { $0.item.persistentModelID }
        let liveIDs = live.targets.map { $0.item.persistentModelID }
        guard plannedIDs == liveIDs else {
            throw ReplaceError.planStale(planned: plannedIDs.count, live: liveIDs.count)
        }

        if context.hasChanges { try context.save() }

        let restorePoints = live.targets.map { ItemRestorePoint($0.item) }
        func abandon() {
            for point in restorePoints { point.restore() }
            context.rollback()
        }

        var summary: [String] = []
        for target in live.targets {
            target.item.suggestedLoad = target.afterSuggested
            target.item.plannedLoadsBySet = target.afterLoads
            // planEdited is left alone (verified below): re-rounding to the unit's steps neither sets nor clears it.
            let line = "SessionItemEdit: round \(isoDay(target.date)) \(target.session.dayLabel ?? "?") wk\(target.weekIndex) "
                + "\(target.item.exerciseId) \(target.changedLoads) load(s) to \(plan.unit.label) steps"
            summary.append(line)
            print(line)
        }

        var problems: [String] = []
        for (target, point) in zip(live.targets, restorePoints) {
            let i = target.item
            func check<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
                if expected != actual { problems.append("\(i.exerciseId) wk\(target.weekIndex): \(name): expected \(expected), found \(actual)") }
            }
            check("suggestedLoad", target.afterSuggested, i.suggestedLoad)
            check("plannedLoads", target.afterLoads, i.plannedLoadsBySet)
            check("planEdited", point.planEdited, i.planEdited)
            check("actualLoads", point.actualLoads, i.actualLoads); check("actualReps", point.actualReps, i.actualReps)
            check("actualRIRs", point.actualRIRs, i.actualRIRs); check("isCompleted", point.isCompleted, i.isCompleted)
            check("targetSets", point.targetSets, i.targetSets); check("prescribedSets", point.prescribedSets, i.prescribedSets)
            check("plannedReps", point.plannedReps, i.plannedRepsBySet); check("plannedRIRs", point.plannedRIRs, i.plannedRIRsBySet)
            check("roles", point.roles, i.setRolesBySet); check("exerciseId", point.exerciseId, i.exerciseId)
            check("session status", SessionStatus.planned, target.session.status)
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
}

// MARK: - Undo for a multi-session prescription change

extension SessionItemEditService {

    /// Exactly the fields `applyChange` can write, as they were on exactly the items it changes, captured BEFORE the
    /// apply. Undo puts these back; it is not a backup restore, so logged data, loads the lifter has typed since and
    /// every other item are never touched.
    struct PrescriptionUndo {
        struct Point {
            let item: SessionItem
            let session: Session
            let targetSets: Int, targetReps: Int, targetRIR: Int
            let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?
            let plannedLoads: [Double], plannedReps: [Int], plannedRIRs: [Int]
            let roles: [String]?, topRepMin: Int?, topRepMax: Int?, topRIR: Int?
            let prescribedSets: Int?
            let notes: NoteFields

            init(_ target: PrescriptionTarget) {
                let i = target.item
                item = i; session = target.session
                targetSets = i.targetSets; targetReps = i.targetReps; targetRIR = i.targetRIR
                setMin = i.setMin; setMax = i.setMax; repMin = i.repMin; repMax = i.repMax
                rirMin = i.targetRIRMin; rirMax = i.targetRIRMax
                plannedLoads = i.plannedLoadsBySet; plannedReps = i.plannedRepsBySet; plannedRIRs = i.plannedRIRsBySet
                roles = i.setRolesBySet; topRepMin = i.topRepMin; topRepMax = i.topRepMax; topRIR = i.topRIR
                prescribedSets = i.prescribedSets
                notes = NoteFields(i)
            }

            func restore() {
                item.targetSets = targetSets; item.targetReps = targetReps; item.targetRIR = targetRIR
                item.setMin = setMin; item.setMax = setMax; item.repMin = repMin; item.repMax = repMax
                item.targetRIRMin = rirMin; item.targetRIRMax = rirMax
                item.plannedLoadsBySet = plannedLoads; item.plannedRepsBySet = plannedReps; item.plannedRIRsBySet = plannedRIRs
                item.setRolesBySet = roles; item.topRepMin = topRepMin; item.topRepMax = topRepMax; item.topRIR = topRIR
                item.prescribedSets = prescribedSets
                notes.write(to: item)
            }
        }

        let points: [Point]
        var sessionCount: Int { points.count }
    }

    /// Call before `applyChange(plan)`.
    static func capturePrescriptionUndo(for plan: ChangePlan) -> PrescriptionUndo {
        PrescriptionUndo(points: plan.targets.map(PrescriptionUndo.Point.init))
    }

    /// Puts the captured fields back on the captured items and saves. An item that is gone, or whose session is no
    /// longer planned (started or logged since), is left alone. Returns how many sessions were restored.
    @discardableResult
    static func undoPrescriptionChange(_ undo: PrescriptionUndo, in context: ModelContext) throws -> Int {
        let usable = undo.points.filter { $0.item.modelContext != nil && !$0.item.isDeleted && $0.session.status == .planned }
        for point in usable { point.restore() }
        do { try context.save() } catch {
            context.rollback()
            throw ReplaceError.saveFailed("\(error)")
        }
        return usable.count
    }
}
