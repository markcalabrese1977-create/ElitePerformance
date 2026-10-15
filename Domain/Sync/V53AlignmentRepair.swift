// Domain/Sync/V53AlignmentRepair.swift
import Foundation
import SwiftData

/// One-shot repair: align the active, converted 12-week block to program v5.3 (supersedes v5.2 from week 4,
/// Fri Oct 16). Same pattern as `V52AlignmentRepair`: gates, snapshot-and-restore rollback, autosave off, its own
/// fresh `ModelContext`, completion flag only after a verified save, a full launch log.
///
/// Waves: A = weeks 4, 7, 10 · B = 5, 8, 11 · C = 6, 9, 12. Scope is weeks 4-12 of the single active regular block;
/// planned, unlogged sessions only (any other session is skipped whole and listed).
///
///  * L1  Legs A hack squat -> Single Leg Press, in place (id kept), per-wave prescription and load.
///  * L2  Legs A Smith Split Squat -> built-in Leg Press, in place, load 0.
///  * L3  Legs A renumbered: lying curl 1, single-leg press 2, leg press 3, leg extension 4, seated calf 5.
///  * L4  Legs A Cable Hip Adduction deleted (the CustomExercise row stays).
///  * P1  Pull A pull-up RIR 2 in A weeks.   S1  Push A / Push B rope pushdown load 75.
///  * N1-N5 note-only edits (Push B decline, Push A long head, Legs B hip thrust, Pull B pulldown, Pull B lateral).
///
/// Items with `planEdited` never get sets / reps / RIR / loads changed (the numbers are skipped and listed); notes
/// and order are allowed. A Legs A session whose hack squat, Smith Split Squat or adduction item is planEdited is
/// skipped whole (its replace / delete can't be partial).
///
/// Live run: plan (every gate, nothing written) -> apply (autosave off, pending-changes refusal, snapshot, mutate,
/// verify the whole result, ONE save). Any failed verification or failed save restores every written field and
/// re-attaches every deleted item. No custom exercise is created: every target already exists.
/// Ships DRY RUN (`dryRun = true`): reports once, writes nothing.
enum V53AlignmentRepair {

    /// true = read-only report. Arm by flipping to false after the dry-run report has been reviewed.
    static let dryRun = true

    /// Bump when the REPORT changes, so a changed report logs again instead of being swallowed by the
    /// previous install's "already logged" flag.
    static let reportVersion = "v1"

    static let completionKey = "v53AlignmentRepair.v1.completed"
    static var dryRunLoggedKey: String { "v53AlignmentRepair.v1.dryRunLogged.\(reportVersion)" }
    static var reportKey: String { "v53AlignmentRepair.v1.dryRunReport.\(reportVersion)" }

    static let firstWeek = 4
    static let lastWeek = 12
    static let expectedTotalWeeks = 12
    static let expectedSessionCount = 72

    typealias Rx = V52AlignmentRepair.Rx
    typealias WaveRx = V52AlignmentRepair.WaveRx
    typealias ApplyHooks = V52AlignmentRepair.ApplyHooks

    // MARK: - Specification (v5.3)

    private static let pushA = "Push A", legsA = "Legs A", pullA = "Pull A"
    private static let pushB = "Push B", legsB = "Legs B", pullB = "Pull B"
    private static let dayOrder = [pushA, legsA, pullA, pushB, legsB, pullB]

    static let hackSquatId = "hack_squat"
    static let singleLegPressId = "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef"
    static let smithSplitSquatId = "custom_8f31d954-1bd8-4883-acf5-d3041e6ea04b"
    static let legExtensionId = "leg_extension"
    static let seatedCalfId = "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822"
    static let lyingLegCurlId = "lying_leg_curl"
    static let hipAdductionId = "custom_e7c47a0c-b6c3-434b-bf34-8893edfd9fd5"
    /// Built-in bilateral leg press (NOT the custom "Leg Press [Gym]").
    static let legPressId = "leg_press"
    static let pullUpId = "pull_up"
    static let pushdownId = "cable_tricep_rope_pushdown"
    static let declineBenchId = "decline_bench_press"
    static let longHeadId = "custom_bf720451-0d6b-4d68-8a55-c25286b25c80"
    static let hipThrustId = "custom_7f4ffc44-7aea-449f-87d9-41e76f2f3361"
    static let saPulldownId = "custom_fdd7dfeb-24ba-4795-b00b-0d89e1a52005"
    static let dbLateralRaiseId = "dumbbell_lateral_raise"

    /// v5.2 Legs A shape: (exercise, order).
    static let legsPreShape: [(id: String, order: Int)] = [
        (hackSquatId, 1), (smithSplitSquatId, 2), (legExtensionId, 3), (seatedCalfId, 4), (lyingLegCurlId, 14), (hipAdductionId, 15)
    ]
    /// v5.3 Legs A shape.
    static let legsPostShape: [(id: String, order: Int)] = [
        (lyingLegCurlId, 1), (singleLegPressId, 2), (legPressId, 3), (legExtensionId, 4), (seatedCalfId, 5)
    ]

    static let l1Rx = WaveRx(a: Rx(4, 6, 8, rir: 1, 2), b: Rx(3, 8, 10, rir: 2), c: Rx(3, 10, 15, rir: 2))
    static func l1Load(_ wave: WaveType) -> Double {
        switch wave {
        case .a: return 440
        case .b: return 410
        case .c: return 385
        case .deload: return 0
        }
    }
    static let l2Rx = WaveRx(a: Rx(2, 8, 10, rir: 2), b: Rx(2, 10, 12, rir: 2), c: Rx(2, 12, 15, rir: 2))

    static let l1Note = "Primary while hack squat is pulled. Left first, match right. Openers from R1 e1RM ~570."
    static let l2Note = "Pain-free warm-up gate: lateral hip > 2/10 -> skip, no substitute."
    static let l3Note = "First, so hamstrings are fresh at full flexion (cramp history). Electrolytes 30-45 min pre-session."

    /// P1 target RIR in the A weeks (was 3).
    static let pullUpRIR = 2
    /// S1 rope pushdown load, lb (rehab track).
    static let pushdownLoad = 75.0

    struct SimpleOp {
        let key: String
        let day: String
        let exerciseId: String
        /// P1: set the RIR to this value in the waves listed in `rirWaves`.
        var rirTo: Int? = nil
        var rirWaves: Set<String> = []
        /// S1: set suggestedLoad and the planned loads to this value.
        var loadTo: Double? = nil
        /// The new note. With `noteOld` set, only that phrase is replaced inside the existing note.
        let note: String
        var noteOld: String? = nil
    }

    static let simpleOps: [SimpleOp] = [
        SimpleOp(key: "P1", day: pullA, exerciseId: pullUpId, rirTo: pullUpRIR, rirWaves: ["a"],
                 note: "Strict, no kip, no dead-hang, BW, 2 RIR. If < 1 rep/set gain across R2, add a 3-s eccentric."),
        SimpleOp(key: "S1", day: pushA, exerciseId: pushdownId, loadTo: pushdownLoad,
                 note: "Rehab track, shortened range. Hold 75 for the first two Push A exposures with the long-head extension. Exit: ~95-100 lb pain-free x 2 weeks graduates it."),
        SimpleOp(key: "S1", day: pushB, exerciseId: pushdownId, loadTo: pushdownLoad,
                 note: "Rehab track, shortened range. Hold 75 for the first two Push A exposures with the long-head extension. Exit: ~95-100 lb pain-free x 2 weeks graduates it."),
        SimpleOp(key: "N1", day: pushB, exerciseId: declineBenchId,
                 note: "4th set earnable (see Earned Volume).", noteOld: "3 sets during the cut."),
        SimpleOp(key: "N2", day: pushA, exerciseId: longHeadId,
                 note: "Light fixed load first 2 exposures; anchor after. Cable low/behind; upper arm ~45-60 deg forward of vertical, not pinned overhead; neutral D-handle; stop short of any elbow pinch. Right elbow > 2/10 next morning -> removed."),
        SimpleOp(key: "N3", day: legsB, exerciseId: hipThrustId,
                 note: "Gated: back 0-1/10 and lateral hip <= 2/10 in warm-ups. Next-morning stairs/side-lying worse -> hold load next time. Not cleared -> leg curl to 4 sets. Neutral-spine lockout."),
        SimpleOp(key: "N4", day: pullB, exerciseId: saPulldownId,
                 note: "Left first, left caps reps. Log right-arm RIR each session. Shoulder blade down/back first; 1-s pause + slow eccentric on left."),
        SimpleOp(key: "N5", day: pullB, exerciseId: dbLateralRaiseId,
                 note: "Lengthened-bias setup (lean-away or side-lying incline).")
    ]

