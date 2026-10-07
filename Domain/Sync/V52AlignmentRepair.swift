// Domain/Sync/V52AlignmentRepair.swift
import Foundation
import SwiftData

/// One-shot repair: align the active, CONVERTED 12-week block to program v5.2 (effective week 4).
///
/// Waves: A = weeks 4, 7, 10 · B = 5, 8, 11 · C = 6, 9, 12. Scope is weeks 4-12 only, of the single
/// active regular block. Weeks 1-3 (including the planned Oct 6 / Oct 7 sessions) are never touched.
///
///  * REPLACE (7 slots): the item keeps its id, order and wave; exerciseId, name snapshot, prescription
///    and notes change; loads go to 0; coachNote / actuals / nextSuggestedLoad are cleared; planEdited false.
///  * RE-RANGE (3 slots): same exercise, order and CURRENT seeds; sets / reps / RIR / notes change and the
///    planned arrays are resized to the new set count (loads repeat the current seed).
///  * ADD (2 slots): a new item at (current max order + 1) built through
///    `DUPSessionMaterializer.makeSessionItems`, load 0, wave taken from the session.
///  * Every other item is never read for writing; a runtime fingerprint proves it is byte-identical.
///
/// Phases of a live run (all but the second are read-only until the third):
///  1. plan   — every gate is evaluated across every target; nothing is written.
///  2. ensure — `ensureCustomExercises` creates ONLY the missing custom exercises through
///              `ExerciseCatalog.addCustomExercise` (idempotent; it saves on its own, which is why it runs
///              BEFORE the atomic transaction and is never rolled back — a retry reuses the rows).
///  3. apply  — autosave off, pending-changes refusal, snapshot, mutate, verify the whole result
///              (retained chains unbroken, new chains 4→7→10 / 5→8→11 / 6→9→12, nothing after weeks
///              10-12 has a target, unlisted items byte-identical), ONE save. Any failed verification or
///              failed save restores every overwritten field and removes every inserted item.
///
/// LIVE APPLY REQUIRES the 12-week conversion: `twelveWeekMesoConversion.v1.completed` AND the converted
/// shape. Otherwise the run logs "blocked: not converted" and writes nothing (a dry run still reports).
/// Ships `dryRun = true`.
enum V52AlignmentRepair {

    /// Flip to false (its own commit) to apply. Read-only while true.
    static let dryRun = true

    /// Bump when the REPORT changes, so a changed report logs again instead of being swallowed by the
    /// previous install's "already logged" flag.
    static let reportVersion = "v1"

    static let completionKey = "v52AlignmentRepair.v1.completed"
    static var dryRunLoggedKey: String { "v52AlignmentRepair.v1.dryRunLogged.\(reportVersion)" }
    static var reportKey: String { "v52AlignmentRepair.v1.dryRunReport.\(reportVersion)" }

    /// Raw key of the UserDefaults mirror of custom exercises (see ExerciseCatalog), used by tests to isolate.
    static let customMirrorKey = "custom_exercises_v2"

    static let firstWeek = 4
    static let convertedLastWeek = 12
    /// A 10-week (not yet converted) block: weeks 4-9 are reported; week 10 is a deload that the conversion
    /// rewrites from week 7, so it is deferred to the converted shape.
    static let unconvertedLastWeek = 9

    // MARK: - Specification (v5.2)

    private static let pushA = "Push A", legsA = "Legs A", pullA = "Pull A"
    private static let pushB = "Push B", legsB = "Legs B", pullB = "Pull B"
    private static let dayOrder = [pushA, legsA, pullA, pushB, legsB, pullB]

    struct Rx: Equatable {
        let sets: Int, repMin: Int, repMax: Int, rirMin: Int, rirMax: Int
        init(_ sets: Int, _ repMin: Int, _ repMax: Int, rir rirMin: Int, _ rirMax: Int? = nil) {
            self.sets = sets; self.repMin = repMin; self.repMax = repMax
            self.rirMin = rirMin; self.rirMax = rirMax ?? rirMin
        }
        var label: String {
            "\(sets)x\(repMin == repMax ? "\(repMin)" : "\(repMin)-\(repMax)") @\(rirMin == rirMax ? "\(rirMin)" : "\(rirMin)-\(rirMax)")"
        }
    }

    struct WaveRx {
        let a: Rx, b: Rx, c: Rx
        func rx(for wave: WaveType) -> Rx? {
            switch wave {
            case .a: return a
            case .b: return b
            case .c: return c
            case .deload: return nil
            }
        }
    }

    struct CustomSpec {
        let name: String
        let muscle: MuscleGroup
        let isCompound: Bool
    }

    enum Target {
        case builtIn(String)
        case custom(CustomSpec)
    }

    enum Kind {
        case replace(order: Int, fromId: String, to: Target)
        case rerange(id: String)
        case add(Target)
    }

    struct Op {
        let key: String
        let day: String
        let kind: Kind
        let rx: WaveRx
        let note: String
    }

    static let longHead = CustomSpec(name: "Single-Arm Cable Extension (Long Head)", muscle: .triceps, isCompound: false)
    static let smithSplitSquat = CustomSpec(name: "Smith Split Squat", muscle: .quads, isCompound: true)
    // MuscleGroup has no rear-delt case.
    static let proneYRaise = CustomSpec(name: "Prone Y-Raise", muscle: .shoulders, isCompound: false)
    static let inclineHammerCurl = CustomSpec(name: "Incline Hammer Curl", muscle: .biceps, isCompound: false)
    static let straightArmPulldown = CustomSpec(name: "Straight-Arm Cable Pulldown", muscle: .back, isCompound: false)
    // MuscleGroup has no adductor case.
    static let cableHipAdduction = CustomSpec(name: "Cable Hip Adduction", muscle: .glutes, isCompound: false)

    /// The six custom exercises this repair may create (R1, R2, R3, R5, R7, A1).
    static let customSpecs: [CustomSpec] = [
        longHead, smithSplitSquat, proneYRaise, inclineHammerCurl, straightArmPulldown, cableHipAdduction
    ]

