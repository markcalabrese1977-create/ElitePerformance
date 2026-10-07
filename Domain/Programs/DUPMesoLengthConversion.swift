// Domain/Programs/DUPMesoLengthConversion.swift
import Foundation
import SwiftData

/// Converts an ACTIVE wave-based 10-week block (A B C A B C A B C deload) into a 12-week block
/// with four full A/B/C rotations and no scheduled deload (A B C A B C A B C A B C).
///
/// - Week 10 is converted IN PLACE: its deload items take the prescription of the matching
///   week-7 (wave A) item, same dayLabel.
/// - Weeks 11 and 12 are CREATED by cloning weeks 8 (wave B) and 9 (wave C), session for
///   session, +21 days (same weekday, so the Thursday rest day stays empty).
/// - `block.totalWeeks` becomes 12 and a "10-Week" name becomes "12-Week".
///
/// The per-letter carry-forward chains then run 1→4→7→10, 2→5→8→11, 3→6→9→12
/// (`PlanMemoryEngine.nextTargetItem`: same meso, same dayLabel, same wave).
///
/// Safety model (mirrors Week6UpperBCleanupMigration): nothing is written unless every
/// precondition holds, checked live. `dryRun` runs the identical planner and writes nothing;
/// `apply` refuses on any blocker and saves once at the end. A re-run on an already converted
/// block is a no-op.
///
/// Loads are COPIED from the source week's matching item (week 7 -> 10, 8 -> 11, 9 -> 12):
/// suggestedLoad and plannedLoadsBySet (resized to targetSets), plus the planned reps/RIR arrays.
/// Bodyweight items (catalog or custom) stay at 0, as they do everywhere else in the app.
///
/// Why a copy and not an empty target (the alternative considered): carry-forward writes into an
/// EMPTY target through its seed path (hold/bump/reduce applied to the carried load), but into a
/// NON-empty target only through the propagate path, which writes only when the recommended load
/// is higher than what is already there. A copied load therefore means a "reduce" outcome from
/// week 7 will not lower week 10 below the copied value. The copy is the requested behavior; this
/// is the tradeoff it carries.
///
/// NOT wired to any UI or launch hook. It must be invoked deliberately (see the dry-run report
/// first), and before the first week-7 session completes, or week 7's result will not reach
/// week 10 (carry-forward looks the target up when the source session is saved).
enum DUPMesoLengthConversion {

    static let sourceTotalWeeks = 10
    static let targetTotalWeeks = 12
    /// Week that is converted in place, and the weeks cloned to create 11 and 12.
    private static let convertedWeek = 10
    private static let cloneSources: [(from: Int, to: Int)] = [(8, 11), (9, 12)]
    private static let letterSource = 7                      // wave-A week that week 10 copies
    private static let shiftDays = 21

    // MARK: - Report

    struct Gate {
        enum Status: String { case passed = "PASS", failed = "FAIL", notEvaluated = "not evaluated" }
        let name: String
        var status: Status
        var detail: String
    }

    struct Report {
        var lines: [String] = []
        var gates: [Gate] = []
        /// One line per week-10 item: day, exercise, before -> after.
        var itemTable: [String] = []
        /// One line per (dayLabel, letter): the projected per-letter chain and how many lifts link at each hop.
        var chainTable: [String] = []
        var blockers: [String] = []
        var alreadyConverted = false
        var sessionsConverted = 0
        var itemsConverted = 0
        var sessionsCreated = 0
        var itemsCreated = 0
        var didWrite = false
        /// Pre-save verification results, one line per check ("[PASS] ..." / "[FAIL] ..."), and the
        /// 18-row table of the created links (weeks 7/8/9 to 10/11/12) read back from the live (pre-save) object graph.
        var verification: [String] = []
        var postWriteChainTable: [String] = []

        var isSafe: Bool { blockers.isEmpty }

        /// Everything, formatted for reading (and for the on-device dry-run log).
        var text: String {
            var out: [String] = []
            out.append("== GATES ==")
            out += gates.map { "[\($0.status.rawValue)] \($0.name)\($0.detail.isEmpty ? "" : " — \($0.detail)")" }
            if !blockers.isEmpty { out.append("== BLOCKERS =="); out += blockers.map { "  ! \($0)" } }
            out.append("== SUMMARY =="); out += lines
            if !itemTable.isEmpty { out.append("== WEEK 10 ITEM CONVERSION (before -> after) =="); out += itemTable }
            if !chainTable.isEmpty { out.append("== PROJECTED CHAINS =="); out += chainTable }
            return out.joined(separator: "\n")
        }
    }

    // MARK: - Plan (pure; no mutation)

    private struct ConvertStep {
        let week10: Session
        let week7: Session
        let pairs: [(dst: SessionItem, src: SessionItem)]
    }

    private struct CreateStep {
        let source: Session
        let newWeek: Int
        let newDate: Date
        let newProgramIndex: Int?
    }

    private struct Plan {
        var converts: [ConvertStep] = []
        var creates: [CreateStep] = []
        var report = Report()
    }

    // MARK: - Public API

    /// Runs every check and describes every write. Mutates nothing.
    static func dryRun(block: MesoBlock, context: ModelContext, calendar: Calendar = .current) -> Report {
        makePlan(block: block, context: context, calendar: calendar).report
    }

