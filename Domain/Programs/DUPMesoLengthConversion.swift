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
        let sessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        func week(_ w: Int) -> [Session] { sessions.filter { $0.weekIndex == w }.sorted { $0.date < $1.date } }

        // Already converted: totalWeeks 12 and weeks 11/12 present -> no-op.
        if block.totalWeeks == targetTotalWeeks, !week(11).isEmpty, !week(12).isEmpty {
            plan.report.alreadyConverted = true
            note("NO-OP: block is already \(targetTotalWeeks) weeks with weeks 11-12 present.")
            return finish(unevaluated: allGateNames)
        }

        gate(allGateNames[0], detail: "'\(block.name)', \(sessions.count) sessions") {
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
        note("CONVERT week 10 in place (\(plan.converts.count) sessions, \(plan.converts.reduce(0) { $0 + $1.pairs.count }) items): waveRaw deload -> a; prescription copied from week 7; loads zeroed.")
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
                var after = desc(src)
                after = after.replacingOccurrences(of: #"load [0-9.]+"#, with: "load 0", options: .regularExpression)
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
        note("Projected chains: 1→4→7→10, 2→5→8→11, 3→6→9→12 (run verifyChains after apply).")
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