    static let opKeys = ["L1", "L2", "L3", "L4", "P1", "S1", "N1", "N2", "N3", "N4", "N5"]

    // MARK: - Report

    typealias Gate = V52AlignmentRepair.Gate

    struct Report {
        var gates: [Gate] = []
        var blockers: [String] = []
        var lines: [String] = []
        var skipped: [String] = []
        var opLines: [String] = []
        var noteLines: [String] = []
        var rosterLines: [String] = []
        var chainTable: [String] = []
        var verification: [String] = []
        var postWriteChainTable: [String] = []

        var shape = ""
        var alreadyAligned = false

        /// Items changed per op key (L3 counts sessions renumbered).
        var counts: [String: Int] = [:]
        /// Items (sessions for L3) the op applies to in sessions that are planned and unlogged, before skips.
        var inScope: [String: Int] = [:]
        var alreadyApplied = 0
        var planEditedInScope = 0
        var planEditedNoteOnly = 0
        var didWrite = false

        var isSafe: Bool { blockers.isEmpty }

        var text: String {
            var out: [String] = []
            out.append("== SHAPE == \(shape)")
            out.append("== GATES ==")
            out += gates.map { "[\($0.status.rawValue)] \($0.name)\($0.detail.isEmpty ? "" : " — \($0.detail)")" }
            if !blockers.isEmpty { out.append("== BLOCKERS =="); out += blockers.map { "  ! \($0)" } }
            out.append("== LIVE APPLY == " + (blockers.isEmpty ? "allowed (every gate passes)" : "refused: \(blockers.count) blocker(s)"))
            out.append("== SUMMARY =="); out += lines
            if !skipped.isEmpty { out.append("== SKIPPED (\(skipped.count)) =="); out += skipped.map { "  \($0)" } }
            if !opLines.isEmpty { out.append("== WRITES, per item (before -> after) =="); out += opLines }
            if !noteLines.isEmpty { out.append("== NOTES (previous text -> new text) =="); out += noteLines }
            if !rosterLines.isEmpty { out.append("== LEGS A ROSTER, projected =="); out += rosterLines }
            if !chainTable.isEmpty { out.append("== PROJECTED CHAINS =="); out += chainTable }
            return out.joined(separator: "\n")
        }
    }

    // MARK: - Plan

    private struct Replace {
        let toId: String
        let toName: String
        let rx: Rx
        let load: Double
    }

    private struct ItemPlan {
        let item: SessionItem
        let session: Session
        let week: Int
        var keys: [String] = []
        var replace: Replace?
        var rirTo: Int?
        var loadTo: Double?
        var newOrder: Int?
        var newNote: String?
        var delete = false

        /// Fields this plan may write; anything else changing on the item fails verification.
        var allowedFields: Set<String> {
            var f: Set<String> = ["updatedAt"]
            if replace != nil {
                f.formUnion(["exerciseId", "exerciseNameSnapshot", "order", "targetReps", "targetSets", "targetRIR", "suggestedLoad",
                             "setMin", "setMax", "repMin", "repMax", "targetRIRMin", "targetRIRMax", "intensifierRaw", "intensifierNotes",
                             "prescriptionNotes", "plannedRepsBySet", "plannedRIRsBySet", "plannedLoadsBySet", "planEdited", "actualReps",
                             "actualLoads", "actualRIRs", "usedRestPauseFlags", "restPausePatternsBySet", "dropSetPatternsBySet",
                             "setFeedbackBySet", "pumpRatingsBySet", "coachNote", "loadOverrideReasonRaw", "nextSuggestedLoad"])
            }
            if rirTo != nil { f.formUnion(["targetRIR", "targetRIRMin", "targetRIRMax", "plannedRIRsBySet"]) }
            if loadTo != nil { f.formUnion(["suggestedLoad", "plannedLoadsBySet"]) }
            if newOrder != nil { f.insert("order") }
            if newNote != nil { f.insert("prescriptionNotes") }
            return f
        }
    }

    private struct Plan {
        var items: [ItemPlan] = []
        var index: [PersistentIdentifier: Int] = [:]
        var report = Report()

        var written: [ItemPlan] { items.filter { !$0.delete } }
        var deleted: [ItemPlan] { items.filter(\.delete) }

        mutating func edit(_ item: SessionItem, session: Session, week: Int, _ change: (inout ItemPlan) -> Void) {
            if let i = index[item.persistentModelID] {
                change(&items[i])
            } else {
                var p = ItemPlan(item: item, session: session, week: week)
                change(&p)
                index[item.persistentModelID] = items.count
                items.append(p)
            }
        }
    }

    // MARK: - Waves

    /// A = 4, 7, 10 · B = 5, 8, 11 · C = 6, 9, 12 (same as V52).
    static func wave(forWeek week: Int) -> WaveType { V52AlignmentRepair.wave(forWeek: week) }

    // MARK: - Public API

    /// Runs every check and describes every write. Mutates nothing.
    static func dryRun(block: MesoBlock, context: ModelContext, defaults: UserDefaults = .standard) -> Report {
        makePlan(block: block, context: context, defaults: defaults).report
    }

    enum ApplyError: Error, CustomStringConvertible {
        case pendingChanges
        case verificationFailed([String])
        case saveFailed(String)
        case planUnsafe([String])

        var description: String {
            switch self {
            case .pendingChanges: return "context had unsaved changes before apply; refusing so a rollback can never discard them"
            case .verificationFailed(let f): return "post-mutation verification failed (rolled back): " + f.joined(separator: "; ")
            case .saveFailed(let e): return "save failed (rolled back): \(e)"
            case .planUnsafe(let b): return "plan has blockers: " + b.joined(separator: "; ")
            }
        }
    }

    /// Applies the plan if (and only if) it is safe and live apply is allowed. Plan -> (autosave off) ->
    /// mutate -> verify the whole result -> ONE save. Any failure after the first mutation restores the store.
    @discardableResult
    static func apply(block: MesoBlock, context: ModelContext, defaults: UserDefaults = .standard,
                      hooks: ApplyHooks = ApplyHooks()) throws -> Report {
        var plan = makePlan(block: block, context: context, defaults: defaults)
        guard plan.report.isSafe else { throw ApplyError.planUnsafe(plan.report.blockers) }
        guard !plan.report.alreadyAligned else { return plan.report }
        guard !context.hasChanges else { throw ApplyError.pendingChanges }

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let before = Baseline(context: context, block: block)
        let snapshot = Snapshot(items: plan.items.map(\.item))

        // Mutate.
        for p in plan.items {
            let item = p.item
            if p.delete {
                p.session.items.removeAll { $0 === item }
                context.delete(item)
                continue
            }
            if let r = p.replace { writeReplace(item, r) }
            if let r = p.rirTo { writeRIR(item, r) }
            if let l = p.loadTo { writeLoad(item, l) }
            if let o = p.newOrder { item.order = o }
            if let n = p.newNote { item.prescriptionNotes = n }
            item.updatedAt = Date()
        }

        func undo() {
            snapshot.restore()
            context.rollback()
            // A rollback revives deleted objects; make sure they are back in their session either way.
            for p in plan.deleted where !p.session.items.contains(where: { $0 === p.item }) {
                p.session.items.append(p.item)
            }
        }

        hooks.beforeVerify?(context)

        let result = verify(block: block, context: context, plan: plan, before: before)
        plan.report.verification = result.lines
        plan.report.postWriteChainTable = result.chainTable
        guard result.failures.isEmpty else {
            undo()
            throw ApplyError.verificationFailed(result.failures)
        }
        do {
            try hooks.save(context)
        } catch {
            undo()
            throw ApplyError.saveFailed("\(error)")
        }
        plan.report.didWrite = true
        plan.report.lines.append("WROTE: " + countsLine(plan.report))
        return plan.report
    }