    /// Why an apply attempt did not persist. Every case means: nothing was saved, the context was
    /// rolled back (or never touched), and the caller must leave the completion flag unset.
    enum ApplyError: Error, CustomStringConvertible {
        case pendingChanges
        case verificationFailed([String])
        case saveFailed(String)

        var description: String {
            switch self {
            case .pendingChanges: return "context had unsaved changes before apply; refusing so a rollback can never discard them"
            case .verificationFailed(let f): return "post-mutation verification failed (rolled back): " + f.joined(separator: "; ")
            case .saveFailed(let m): return "save failed (rolled back): \(m)"
            }
        }
    }

    /// Test seams. Production uses the defaults.
    struct ApplyHooks {
        /// Replaces `context.save()`.
        var save: (ModelContext) throws -> Void = { try $0.save() }
        /// Runs after the mutations and before verification (used to force a broken result).
        var beforeVerify: ((ModelContext) -> Void)? = nil
        init(save: @escaping (ModelContext) throws -> Void = { try $0.save() },
             beforeVerify: ((ModelContext) -> Void)? = nil) {
            self.save = save; self.beforeVerify = beforeVerify
        }
    }

    /// Applies the conversion if (and only if) the dry run is clean.
    ///
    /// Order: plan -> (autosave off) -> mutate -> verify the whole result -> ONE save. Any failure
    /// after the first mutation (verification, save) rolls the context back and throws, so the
    /// store is exactly as it was and the caller leaves its completion flag unset.
    @discardableResult
    static func apply(block: MesoBlock, context: ModelContext, calendar: Calendar = .current,
                      hooks: ApplyHooks = ApplyHooks()) throws -> Report {
        var plan = makePlan(block: block, context: context, calendar: calendar)
        guard plan.report.isSafe, !plan.report.alreadyConverted else { return plan.report }
        // rollback() discards every unsaved change in the context, so never start with someone else's.
        guard !context.hasChanges else { throw ApplyError.pendingChanges }

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let snapshot = Snapshot(block: block, converts: plan.converts.map { ($0.week10, $0.pairs) })
        let customExercises = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        var touchedItems: [SessionItem] = []          // converted + newly created: held to the "clean plan" rule

        for step in plan.converts {
            for (dst, src) in step.pairs {
                copyPrescription(from: src, to: dst, customExercises: customExercises)
                touchedItems.append(dst)
                plan.report.itemsConverted += 1
            }
            step.week10.sessionNotes = step.week7.sessionNotes
            plan.report.sessionsConverted += 1
        }

        for step in plan.creates {
            let items = step.source.items
                .sorted { $0.order < $1.order }
                .map { cloneItem($0, customExercises: customExercises) }
            let session = Session(
                date: step.newDate,
                status: .planned,
                readinessStars: 0,
                sessionNotes: step.source.sessionNotes,
                weekIndex: step.newWeek,
                dayLabel: step.source.dayLabel,
                items: items
            )
            session.programIndex = step.newProgramIndex
            session.meso = block
            context.insert(session)
            touchedItems += items
            plan.report.sessionsCreated += 1
            plan.report.itemsCreated += items.count
        }

        block.totalWeeks = targetTotalWeeks
        if block.name.contains("10-Week") {
            block.name = block.name.replacingOccurrences(of: "10-Week", with: "12-Week")
        }
        block.updatedAt = Date()

        hooks.beforeVerify?(context)

        let result = verifyConversion(block: block, context: context, touchedItems: touchedItems, calendar: calendar)
        plan.report.verification = result.lines
        plan.report.postWriteChainTable = result.chainTable
        guard result.failures.isEmpty else {
            snapshot.undo(in: context)
            throw ApplyError.verificationFailed(result.failures)
        }

        do {
            try hooks.save(context)
        } catch {
            snapshot.undo(in: context)
            throw ApplyError.saveFailed("\(error)")
        }
        plan.report.didWrite = true
        plan.report.lines.append("WROTE: week 10 converted in place (\(plan.report.sessionsConverted) sessions, \(plan.report.itemsConverted) items); weeks 11-12 created (\(plan.report.sessionsCreated) sessions, \(plan.report.itemsCreated) items); totalWeeks = \(targetTotalWeeks).")
        return plan.report
    }

    // MARK: - Already-converted shape

    /// Empty = `block` already has exactly the converted shape (12 weeks, 6 sessions in each of weeks
    /// 1-12, programIndex covering 1...72 with no repeats, no deload item). Anything else is listed.
    static func convertedShapeProblems(block: MesoBlock, context: ModelContext) -> [String] {
        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let sessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        let total = expectedSessionsPerWeek * targetTotalWeeks
        var problems: [String] = []
        if block.totalWeeks != targetTotalWeeks { problems.append("totalWeeks is \(block.totalWeeks.map(String.init) ?? "nil")") }
        for w in 1...targetTotalWeeks {
            let n = sessions.filter { $0.weekIndex == w }.count
            if n != expectedSessionsPerWeek { problems.append("week \(w) has \(n) session(s), expected \(expectedSessionsPerWeek)") }
        }
        let stray = sessions.filter { !(1...targetTotalWeeks).contains($0.weekIndex) }.count
        if stray > 0 { problems.append("\(stray) session(s) outside weeks 1-\(targetTotalWeeks)") }
        let indices = sessions.compactMap { $0.programIndex }
        if indices.count != sessions.count || Set(indices) != Set(1...total) || indices.count != total {
            problems.append("programIndex does not cover exactly 1...\(total) once each")
        }
        let deload = sessions.reduce(0) { $0 + $1.items.filter { $0.waveRaw?.lowercased() == "deload" }.count }
        if deload > 0 { problems.append("\(deload) item(s) with waveRaw == deload") }
        return problems
    }