    static let ops: [Op] = [
        Op(key: "R1", day: pushA, kind: .replace(order: 5, fromId: "single_arm_cable_lateral_raise", to: .custom(longHead)),
           rx: WaveRx(a: Rx(2, 10, 12, rir: 1, 2), b: Rx(2, 12, 15, rir: 1, 2), c: Rx(2, 15, 20, rir: 1, 2)),
           note: "Last. Neutral grip, arm only partway overhead, no rope. Gated: next-morning right elbow above 2/10 removes it."),
        Op(key: "R2", day: legsA, kind: .replace(order: 2, fromId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef", to: .custom(smithSplitSquat)),
           rx: WaveRx(a: Rx(2, 8, 10, rir: 2), b: Rx(2, 10, 12, rir: 2), c: Rx(2, 12, 15, rir: 2)),
           note: "Front foot slightly elevated. Long-position quad, glute, and adductor load. If the back objects, go back to single-leg press."),
        Op(key: "R3", day: pullA, kind: .replace(order: 3, fromId: "incline_rear_delt_fly", to: .custom(proneYRaise)),
           rx: WaveRx(a: Rx(3, 10, 12, rir: 1), b: Rx(3, 12, 15, rir: 1), c: Rx(3, 15, 20, rir: 1)),
           note: "Incline bench with Bowflex, light. Lower traps in the scapular plane."),
        Op(key: "R4", day: pullA, kind: .replace(order: 5, fromId: "dumbbell_lateral_raise", to: .builtIn("single_arm_cable_lateral_raise")),
           rx: WaveRx(a: Rx(3, 10, 12, rir: 1), b: Rx(3, 12, 15, rir: 1), c: Rx(3, 15, 20, rir: 1)),
           note: "Set the cable behind the body to keep tension at the bottom."),
        Op(key: "R5", day: pushB, kind: .replace(order: 3, fromId: "dumbbell_lateral_raise", to: .custom(inclineHammerCurl)),
           rx: WaveRx(a: Rx(3, 8, 10, rir: 1, 2), b: Rx(3, 10, 12, rir: 1, 2), c: Rx(3, 12, 15, rir: 1, 2)),
           note: "DB, neutral grip, incline bench. Track left arm independently. Next-morning left elbow or biceps above 2/10 means swap."),
        Op(key: "R6", day: legsB, kind: .replace(order: 4, fromId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822", to: .builtIn("smith_machine_calves")),
           rx: WaveRx(a: Rx(3, 10, 12, rir: 1), b: Rx(3, 12, 15, rir: 1), c: Rx(3, 15, 20, rir: 1)),
           note: "Standing calf: full stretch, pause at the bottom. Ease in over the first sessions and watch the Achilles."),
        Op(key: "R7", day: pullB, kind: .replace(order: 5, fromId: "cable_rear_delt_fly", to: .custom(straightArmPulldown)),
           rx: WaveRx(a: Rx(3, 10, 12, rir: 1), b: Rx(3, 12, 15, rir: 1), c: Rx(3, 15, 20, rir: 1)),
           note: "Last. Lat at long length with no elbow or biceps demand."),

        Op(key: "H1", day: legsA, kind: .rerange(id: "hack_squat"),
           rx: WaveRx(a: Rx(4, 5, 8, rir: 1, 2), b: Rx(3, 8, 10, rir: 2), c: Rx(3, 10, 15, rir: 2)),
           note: "Wide stance, toe-out. Ranges moved from rotation 1, so each letter sets a fresh anchor. Rotation-1 loads are only a floor reference."),
        Op(key: "H2", day: legsB, kind: .rerange(id: "custom_7f4ffc44-7aea-449f-87d9-41e76f2f3361"),
           rx: WaveRx(a: Rx(4, 6, 8, rir: 1, 2), b: Rx(3, 8, 12, rir: 2), c: Rx(3, 12, 15, rir: 2)),
           note: "Gated: back 0-1/10, no spasm. Neutral-spine lockout. Ranges moved, so each letter sets a fresh anchor. Not cleared: skip it and take leg curl to 4 sets."),
        Op(key: "H3", day: legsB, kind: .rerange(id: "romanian_deadlift"),
           rx: WaveRx(a: Rx(3, 6, 8, rir: 1, 2), b: Rx(3, 8, 10, rir: 1, 2), c: Rx(3, 10, 12, rir: 1, 2)),
           note: "No load cap. Reps first, then 5-10 lb. End the set when hinge position or neutral spine degrades. Belt on. Next-morning low back above 3/10 means hold load next session."),

        Op(key: "A1", day: legsA, kind: .add(.custom(cableHipAdduction)),
           rx: WaveRx(a: Rx(2, 10, 12, rir: 1, 2), b: Rx(2, 12, 15, rir: 1, 2), c: Rx(2, 15, 20, rir: 1, 2)),
           note: "Last. Fills the adductor gap; adductor magnus is a hip extensor."),
        Op(key: "A2", day: legsB, kind: .add(.builtIn("pallof_press")),
           rx: WaveRx(a: Rx(2, 10, 10, rir: 1, 2), b: Rx(2, 10, 12, rir: 1, 2), c: Rx(2, 12, 15, rir: 1, 2)),
           note: "Optional finisher; anti-rotation work for the back. First cut if the session passes 60 min.")
    ]

    // MARK: - Waves

    /// A = 4, 7, 10 · B = 5, 8, 11 · C = 6, 9, 12.
    static func wave(forWeek week: Int) -> WaveType {
        switch ((week - firstWeek) % 3 + 3) % 3 {
        case 0: return .a
        case 1: return .b
        default: return .c
        }
    }

    // MARK: - Report

    struct Gate {
        enum Status: String { case passed = "PASS", failed = "FAIL", notEvaluated = "not evaluated" }
        let name: String
        var status: Status
        var detail: String
    }

    struct Report {
        var gates: [Gate] = []
        var blockers: [String] = []
        var lines: [String] = []
        var customLines: [String] = []
        var skipped: [String] = []
        var opLines: [String] = []
        var chainTable: [String] = []
        var verification: [String] = []
        var postWriteChainTable: [String] = []

        var shape = ""
        var converted = false
        var liveBlocker: String?                  // nil = live apply allowed
        var scopeWeeks: ClosedRange<Int> = firstWeek...convertedLastWeek
        var alreadyAligned = false

        var replaced = 0, reranged = 0, created = 0
        var alreadyApplied = 0
        var planEditedRetained = 0, planEditedTouched = 0
        var customsToCreate: [String] = []
        var didWrite = false

        var isSafe: Bool { blockers.isEmpty }

        var text: String {
            var out: [String] = []
            out.append("== SHAPE == \(shape)")
            out.append("== GATES ==")
            out += gates.map { "[\($0.status.rawValue)] \($0.name)\($0.detail.isEmpty ? "" : " — \($0.detail)")" }
            if !blockers.isEmpty { out.append("== BLOCKERS =="); out += blockers.map { "  ! \($0)" } }
            out.append("== LIVE APPLY == " + (liveBlocker.map { "blocked: \($0)" } ?? "allowed (converted shape and completion flag present)"))
            out.append("== CUSTOM EXERCISES =="); out += customLines
            out.append("== SUMMARY =="); out += lines
            if !skipped.isEmpty { out.append("== SKIPPED (\(skipped.count)) =="); out += skipped.map { "  \($0)" } }
            if !opLines.isEmpty { out.append("== WRITES (before -> after) =="); out += opLines }
            if !chainTable.isEmpty { out.append("== PROJECTED CHAINS =="); out += chainTable }
            return out.joined(separator: "\n")
        }
    }

    // MARK: - Plan

    private struct Resolved {
        let id: String
        let name: String
        let exists: Bool
    }

    private struct Seed { let load: Double; let loads: [Double] }

    private enum Step {
        case replace(item: SessionItem, session: Session, week: Int, op: Op, target: Resolved, wave: WaveType, rx: Rx)
        case rerange(item: SessionItem, session: Session, week: Int, op: Op, rx: Rx)
        case add(session: Session, week: Int, op: Op, target: Resolved, order: Int, wave: WaveType, rx: Rx)
    }

    private struct Plan {
        var steps: [Step] = []
        var report = Report()
        /// Items the plan will overwrite (replace + rerange), for snapshot and the "everything else is identical" check.
        var touchedItems: [SessionItem] {
            steps.compactMap {
                switch $0 {
                case .replace(let item, _, _, _, _, _, _): return item
                case .rerange(let item, _, _, _, _): return item
                case .add: return nil
                }
            }
        }
    }

    // MARK: - Public API

    /// Runs every check and describes every write. Mutates nothing (no custom exercise is created either).
    static func dryRun(block: MesoBlock, context: ModelContext, defaults: UserDefaults = .standard) -> Report {
        makePlan(block: block, context: context, defaults: defaults).report
    }

    struct EnsureResult {
        var created: [String] = []      // names created this call
        var reused: [String] = []       // names that already had a CustomExercise row
    }

    /// Creates ONLY the missing custom exercises (matched by normalized name, exactly like
    /// `ExerciseCatalog.addCustomExercise`). Idempotent. `addCustomExercise` saves and mirrors to
    /// UserDefaults on its own, so this is a separate step that runs before the atomic transaction.
    @discardableResult
    static func ensureCustomExercises(in context: ModelContext) throws -> EnsureResult {
        var result = EnsureResult()
        for spec in customSpecs {
            let existing = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
            if existing.contains(where: { normalized($0.name) == normalized(spec.name) }) {
                result.reused.append(spec.name)
                continue
            }
            let made = ExerciseCatalog.addCustomExercise(
                name: spec.name, primaryMuscle: spec.muscle, isCompound: spec.isCompound,
                isBodyweight: false, in: context
            )
            let after = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
            guard after.contains(where: { $0.id == made.id && normalized($0.name) == normalized(spec.name) }) else {
                throw ApplyError.customExerciseMissing(spec.name)
            }
            result.created.append(spec.name)
        }
        return result
    }

    enum ApplyError: Error, CustomStringConvertible {
        case pendingChanges
        case verificationFailed([String])
        case saveFailed(String)
        case customExerciseMissing(String)
        case planUnsafe([String])

        var description: String {
            switch self {
            case .pendingChanges: return "context had unsaved changes before apply; refusing so a rollback can never discard them"
            case .verificationFailed(let f): return "post-mutation verification failed (rolled back): " + f.joined(separator: "; ")
            case .saveFailed(let e): return "save failed (rolled back): \(e)"
            case .customExerciseMissing(let n): return "custom exercise '\(n)' is not in the custom exercise table after creation"
            case .planUnsafe(let b): return "plan has blockers: " + b.joined(separator: "; ")
            }
        }
    }

    /// Test seams. Production uses the defaults.
    struct ApplyHooks {
        var save: (ModelContext) throws -> Void = { try $0.save() }
        var beforeVerify: ((ModelContext) -> Void)? = nil
        init(save: @escaping (ModelContext) throws -> Void = { try $0.save() },
             beforeVerify: ((ModelContext) -> Void)? = nil) {
            self.save = save; self.beforeVerify = beforeVerify
        }
    }

    /// Applies the plan if (and only if) it is safe and live apply is allowed. Plan -> (autosave off) ->
    /// mutate -> verify the whole result -> ONE save. Any failure after the first mutation restores the store.
    @discardableResult
    static func apply(block: MesoBlock, context: ModelContext, defaults: UserDefaults = .standard,
                      hooks: ApplyHooks = ApplyHooks()) throws -> Report {
        var plan = makePlan(block: block, context: context, defaults: defaults)
        guard plan.report.liveBlocker == nil else { return plan.report }
        guard plan.report.isSafe else { throw ApplyError.planUnsafe(plan.report.blockers) }
        guard !plan.report.alreadyAligned else { return plan.report }
        guard !context.hasChanges else { throw ApplyError.pendingChanges }

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        let sessions = blockSessions(block: block, context: context)
        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let touched = plan.touchedItems
        let touchedIDs = Set(touched.map(\.persistentModelID))

        // Before-state: snapshot of every overwritten item, fingerprint of every other item, pre-chain targets.
        let snapshot = Snapshot(items: touched)
        var untouchedBefore: [PersistentIdentifier: String] = [:]
        var preTarget: [PersistentIdentifier: PersistentIdentifier?] = [:]
        func remember(_ k: PersistentIdentifier, _ v: PersistentIdentifier?) { preTarget.updateValue(v, forKey: k) }
        for s in sessions {
            for i in s.items {
                if !touchedIDs.contains(i.persistentModelID) { untouchedBefore[i.persistentModelID] = fingerprint(i) }
                if WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                    remember(i.persistentModelID, PlanMemoryEngine.nextTargetItem(for: i, after: s, in: allSessions)?.persistentModelID)
                }
            }
        }
        var preSeeds: [PersistentIdentifier: Seed] = [:]
        for step in plan.steps {
            if case .rerange(let item, _, _, _, _) = step {
                preSeeds[item.persistentModelID] = Seed(load: item.suggestedLoad, loads: item.plannedLoadsBySet)
            }
        }

        // Mutate.
        var inserted: [(Session, SessionItem)] = []
        for step in plan.steps {
            switch step {
            case .replace(let item, _, _, let op, let target, let wave, let rx):
                let built = buildItem(exerciseId: target.id, name: target.name, order: item.order, wave: wave, rx: rx, note: op.note)
                copyReplacement(from: built, to: item)
            case .rerange(let item, _, _, let op, let rx):
                applyRerange(item: item, rx: rx, note: op.note)
            case .add(let session, _, let op, let target, let order, let wave, let rx):
                let item = buildItem(exerciseId: target.id, name: target.name, order: order, wave: wave, rx: rx, note: op.note)
                context.insert(item)
                session.items.append(item)
                inserted.append((session, item))
            }
        }

        func undo() {
            snapshot.restore()
            for (session, item) in inserted {
                session.items.removeAll { $0 === item }
                context.delete(item)
            }
            context.rollback()
        }

        hooks.beforeVerify?(context)

        let result = verify(block: block, context: context, plan: plan,
                            untouchedBefore: untouchedBefore, preTarget: preTarget, preSeeds: preSeeds,
                            touchedIDs: touchedIDs, inserted: inserted.map(\.1))
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
        plan.report.lines.append("WROTE: replaced \(plan.report.replaced), re-ranged \(plan.report.reranged), created \(plan.report.created).")
        return plan.report
    }

    // MARK: - Planner

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func canonical(_ id: String) -> String { ExerciseCatalog.canonicalExerciseId(for: id) }

    private static func trimmedLabel(_ s: Session) -> String { (s.dayLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func blockSessions(block: MesoBlock, context: ModelContext) -> [Session] {
        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        return all.filter { $0.meso?.persistentModelID == block.persistentModelID }
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains {
            $0.isCompleted || !$0.logs.isEmpty || $0.actualLoads.contains { $0 > 0 } || $0.actualReps.contains { $0 > 0 }
        }
    }

    private static func resolve(_ target: Target, customs: [CustomExercise]) -> Resolved {
        switch target {
        case .builtIn(let id):
            return Resolved(id: id, name: ExerciseCatalog.displayName(for: id), exists: ExerciseCatalog.all.contains { $0.id == id })
        case .custom(let spec):
            if let row = customs.first(where: { normalized($0.name) == normalized(spec.name) }) {
                return Resolved(id: row.id, name: row.name, exists: true)
            }
            // Dry-run placeholder; a live apply only ever plans after `ensureCustomExercises`.
            return Resolved(id: "custom_pending_" + spec.name.lowercased().replacingOccurrences(of: " ", with: "-"), name: spec.name, exists: false)
        }
    }

    private static func makePlan(block: MesoBlock, context: ModelContext, defaults: UserDefaults) -> Plan {
        var plan = Plan()
        func fail(_ s: String) { plan.report.blockers.append(s) }
        func note(_ s: String) { plan.report.lines.append(s) }
        let allGateNames = [
            "block is active and not maintenance",
            "every day has exactly one session per week in scope",
            "wave letters per session match the week (A 4,7,10 · B 5,8,11 · C 6,9,12)",
            "built-in target exercises exist in the catalog",
            "every replace / re-range target found exactly once (or already applied)",
            "no order ties in the projected rosters"
        ]
        var gateIdx = 0
        func gate(_ detail: String = "", _ body: () -> Void) {
            let before = plan.report.blockers.count
            body()
            let added = plan.report.blockers.count - before
            plan.report.gates.append(Gate(name: allGateNames[gateIdx], status: added == 0 ? .passed : .failed,
                                          detail: added == 0 ? detail : "\(added) blocker(s)"))
            gateIdx += 1
        }
        func finish() -> Plan {
            while gateIdx < allGateNames.count {
                plan.report.gates.append(Gate(name: allGateNames[gateIdx], status: .notEvaluated, detail: "")); gateIdx += 1
            }
            return plan
        }

        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let sessions = blockSessions(block: block, context: context)

        // Shape and live precondition.
        let problems = DUPMesoLengthConversion.convertedShapeProblems(block: block, context: context)
        let flag = defaults.bool(forKey: TwelveWeekMesoConversionMigration.completionKey)
        plan.report.converted = problems.isEmpty
        plan.report.scopeWeeks = problems.isEmpty ? firstWeek...convertedLastWeek : firstWeek...unconvertedLastWeek
        plan.report.shape = problems.isEmpty
            ? "converted (\(block.totalWeeks ?? 0) weeks, \(sessions.count) sessions); scope weeks \(firstWeek)-\(convertedLastWeek)"
            : "NOT converted (totalWeeks \(block.totalWeeks.map(String.init) ?? "nil"), \(sessions.count) sessions: \(problems.joined(separator: "; "))); scope reduced to weeks \(firstWeek)-\(unconvertedLastWeek), dry run only"
        if !problems.isEmpty {
            plan.report.liveBlocker = "not converted (12-week shape missing)"
        } else if !flag {
            plan.report.liveBlocker = "not converted (\(TwelveWeekMesoConversionMigration.completionKey) is not set)"
        }
        let weeks = plan.report.scopeWeeks

        // Custom exercise resolution (read-only).
        var resolvedByKey: [String: Resolved] = [:]
        for op in ops {
            switch op.kind {
            case .replace(_, _, let t), .add(let t): resolvedByKey[op.key] = resolve(t, customs: customs)
            case .rerange: break
            }
        }
        for spec in customSpecs {
            let r = resolve(.custom(spec), customs: customs)
            if r.exists {
                plan.report.customLines.append("  reuse  \(spec.name) → \(r.id)")
            } else {
                plan.report.customsToCreate.append(spec.name)
                plan.report.customLines.append("  would create  \(spec.name) [\(spec.muscle.rawValue), \(spec.isCompound ? "compound" : "noncompound")]")
            }
        }
        for op in ops {
            if case .replace(_, _, .builtIn(let id)) = op.kind { plan.report.customLines.append("  built-in \(op.key) → \(id) (\(ExerciseCatalog.displayName(for: id)))") }
            if case .add(.builtIn(let id)) = op.kind { plan.report.customLines.append("  built-in \(op.key) → \(id) (\(ExerciseCatalog.displayName(for: id)))") }
        }

        // Gate 1.
        gate("'\(block.name)' [\(block.id.map { String($0.uuidString.prefix(8)) } ?? "no id")]") {
            if block.status != .active { fail("block status is \(block.status.rawValue), not active") }
            if block.isMaintenance { fail("block is a maintenance block") }
        }

        // Gate 2: resolve (day, week) -> session.
        var sessionAt: [String: [Int: Session]] = [:]
        gate("6 days × \(weeks.count) weeks") {
            for day in dayOrder {
                for w in weeks {
                    let found = sessions.filter { trimmedLabel($0) == day && $0.weekIndex == w }
                    if found.count != 1 { fail("\(day) wk\(w): expected exactly 1 session, found \(found.count)"); continue }
                    sessionAt[day, default: [:]][w] = found[0]
                }
            }
        }
        if !plan.report.isSafe { return finish() }

        // Gate 3: waves.
        gate() {
            for day in dayOrder {
                for w in weeks {
                    guard let s = sessionAt[day]?[w] else { continue }
                    let waves = Set(s.items.compactMap { $0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() })
                    if waves != [wave(forWeek: w).rawValue] { fail("\(day) wk\(w): waves are \(waves.sorted()), expected [\(wave(forWeek: w).rawValue)]") }
                }
            }
        }

        // Gate 4: built-ins exist.
        gate() {
            for op in ops {
                guard let r = resolvedByKey[op.key], !r.exists, builtInTarget(of: op) != nil else { continue }
                fail("\(op.key): built-in \(r.id) is not in the catalog")
            }
        }
        if !plan.report.isSafe { return finish() }

        // Gate 5 + the plan itself.
        var projected: [String: [Int: [(id: String, order: Int)]]] = [:]   // day -> week -> roster
        func fmt(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        func desc(_ i: SessionItem) -> String {
            let reps = (i.repMin != nil && i.repMax != nil) ? (i.repMin == i.repMax ? "\(i.repMin!)" : "\(i.repMin!)-\(i.repMax!)") : "\(i.targetReps)"
            let rir = (i.targetRIRMin != nil && i.targetRIRMax != nil) ? (i.targetRIRMin == i.targetRIRMax ? "\(i.targetRIRMin!)" : "\(i.targetRIRMin!)-\(i.targetRIRMax!)") : "\(i.targetRIR)"
            let load = i.suggestedLoad == i.suggestedLoad.rounded() ? String(Int(i.suggestedLoad)) : String(format: "%.1f", i.suggestedLoad)
            return "\(i.targetSets)x\(reps) @\(rir) L\(load)"
        }

        gate("\(ops.count) specs") {
            for day in dayOrder {
                for w in weeks {
                    guard let session = sessionAt[day]?[w] else { continue }
                    let waveType = wave(forWeek: w)
                    let tag = "wk\(w) \(day) \(fmt(session.date)) [\(waveType.displayName)]"
                    var roster = session.items.map { (id: canonical($0.exerciseId), order: $0.order) }

                    // planEdited reporting over everything in scope.
                    let touchedKeys = Set(ops.filter { $0.day == day }.compactMap { op -> String? in
                        switch op.kind {
                        case .replace(_, let from, _): return canonical(from)
                        case .rerange(let id): return canonical(id)
                        case .add: return nil
                        }
                    })
                    for i in session.items where i.planEdited {
                        if touchedKeys.contains(canonical(i.exerciseId)) { plan.report.planEditedTouched += 1 } else { plan.report.planEditedRetained += 1 }
                    }

                    // A session that is not planned or has logged data is skipped whole.
                    if session.status != .planned || hasLoggedData(session) {
                        let dayOps = ops.filter { $0.day == day }.map(\.key).joined(separator: ",")
                        plan.report.skipped.append("\(tag): session is \(session.status.rawValue)\(hasLoggedData(session) ? " with logged data" : "") — \(dayOps) not applied")
                        projected[day, default: [:]][w] = roster
                        continue
                    }
                    for op in ops where op.day == day {
                        guard let rx = op.rx.rx(for: waveType) else { continue }
                        switch op.kind {
                        case .replace(let order, let fromId, _):
                            let target = resolvedByKey[op.key]!
                            let fromMatches = session.items.filter { canonical($0.exerciseId) == canonical(fromId) }
                            let toMatches = session.items.filter { canonical($0.exerciseId) == canonical(target.id) }
                            if fromMatches.isEmpty, toMatches.count == 1 {
                                plan.report.alreadyApplied += 1
                                continue
                            }
                            guard fromMatches.count == 1, toMatches.isEmpty else {
                                fail("\(tag): \(op.key) expects exactly 1 \(fromId) and no \(target.id); found \(fromMatches.count)/\(toMatches.count)")
                                continue
                            }
                            let item = fromMatches[0]
                            if item.order != order { fail("\(tag): \(op.key) \(fromId) is at order \(item.order), expected \(order)"); continue }
                            if item.planEdited {
                                plan.report.skipped.append("\(tag): \(op.key) \(fromId) skipped — planEdited")
                                continue
                            }
                            plan.steps.append(.replace(item: item, session: session, week: w, op: op, target: target, wave: waveType, rx: rx))
                            plan.report.opLines.append("  \(tag) | \(op.key) o\(order) \(item.exerciseNameSnapshot ?? item.exerciseId) \(desc(item))  ->  \(target.name) \(rx.label) L0")
                            roster = roster.map { canonical($0.id) == canonical(fromId) ? (canonical(target.id), $0.order) : $0 }
                        case .rerange(let id):
                            let matches = session.items.filter { canonical($0.exerciseId) == canonical(id) }
                            guard matches.count == 1 else { fail("\(tag): \(op.key) expects exactly 1 \(id), found \(matches.count)"); continue }
                            let item = matches[0]
                            if item.planEdited {
                                plan.report.skipped.append("\(tag): \(op.key) \(id) skipped — planEdited")
                                continue
                            }
                            if isReranged(item, rx: rx, note: op.note) { plan.report.alreadyApplied += 1; continue }
                            plan.steps.append(.rerange(item: item, session: session, week: w, op: op, rx: rx))
                            plan.report.opLines.append("  \(tag) | \(op.key) o\(item.order) \(item.exerciseNameSnapshot ?? item.exerciseId) \(desc(item))  ->  \(rx.label) (seed L\(item.suggestedLoad == item.suggestedLoad.rounded() ? String(Int(item.suggestedLoad)) : String(item.suggestedLoad)) kept)")
                        case .add:
                            let target = resolvedByKey[op.key]!
                            if session.items.contains(where: { canonical($0.exerciseId) == canonical(target.id) }) {
                                plan.report.alreadyApplied += 1
                                continue
                            }
                            let order = (roster.map(\.order).max() ?? 0) + 1
                            plan.steps.append(.add(session: session, week: w, op: op, target: target, order: order, wave: waveType, rx: rx))
                            plan.report.opLines.append("  \(tag) | \(op.key) + \(target.name) \(rx.label) L0 at order \(order)")
                            roster.append((canonical(target.id), order))
                        }
                    }
                    projected[day, default: [:]][w] = roster
                }
            }
        }
        gate() {
            for day in dayOrder {
                for w in weeks {
                    let orders = (projected[day]?[w] ?? []).map(\.order)
                    if Set(orders).count != orders.count { fail("\(day) wk\(w): projected roster has order tie(s)") }
                }
            }
        }

        // Counts.
        for step in plan.steps {
            switch step {
            case .replace: plan.report.replaced += 1
            case .rerange: plan.report.reranged += 1
            case .add: plan.report.created += 1
            }
        }
        plan.report.alreadyAligned = plan.steps.isEmpty && plan.report.isSafe
        note("Block '\(block.name)': \(sessions.count) sessions; scope weeks \(weeks.lowerBound)-\(weeks.upperBound).")
        note("PLAN: replace \(plan.report.replaced) item(s), re-range \(plan.report.reranged), create \(plan.report.created); already applied \(plan.report.alreadyApplied); sessions/slots skipped \(plan.report.skipped.count).")
        note("custom exercises: \(plan.report.customsToCreate.count) to create (\(plan.report.customsToCreate.joined(separator: ", "))), \(customSpecs.count - plan.report.customsToCreate.count) already present.")
        note("planEdited in scope: \(plan.report.planEditedRetained) on retained items (reported only), \(plan.report.planEditedTouched) on replace/re-range targets (those are skipped and listed).")
        if plan.report.alreadyAligned { note("NO-OP: nothing left to change in scope.") }

        // Projected chains (structure only), per day and letter.
        let letters: [(String, [Int])] = [("A", [4, 7, 10]), ("B", [5, 8, 11]), ("C", [6, 9, 12])]
        for day in dayOrder {
            for (letter, wks) in letters {
                let ws = wks.filter { weeks.contains($0) }
                guard ws.count >= 1 else { continue }
                var hops: [String] = []
                for (a, b) in zip(ws, ws.dropFirst()) {
                    guard let ra = projected[day]?[a], let rb = projected[day]?[b] else { hops.append("W\(a)→W\(b) MISSING"); continue }
                    let sa = Set(ra.map(\.id)), sb = Set(rb.map(\.id))
                    hops.append("W\(a)→W\(b) \(sa.intersection(sb).count)/\(sa.count)")
                }
                plan.report.chainTable.append("  \(day) / \(letter): " + ws.map { "W\($0)" }.joined(separator: "→") + "→nil   links: " + (hops.isEmpty ? "-" : hops.joined(separator: ", ")))
            }
        }
        return finish()
    }

    private static func builtInTarget(of op: Op) -> Target? {
        switch op.kind {
        case .replace(_, _, let t), .add(let t): if case .builtIn = t { return t } else { return nil }
        case .rerange: return nil
        }
    }

    private static func isReranged(_ item: SessionItem, rx: Rx, note: String) -> Bool {
        item.targetSets == rx.sets && item.setMin == rx.sets && item.setMax == rx.sets
            && item.repMin == rx.repMin && item.repMax == rx.repMax
            && item.targetRIRMin == rx.rirMin && item.targetRIRMax == rx.rirMax
            && item.prescriptionNotes == note
            && item.plannedLoadsBySet.count == rx.sets
    }

    // MARK: - Item construction / mutation

    /// Builds a new item by CALLING the materializer with a single-exercise day, so the field set, the array
    /// sizing and the reps/RIR flattening (targetReps = repMin, targetRIR = targetRIRMax) come from
    /// `DUPSessionMaterializer`. The name snapshot is set from the resolved name (the CustomExercise table for
    /// customs — `ExerciseCatalog.displayName` reads only the UserDefaults mirror).
    private static func buildItem(exerciseId: String, name: String, order: Int, wave: WaveType, rx: Rx, note: String) -> SessionItem {
        let spec = WavePrescription(wave: wave, setMin: rx.sets, setMax: rx.sets, repMin: rx.repMin, repMax: rx.repMax,
                                    targetRIRMin: rx.rirMin, targetRIRMax: rx.rirMax, intensifier: .none, intensifierNotes: nil)
        let plan = ResolvedExercisePlan(
            order: order, exerciseId: exerciseId, priority: .standard, notes: note, wave: wave,
            setMin: spec.setMin, setMax: spec.setMax, repMin: spec.repMin, repMax: spec.repMax,
            targetRIRMin: spec.targetRIRMin, targetRIRMax: spec.targetRIRMax,
            intensifier: spec.intensifier, intensifierNotes: spec.intensifierNotes,
            defaultSets: spec.defaultSetCount, defaultTargetReps: spec.defaultTargetReps, defaultTargetRIR: spec.defaultTargetRIR
        )
        let day = MaterializedProgramDay(templateId: "", weekNumber: 0, wave: wave, dayNumber: 0, title: "", role: "", exercises: [plan])
        let item = DUPSessionMaterializer.makeSessionItems(from: day)[0]
        item.exerciseNameSnapshot = name
        return item
    }

    /// Everything the replacement owns; id, createdAt, order, wave and priority stay with the existing item.
    private static func copyReplacement(from built: SessionItem, to dst: SessionItem) {
        dst.exerciseId = built.exerciseId
        dst.exerciseNameSnapshot = built.exerciseNameSnapshot
        dst.targetReps = built.targetReps
        dst.targetSets = built.targetSets
        dst.targetRIR = built.targetRIR
        dst.suggestedLoad = 0
        dst.setMin = built.setMin
        dst.setMax = built.setMax
        dst.repMin = built.repMin
        dst.repMax = built.repMax
        dst.targetRIRMin = built.targetRIRMin
        dst.targetRIRMax = built.targetRIRMax
        dst.intensifierRaw = built.intensifierRaw
        dst.intensifierNotes = built.intensifierNotes
        dst.prescriptionNotes = built.prescriptionNotes
        dst.plannedRepsBySet = built.plannedRepsBySet
        dst.plannedRIRsBySet = built.plannedRIRsBySet
        dst.plannedLoadsBySet = built.plannedLoadsBySet
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
        dst.loadOverrideReasonRaw = nil
        dst.nextSuggestedLoad = nil
        dst.updatedAt = Date()
    }

    /// Same exercise, order, wave and CURRENT seeds. Ranges, RIR, set count and notes change; the planned
    /// arrays are resized to the new set count (loads repeat the last current value).
    private static func applyRerange(item: SessionItem, rx: Rx, note: String) {
        item.targetSets = rx.sets
        item.setMin = rx.sets
        item.setMax = rx.sets
        item.repMin = rx.repMin
        item.repMax = rx.repMax
        item.targetRIRMin = rx.rirMin
        item.targetRIRMax = rx.rirMax
        item.targetReps = rx.repMin
        item.targetRIR = rx.rirMax
        item.plannedRepsBySet = Array(repeating: rx.repMin, count: rx.sets)
        item.plannedRIRsBySet = Array(repeating: rx.rirMax, count: rx.sets)
        item.plannedLoadsBySet = resized(item.plannedLoadsBySet, to: rx.sets, fill: item.suggestedLoad)
        item.prescriptionNotes = note
        item.updatedAt = Date()
    }

    static func resized<T>(_ array: [T], to count: Int, fill: T) -> [T] {
        let n = max(0, count)
        if array.count == n { return array }
        if array.count > n { return Array(array.prefix(n)) }
        return array + Array(repeating: array.last ?? fill, count: n - array.count)
    }

    // MARK: - Snapshot / fingerprint

    /// `ModelContext.rollback()` discards inserts but does NOT revert property edits on persisted objects, so
    /// every field this repair can write is recorded and restored before the rollback.
    private struct Snapshot {
        struct ItemState {
            let item: SessionItem
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

            init(_ i: SessionItem) {
                item = i
                exerciseId = i.exerciseId; exerciseNameSnapshot = i.exerciseNameSnapshot
                order = i.order; targetReps = i.targetReps; targetSets = i.targetSets; targetRIR = i.targetRIR
                suggestedLoad = i.suggestedLoad
                setMin = i.setMin; setMax = i.setMax; repMin = i.repMin; repMax = i.repMax
                targetRIRMin = i.targetRIRMin; targetRIRMax = i.targetRIRMax
                intensifierRaw = i.intensifierRaw; intensifierNotes = i.intensifierNotes; prescriptionNotes = i.prescriptionNotes
                plannedRepsBySet = i.plannedRepsBySet; plannedRIRsBySet = i.plannedRIRsBySet; plannedLoadsBySet = i.plannedLoadsBySet
                planEdited = i.planEdited
                actualReps = i.actualReps; actualLoads = i.actualLoads; actualRIRs = i.actualRIRs
                usedRestPauseFlags = i.usedRestPauseFlags; restPausePatternsBySet = i.restPausePatternsBySet
                dropSetPatternsBySet = i.dropSetPatternsBySet; setFeedbackBySet = i.setFeedbackBySet
                pumpRatingsBySet = i.pumpRatingsBySet
                coachNote = i.coachNote; loadOverrideReasonRaw = i.loadOverrideReasonRaw
                nextSuggestedLoad = i.nextSuggestedLoad; updatedAt = i.updatedAt
            }

            func restore() {
                let i = item
                i.exerciseId = exerciseId; i.exerciseNameSnapshot = exerciseNameSnapshot
                i.order = order; i.targetReps = targetReps; i.targetSets = targetSets; i.targetRIR = targetRIR
                i.suggestedLoad = suggestedLoad
                i.setMin = setMin; i.setMax = setMax; i.repMin = repMin; i.repMax = repMax
                i.targetRIRMin = targetRIRMin; i.targetRIRMax = targetRIRMax
                i.intensifierRaw = intensifierRaw; i.intensifierNotes = intensifierNotes; i.prescriptionNotes = prescriptionNotes
                i.plannedRepsBySet = plannedRepsBySet; i.plannedRIRsBySet = plannedRIRsBySet; i.plannedLoadsBySet = plannedLoadsBySet
                i.planEdited = planEdited
                i.actualReps = actualReps; i.actualLoads = actualLoads; i.actualRIRs = actualRIRs
                i.usedRestPauseFlags = usedRestPauseFlags; i.restPausePatternsBySet = restPausePatternsBySet
                i.dropSetPatternsBySet = dropSetPatternsBySet; i.setFeedbackBySet = setFeedbackBySet
                i.pumpRatingsBySet = pumpRatingsBySet
                i.coachNote = coachNote; i.loadOverrideReasonRaw = loadOverrideReasonRaw
                i.nextSuggestedLoad = nextSuggestedLoad; i.updatedAt = updatedAt
            }
        }

        let states: [ItemState]
        init(items: [SessionItem]) { states = items.map { ItemState($0) } }
        func restore() { states.forEach { $0.restore() } }
    }

    /// Every stored field of an item, for the byte-identical check on everything this repair must not touch.
    static func fingerprint(_ i: SessionItem) -> String {
        [
            i.id?.uuidString ?? "", "\(i.createdAt?.timeIntervalSince1970 ?? 0)", "\(i.updatedAt?.timeIntervalSince1970 ?? 0)",
            "\(i.order)", i.exerciseId, i.exerciseNameSnapshot ?? "",
            "\(i.targetReps)", "\(i.targetSets)", "\(i.targetRIR)", "\(i.suggestedLoad)",
            i.waveRaw ?? "", i.priorityRaw ?? "",
            "\(String(describing: i.setMin))", "\(String(describing: i.setMax))", "\(String(describing: i.repMin))", "\(String(describing: i.repMax))",
            "\(String(describing: i.targetRIRMin))", "\(String(describing: i.targetRIRMax))",
            i.intensifierRaw ?? "", i.intensifierNotes ?? "", i.prescriptionNotes ?? "",
            "\(i.logs.count)", "\(i.plannedRepsBySet)", "\(i.plannedLoadsBySet)", "\(i.plannedRIRsBySet)", "\(i.planEdited)",
            "\(i.actualReps)", "\(i.actualLoads)", "\(i.actualRIRs)", "\(i.usedRestPauseFlags)", "\(i.restPausePatternsBySet)",
            "\(i.dropSetPatternsBySet)", "\(i.setFeedbackBySet)", "\(i.pumpRatingsBySet)",
            "\(i.isCompleted)", "\(i.isPR)", i.coachNote ?? "", i.loadOverrideReasonRaw ?? "", "\(String(describing: i.nextSuggestedLoad))"
        ].joined(separator: "¦")
    }

    // MARK: - Verification (runs before save)

    private static func verify(
        block: MesoBlock, context: ModelContext, plan: Plan,
        untouchedBefore: [PersistentIdentifier: String],
        preTarget: [PersistentIdentifier: PersistentIdentifier?],
        preSeeds: [PersistentIdentifier: Seed],
        touchedIDs: Set<PersistentIdentifier>, inserted: [SessionItem]
    ) -> (lines: [String], failures: [String], chainTable: [String]) {
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
        let replacedIDs = Set(plan.steps.compactMap { step -> PersistentIdentifier? in
            if case .replace(let item, _, _, _, _, _, _) = step { return item.persistentModelID }
            return nil
        })

        // 1. Retained chains: every item whose exercise did not change targets exactly what it targeted before.
        //    The one accepted exception is an item whose old target was REPLACED (weeks 1-3 on the old lift, or the
        //    old lift in a skipped session): its chain is a dead end by design and is counted, not failed. Check 2
        //    pins exactly what such an item may target afterwards.
        var retainedBroken: [String] = []
        var retainedChecked = 0
        var deadEnds = 0
        for s in sessions {
            for i in s.items where WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                let id = i.persistentModelID
                guard let before = preTarget[id], !replacedIDs.contains(id) else { continue }
                if let before, replacedIDs.contains(before) { deadEnds += 1; continue }
                retainedChecked += 1
                let now = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)?.persistentModelID
                if now != before { retainedBroken.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId)") }
            }
        }
        check("retained chains unbroken (target unchanged)", detail: "\(retainedChecked) items; \(deadEnds) old-lift items whose target was replaced are accepted dead ends", retainedBroken)

        // 2. Every lettered item targets the same lift 3 weeks later (same day, same wave) or nothing; weeks 10+ never have a target.
        var linkProblems: [String] = []
        var checked = 0
        for s in sessions {
            for i in s.items where WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                checked += 1
                let target = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)
                let targetWeek = target.flatMap { week(of: $0) }
                let expected = sessions.first { $0.weekIndex == s.weekIndex + 3 && trimmedLabel($0) == trimmedLabel(s)
                    && $0.items.contains { canonical($0.exerciseId) == canonical(i.exerciseId) } }
                if let expected {
                    if targetWeek != expected.weekIndex { linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) -> \(targetWeek.map { "W\($0)" } ?? "none") (expected W\(expected.weekIndex))") }
                } else if target != nil {
                    linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) has an unexpected target W\(targetWeek ?? -1)")
                }
                if s.weekIndex >= 10, target != nil { linkProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId) has a target after the last rotation") }
            }
        }
        check("every chain links +3 weeks or ends; nothing after weeks 10-12 has a target", detail: "\(checked) items", linkProblems)