    // MARK: - Planner

    private static func normalizedLabel(_ s: Session) -> String { (s.dayLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func canonical(_ id: String) -> String { ExerciseCatalog.canonicalExerciseId(for: id) }

    private static func blockSessions(block: MesoBlock, context: ModelContext) -> [Session] {
        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        return all.filter { $0.meso?.persistentModelID == block.persistentModelID }
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains {
            $0.isCompleted || !$0.logs.isEmpty || $0.actualLoads.contains { $0 > 0 } || $0.actualReps.contains { $0 > 0 }
        }
    }

    private static func fmtLoad(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private static func desc(_ i: SessionItem) -> String {
        let reps = (i.repMin != nil && i.repMax != nil) ? (i.repMin == i.repMax ? "\(i.repMin!)" : "\(i.repMin!)-\(i.repMax!)") : "\(i.targetReps)"
        let rir = (i.targetRIRMin != nil && i.targetRIRMax != nil) ? (i.targetRIRMin == i.targetRIRMax ? "\(i.targetRIRMin!)" : "\(i.targetRIRMin!)-\(i.targetRIRMax!)") : "\(i.targetRIR)"
        return "\(i.targetSets)x\(reps) @\(rir) L\(fmtLoad(i.suggestedLoad))"
    }

    private static func countsLine(_ r: Report) -> String {
        opKeys.map { "\($0) \(r.counts[$0, default: 0])" }.joined(separator: ", ")
    }

    private static func rirIsApplied(_ i: SessionItem, _ rir: Int) -> Bool {
        i.targetRIR == rir && i.targetRIRMin == rir && i.targetRIRMax == rir
            && !i.plannedRIRsBySet.isEmpty && i.plannedRIRsBySet.allSatisfy { $0 == rir }
    }

    private static func loadIsApplied(_ i: SessionItem, _ load: Double) -> Bool {
        i.suggestedLoad == load && i.plannedLoadsBySet.count == i.targetSets && i.plannedLoadsBySet.allSatisfy { $0 == load }
    }

    private static func makePlan(block: MesoBlock, context: ModelContext, defaults: UserDefaults) -> Plan {
        var plan = Plan()
        func fail(_ s: String) { plan.report.blockers.append(s) }
        func note(_ s: String) { plan.report.lines.append(s) }
        func skip(_ s: String) { plan.report.skipped.append(s) }
        let gateNames = [
            "exactly one active non-maintenance block, and it is this one",
            "block shape: totalWeeks 12, 72 sessions",
            "V52 completion flag set (\(V52AlignmentRepair.completionKey))",
            "weeks 4-12: one session per day per week; wave letters match the week (A 4,7,10 · B 5,8,11 · C 6,9,12)",
            "targets exist: Single Leg Press (custom row), Leg Press (built-in)",
            "every Legs A session in weeks 4-12 has exactly the v5.2 roster (or the v5.3 one, already applied)",
            "every op source item found exactly once per session",
            "no order ties in the projected rosters"
        ]
        var gateIdx = 0
        func gate(_ detail: String = "", _ body: () -> Void) {
            let before = plan.report.blockers.count
            body()
            let added = plan.report.blockers.count - before
            plan.report.gates.append(Gate(name: gateNames[gateIdx], status: added == 0 ? .passed : .failed,
                                          detail: added == 0 ? detail : "\(added) blocker(s)"))
            gateIdx += 1
        }
        func finish() -> Plan {
            while gateIdx < gateNames.count {
                plan.report.gates.append(Gate(name: gateNames[gateIdx], status: .notEvaluated, detail: "")); gateIdx += 1
            }
            return plan
        }

        let sessions = blockSessions(block: block, context: context)
        let weeks = firstWeek...lastWeek
        plan.report.shape = "'\(block.name)' totalWeeks \(block.totalWeeks.map(String.init) ?? "nil"), \(sessions.count) sessions; scope weeks \(firstWeek)-\(lastWeek)"

        // Gate 0.
        gate("'\(block.name)' [\(block.id.map { String($0.uuidString.prefix(8)) } ?? "no id")]") {
            let blocks = (try? context.fetch(FetchDescriptor<MesoBlock>())) ?? []
            let active = blocks.filter { $0.status == .active && !$0.isMaintenance }
            if active.count != 1 { fail("\(active.count) active non-maintenance blocks, expected exactly 1") }
            else if active[0].persistentModelID != block.persistentModelID { fail("the single active block is not the block under repair") }
            if block.status != .active { fail("block status is \(block.status.rawValue), not active") }
            if block.isMaintenance { fail("block is a maintenance block") }
        }
        // Gate 1.
        gate("\(sessions.count) sessions") {
            if block.totalWeeks != expectedTotalWeeks { fail("totalWeeks is \(block.totalWeeks.map(String.init) ?? "nil"), expected \(expectedTotalWeeks)") }
            if sessions.count != expectedSessionCount { fail("\(sessions.count) sessions, expected \(expectedSessionCount)") }
        }
        // Gate 2.
        gate() {
            if !defaults.bool(forKey: V52AlignmentRepair.completionKey) { fail("\(V52AlignmentRepair.completionKey) is not set") }
        }

        // Gate 3: resolve (day, week) -> session; waves.
        var sessionAt: [String: [Int: Session]] = [:]
        gate("6 days × \(weeks.count) weeks") {
            for day in dayOrder {
                for w in weeks {
                    let found = sessions.filter { normalizedLabel($0) == day && $0.weekIndex == w }
                    if found.count != 1 { fail("\(day) wk\(w): expected exactly 1 session, found \(found.count)"); continue }
                    let s = found[0]
                    sessionAt[day, default: [:]][w] = s
                    let waves = Set(s.items.compactMap { $0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() })
                    if waves != [wave(forWeek: w).rawValue] { fail("\(day) wk\(w): waves are \(waves.sorted()), expected [\(wave(forWeek: w).rawValue)]") }
                }
            }
        }
        if !plan.report.isSafe { return finish() }

        // Gate 4: targets.
        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        var slpName = ""
        var legPressName = ""
        gate() {
            if let row = customs.first(where: { canonical($0.id) == canonical(singleLegPressId) }), !row.name.isEmpty {
                slpName = row.name
            } else {
                fail("no CustomExercise row \(singleLegPressId)")
            }
            if let built = ExerciseCatalog.all.first(where: { $0.id == legPressId }), built.name == "Leg Press" {
                legPressName = built.name
            } else {
                fail("built-in \(legPressId) 'Leg Press' is not in the catalog")
            }
        }

        // Session status is shared by every op below.
        func sessionSkipReason(_ s: Session) -> String? {
            if s.status != .planned || hasLoggedData(s) {
                return "session is \(s.status.rawValue)\(hasLoggedData(s) ? " with logged data" : "")"
            }
            return nil
        }
        func fmtDate(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        func tag(_ s: Session, _ w: Int) -> String { "wk\(w) \(normalizedLabel(s)) \(fmtDate(s.date)) [\(wave(forWeek: w).displayName)]" }

        var projected: [String: [Int: [(id: String, order: Int)]]] = [:]
        var legsShape: [Int: Bool] = [:]    // week -> true = v5.2 shape, false = v5.3 (already applied)

        // Gate 5: Legs A roster, every session in scope regardless of status.
        gate() {
            for w in weeks {
                guard let s = sessionAt[legsA]?[w] else { continue }
                let have = s.items.map { (id: canonical($0.exerciseId), order: $0.order) }.sorted { $0.order < $1.order }
                func matches(_ shape: [(id: String, order: Int)]) -> Bool {
                    let want = shape.map { (id: canonical($0.id), order: $0.order) }.sorted { $0.order < $1.order }
                    return have.count == want.count && zip(have, want).allSatisfy { $0.id == $1.id && $0.order == $1.order }
                }
                if matches(legsPreShape) { legsShape[w] = true }
                else if matches(legsPostShape) { legsShape[w] = false }
                else { fail("\(tag(s, w)): roster is " + have.map { "o\($0.order) \($0.id)" }.joined(separator: ", ") + " — neither the v5.2 nor the v5.3 shape") }
            }
        }
        if !plan.report.isSafe { return finish() }

        // Gate 6 + the plan itself.
        gate("\(simpleOps.count) simple ops + L1-L4") {
            for day in dayOrder {
                for w in weeks {
                    guard let session = sessionAt[day]?[w] else { continue }
                    let waveType = wave(forWeek: w)
                    let t = tag(session, w)
                    var roster = session.items.map { (id: canonical($0.exerciseId), order: $0.order) }
                    let skipReason = sessionSkipReason(session)
                    plan.report.planEditedInScope += session.items.filter(\.planEdited).count

                    // Resolve the simple ops first: exactly one source item, or a blocker.
                    var found: [(op: SimpleOp, item: SessionItem)] = []
                    for op in simpleOps where op.day == day {
                        let m = session.items.filter { canonical($0.exerciseId) == canonical(op.exerciseId) }
                        guard m.count == 1 else { fail("\(t): \(op.key) expects exactly 1 \(op.exerciseId), found \(m.count)"); continue }
                        found.append((op, m[0]))
                    }

                    if let skipReason {
                        var keys = found.map(\.op.key)
                        if day == legsA, legsShape[w] == true { keys += ["L1", "L2", "L3", "L4"] }
                        if !keys.isEmpty { skip("\(t): \(skipReason) — \(keys.joined(separator: ",")) not applied") }
                        projected[day, default: [:]][w] = roster
                        continue
                    }

                    // ---- Legs A: L1-L4 ----
                    if day == legsA {
                        if legsShape[w] == false {
                            plan.report.alreadyApplied += 4
                        } else {
                            let byId = Dictionary(uniqueKeysWithValues: session.items.map { (canonical($0.exerciseId), $0) })
                            let hack = byId[canonical(hackSquatId)]!, smith = byId[canonical(smithSplitSquatId)]!
                            let ext = byId[canonical(legExtensionId)]!, calf = byId[canonical(seatedCalfId)]!
                            let curl = byId[canonical(lyingLegCurlId)]!, adduction = byId[canonical(hipAdductionId)]!
                            plan.report.inScope["L1", default: 0] += 1; plan.report.inScope["L2", default: 0] += 1
                            plan.report.inScope["L3", default: 0] += 1; plan.report.inScope["L4", default: 0] += 1
                            let editedTargets = [hack, smith, adduction].filter(\.planEdited)
                            if !editedTargets.isEmpty {
                                skip("\(t): L1-L4 skipped — planEdited on \(editedTargets.map { $0.exerciseNameSnapshot ?? $0.exerciseId }.joined(separator: ", ")) (replace / delete can't be partial)")
                            } else {
                                let r1 = Replace(toId: singleLegPressId, toName: slpName, rx: l1Rx.rx(for: waveType)!, load: l1Load(waveType))
                                let r2 = Replace(toId: legPressId, toName: legPressName, rx: l2Rx.rx(for: waveType)!, load: 0)
                                plan.edit(hack, session: session, week: w) { $0.keys += ["L1", "L3"]; $0.replace = r1; $0.newOrder = 2; $0.newNote = l1Note }
                                plan.edit(smith, session: session, week: w) { $0.keys += ["L2", "L3"]; $0.replace = r2; $0.newOrder = 3; $0.newNote = l2Note }
                                plan.edit(curl, session: session, week: w) { $0.keys += ["L3"]; $0.newOrder = 1; $0.newNote = l3Note }
                                plan.edit(ext, session: session, week: w) { $0.keys += ["L3"]; $0.newOrder = 4 }
                                plan.edit(calf, session: session, week: w) { $0.keys += ["L3"]; $0.newOrder = 5 }
                                plan.edit(adduction, session: session, week: w) { $0.keys += ["L4"]; $0.delete = true }
                                for k in ["L1", "L2", "L3", "L4"] { plan.report.counts[k, default: 0] += 1 }
                                roster = legsPostShape.map { (canonical($0.id), $0.order) }
                            }
                        }
                    }

                    // ---- simple ops ----
                    for (op, item) in found {
                        if op.rirTo != nil, !op.rirWaves.contains(waveType.rawValue) { continue }
                        plan.report.inScope[op.key, default: 0] += 1

                        var rirTo: Int?
                        var loadTo: Double?
                        var newNote: String?
                        if let r = op.rirTo, !rirIsApplied(item, r) { rirTo = r }
                        if let l = op.loadTo, !loadIsApplied(item, l) { loadTo = l }
                        let oldNote = item.prescriptionNotes ?? ""
                        if let phrase = op.noteOld {
                            if oldNote.contains(op.note) { /* already applied */ }
                            else if oldNote.contains(phrase) { newNote = oldNote.replacingOccurrences(of: phrase, with: op.note) }
                            else { skip("\(t): \(op.key) note skipped — existing note '\(oldNote)' does not contain '\(phrase)'") }
                        } else if oldNote != op.note {
                            newNote = op.note
                        }
                        if item.planEdited, rirTo != nil || loadTo != nil {
                            skip("\(t): \(op.key) \(item.exerciseNameSnapshot ?? item.exerciseId) numbers skipped — planEdited\(newNote != nil ? " (note applied)" : "")")
                            rirTo = nil; loadTo = nil
                            if newNote != nil { plan.report.planEditedNoteOnly += 1 }
                        } else if item.planEdited, newNote != nil {
                            plan.report.planEditedNoteOnly += 1
                        }
                        guard rirTo != nil || loadTo != nil || newNote != nil else { plan.report.alreadyApplied += 1; continue }
                        plan.edit(item, session: session, week: w) {
                            $0.keys.append(op.key); $0.rirTo = rirTo; $0.loadTo = loadTo; $0.newNote = newNote
                        }
                        // A numeric op counts only when its numbers change; a planEdited item that takes just the note is
                        // reported separately (planEditedNoteOnly).
                        if op.rirTo == nil && op.loadTo == nil || rirTo != nil || loadTo != nil {
                            plan.report.counts[op.key, default: 0] += 1
                        }
                    }
                    projected[day, default: [:]][w] = roster
                }
            }
        }

        // Per-item lines, in session order.
        for p in plan.items.sorted(by: { ($0.week, dayOrder.firstIndex(of: normalizedLabel($0.session)) ?? 0, $0.item.order)
                                          < ($1.week, dayOrder.firstIndex(of: normalizedLabel($1.session)) ?? 0, $1.item.order) }) {
            plan.report.opLines.append("  " + tag(p.session, p.week) + " | " + p.keys.joined(separator: "+") + " | " + lineBody(p))
        }
        plan.report.noteLines = noteLines(plan)

        // Gate 7: order ties.
        gate() {
            for day in dayOrder {
                for w in weeks {
                    let orders = (projected[day]?[w] ?? []).map(\.order)
                    if Set(orders).count != orders.count { fail("\(day) wk\(w): projected roster has order tie(s)") }
                }
            }
        }

        // Summary.
        plan.report.alreadyAligned = plan.items.isEmpty && plan.report.isSafe
        note("Block '\(block.name)': \(sessions.count) sessions; scope weeks \(firstWeek)-\(lastWeek).")
        note("PLAN (changed / in scope): " + opKeys.map { "\($0) \(plan.report.counts[$0, default: 0])/\(plan.report.inScope[$0, default: 0])" }.joined(separator: ", ") + ".")
        note("L3 counts sessions renumbered; L4 counts items deleted. Already applied: \(plan.report.alreadyApplied). Sessions/slots skipped: \(plan.report.skipped.count).")
        note("planEdited items in scope weeks 4-12: \(plan.report.planEditedInScope) (numbers never touched); note-only edits applied to \(plan.report.planEditedNoteOnly) of them.")
        if plan.report.alreadyAligned { note("NO-OP: nothing left to change in scope.") }

        // Projected Legs A roster (wk 4 / 5 / 6 are representative; every session in scope gets the same shape).
        for w in [4, 5, 6] {
            guard let s = sessionAt[legsA]?[w], let items = projected[legsA]?[w] else { continue }
            _ = s
            plan.report.rosterLines.append("  wk\(w) [\(wave(forWeek: w).displayName)]: " + items.sorted { $0.order < $1.order }.map { "o\($0.order) \($0.id)" }.joined(separator: " · "))
        }

        // Projected chains (structure only), per day and letter.
        let letters: [(String, [Int])] = [("A", [4, 7, 10]), ("B", [5, 8, 11]), ("C", [6, 9, 12])]
        for day in dayOrder {
            for (letter, wks) in letters {
                var hops: [String] = []
                for (a, b) in zip(wks, wks.dropFirst()) {
                    guard let ra = projected[day]?[a], let rb = projected[day]?[b] else { hops.append("W\(a)→W\(b) MISSING"); continue }
                    let sa = Set(ra.map(\.id)), sb = Set(rb.map(\.id))
                    hops.append("W\(a)→W\(b) \(sa.intersection(sb).count)/\(sa.count)")
                }
                plan.report.chainTable.append("  \(day) / \(letter): " + wks.map { "W\($0)" }.joined(separator: "→") + "→nil   links: " + hops.joined(separator: ", "))
            }
        }
        for (name, id) in [("single leg press", singleLegPressId), ("leg press", legPressId)] {
            var parts: [String] = []
            for (letter, wks) in letters {
                let carrying = wks.filter { w in projected[legsA]?[w]?.contains { $0.id == canonical(id) } == true }
                parts.append("\(letter) " + carrying.map { "W\($0)" }.joined(separator: "→") + "→nil")
            }
            plan.report.chainTable.append("  NEW \(legsA) \(name): " + parts.joined(separator: ", "))
        }
        plan.report.chainTable.append("  NOTE: weeks 1-3 single-leg-press items (logged) link forward into W4/W5/W6 again; weeks 1-3 hack-squat items become dead ends (hack squat is pulled).")
        return finish()
    }

    /// One line per (op, previous text, new text), with the weeks it covers. The note belongs to the op that comes first
    /// in the item's key list (L1 for the single-leg press, L2 for the leg press, L3 for the lying curl).
    private static func noteLines(_ plan: Plan) -> [String] {
        var groups: [String: (key: String, old: String, new: String, weeks: [Int])] = [:]
        for p in plan.items {
            guard let new = p.newNote, let key = p.keys.first else { continue }
            let old = p.item.prescriptionNotes ?? "(none)"
            let g = "\(key)|\(old)|\(new)"
            groups[g, default: (key, old, new, [])].weeks.append(p.week)
        }
        return groups.values
            .sorted { (opKeys.firstIndex(of: $0.key) ?? 0, $0.old) < (opKeys.firstIndex(of: $1.key) ?? 0, $1.old) }
            .map { "  \($0.key) ×\($0.weeks.count) (wk \($0.weeks.sorted().map(String.init).joined(separator: ","))): '\($0.old)' -> '\($0.new)'" }
    }

    private static func lineBody(_ p: ItemPlan) -> String {
        let item = p.item
        let name = item.exerciseNameSnapshot ?? item.exerciseId
        if p.delete { return "o\(item.order) DELETE \(name) \(desc(item))" }
        var parts: [String] = []
        if let r = p.replace {
            parts.append("o\(item.order) \(name) \(desc(item))  ->  \(r.toName) \(r.rx.label) L\(fmtLoad(r.load))")
        } else {
            var change: [String] = []
            if let r = p.rirTo { change.append("RIR \(item.targetRIR)->\(r)") }
            if let l = p.loadTo { change.append("load \(fmtLoad(item.suggestedLoad))->\(fmtLoad(l))") }
            parts.append("o\(item.order) \(name) \(desc(item))" + (change.isEmpty ? "" : "  ->  " + change.joined(separator: ", ")))
        }
        if let o = p.newOrder, o != item.order { parts.append("order \(item.order)->\(o)") }
        if p.newNote != nil { parts.append("note") }
        return parts.joined(separator: "; ")
    }

    // MARK: - Item writes

    private static func writeReplace(_ item: SessionItem, _ r: Replace) {
        let rx = r.rx
        item.exerciseId = r.toId
        item.exerciseNameSnapshot = r.toName
        item.targetSets = rx.sets
        item.setMin = rx.sets
        item.setMax = rx.sets
        item.repMin = rx.repMin
        item.repMax = rx.repMax
        item.targetRIRMin = rx.rirMin
        item.targetRIRMax = rx.rirMax
        item.targetReps = rx.repMin
        item.targetRIR = rx.rirMax
        item.suggestedLoad = r.load
        item.plannedRepsBySet = Array(repeating: rx.repMin, count: rx.sets)
        item.plannedRIRsBySet = Array(repeating: rx.rirMax, count: rx.sets)
        item.plannedLoadsBySet = Array(repeating: r.load, count: rx.sets)
        item.intensifierRaw = "none"
        item.intensifierNotes = nil
        item.planEdited = false
        item.actualReps = []
        item.actualLoads = []
        item.actualRIRs = []
        item.usedRestPauseFlags = []
        item.restPausePatternsBySet = []
        item.dropSetPatternsBySet = []
        item.setFeedbackBySet = []
        item.pumpRatingsBySet = []
        item.coachNote = nil
        item.loadOverrideReasonRaw = nil
        item.nextSuggestedLoad = nil
    }

    private static func writeRIR(_ item: SessionItem, _ rir: Int) {
        item.targetRIR = rir
        item.targetRIRMin = rir
        item.targetRIRMax = rir
        let n = item.plannedRIRsBySet.isEmpty ? item.targetSets : item.plannedRIRsBySet.count
        item.plannedRIRsBySet = Array(repeating: rir, count: n)
    }

    private static func writeLoad(_ item: SessionItem, _ load: Double) {
        item.suggestedLoad = load
        item.plannedLoadsBySet = Array(repeating: load, count: item.targetSets)
    }

    // MARK: - Snapshot / fingerprint

    /// `ModelContext.rollback()` does NOT revert property edits on persisted objects, so every field this repair can
    /// write is recorded and restored before the rollback (the same approach as V52).
    private struct Snapshot {
        struct ItemState {
            let item: SessionItem
            let fields: Fields
            struct Fields {
                let exerciseId: String, exerciseNameSnapshot: String?
                let order: Int, targetReps: Int, targetSets: Int, targetRIR: Int, suggestedLoad: Double
                let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, targetRIRMin: Int?, targetRIRMax: Int?
                let intensifierRaw: String?, intensifierNotes: String?, prescriptionNotes: String?
                let plannedRepsBySet: [Int], plannedRIRsBySet: [Int], plannedLoadsBySet: [Double]
                let planEdited: Bool
                let actualReps: [Int], actualLoads: [Double], actualRIRs: [Int]
                let usedRestPauseFlags: [Bool], restPausePatternsBySet: [String], dropSetPatternsBySet: [String]
                let setFeedbackBySet: [String], pumpRatingsBySet: [Int]
                let coachNote: String?, loadOverrideReasonRaw: String?, nextSuggestedLoad: Double?, updatedAt: Date?
            }

            init(_ i: SessionItem) {
                item = i
                fields = Fields(
                    exerciseId: i.exerciseId, exerciseNameSnapshot: i.exerciseNameSnapshot,
                    order: i.order, targetReps: i.targetReps, targetSets: i.targetSets, targetRIR: i.targetRIR, suggestedLoad: i.suggestedLoad,
                    setMin: i.setMin, setMax: i.setMax, repMin: i.repMin, repMax: i.repMax,
                    targetRIRMin: i.targetRIRMin, targetRIRMax: i.targetRIRMax,
                    intensifierRaw: i.intensifierRaw, intensifierNotes: i.intensifierNotes, prescriptionNotes: i.prescriptionNotes,
                    plannedRepsBySet: i.plannedRepsBySet, plannedRIRsBySet: i.plannedRIRsBySet, plannedLoadsBySet: i.plannedLoadsBySet,
                    planEdited: i.planEdited,
                    actualReps: i.actualReps, actualLoads: i.actualLoads, actualRIRs: i.actualRIRs,
                    usedRestPauseFlags: i.usedRestPauseFlags, restPausePatternsBySet: i.restPausePatternsBySet,
                    dropSetPatternsBySet: i.dropSetPatternsBySet, setFeedbackBySet: i.setFeedbackBySet, pumpRatingsBySet: i.pumpRatingsBySet,
                    coachNote: i.coachNote, loadOverrideReasonRaw: i.loadOverrideReasonRaw,
                    nextSuggestedLoad: i.nextSuggestedLoad, updatedAt: i.updatedAt)
            }

            func restore() {
                let i = item, f = fields
                i.exerciseId = f.exerciseId; i.exerciseNameSnapshot = f.exerciseNameSnapshot
                i.order = f.order; i.targetReps = f.targetReps; i.targetSets = f.targetSets; i.targetRIR = f.targetRIR
                i.suggestedLoad = f.suggestedLoad
                i.setMin = f.setMin; i.setMax = f.setMax; i.repMin = f.repMin; i.repMax = f.repMax
                i.targetRIRMin = f.targetRIRMin; i.targetRIRMax = f.targetRIRMax
                i.intensifierRaw = f.intensifierRaw; i.intensifierNotes = f.intensifierNotes; i.prescriptionNotes = f.prescriptionNotes
                i.plannedRepsBySet = f.plannedRepsBySet; i.plannedRIRsBySet = f.plannedRIRsBySet; i.plannedLoadsBySet = f.plannedLoadsBySet
                i.planEdited = f.planEdited
                i.actualReps = f.actualReps; i.actualLoads = f.actualLoads; i.actualRIRs = f.actualRIRs
                i.usedRestPauseFlags = f.usedRestPauseFlags; i.restPausePatternsBySet = f.restPausePatternsBySet
                i.dropSetPatternsBySet = f.dropSetPatternsBySet; i.setFeedbackBySet = f.setFeedbackBySet
                i.pumpRatingsBySet = f.pumpRatingsBySet
                i.coachNote = f.coachNote; i.loadOverrideReasonRaw = f.loadOverrideReasonRaw
                i.nextSuggestedLoad = f.nextSuggestedLoad; i.updatedAt = f.updatedAt
            }
        }

        let states: [ItemState]
        init(items: [SessionItem]) { states = items.map { ItemState($0) } }
        func restore() { states.forEach { $0.restore() } }
    }

    /// Every stored field of an item by name, for the field-level "only what the plan may write changed" check.
    static func fields(_ i: SessionItem) -> [String: String] {
        func s<T>(_ v: T) -> String { "\(v)" }
        return [
            "id": i.id?.uuidString ?? "", "createdAt": s(i.createdAt?.timeIntervalSince1970 ?? 0), "updatedAt": s(i.updatedAt?.timeIntervalSince1970 ?? 0),
            "order": s(i.order), "exerciseId": i.exerciseId, "exerciseNameSnapshot": i.exerciseNameSnapshot ?? "<nil>",
            "targetReps": s(i.targetReps), "targetSets": s(i.targetSets), "targetRIR": s(i.targetRIR), "suggestedLoad": s(i.suggestedLoad),
            "waveRaw": i.waveRaw ?? "<nil>", "priorityRaw": i.priorityRaw ?? "<nil>",
            "setMin": s(i.setMin), "setMax": s(i.setMax), "repMin": s(i.repMin), "repMax": s(i.repMax),
            "targetRIRMin": s(i.targetRIRMin), "targetRIRMax": s(i.targetRIRMax),
            "intensifierRaw": i.intensifierRaw ?? "<nil>", "intensifierNotes": i.intensifierNotes ?? "<nil>", "prescriptionNotes": i.prescriptionNotes ?? "<nil>",
            "logs": s(i.logs.count), "plannedRepsBySet": s(i.plannedRepsBySet), "plannedLoadsBySet": s(i.plannedLoadsBySet),
            "plannedRIRsBySet": s(i.plannedRIRsBySet), "planEdited": s(i.planEdited),
            "actualReps": s(i.actualReps), "actualLoads": s(i.actualLoads), "actualRIRs": s(i.actualRIRs),
            "usedRestPauseFlags": s(i.usedRestPauseFlags), "restPausePatternsBySet": s(i.restPausePatternsBySet),
            "dropSetPatternsBySet": s(i.dropSetPatternsBySet), "setFeedbackBySet": s(i.setFeedbackBySet), "pumpRatingsBySet": s(i.pumpRatingsBySet),
            "isCompleted": s(i.isCompleted), "isPR": s(i.isPR), "coachNote": i.coachNote ?? "<nil>",
            "loadOverrideReasonRaw": i.loadOverrideReasonRaw ?? "<nil>", "nextSuggestedLoad": s(i.nextSuggestedLoad)
        ]
    }

    static func fingerprint(_ i: SessionItem) -> String {
        fields(i).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "¦")
    }

    /// Every stored field of a session except its items (their ids are compared separately).
    static func sessionFingerprint(_ s: Session) -> String {
        [
            "\(s.id?.uuidString ?? "")", "\(s.createdAt?.timeIntervalSince1970 ?? 0)", "\(s.updatedAt?.timeIntervalSince1970 ?? 0)",
            "\(s.date.timeIntervalSince1970)", s.status.rawValue, "\(s.completedAt?.timeIntervalSince1970 ?? 0)",
            "\(s.readinessStars)", s.readinessRaw, s.sessionNotes ?? "<nil>", "\(String(describing: s.weekInMeso))",
            "\(String(describing: s.programIndex))", s.dayLabel ?? "<nil>", s.meso?.id?.uuidString ?? "<no meso>",
            s.hkWorkoutUUID ?? "<nil>", "\(String(describing: s.hkWorkoutStart))", "\(String(describing: s.hkWorkoutEnd))",
            "\(s.hkDuration)", "\(s.hkActiveCalories)", "\(s.hkTotalCalories)", "\(s.hkAvgHeartRate)", "\(s.hkMaxHeartRate)",
            "\(s.hkZone1Seconds)", "\(s.hkZone2Seconds)", "\(s.hkZone3Seconds)", "\(s.hkZone4Seconds)", "\(s.hkZone5Seconds)",
            "\(s.hkHeartRateSeriesBPM)", "\(s.hkHeartRateSeriesStepSeconds)",
            "\(s.hkPostWorkoutHeartRateBPM)", "\(s.hkPostWorkoutHeartRateStepSeconds)"
        ].joined(separator: "¦")
    }

    /// Everything the verification compares against, captured before the first mutation.
    private struct Baseline {
        var itemFields: [PersistentIdentifier: [String: String]] = [:]
        var sessionPrint: [PersistentIdentifier: String] = [:]
        var sessionItemIds: [PersistentIdentifier: Set<PersistentIdentifier>] = [:]
        var preTarget: [PersistentIdentifier: PersistentIdentifier?] = [:]
        var customCount = 0
        var blockPrint = ""

        init(context: ModelContext, block: MesoBlock) {
            let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
            for s in all {
                sessionPrint[s.persistentModelID] = sessionFingerprint(s)
                sessionItemIds[s.persistentModelID] = Set(s.items.map(\.persistentModelID))
                for i in s.items {
                    itemFields[i.persistentModelID] = V53AlignmentRepair.fields(i)
                    if s.meso?.persistentModelID == block.persistentModelID, WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                        preTarget.updateValue(PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)?.persistentModelID, forKey: i.persistentModelID)
                    }
                }
            }
            customCount = ((try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []).count
            blockPrint = V53AlignmentRepair.blockFingerprint(block)
        }
    }

    private static func blockFingerprint(_ b: MesoBlock) -> String {
        "\(b.id?.uuidString ?? "")¦\(b.name)¦\(b.status.rawValue)¦\(b.totalWeeks.map(String.init) ?? "nil")¦\(b.isMaintenance)¦\(b.startDate.timeIntervalSince1970)¦\(b.notes ?? "<nil>")"
    }

    // MARK: - Verification (runs before save)

    private static func verify(block: MesoBlock, context: ModelContext, plan: Plan, before: Baseline)
        -> (lines: [String], failures: [String], chainTable: [String]) {
        var lines: [String] = []
        var failures: [String] = []
        func check(_ name: String, detail: String = "", _ problems: [String]) {
            if problems.isEmpty { lines.append("[PASS] \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
            else { lines.append("[FAIL] \(name) — \(problems.prefix(6).joined(separator: "; "))"); failures += problems.map { "\(name): \($0)" } }
        }

        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let sessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        let sessionOf: [PersistentIdentifier: Session] = Dictionary(
            sessions.flatMap { s in s.items.map { ($0.persistentModelID, s) } }, uniquingKeysWith: { a, _ in a })
        func week(of item: SessionItem) -> Int? { sessionOf[item.persistentModelID]?.weekIndex }
        let deletedIDs = Set(plan.deleted.map(\.item.persistentModelID))
        let replacedIDs = Set(plan.items.filter { $0.replace != nil }.map(\.item.persistentModelID))
        let plannedByID = Dictionary(plan.items.map { ($0.item.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Counts agree with the plan.
        var countProblems: [String] = []
        let expectDeleted = plan.report.counts["L4", default: 0]
        if plan.deleted.count != expectDeleted { countProblems.append("planned deletions \(plan.deleted.count) != L4 \(expectDeleted)") }
        if plan.items.filter({ $0.replace?.toId == singleLegPressId }).count != plan.report.counts["L1", default: 0] { countProblems.append("L1 items != count") }
        if plan.items.filter({ $0.replace?.toId == legPressId }).count != plan.report.counts["L2", default: 0] { countProblems.append("L2 items != count") }
        if plan.items.filter({ $0.keys.contains("L3") && $0.newOrder == 1 }).count != plan.report.counts["L3", default: 0] { countProblems.append("L3 sessions != count") }
        check("counts match the plan", detail: countsLine(plan.report), countProblems)

        // 2. Deleted items are gone from every session; nothing deleted is reachable.
        var goneProblems: [String] = []
        for p in plan.deleted {
            if p.session.items.contains(where: { $0 === p.item }) { goneProblems.append("\(p.item.exerciseId) wk\(p.week) still in its session") }
        }
        let livingIds = Set(all.flatMap { $0.items.map(\.persistentModelID) })
        for id in deletedIDs where livingIds.contains(id) { goneProblems.append("a deleted item is still attached to a session") }
        check("deleted items are detached", detail: "\(deletedIDs.count) items", goneProblems)

        // 3. Written values per item.
        var valueProblems: [String] = []
        for p in plan.written {
            let i = p.item
            let t = "wk\(p.week) \(p.session.dayLabel ?? "?") \(p.keys.joined(separator: "+"))"
            if let r = p.replace {
                let rx = r.rx
                let ok = i.exerciseId == r.toId && i.exerciseNameSnapshot == r.toName
                    && i.targetSets == rx.sets && i.setMin == rx.sets && i.setMax == rx.sets
                    && i.repMin == rx.repMin && i.repMax == rx.repMax && i.targetRIRMin == rx.rirMin && i.targetRIRMax == rx.rirMax
                    && i.targetReps == rx.repMin && i.targetRIR == rx.rirMax
                    && i.suggestedLoad == r.load && i.plannedLoadsBySet == Array(repeating: r.load, count: rx.sets)
                    && i.plannedRepsBySet.count == rx.sets && i.plannedRIRsBySet.count == rx.sets
                    && !i.planEdited && i.actualReps.isEmpty && i.actualLoads.isEmpty && i.actualRIRs.isEmpty && !i.isCompleted
                    && i.coachNote == nil && i.nextSuggestedLoad == nil
                if !ok { valueProblems.append("\(t): replacement fields are wrong (\(i.exerciseId) \(desc(i)))") }
            }
            if let r = p.rirTo, !rirIsApplied(i, r) { valueProblems.append("\(t): RIR is not \(r)") }
            if let l = p.loadTo, !loadIsApplied(i, l) { valueProblems.append("\(t): load is not \(l) across the sets") }
            if let o = p.newOrder, i.order != o { valueProblems.append("\(t): order is \(i.order), expected \(o)") }
            if let n = p.newNote, i.prescriptionNotes != n { valueProblems.append("\(t): note is not the new text") }
            if i.planEdited, p.replace == nil {
                // planEdited items only ever take a note / order.
                if p.rirTo != nil || p.loadTo != nil { valueProblems.append("\(t): numbers planned on a planEdited item") }
            }
        }
        check("written values match the spec", detail: "\(plan.written.count) items", valueProblems)

        // 4. Field-level: nothing outside the plan's allowed fields changed on any item in the store.
        var fieldProblems: [String] = []
        var untouchedChecked = 0
        for s in all {
            for i in s.items {
                guard let was = before.itemFields[i.persistentModelID] else { fieldProblems.append("an item appeared in \(s.dayLabel ?? "?") wk\(s.weekIndex)"); continue }
                let now = fields(i)
                let allowed = plannedByID[i.persistentModelID]?.allowedFields ?? []
                if plannedByID[i.persistentModelID] == nil { untouchedChecked += 1 }
                let changed = now.filter { was[$0.key] != $0.value }.keys.filter { !allowed.contains($0) }
                if !changed.isEmpty { fieldProblems.append("wk\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId): \(changed.sorted().joined(separator: ",")) changed") }
            }
        }
        check("only the plan's fields changed; every unlisted item is byte-identical", detail: "\(untouchedChecked) unlisted items across \(all.count) sessions", fieldProblems)

        // 5. Sessions, blocks, custom exercises untouched; item sets differ only by the deletions.
        var sessionProblems: [String] = []
        for s in all {
            if before.sessionPrint[s.persistentModelID] != sessionFingerprint(s) { sessionProblems.append("session wk\(s.weekIndex) \(s.dayLabel ?? "?") fields changed") }
            let expectedIds = (before.sessionItemIds[s.persistentModelID] ?? []).subtracting(deletedIDs)
            if Set(s.items.map(\.persistentModelID)) != expectedIds { sessionProblems.append("session wk\(s.weekIndex) \(s.dayLabel ?? "?") has the wrong item set") }
        }
        if before.sessionPrint.count != all.count { sessionProblems.append("session count changed") }
        if blockFingerprint(block) != before.blockPrint { sessionProblems.append("block changed") }
        let customCount = ((try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []).count
        if customCount != before.customCount { sessionProblems.append("custom exercise rows changed \(before.customCount) -> \(customCount)") }
        check("sessions, block and custom exercise rows byte-identical (Cable Hip Adduction row kept)", detail: "\(all.count) sessions", sessionProblems)

        // 6. No order ties; Legs A in the v5.3 shape wherever it was changed.
        var orderProblems: [String] = []
        for s in sessions {
            let orders = s.items.map(\.order)
            if Set(orders).count != orders.count { orderProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?")") }
        }
        for p in plan.written where p.keys.contains("L3") && p.newOrder == 1 {
            let have = p.session.items.map { (canonical($0.exerciseId), $0.order) }.sorted { $0.1 < $1.1 }
            let want = legsPostShape.map { (canonical($0.id), $0.order) }
            if have.count != want.count || !zip(have, want).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) {
                orderProblems.append("Legs A wk\(p.week) is not lying curl 1, single-leg press 2, leg press 3, leg extension 4, seated calf 5")
            }
        }
        check("no order ties; Legs A renumbered 1-5", orderProblems)

        // 7. Chains.
        //    a. Every unchanged lettered item targets what it targeted before. Accepted: its old target was replaced / deleted
        //       (a dead end now, e.g. weeks 1-3 hack squat) or it had none and now links into a replaced lift (weeks 1-3 single-leg press).
        var retainedBroken: [String] = []
        var retainedChecked = 0, deadEnds = 0, newLinks = 0
        for s in sessions {
            for i in s.items where WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                let id = i.persistentModelID
                guard let was = before.preTarget[id], !replacedIDs.contains(id) else { continue }
                let now = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)?.persistentModelID
                if now == was { retainedChecked += 1; continue }
                // Its old target was a pulled lift: now nothing (dead end) or the next session that still carries the lift
                // (a skipped session in between). Check b pins which.
                if let was, replacedIDs.contains(was) || deletedIDs.contains(was) { deadEnds += 1; continue }
                if was == nil, let now, replacedIDs.contains(now) { newLinks += 1; continue }
                retainedBroken.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId)")
            }
        }
        check("retained chains unbroken (target unchanged)",
              detail: "\(retainedChecked) items; \(deadEnds) dead end(s) from pulled lifts, \(newLinks) newly linked into single-leg press / leg press", retainedBroken)

        //    b. Every lettered item targets the same lift 3 weeks later (same day, same wave) or nothing; weeks 10+ have no target;
        //       nothing targets a deleted item.
        var linkProblems: [String] = []
        var checked = 0
        for s in sessions {
            for i in s.items where WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                checked += 1
                let target = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)
                if let target, deletedIDs.contains(target.persistentModelID) { linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) targets a deleted item") }
                let targetWeek = target.flatMap { week(of: $0) }
                // The engine's rule: the next session of the same day, same letter (every 3rd week), that carries the lift.
                // That is +3 weeks unless a skipped (logged / hand-edited) session in between does not carry it.
                let expected = sessions.filter { $0.weekIndex > s.weekIndex && ($0.weekIndex - s.weekIndex) % 3 == 0
                    && normalizedLabel($0) == normalizedLabel(s)
                    && $0.items.contains { canonical($0.exerciseId) == canonical(i.exerciseId) } }
                    .min { $0.weekIndex < $1.weekIndex }
                if let expected {
                    if targetWeek != expected.weekIndex { linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) -> \(targetWeek.map { "W\($0)" } ?? "none") (expected W\(expected.weekIndex))") }
                } else if target != nil {
                    linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) has an unexpected target W\(targetWeek ?? -1)")
                }
                if s.weekIndex >= 10, target != nil { linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) has a target after the last rotation") }
            }
        }
        check("every chain links to the next same-letter session carrying the lift (+3 weeks) or ends; nothing after weeks 10-12 has a target; nothing targets a deleted item", detail: "\(checked) items", linkProblems)

        //    c. New chains: single-leg press and leg press run 4→7→10, 5→8→11, 6→9→12.
        var newProblems: [String] = []
        var table: [String] = []
        for (name, id) in [("single leg press", singleLegPressId), ("leg press", legPressId)] {
            var parts: [String] = []
            for (letter, startWeek) in [("A", 4), ("B", 5), ("C", 6)] {
                let withLift = stride(from: startWeek, through: lastWeek, by: 3).filter { w in
                    sessions.contains { $0.weekIndex == w && normalizedLabel($0) == legsA && $0.items.contains { canonical($0.exerciseId) == canonical(id) } }
                }
                guard let first = withLift.first,
                      var currentSession = sessions.first(where: { $0.weekIndex == first && normalizedLabel($0) == legsA }),
                      var current = currentSession.items.first(where: { canonical($0.exerciseId) == canonical(id) }) else {
                    parts.append("\(letter): none"); continue
                }
                var visited = [first]
                while let next = PlanMemoryEngine.nextTargetItem(for: current, after: currentSession, in: all),
                      let nextSession = sessionOf[next.persistentModelID] {
                    visited.append(nextSession.weekIndex); current = next; currentSession = nextSession
                    if visited.count > 6 { break }
                }
                if visited != withLift { newProblems.append("\(name) \(letter): visits \(visited), expected \(withLift)") }
                parts.append("\(letter) " + visited.map { "W\($0)" }.joined(separator: "→") + "→nil")
            }
            table.append("  \(legsA) \(name): " + parts.joined(separator: ", "))
        }
        check("new chains: 4→7→10, 5→8→11, 6→9→12 (single-leg press, leg press)", detail: "\(table.count) lifts", newProblems)

        return (lines, failures, table)
    }