    // MARK: - Undo

    /// `ModelContext.rollback()` discards inserts but does NOT revert property edits on objects that
    /// were already persisted (verified: converted week-10 items kept their new values). So apply
    /// records every field it is about to overwrite and restores them itself before rolling back.
    private struct Snapshot {
        struct ItemState {
            let item: SessionItem
            let order: Int, targetReps: Int, targetSets: Int, targetRIR: Int, suggestedLoad: Double
            let waveRaw: String?, priorityRaw: String?
            let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, targetRIRMin: Int?, targetRIRMax: Int?
            let intensifierRaw: String?, intensifierNotes: String?, prescriptionNotes: String?
            let plannedRepsBySet: [Int], plannedRIRsBySet: [Int], plannedLoadsBySet: [Double]
            let planEdited: Bool
            let actualReps: [Int], actualLoads: [Double], actualRIRs: [Int]
            let usedRestPauseFlags: [Bool], restPausePatternsBySet: [String], dropSetPatternsBySet: [String]
            let setFeedbackBySet: [String], pumpRatingsBySet: [Int]
            let coachNote: String?, nextSuggestedLoad: Double?, updatedAt: Date?

            init(_ i: SessionItem) {
                item = i
                order = i.order; targetReps = i.targetReps; targetSets = i.targetSets; targetRIR = i.targetRIR
                suggestedLoad = i.suggestedLoad; waveRaw = i.waveRaw; priorityRaw = i.priorityRaw
                setMin = i.setMin; setMax = i.setMax; repMin = i.repMin; repMax = i.repMax
                targetRIRMin = i.targetRIRMin; targetRIRMax = i.targetRIRMax
                intensifierRaw = i.intensifierRaw; intensifierNotes = i.intensifierNotes; prescriptionNotes = i.prescriptionNotes
                plannedRepsBySet = i.plannedRepsBySet; plannedRIRsBySet = i.plannedRIRsBySet; plannedLoadsBySet = i.plannedLoadsBySet
                planEdited = i.planEdited
                actualReps = i.actualReps; actualLoads = i.actualLoads; actualRIRs = i.actualRIRs
                usedRestPauseFlags = i.usedRestPauseFlags; restPausePatternsBySet = i.restPausePatternsBySet
                dropSetPatternsBySet = i.dropSetPatternsBySet; setFeedbackBySet = i.setFeedbackBySet
                pumpRatingsBySet = i.pumpRatingsBySet
                coachNote = i.coachNote; nextSuggestedLoad = i.nextSuggestedLoad; updatedAt = i.updatedAt
            }

            func restore() {
                let i = item
                i.order = order; i.targetReps = targetReps; i.targetSets = targetSets; i.targetRIR = targetRIR
                i.suggestedLoad = suggestedLoad; i.waveRaw = waveRaw; i.priorityRaw = priorityRaw
                i.setMin = setMin; i.setMax = setMax; i.repMin = repMin; i.repMax = repMax
                i.targetRIRMin = targetRIRMin; i.targetRIRMax = targetRIRMax
                i.intensifierRaw = intensifierRaw; i.intensifierNotes = intensifierNotes; i.prescriptionNotes = prescriptionNotes
                i.plannedRepsBySet = plannedRepsBySet; i.plannedRIRsBySet = plannedRIRsBySet; i.plannedLoadsBySet = plannedLoadsBySet
                i.planEdited = planEdited
                i.actualReps = actualReps; i.actualLoads = actualLoads; i.actualRIRs = actualRIRs
                i.usedRestPauseFlags = usedRestPauseFlags; i.restPausePatternsBySet = restPausePatternsBySet
                i.dropSetPatternsBySet = dropSetPatternsBySet; i.setFeedbackBySet = setFeedbackBySet
                i.pumpRatingsBySet = pumpRatingsBySet
                i.coachNote = coachNote; i.nextSuggestedLoad = nextSuggestedLoad; i.updatedAt = updatedAt
            }
        }

        let block: MesoBlock
        let totalWeeks: Int?, name: String, updatedAt: Date?
        let sessionNotes: [(Session, String?)]
        let items: [ItemState]

        init(block: MesoBlock, converts: [(week10: Session, pairs: [(dst: SessionItem, src: SessionItem)])]) {
            self.block = block
            totalWeeks = block.totalWeeks; name = block.name; updatedAt = block.updatedAt
            sessionNotes = converts.map { ($0.week10, $0.week10.sessionNotes) }
            items = converts.flatMap { $0.pairs.map { ItemState($0.dst) } }
        }

        /// Puts every overwritten field back, then discards the inserted sessions.
        func undo(in context: ModelContext) {
            block.totalWeeks = totalWeeks; block.name = name; block.updatedAt = updatedAt
            for (s, notes) in sessionNotes { s.sessionNotes = notes }
            for i in items { i.restore() }
            context.rollback()
        }
    }

    // MARK: - Verification (runs before save)

    private static let expectedSessionsPerWeek = 6
    private static let thursday = 5                        // Gregorian weekday: the rest day stays empty

