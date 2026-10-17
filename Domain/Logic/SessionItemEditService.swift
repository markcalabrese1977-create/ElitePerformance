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
        var candidates: [(session: Session, item: SessionItem)] = []
        var refusals: [Refusal] = []

        func fromItem(in s: Session) -> SessionItem? {
            s.items.sorted { $0.order < $1.order }
                .first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == from }
        }

        switch scope {
        case .thisSession(let session):
            if let item = fromItem(in: session),
               session.meso?.persistentModelID == meso.persistentModelID,
               SessionDayLabelMatcher.matches(session.dayLabel, dayLabel) {
                candidates = [(session, item)]
            } else {
                refusals.append(Refusal(session: session, reason: .notApplicable))
            }
        case .allRemaining:
            for s in meso.sessions.sorted(by: { $0.date < $1.date })
            where SessionDayLabelMatcher.matches(s.dayLabel, dayLabel) {
                guard let item = fromItem(in: s) else { continue }
                // History is not "remaining": completed sessions, and planned ones from before today
                // with nothing logged (missed), are simply left alone. Today's session is remaining
                // whatever time of day it is dated.
                if s.status == .completed { continue }
                if s.status == .planned && s.date < startOfToday && !SessionEditSafety.hasLoggedData(s) { continue }
                candidates.append((s, item))
            }
        }

        if from == to {
            return plan([], candidates.map { Refusal(session: $0.session, reason: .sameExercise) } + refusals)
        }

        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let increment = profile?.minLoadIncrement ?? 2.5

        var targets: [Target] = []
        for (session, item) in candidates {
            if meso.status != .active {
                refusals.append(Refusal(session: session, reason: .inactiveMeso)); continue
            }
            if !SessionEditSafety.isSafeToModify(session) {
                refusals.append(Refusal(session: session, reason: .unsafe)); continue
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

        init(_ i: SessionItem) {
            item = i
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