    // MARK: - Driver

    /// Registered LAST in `StartupBackfills`, on its own fresh context. Ships dry run: plan, print, store the report,
    /// set the version-keyed logged flag (only once the plan is safe), return. Armed: blocked unless every gate passes;
    /// the completion flag is set only after the verified save.
    static func runIfNeeded(
        in context: ModelContext,
        dryRun: Bool = V53AlignmentRepair.dryRun,
        defaults: UserDefaults = .standard,
        hooks: ApplyHooks = ApplyHooks()
    ) {
        if defaults.bool(forKey: completionKey) {
            print("ℹ️ V53 alignment not needed.")
            return
        }
        if dryRun, defaults.bool(forKey: dryRunLoggedKey) {
            print("ℹ️ V53 alignment dry run already logged on this install.")
            return
        }
        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ V53 alignment: could not fetch meso blocks — nothing done.")
            return
        }
        let candidates = blocks.filter { $0.status == .active && !$0.isMaintenance }
        guard candidates.count == 1, let block = candidates.first else {
            print("ℹ️ V53 alignment: \(candidates.count) active regular blocks — nothing done, will retry.")
            return
        }

        let report = makePlan(block: block, context: context, defaults: defaults).report
        print("\(logHeader(dryRun: dryRun, blockName: block.name))\n\(report.text)")