    /// Checks the converted object graph as it will be saved. Reads through the context, which sees
    /// the pending mutations. Returns one line per check plus the failures (empty = all passed).
    static func verifyConversion(block: MesoBlock, context: ModelContext, touchedItems: [SessionItem],
                                 calendar: Calendar) -> (lines: [String], failures: [String], chainTable: [String]) {
        var lines: [String] = []
        var failures: [String] = []
        func check(_ name: String, detail: String = "", _ problems: [String]) {
            if problems.isEmpty {
                lines.append("[PASS] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                lines.append("[FAIL] \(name) — \(problems.joined(separator: "; "))")
                failures += problems.map { "\(name): \($0)" }
            }
        }

        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let sessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        let total = expectedSessionsPerWeek * targetTotalWeeks

        // Links the conversion CREATES: every wave-lettered item in weeks 7, 8, 9 targets the matching item
        // (same meso, day, wave, canonical id) in weeks 10, 11, 12, and weeks 10-12 have no later target.
        // Links in weeks 1-6 are not this conversion's doing and are NOT verified here (legacy dead ends such
        // as hotel swaps, wave-nil lifts and replaced items are listed below as INFO, never as failures).
        let created = createdLinks(sessions: sessions, all: all)
        check("created links: weeks 7/8/9 -> 10/11/12 and nothing after 10-12", detail: "\(created.checked) items checked", created.problems)
        let legacy = legacyDeadEnds(sessions: sessions, all: all)
        if !legacy.isEmpty {
            lines.append("[INFO] \(legacy.count) week 1-6 item(s) have no same-lift target 3 weeks later (legacy dead ends, not verified, not failures): \(legacy.prefix(14).joined(separator: ", "))\(legacy.count > 14 ? ", …" : "")")
        }
        let unwaved = unwavedItems(block: block, context: context)
        if !unwaved.isEmpty {
            lines.append("[INFO] \(unwaved.count) hand-added item(s) with no wave letter are outside the A/B/C chains (legacy chronological path, unchanged by this conversion): \(unwaved.joined(separator: ", "))")
        }

        check("block has exactly \(total) sessions", detail: "\(sessions.count)", sessions.count == total ? [] : ["\(sessions.count) sessions"])
        var perWeek: [String] = []
        for w in 1...targetTotalWeeks {
            let n = sessions.filter { $0.weekIndex == w }.count
            if n != expectedSessionsPerWeek { perWeek.append("week \(w) has \(n)") }
        }
        let stray = sessions.filter { !(1...targetTotalWeeks).contains($0.weekIndex) }.count
        if stray > 0 { perWeek.append("\(stray) session(s) outside weeks 1-\(targetTotalWeeks)") }
        check("\(expectedSessionsPerWeek) sessions in each of weeks 1-\(targetTotalWeeks)", perWeek)

        let indices = sessions.compactMap { $0.programIndex }
        var pi: [String] = []
        if indices.count != sessions.count { pi.append("\(sessions.count - indices.count) session(s) have no programIndex") }
        if Set(indices).count != indices.count { pi.append("duplicate programIndex values") }
        if Set(indices) != Set(1...total) { pi.append("programIndex is not exactly 1...\(total)") }
        check("programIndex is exactly 1...\(total), no repeats", pi)

        let days = sessions.map { calendar.startOfDay(for: $0.date) }
        check("no two sessions share a date", Set(days).count == days.count ? [] : ["\(days.count - Set(days).count) shared date(s)"])
        let thursdays = sessions.filter { calendar.component(.weekday, from: $0.date) == thursday }
        check("no session falls on a Thursday", thursdays.map { "W\($0.weekIndex) \($0.dayLabel ?? "?")" })

        let deloadItems = sessions.flatMap { s in s.items.filter { $0.waveRaw?.lowercased() == "deload" }.map { _ in "W\(s.weekIndex) \(s.dayLabel ?? "?")" } }
        check("no item has waveRaw == deload", deloadItems)
        check("isDeloadWeek is false for every session", sessions.filter { $0.isDeloadWeek }.map { "W\($0.weekIndex) \($0.dayLabel ?? "?")" })
        check("totalWeeks == \(targetTotalWeeks)", block.totalWeeks == targetTotalWeeks ? [] : ["totalWeeks is \(block.totalWeeks.map(String.init) ?? "nil")"])

        var dirty: [String] = []
        for i in touchedItems {
            if i.planEdited { dirty.append("\(i.exerciseId) planEdited") }
            if !i.actualReps.isEmpty || !i.actualLoads.isEmpty || !i.actualRIRs.isEmpty { dirty.append("\(i.exerciseId) has actuals") }
            if i.isCompleted { dirty.append("\(i.exerciseId) isCompleted") }
        }
        check("converted/new items: planEdited false, no actuals, not completed", detail: "\(touchedItems.count) items", dirty)

        var waves: [String] = []
        for (w, letter) in [(11, "b"), (12, "c")] {
            for s in sessions where s.weekIndex == w {
                for i in s.items where i.waveRaw?.lowercased() != letter { waves.append("W\(w) \(s.dayLabel ?? "?") \(i.exerciseId) wave \(i.waveRaw ?? "nil")") }
            }
        }
        check("weeks 11/12 waves are b/c", waves)

        return (lines, failures, created.rows)
    }

    /// Hand-added items in the block that carry no wave letter ("W1 Pull A dumbbell_lateral_raise").
    static func unwavedItems(block: MesoBlock, context: ModelContext) -> [String] {
        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        return all.filter { $0.meso?.persistentModelID == block.persistentModelID }
            .sorted { $0.date < $1.date }
            .flatMap { s in s.items.filter { !WavePrescriptionGuard.isWaveLetter($0.waveRaw) && $0.waveRaw?.lowercased() != "deload" }
                .map { "W\(s.weekIndex) \(s.dayLabel ?? "?") \($0.exerciseId)" } }
    }

    /// The links this conversion creates. For every wave-lettered item of weeks 7, 8, 9 the target must be the
    /// item with the same canonical id in the same day, three weeks later (weeks 10, 11, 12); every wave-lettered
    /// item of weeks 10-12 must have no target. One row per (dayLabel, letter) for the report.
    static func createdLinks(sessions: [Session], all: [Session]) -> (rows: [String], problems: [String], checked: Int) {
        var rows: [String] = []
        var problems: [String] = []
        var checked = 0
        func label(_ s: Session) -> String { (s.dayLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func owner(_ item: SessionItem) -> Session? { sessions.first { $0.items.contains { $0 === item } } }
        for day in Set(sessions.map(label)).sorted() {
            for (letter, source) in [("A", 7), ("B", 8), ("C", 9)] {
                guard let from = sessions.first(where: { $0.weekIndex == source && label($0) == day }) else {
                    problems.append("\(day) / \(letter): no week-\(source) session"); continue
                }
                let lettered = from.items.filter { WavePrescriptionGuard.isWaveLetter($0.waveRaw) }
                var linked = 0
                for item in lettered {
                    checked += 1
                    let target = PlanMemoryEngine.nextTargetItem(for: item, after: from, in: all)
                    let expected = sessions.first { $0.weekIndex == source + 3 && label($0) == day }?.items.first {
                        ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                    }
                    if let target, let expected, target === expected { linked += 1 }
                    else { problems.append("W\(source) \(day) \(item.exerciseId) -> \(target.flatMap(owner).map { "W\($0.weekIndex)" } ?? "none") (expected W\(source + 3))") }
                }
                rows.append("  \(day) / \(letter): W\(source)→W\(source + 3)→nil   items linked \(linked)/\(lettered.count)")
            }
        }
        for s in sessions where s.weekIndex >= 10 {
            for item in s.items where WavePrescriptionGuard.isWaveLetter(item.waveRaw) {
                checked += 1
                if let t = PlanMemoryEngine.nextTargetItem(for: item, after: s, in: all) {
                    problems.append("W\(s.weekIndex) \(label(s)) \(item.exerciseId) has a later target W\(owner(t)?.weekIndex ?? -1)")
                }
            }
        }
        return (rows, problems, checked)
    }

    /// Week 1-6 wave-lettered items that do not link to the same lift three weeks later: hotel swaps, replaced
    /// lifts and the like. Information for the report only.
    static func legacyDeadEnds(sessions: [Session], all: [Session]) -> [String] {
        var out: [String] = []
        for s in sessions.sorted(by: { $0.date < $1.date }) where s.weekIndex <= 6 {
            for item in s.items where WavePrescriptionGuard.isWaveLetter(item.waveRaw) {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let expected = sessions.first {
                    $0.weekIndex == s.weekIndex + 3 && $0.dayLabel == s.dayLabel
                }?.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id }
                let target = PlanMemoryEngine.nextTargetItem(for: item, after: s, in: all)
                if target == nil || target !== expected {
                    out.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(item.exerciseNameSnapshot ?? item.exerciseId)")
                }
            }
        }
        return out
    }

    /// Post-write check usable at any time: for every wave-lettered item in weeks 1...9, the per-letter
    /// target must be the same lift three weeks later (same dayLabel, same wave); weeks 10+ have no
    /// target. Items with no wave letter (hand-added lifts) are not in a rotation: they follow the legacy
    /// chronological path, so they are excluded here and listed separately by `unwavedItems`.
    static func verifyChains(block: MesoBlock, context: ModelContext) -> (checked: Int, broken: [String]) {
        let all = ((try? context.fetch(FetchDescriptor<Session>())) ?? [])
        let blockSessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        var checked = 0
        var broken: [String] = []
        for session in blockSessions.sorted(by: { $0.date < $1.date }) {
            let week = session.weekIndex
            for item in session.items where WavePrescriptionGuard.isWaveLetter(item.waveRaw) {
                checked += 1
                let target = PlanMemoryEngine.nextTargetItem(for: item, after: session, in: all)
                let targetSession = target.flatMap { t in blockSessions.first { $0.items.contains { $0 === t } } }
                let expectedWeek = week + 3
                if expectedWeek <= targetTotalWeeks {
                    if targetSession?.weekIndex != expectedWeek {
                        broken.append("W\(week) \(session.dayLabel ?? "?") \(item.exerciseId) -> \(targetSession.map { "W\($0.weekIndex)" } ?? "none") (expected W\(expectedWeek))")
                    }
                } else if target != nil {
                    broken.append("W\(week) \(session.dayLabel ?? "?") \(item.exerciseId) has an unexpected target W\(targetSession?.weekIndex ?? -1)")
                }
            }
        }
        return (checked, broken)
    }

    // MARK: - Planner

    private static func makePlan(block: MesoBlock, context: ModelContext, calendar: Calendar) -> Plan {
        var plan = Plan()
        var gateNames: [String] = []               // evaluation order, for "not evaluated" reporting
        func fail(_ s: String) { plan.report.blockers.append(s) }
        func note(_ s: String) { plan.report.lines.append(s) }
        /// Runs `body`; the gate passes iff it added no blocker.
        func gate(_ name: String, detail okDetail: String = "", _ body: () -> Void) {
            gateNames.append(name)
            let before = plan.report.blockers.count
            body()
            let added = plan.report.blockers.count - before
            plan.report.gates.append(Gate(name: name, status: added == 0 ? .passed : .failed,
                                          detail: added == 0 ? okDetail : "\(added) blocker(s)"))
        }
        func finish(unevaluated: [String]) -> Plan {
            for n in unevaluated { plan.report.gates.append(Gate(name: n, status: .notEvaluated, detail: "")) }
            return plan
        }
        let allGateNames = [
            "block is active, not maintenance, totalWeeks == 10",
            "weeks 11-12 do not exist yet",
            "weeks 7-10 have equal session counts",
            "wave letters: wk7=a, wk8=b, wk9=c, wk10=deload",
            "dayLabels present, unique per week, identical wk7 vs wk10",
            "week 10 sessions planned with no logged data",
            "week 10 rosters match week 7 (per day, by exerciseId)",
            "new dates: same weekday, no collisions, no duplicates",
            "new programIndex values unused"
        ]
        func unevaluatedAfter(_ done: Int) -> [String] { Array(allGateNames.dropFirst(done)) }

        guard let all = try? context.fetch(FetchDescriptor<Session>()) else {
            fail("could not fetch sessions")
            return finish(unevaluated: allGateNames)
        }
        let customExercises = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let sessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        func week(_ w: Int) -> [Session] { sessions.filter { $0.weekIndex == w }.sorted { $0.date < $1.date } }

        // Already converted: totalWeeks 12 and weeks 11/12 present -> no-op.
        if block.totalWeeks == targetTotalWeeks, !week(11).isEmpty, !week(12).isEmpty {
            plan.report.alreadyConverted = true
            note("NO-OP: block is already \(targetTotalWeeks) weeks with weeks 11-12 present.")
            return finish(unevaluated: allGateNames)
        }

        gate(allGateNames[0], detail: "'\(block.name)' [\(block.id.map { String($0.uuidString.prefix(8)) } ?? "no id")], \(sessions.count) sessions") {
            if block.status != .active { fail("block status is \(block.status.rawValue), not active") }
            if block.isMaintenance { fail("block is a maintenance block") }
            if block.totalWeeks != sourceTotalWeeks { fail("totalWeeks is \(block.totalWeeks.map(String.init) ?? "nil"), expected \(sourceTotalWeeks)") }
        }
        gate(allGateNames[1]) {
            if !week(11).isEmpty || !week(12).isEmpty { fail("weeks 11/12 already contain sessions (partial conversion?) — refusing") }
        }

        let w7 = week(7), w8 = week(8), w9 = week(9), w10 = week(10)
        let n = w7.count
        note("Block '\(block.name)': \(sessions.count) sessions; week sizes 7/8/9/10 = \(w7.count)/\(w8.count)/\(w9.count)/\(w10.count).")
        gate(allGateNames[2], detail: "\(n) per week") {
            if n == 0 { fail("week 7 has no sessions") }
            for (w, ss) in [(8, w8), (9, w9), (10, w10)] where ss.count != n { fail("week \(w) has \(ss.count) sessions, week 7 has \(n)") }
        }
        if !plan.report.isSafe { return finish(unevaluated: unevaluatedAfter(3)) }

        func waves(_ ss: [Session]) -> Set<String> { Set(ss.flatMap { $0.items.compactMap { $0.waveRaw?.lowercased() } }) }
        gate(allGateNames[3]) {
            if waves(w7) != ["a"] { fail("week 7 waves are \(waves(w7).sorted()), expected [a]") }
            if waves(w8) != ["b"] { fail("week 8 waves are \(waves(w8).sorted()), expected [b]") }
            if waves(w9) != ["c"] { fail("week 9 waves are \(waves(w9).sorted()), expected [c]") }
            if waves(w10) != ["deload"] { fail("week 10 waves are \(waves(w10).sorted()), expected [deload]") }
        }
        func labels(_ ss: [Session]) -> [String] { ss.compactMap { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) } }
        gate(allGateNames[4], detail: labels(w7).joined(separator: " | ")) {
            for (w, ss) in [(7, w7), (8, w8), (9, w9), (10, w10)] {
                let l = labels(ss)
                if l.count != ss.count { fail("week \(w) has a session with no dayLabel") }
                if Set(l).count != l.count { fail("week \(w) has duplicate dayLabels: \(l)") }
            }
            if Set(labels(w7)) != Set(labels(w10)) { fail("week 7 and week 10 dayLabels differ: \(labels(w7)) vs \(labels(w10))") }
            if Set(labels(w7)) != Set(labels(w8)) || Set(labels(w7)) != Set(labels(w9)) { fail("weeks 7/8/9 dayLabels differ") }
        }
        if !plan.report.isSafe { return finish(unevaluated: unevaluatedAfter(5)) }

        gate(allGateNames[5]) {
            for s10 in w10 {
                let label = s10.dayLabel!.trimmingCharacters(in: .whitespacesAndNewlines)
                if s10.status != .planned { fail("week 10 \(label) is \(s10.status.rawValue), not planned") }
                if hasLoggedData(s10) { fail("week 10 \(label) has logged data") }
            }
        }
        gate(allGateNames[6]) {
            for s10 in w10 {
                let label = s10.dayLabel!.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let s7 = w7.first(where: { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == label }) else {
                    fail("week 10 \(label) has no week-7 counterpart"); continue
                }
                let (pairs, problems) = pairItems(dst: s10, src: s7)
                for p in problems { fail("week 10 \(label): \(p)") }
                if problems.isEmpty { plan.converts.append(ConvertStep(week10: s10, week7: s7, pairs: pairs)) }
            }
        }

        // Weeks 11 / 12: clone sources, dates, indices, collisions.
        let occupied = Set(all.map { calendar.startOfDay(for: $0.date) })
        var plannedDates = Set<Date>()
        gate(allGateNames[7]) {
            for (from, to) in cloneSources {
                for src in week(from) {
                    guard let d = calendar.date(byAdding: .day, value: shiftDays, to: calendar.startOfDay(for: src.date)) else {
                        fail("could not compute date for W\(to) \(src.dayLabel ?? "?")"); continue
                    }
                    if calendar.component(.weekday, from: d) != calendar.component(.weekday, from: src.date) { fail("shifted date for W\(to) changes weekday") }
                    if occupied.contains(d) { fail("date \(d.formatted(date: .abbreviated, time: .omitted)) for W\(to) \(src.dayLabel ?? "?") collides with an existing session") }
                    if !plannedDates.insert(d).inserted { fail("two new sessions planned on \(d.formatted(date: .abbreviated, time: .omitted))") }
                    plan.creates.append(CreateStep(source: src, newWeek: to, newDate: d, newProgramIndex: src.programIndex.map { $0 + 3 * n }))
                }
            }
        }
        gate(allGateNames[8]) {
            let existing = Set(sessions.compactMap { $0.programIndex })
            if let clash = plan.creates.compactMap({ $0.newProgramIndex }).first(where: { existing.contains($0) }) { fail("programIndex \(clash) already used in this block") }
        }

        // Describe.
        func fmt(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()) }
        note("CONVERT week 10 in place (\(plan.converts.count) sessions, \(plan.converts.reduce(0) { $0 + $1.pairs.count }) items): waveRaw deload -> a; prescription, loads (bodyweight stays 0) and planned reps/RIR copied from week 7.")
        for s in plan.converts.sorted(by: { $0.week10.date < $1.week10.date }) {
            note("  W10 \(s.week10.dayLabel ?? "?") \(fmt(s.week10.date)) <- W7 \(s.week7.dayLabel ?? "?") (\(s.pairs.count) items); programIndex \(s.week10.programIndex.map(String.init) ?? "nil") unchanged")
        }
        note("CREATE weeks 11-12 (\(plan.creates.count) sessions, \(plan.creates.reduce(0) { $0 + $1.source.items.count }) items), cloned from weeks 8/9 +\(shiftDays) days:")
        for c in plan.creates.sorted(by: { $0.newDate < $1.newDate }) {
            let wave = c.source.items.compactMap { $0.waveRaw }.first ?? "?"
            note("  W\(c.newWeek) \(c.source.dayLabel ?? "?") \(fmt(c.newDate)) wave \(wave) programIndex \(c.newProgramIndex.map(String.init) ?? "nil") <- W\(c.source.weekIndex) (\(c.source.items.count) items)")
        }
        if let first = plan.creates.map(\.newDate).min(), let last = plan.creates.map(\.newDate).max() {
            note("New weeks span \(fmt(first)) – \(fmt(last)).")
        }
        note("block.totalWeeks \(block.totalWeeks.map(String.init) ?? "nil") -> \(targetTotalWeeks); name '\(block.name)' -> '\(block.name.replacingOccurrences(of: "10-Week", with: "12-Week"))'.")

        // Week-10 item table.
        func desc(_ i: SessionItem) -> String {
            let reps = (i.repMin != nil && i.repMax != nil) ? "\(i.repMin!)-\(i.repMax!)" : "\(i.targetReps)"
            let rir = (i.targetRIRMin != nil && i.targetRIRMax != nil) ? "\(i.targetRIRMin!)-\(i.targetRIRMax!)" : "\(i.targetRIR)"
            let load = i.suggestedLoad > 0 ? String(format: "%.1f", i.suggestedLoad) : "0"
            return "\(i.waveRaw ?? "-") \(i.targetSets)s \(reps)r RIR\(rir) load \(load)\(i.intensifierRaw.map { $0 == "none" ? "" : " [\($0)]" } ?? "")"
        }
        for s in plan.converts.sorted(by: { $0.week10.date < $1.week10.date }) {
            for (dst, src) in s.pairs {
                let bw = ExerciseCatalog.isBodyweight(exerciseId: src.exerciseId, customExercises: customExercises)
                var after = desc(src)
                if bw { after = after.replacingOccurrences(of: #"load [0-9.]+"#, with: "load 0", options: .regularExpression) }
                plan.report.itemTable.append("  \(s.week10.dayLabel ?? "?") | \(dst.exerciseNameSnapshot ?? dst.exerciseId) : \(desc(dst))  ->  \(after)")
            }
        }

        // Projected chains (structure only): roster that will exist in each week, per dayLabel.
        func roster(_ w: Int, _ label: String) -> Set<String>? {
            func ids(_ s: Session?) -> Set<String>? { s.map { Set($0.items.map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) }) } }
            func sess(_ ww: Int) -> Session? { week(ww).first { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == label } }
            switch w {
            case 10: return ids(sess(7))      // converted in place from week 7
            case 11: return ids(sess(8))      // cloned from week 8
            case 12: return ids(sess(9))      // cloned from week 9
            default: return ids(sess(w))
            }
        }
        let letters: [(String, [Int])] = [("A", [1, 4, 7, 10]), ("B", [2, 5, 8, 11]), ("C", [3, 6, 9, 12])]
        for label in labels(w7).sorted() {
            for (letter, weeks) in letters {
                var hops: [String] = []
                for (a, b) in zip(weeks, weeks.dropFirst()) {
                    guard let ra = roster(a, label), let rb = roster(b, label) else { hops.append("W\(a)→W\(b) MISSING SESSION"); continue }
                    hops.append("W\(a)→W\(b) \(ra.intersection(rb).count)/\(ra.count)")
                }
                let tail = weeks.last!
                plan.report.chainTable.append("  \(label) / \(letter): " + weeks.map { "W\($0)" }.joined(separator: "→") + "→nil   links: " + hops.joined(separator: ", ") + "   (W\(tail) has no later \(letter) -> target nil)")
            }
        }
        note("Projected chains: 1→4→7→10, 2→5→8→11, 3→6→9→12. Apply verifies only the links it creates (weeks 7/8/9 → 10/11/12); weeks 1-6 are not verified.")
        return finish(unevaluated: [])
    }