        // 3. New chains per replaced / added slot: A 4→7→10, B 5→8→11, C 6→9→12 over the weeks that carry the new lift.
        var newProblems: [String] = []
        var table: [String] = []
        var seen = Set<String>()
        for step in plan.steps {
            let (session, op, targetId): (Session, Op, String)
            switch step {
            case .replace(let item, let s, _, let o, let t, _, _): session = s; op = o; targetId = canonical(t.id); _ = item
            case .add(let s, _, let o, let t, _, _, _): session = s; op = o; targetId = canonical(t.id)
            case .rerange: continue
            }
            let day = trimmedLabel(session)
            guard seen.insert("\(op.key)|\(day)").inserted else { continue }
            var parts: [String] = []
            for (letter, startWeek) in [("A", 4), ("B", 5), ("C", 6)] {
                let withLift: [Int] = stride(from: startWeek, through: convertedLastWeek, by: 3).filter { w in
                    sessions.contains { $0.weekIndex == w && trimmedLabel($0) == day && $0.items.contains { canonical($0.exerciseId) == targetId } }
                }
                guard let first = withLift.first,
                      var currentSession = sessions.first(where: { $0.weekIndex == first && trimmedLabel($0) == day }),
                      var current = currentSession.items.first(where: { canonical($0.exerciseId) == targetId }) else {
                    parts.append("\(letter): none"); continue
                }
                var visited = [first]
                while let next = PlanMemoryEngine.nextTargetItem(for: current, after: currentSession, in: all),
                      let nextSession = sessionOf[next.persistentModelID] {
                    visited.append(nextSession.weekIndex); current = next; currentSession = nextSession
                    if visited.count > 6 { break }
                }
                if visited != withLift { newProblems.append("\(op.key) \(day) / \(letter): visits \(visited), expected \(withLift)") }
                parts.append("\(letter) " + visited.map { "W\($0)" }.joined(separator: "→") + "→nil")
            }
            table.append("  \(op.key) \(day) \(ExerciseCatalog.canonicalExerciseId(for: targetId)): " + parts.joined(separator: ", "))
        }
        check("new chains: 4→7→10, 5→8→11, 6→9→12 (over weeks carrying the new lift)", detail: "\(table.count) slots", newProblems)