        if dryRun {
            // Only a safe plan is worth remembering; an unsafe one reports again next launch.
            if report.isSafe {
                defaults.set(report.text, forKey: reportKey)
                defaults.set(true, forKey: dryRunLoggedKey)
            }
            print("🧪 V53 alignment dry run logged (read-only; nothing was written to the store).")
            return
        }

        guard report.isSafe else {
            print("⛔️ V53 alignment refused: \(report.blockers.count) blocker(s). Flag left unset; will retry.")
            return
        }
        if report.alreadyAligned {
            defaults.set(true, forKey: completionKey)
            print("ℹ️ V53 alignment: nothing left to change — marked complete.")
            return
        }
        if context.hasChanges {
            do { try context.save() } catch {
                print("⚠️ V53 alignment: could not flush pending changes before apply: \(error). Flag NOT set; will retry.")
                return
            }
        }
        do {
            let applied = try apply(block: block, context: context, defaults: defaults, hooks: hooks)
            guard applied.didWrite else {
                print("⚠️ V53 alignment: apply wrote nothing. Flag left unset.")
                return
            }
            defaults.set(true, forKey: completionKey)   // only after the verified save
            logPostWriteSummary(applied, block: block)
        } catch {
            print("⛔️ V53 alignment NOT applied (store unchanged, flag NOT set; will retry): \(error)")
        }
    }

    /// First line of the report in the launch log: "APPLY" when this launch may write, "DRY RUN" only when read-only.
    static func logHeader(dryRun: Bool, blockName: String) -> String {
        "🧪 V53 alignment \(dryRun ? "DRY RUN" : "APPLY") for '\(blockName)':"
    }

    private static func logPostWriteSummary(_ r: Report, block: MesoBlock) {
        var out = ["✅ V53 alignment applied to '\(block.name)'"]
        out.append(countsLine(r) + "   skipped: \(r.skipped.count)")
        out.append("== NEW CHAINS ==")
        out += r.postWriteChainTable
        out.append("== VERIFICATION (ran before save) ==")
        out += r.verification.map { "  \($0)" }
        if !r.skipped.isEmpty { out.append("== SKIPPED =="); out += r.skipped.map { "  \($0)" } }
        print(out.joined(separator: "\n"))
    }
}
