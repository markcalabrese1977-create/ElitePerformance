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
/// Loads are deliberately zeroed on every converted/created item: an empty target is what lets
/// carry-forward's seed path write the earned hold/bump/reduce (see PlanMemoryEngine). A
/// non-empty target takes the propagate path, which only ever raises a load.
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

    struct Report {
        var lines: [String] = []
        var blockers: [String] = []
        var alreadyConverted = false
        var sessionsConverted = 0
        var itemsConverted = 0
        var sessionsCreated = 0
        var itemsCreated = 0
        var didWrite = false

        var isSafe: Bool { blockers.isEmpty }
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

    /// Applies the conversion if (and only if) the dry run is clean. Single save at the end.
    @discardableResult
    static func apply(block: MesoBlock, context: ModelContext, calendar: Calendar = .current) throws -> Report {
        var plan = makePlan(block: block, context: context, calendar: calendar)
        guard plan.report.isSafe, !plan.report.alreadyConverted else { return plan.report }

        for step in plan.converts {
            for (dst, src) in step.pairs {
                copyPrescription(from: src, to: dst)
                plan.report.itemsConverted += 1
            }
            step.week10.sessionNotes = step.week7.sessionNotes
            plan.report.sessionsConverted += 1
        }

        for step in plan.creates {
            let items = step.source.items
                .sorted { $0.order < $1.order }
                .map { cloneItem($0) }
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
            plan.report.sessionsCreated += 1
            plan.report.itemsCreated += items.count
        }

        block.totalWeeks = targetTotalWeeks
        if block.name.contains("10-Week") {
            block.name = block.name.replacingOccurrences(of: "10-Week", with: "12-Week")
        }
        block.updatedAt = Date()

        try context.save()
        plan.report.didWrite = true
        plan.report.lines.append("WROTE: week 10 converted in place (\(plan.report.sessionsConverted) sessions, \(plan.report.itemsConverted) items); weeks 11-12 created (\(plan.report.sessionsCreated) sessions, \(plan.report.itemsCreated) items); totalWeeks = \(targetTotalWeeks).")
        return plan.report
    }

    /// Post-write check usable at any time: for every item in weeks 1...9, the per-letter target
    /// must be the same lift three weeks later (same dayLabel, same wave); weeks 10+ have no target.
    static func verifyChains(block: MesoBlock, context: ModelContext) -> (checked: Int, broken: [String]) {
        let all = ((try? context.fetch(FetchDescriptor<Session>())) ?? [])
        let blockSessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        var checked = 0
        var broken: [String] = []
        for session in blockSessions.sorted(by: { $0.date < $1.date }) {
            let week = session.weekIndex
            for item in session.items {
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
        func block_(_ s: String) { plan.report.blockers.append(s) }
        func note(_ s: String) { plan.report.lines.append(s) }

        guard let all = try? context.fetch(FetchDescriptor<Session>()) else {
            block_("could not fetch sessions")
            return plan
        }
        let sessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        func week(_ w: Int) -> [Session] { sessions.filter { $0.weekIndex == w }.sorted { $0.date < $1.date } }

        // Already converted: totalWeeks 12 and weeks 11/12 present -> no-op.
        if block.totalWeeks == targetTotalWeeks, !week(11).isEmpty, !week(12).isEmpty {
            plan.report.alreadyConverted = true
            note("NO-OP: block is already \(targetTotalWeeks) weeks with weeks 11-12 present.")
            return plan
        }

        // Block-level preconditions.
        if block.status != .active { block_("block status is \(block.status.rawValue), not active") }
        if block.isMaintenance { block_("block is a maintenance block") }
        if block.totalWeeks != sourceTotalWeeks { block_("totalWeeks is \(block.totalWeeks.map(String.init) ?? "nil"), expected \(sourceTotalWeeks)") }
        if !week(11).isEmpty || !week(12).isEmpty { block_("weeks 11/12 already contain sessions (partial conversion?) — refusing") }

        let w7 = week(7), w8 = week(8), w9 = week(9), w10 = week(10)
        let n = w7.count
        note("Block '\(block.name)': \(sessions.count) sessions; week sizes 7/8/9/10 = \(w7.count)/\(w8.count)/\(w9.count)/\(w10.count).")
        if n == 0 { block_("week 7 has no sessions") }
        for (w, ss) in [(8, w8), (9, w9), (10, w10)] where ss.count != n {
            block_("week \(w) has \(ss.count) sessions, week 7 has \(n)")
        }
        if !plan.report.isSafe { return plan }

        // Wave letters per week (first item; every item in a materialized session shares it).
        func waves(_ ss: [Session]) -> Set<String> {
            Set(ss.flatMap { $0.items.compactMap { $0.waveRaw?.lowercased() } })
        }
        if waves(w7) != ["a"] { block_("week 7 waves are \(waves(w7).sorted()), expected [a]") }
        if waves(w8) != ["b"] { block_("week 8 waves are \(waves(w8).sorted()), expected [b]") }
        if waves(w9) != ["c"] { block_("week 9 waves are \(waves(w9).sorted()), expected [c]") }
        if waves(w10) != ["deload"] { block_("week 10 waves are \(waves(w10).sorted()), expected [deload]") }

        // dayLabels unique per week and identical across the weeks involved.
        func labels(_ ss: [Session]) -> [String] { ss.compactMap { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) } }
        for (w, ss) in [(7, w7), (8, w8), (9, w9), (10, w10)] {
            let l = labels(ss)
            if l.count != ss.count { block_("week \(w) has a session with no dayLabel") }
            if Set(l).count != l.count { block_("week \(w) has duplicate dayLabels: \(l)") }
        }
        if Set(labels(w7)) != Set(labels(w10)) { block_("week 7 and week 10 dayLabels differ: \(labels(w7)) vs \(labels(w10))") }
        if !plan.report.isSafe { return plan }

        // Week 10: safe to modify, roster matches week 7.
        for s10 in w10 {
            let label = s10.dayLabel!.trimmingCharacters(in: .whitespacesAndNewlines)
            if s10.status != .planned { block_("week 10 \(label) is \(s10.status.rawValue), not planned") }
            if hasLoggedData(s10) { block_("week 10 \(label) has logged data") }
            guard let s7 = w7.first(where: { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == label }) else {
                block_("week 10 \(label) has no week-7 counterpart"); continue
            }
            let (pairs, problems) = pairItems(dst: s10, src: s7)
            for p in problems { block_("week 10 \(label): \(p)") }
            if problems.isEmpty { plan.converts.append(ConvertStep(week10: s10, week7: s7, pairs: pairs)) }
        }

        // Weeks 11 / 12: clone sources, dates, indices, collisions.
        let occupied = Set(all.map { calendar.startOfDay(for: $0.date) })
        var plannedDates = Set<Date>()
        for (from, to) in cloneSources {
            for src in week(from) {
                guard let d = calendar.date(byAdding: .day, value: shiftDays, to: calendar.startOfDay(for: src.date)) else {
                    block_("could not compute date for W\(to) \(src.dayLabel ?? "?")"); continue
                }
                if calendar.component(.weekday, from: d) != calendar.component(.weekday, from: src.date) {
                    block_("shifted date for W\(to) changes weekday")
                }
                if occupied.contains(d) {
                    block_("date \(d.formatted(date: .abbreviated, time: .omitted)) for W\(to) \(src.dayLabel ?? "?") collides with an existing session")
                }
                if !plannedDates.insert(d).inserted { block_("two new sessions planned on \(d.formatted(date: .abbreviated, time: .omitted))") }
                let newIndex = src.programIndex.map { $0 + 3 * n }
                plan.creates.append(CreateStep(source: src, newWeek: to, newDate: d, newProgramIndex: newIndex))
            }
        }
        if let existing = Set(sessions.compactMap { $0.programIndex }) as Set<Int>?,
           let clash = plan.creates.compactMap({ $0.newProgramIndex }).first(where: { existing.contains($0) }) {
            block_("programIndex \(clash) already used in this block")
        }

        // Describe.
        note("CONVERT week 10 in place (\(plan.converts.count) sessions, \(plan.converts.reduce(0) { $0 + $1.pairs.count }) items): waveRaw deload -> a; prescription copied from week 7; loads zeroed.")
        for s in plan.converts.sorted(by: { $0.week10.date < $1.week10.date }) {
            note("  W10 \(s.week10.dayLabel ?? "?") \(s.week10.date.formatted(date: .abbreviated, time: .omitted)) <- W7 \(s.week7.dayLabel ?? "?") (\(s.pairs.count) items)")
        }
        note("CREATE weeks 11-12 (\(plan.creates.count) sessions, \(plan.creates.reduce(0) { $0 + $1.source.items.count }) items), cloned from weeks 8/9 +\(shiftDays) days:")
        for c in plan.creates.sorted(by: { $0.newDate < $1.newDate }) {
            note("  W\(c.newWeek) \(c.source.dayLabel ?? "?") \(c.newDate.formatted(date: .abbreviated, time: .omitted)) programIndex \(c.newProgramIndex.map(String.init) ?? "nil") <- W\(c.source.weekIndex)")
        }
        if let first = plan.creates.map(\.newDate).min(), let last = plan.creates.map(\.newDate).max() {
            note("New weeks span \(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)).")
        }
        note("block.totalWeeks \(block.totalWeeks.map(String.init) ?? "nil") -> \(targetTotalWeeks); name '\(block.name)' -> '\(block.name.replacingOccurrences(of: "10-Week", with: "12-Week"))'.")
        note("Projected chains: 1→4→7→10, 2→5→8→11, 3→6→9→12 (run verifyChains after apply).")
        return plan
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

    /// Prescription + plan shape only. Loads are zeroed; actuals, feedback, PR, coach notes and
    /// override reasons are never copied; `planEdited` stays false.
    private static func copyPrescription(from src: SessionItem, to dst: SessionItem) {
        dst.order = src.order
        dst.targetReps = src.targetReps
        dst.targetSets = src.targetSets
        dst.targetRIR = src.targetRIR
        dst.suggestedLoad = 0
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
        dst.plannedRepsBySet = resized(src.plannedRepsBySet, to: src.targetSets, fill: src.targetReps)
        dst.plannedRIRsBySet = resized(src.plannedRIRsBySet, to: src.targetSets, fill: src.targetRIR)
        dst.plannedLoadsBySet = Array(repeating: 0.0, count: max(0, src.targetSets))
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

    private static func cloneItem(_ src: SessionItem) -> SessionItem {
        let item = SessionItem(
            order: src.order,
            exerciseId: src.exerciseId,
            exerciseNameSnapshot: src.exerciseNameSnapshot,
            targetReps: src.targetReps,
            targetSets: src.targetSets,
            targetRIR: src.targetRIR,
            suggestedLoad: 0
        )
        copyPrescription(from: src, to: item)
        return item
    }

    private static func resized<T>(_ array: [T], to count: Int, fill: T) -> [T] {
        let n = max(0, count)
        if array.count == n { return array }
        if array.count > n { return Array(array.prefix(n)) }
        return array + Array(repeating: array.last ?? fill, count: n - array.count)
    }
}