        // 4. Counts agree with the plan.
        let plannedReplaced = plan.steps.filter { if case .replace = $0 { return true } else { return false } }.count
        let plannedReranged = plan.steps.filter { if case .rerange = $0 { return true } else { return false } }.count
        let plannedCreated = plan.steps.filter { if case .add = $0 { return true } else { return false } }.count
        check("counts match the plan", detail: "replaced \(plannedReplaced), re-ranged \(plannedReranged), created \(plannedCreated)",
              (inserted.count == plannedCreated ? [] : ["inserted \(inserted.count) != planned \(plannedCreated)"]))

        // 5. Touched and new items: clean plan, correct snapshot names, waves, no order ties.
        var dirty: [String] = []
        for item in plan.touchedItems + inserted {
            if item.planEdited { dirty.append("\(item.exerciseId) planEdited") }
            if !item.actualReps.isEmpty || !item.actualLoads.isEmpty || !item.actualRIRs.isEmpty { dirty.append("\(item.exerciseId) has actuals") }
            if item.isCompleted { dirty.append("\(item.exerciseId) isCompleted") }
            if item.exerciseNameSnapshot?.isEmpty != false { dirty.append("\(item.exerciseId) has no name snapshot") }
        }
        for item in inserted + plan.steps.compactMap({ step -> SessionItem? in if case .replace(let i, _, _, _, _, _, _) = step { return i } else { return nil } }) {
            if item.suggestedLoad != 0 || item.plannedLoadsBySet.contains(where: { $0 != 0 }) { dirty.append("\(item.exerciseId) has a non-zero load") }
            if item.coachNote != nil || item.nextSuggestedLoad != nil { dirty.append("\(item.exerciseId) kept a coachNote / nextSuggestedLoad") }
        }
        check("touched / new items: clean plan, loads 0 where required, names set", detail: "\(plan.touchedItems.count + inserted.count) items", dirty)