    /// Pairs destination (week 10) items with source (week 7) items by canonical exerciseId.
    /// A roster that does not match one-to-one is a problem, not something to guess around.
    private static func pairItems(dst: Session, src: Session) -> ([(dst: SessionItem, src: SessionItem)], [String]) {
        var problems: [String] = []
        var pairs: [(dst: SessionItem, src: SessionItem)] = []
        var remaining = src.items.sorted { $0.order < $1.order }
        for d in dst.items.sorted(by: { $0.order < $1.order }) {
            let id = ExerciseCatalog.canonicalExerciseId(for: d.exerciseId)
            if let idx = remaining.firstIndex(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id }) {
                pairs.append((d, remaining.remove(at: idx)))
            } else {
                problems.append("item \(d.exerciseId) has no week-7 counterpart")
            }
        }
        for r in remaining { problems.append("week-7 item \(r.exerciseId) has no week-10 counterpart") }
        return (pairs, problems)
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains {
            $0.isCompleted || $0.actualLoads.contains { $0 > 0 } || $0.actualReps.contains { $0 > 0 }
        }
    }

    // MARK: - Item copying

    /// Prescription, load and plan shape. Actuals, feedback, PR, coach notes and override reasons are
    /// never copied; `planEdited` stays false. Bodyweight items keep load 0.
    private static func copyPrescription(from src: SessionItem, to dst: SessionItem, customExercises: [CustomExercise]) {
        let bodyweight = ExerciseCatalog.isBodyweight(exerciseId: src.exerciseId, customExercises: customExercises)
        let n = max(0, src.targetSets)
        dst.order = src.order
        dst.targetReps = src.targetReps
        dst.targetSets = src.targetSets
        dst.targetRIR = src.targetRIR
        dst.suggestedLoad = bodyweight ? 0 : src.suggestedLoad
        dst.waveRaw = src.waveRaw
        dst.priorityRaw = src.priorityRaw
        dst.setMin = src.setMin
        dst.setMax = src.setMax
        dst.repMin = src.repMin
        dst.repMax = src.repMax
        dst.targetRIRMin = src.targetRIRMin
        dst.targetRIRMax = src.targetRIRMax
        dst.intensifierRaw = src.intensifierRaw
        dst.intensifierNotes = src.intensifierNotes
        dst.prescriptionNotes = src.prescriptionNotes
        dst.plannedRepsBySet = resized(src.plannedRepsBySet, to: n, fill: src.targetReps)
        dst.plannedRIRsBySet = resized(src.plannedRIRsBySet, to: n, fill: src.targetRIR)
        dst.plannedLoadsBySet = bodyweight
            ? Array(repeating: 0.0, count: n)
            : resized(src.plannedLoadsBySet, to: n, fill: src.suggestedLoad)
        dst.planEdited = false
        dst.actualReps = []
        dst.actualLoads = []
        dst.actualRIRs = []
        dst.usedRestPauseFlags = []
        dst.restPausePatternsBySet = []
        dst.dropSetPatternsBySet = []
        dst.setFeedbackBySet = []
        dst.pumpRatingsBySet = []
        dst.coachNote = nil
        dst.nextSuggestedLoad = nil
        dst.updatedAt = Date()
    }

    private static func cloneItem(_ src: SessionItem, customExercises: [CustomExercise]) -> SessionItem {
        let item = SessionItem(
            order: src.order,
            exerciseId: src.exerciseId,
            exerciseNameSnapshot: src.exerciseNameSnapshot,
            targetReps: src.targetReps,
            targetSets: src.targetSets,
            targetRIR: src.targetRIR,
            suggestedLoad: 0
        )
        copyPrescription(from: src, to: item, customExercises: customExercises)
        return item
    }

    private static func resized<T>(_ array: [T], to count: Int, fill: T) -> [T] {
        let n = max(0, count)
        if array.count == n { return array }
        if array.count > n { return Array(array.prefix(n)) }
        return array + Array(repeating: array.last ?? fill, count: n - array.count)
    }
}