        var orderProblems: [String] = []
        for s in sessions {
            let orders = s.items.map(\.order)
            if Set(orders).count != orders.count { orderProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?")") }
        }
        check("no two items in a session share an order", orderProblems)

        var waveProblems: [String] = []
        for item in inserted {
            if let s = sessionOf[item.persistentModelID], item.waveRaw?.lowercased() != wave(forWeek: s.weekIndex).rawValue {
                waveProblems.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(item.exerciseId) wave \(item.waveRaw ?? "nil")")
            }
        }
        check("new items carry their session's wave", waveProblems)

        // 6. Re-ranged seeds unchanged.
        var seedProblems: [String] = []
        for step in plan.steps {
            guard case .rerange(let item, let s, let w, let op, let rx) = step, let before = preSeeds[item.persistentModelID] else { continue }
            if item.suggestedLoad != before.load { seedProblems.append("W\(w) \(s.dayLabel ?? "?") \(op.key) suggestedLoad changed") }
            if item.plannedLoadsBySet != resized(before.loads, to: rx.sets, fill: before.load) { seedProblems.append("W\(w) \(s.dayLabel ?? "?") \(op.key) planned loads are not the resized seed") }
        }
        check("re-ranged seeds unchanged (loads repeat the current seed)", seedProblems)

        // 7. Everything else is byte-identical.
        var changed: [String] = []
        var untouchedChecked = 0
        for s in sessions {
            for i in s.items where !touchedIDs.contains(i.persistentModelID) {
                guard let before = untouchedBefore[i.persistentModelID] else { continue }   // newly inserted
                untouchedChecked += 1
                if fingerprint(i) != before { changed.append("W\(s.weekIndex) \(s.dayLabel ?? "?") \(i.exerciseId)") }
            }
        }
        check("every unlisted item is byte-identical", detail: "\(untouchedChecked) items", changed)

        return (lines, failures, table)
    }

    // MARK: - Driver

    /// Registered AFTER the 12-week conversion in `runStartupBackfills`. Dry run: plan, print, store the report,
    /// set the version-keyed logged flag, return. Live: blocked unless the conversion completed.
    static func runIfNeeded(
        in context: ModelContext,
        dryRun: Bool = V52AlignmentRepair.dryRun,
        defaults: UserDefaults = .standard,
        hooks: ApplyHooks = ApplyHooks()
    ) {
        if defaults.bool(forKey: completionKey) {
            print("ℹ️ V52 alignment not needed.")
            return
        }
        if dryRun, defaults.bool(forKey: dryRunLoggedKey) {
            print("ℹ️ V52 alignment dry run already logged on this install.")
            return
        }
        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ V52 alignment: could not fetch meso blocks — nothing done.")
            return
        }
        let candidates = blocks.filter { $0.status == .active && !$0.isMaintenance }
        guard candidates.count == 1, let block = candidates.first else {
            print("ℹ️ V52 alignment: \(candidates.count) active regular blocks — nothing done, will retry.")
            return
        }

        let report = makePlan(block: block, context: context, defaults: defaults).report
        print("🧪 V52 alignment \(dryRun ? "DRY RUN" : "plan") for '\(block.name)':\n\(report.text)")

        if dryRun {
            defaults.set(report.text, forKey: reportKey)
            defaults.set(true, forKey: dryRunLoggedKey)
            print("🧪 V52 alignment dry run logged (read-only; nothing was written to the store, no custom exercise created).")
            return
        }

        if let blocker = report.liveBlocker {
            print("⛔️ V52 alignment blocked: \(blocker). Nothing written; flags left unset; will retry.")
            return
        }
        guard report.isSafe else {
            print("⛔️ V52 alignment refused: \(report.blockers.count) blocker(s). Flags left unset; will retry.")
            return
        }
        if report.alreadyAligned {
            defaults.set(true, forKey: completionKey)
            print("ℹ️ V52 alignment: nothing left to change — marked complete.")
            return
        }
        // Earlier startup migrations share this context and may leave unsaved edits. Commit them first
        // (autosave would have), so a rollback can never discard someone else's work.
        if context.hasChanges {
            do { try context.save() } catch {
                print("⚠️ V52 alignment: could not flush pending changes before apply: \(error). Flag NOT set; will retry.")
                return
            }
        }
        do {
            let ensured = try ensureCustomExercises(in: context)
            print("V52 custom exercises: created \(ensured.created.count) \(ensured.created), reused \(ensured.reused.count).")
            let applied = try apply(block: block, context: context, defaults: defaults, hooks: hooks)
            guard applied.didWrite else {
                print("⚠️ V52 alignment: apply wrote nothing. Flag left unset.")
                return
            }
            defaults.set(true, forKey: completionKey)   // only after the verified save
            logPostWriteSummary(applied, block: block, ensured: ensured)
        } catch {
            print("⛔️ V52 alignment NOT applied (store unchanged, flag NOT set; will retry): \(error)")
        }
    }

    private static func logPostWriteSummary(_ r: Report, block: MesoBlock, ensured: EnsureResult) {
        var out = ["✅ V52 alignment applied to '\(block.name)'"]
        out.append("replaced: \(r.replaced)   re-ranged: \(r.reranged)   created: \(r.created)   skipped: \(r.skipped.count)")
        out.append("custom exercises created: \(ensured.created.count) \(ensured.created)   reused: \(ensured.reused.count)")
        out.append("== NEW CHAINS ==")
        out += r.postWriteChainTable
        out.append("== VERIFICATION (ran before save) ==")
        out += r.verification.map { "  \($0)" }
        if !r.skipped.isEmpty { out.append("== SKIPPED =="); out += r.skipped.map { "  \($0)" } }
        print(out.joined(separator: "\n"))
    }
}
