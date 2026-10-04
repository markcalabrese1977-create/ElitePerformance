import XCTest
import SwiftData
@testable import ElitePerformance

/// The one-time same-letter catch-up. Synthetic cases pin each guard and the apply/rollback
/// contract; the fixture test (TEST_RUNNER_EP_BACKUP_FIXTURE) cross-checks the migration against
/// a replay of carry-forward itself on the real backup.
final class SameLetterCatchUpTests: XCTestCase {

    private typealias M = SameLetterTargetCatchUpMigration

    // MARK: - Fixture

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }

    private func source(
        _ id: String = "leg_extension", wave: String? = "a", load: Double = 300, reps: [Int] = [12, 12, 10],
        override: LoadOverrideReason? = nil, targetSets: Int? = nil
    ) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 12, targetSets: targetSets ?? reps.count,
                            targetRIR: 2, suggestedLoad: load, waveRaw: wave, repMin: 10, repMax: 12,
                            loadOverrideReasonRaw: override?.rawValue)
        i.actualReps = reps
        i.actualLoads = Array(repeating: load, count: reps.count)
        i.actualRIRs = Array(repeating: 2, count: reps.count)
        i.plannedLoadsBySet = Array(repeating: load, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    private func target(
        _ id: String = "leg_extension", wave: String? = "a", seed: Double = 317.5, edited: Bool = false
    ) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 12, targetSets: 3, targetRIR: 2,
                            suggestedLoad: seed, waveRaw: wave, repMin: 10, repMax: 12)
        i.plannedLoadsBySet = [seed, seed, seed]
        i.planEdited = edited
        return i
    }

    /// An active block with one completed week-1 session and one planned week-4 session.
    private func block(
        _ ctx: ModelContext, src: SessionItem, tgt: SessionItem, targetStatus: SessionStatus = .planned
    ) throws -> (MesoBlock, Session, Session) {
        let block = MesoBlock(name: "Test Block", startDate: day(-30), status: .active, totalWeeks: 10)
        let s1 = Session(date: day(-3), status: .completed, weekIndex: 1, dayLabel: "Legs A", items: [src])
        let s4 = Session(date: day(18), status: targetStatus, weekIndex: 4, dayLabel: "Legs A", items: [tgt])
        s1.meso = block; s4.meso = block
        ctx.insert(block); ctx.insert(s1); ctx.insert(s4)
        try ctx.save()
        return (block, s1, s4)
    }

    private func defaultsSuite() -> UserDefaults {
        let name = "catchup-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Plan

    func test_plan_holdBelowSeed_isARow_andIsReadOnly() throws {
        let ctx = try makeContext()
        let tgt = target()
        let (blk, _, _) = try block(ctx, src: source(), tgt: tgt)
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].newLoad, 300, accuracy: 0.001)
        XCTAssertEqual(plan.rows[0].storedLoad, 317.5, accuracy: 0.001)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, "planning never writes")
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertTrue(plan.text.contains("317.5 -> 300"), plan.text)
    }

    func test_plan_matchesWhatCarryForwardWouldWrite() throws {
        let ctx = try makeContext(); let ctx2 = try makeContext()
        let tgt = target(); let tgt2 = target()
        let (blk, _, _) = try block(ctx, src: source(), tgt: tgt)
        let (_, s1b, _) = try block(ctx2, src: source(), tgt: tgt2)
        PlanMemoryEngine(context: ctx2).carryForwardPlans(from: s1b)
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertEqual(plan.rows[0].newLoad, tgt2.suggestedLoad, accuracy: 0.001)
        XCTAssertEqual(plan.rows[0].newPlan, tgt2.plannedLoadsBySet)
    }

    func test_plan_waveNilSource_isSkippedEntirely() throws {
        let ctx = try makeContext()
        let tgt = target(wave: nil)
        let (blk, _, _) = try block(ctx, src: source(wave: nil), tgt: tgt)
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertTrue(plan.skipped.contains { $0.contains("wave-nil source") }, "\(plan.skipped)")
    }

    func test_plan_equalTarget_isNotARow() throws {
        let ctx = try makeContext()
        let (blk, _, _) = try block(ctx, src: source(), tgt: target(seed: 300))
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(plan.unchanged, 1)
    }

    func test_plan_guards_eachSkipIsLoggedWithItsReason() throws {
        struct Case { let name: String; let src: SessionItem; let tgt: SessionItem; let status: SessionStatus; let reason: String }
        let cases = [
            Case(name: "edited", src: source(), tgt: target(edited: true), status: .planned, reason: "edited"),
            Case(name: "exempt", src: source("cable_tricep_rope_pushdown"), tgt: target("cable_tricep_rope_pushdown"),
                 status: .planned, reason: "exempt"),
            Case(name: "evidence", src: source(reps: [12], targetSets: 3), tgt: target(), status: .planned,
                 reason: "incomplete evidence (1 of 3"),
            Case(name: "suppressing", src: source(override: .generalFatigue), tgt: target(), status: .planned,
                 reason: "suppressing override"),
            Case(name: "bodyweight", src: source("pull_up", load: 10, reps: [8, 8, 8]), tgt: target("pull_up", seed: 5),
                 status: .planned, reason: "bodyweight"),
            Case(name: "not planned", src: source(), tgt: target(), status: .inProgress, reason: "not planned"),
            Case(name: "empty target", src: source(), tgt: target(seed: 0), status: .planned, reason: "empty target"),
        ]
        for c in cases {
            let ctx = try makeContext()
            let seedBefore = c.tgt.suggestedLoad
            let (blk, _, _) = try block(ctx, src: c.src, tgt: c.tgt, targetStatus: c.status)
            let plan = M.plan(block: blk, context: ctx)
            XCTAssertTrue(plan.rows.isEmpty, "\(c.name): \(plan.skipped)")
            XCTAssertTrue(plan.skipped.contains { $0.contains(c.reason) }, "\(c.name): \(plan.skipped)")
            XCTAssertEqual(c.tgt.suggestedLoad, seedBefore, c.name)
        }
        // A wave-"a" source never targets a deload item (the letter differs) — nothing to write.
        let ctx = try makeContext()
        let d = target(wave: "deload")
        let (blk, _, _) = try block(ctx, src: source(), tgt: d)
        XCTAssertTrue(M.plan(block: blk, context: ctx).rows.isEmpty)
    }

    func test_plan_loggedTarget_isSkipped() throws {
        let ctx = try makeContext()
        let tgt = target()
        tgt.actualReps = [10, 10, 10]; tgt.actualLoads = [300, 300, 300]
        let (blk, _, _) = try block(ctx, src: source(), tgt: tgt)
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertTrue(plan.skipped.contains { $0.contains("already has logged sets") }, "\(plan.skipped)")
    }

    // MARK: - Apply

    func test_apply_writesOnlyTheTwoFields_andIsIdempotent() throws {
        let ctx = try makeContext()
        let tgt = target()
        let (blk, _, _) = try block(ctx, src: source(), tgt: tgt)
        let before = M.fingerprint(of: ctx)
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertEqual(try M.apply(plan: plan, context: ctx), 1)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
        XCTAssertEqual(tgt.plannedLoadsBySet, [300, 300, 300])
        XCTAssertEqual(M.fingerprint(of: ctx), before, "nothing but suggestedLoad / plannedLoadsBySet changed")
        XCTAssertFalse(tgt.planEdited)

        let second = M.plan(block: blk, context: ctx)
        XCTAssertTrue(second.rows.isEmpty, "a second run writes nothing")
        XCTAssertEqual(try M.apply(plan: second, context: ctx), 0)
    }

    func test_apply_forcedSaveFailure_rollsBack_andLeavesTheFlagUnset() throws {
        struct Boom: Error {}
        let ctx = try makeContext()
        let tgt = target()
        let (blk, _, _) = try block(ctx, src: source(), tgt: tgt)
        let plan = M.plan(block: blk, context: ctx)
        XCTAssertThrowsError(try M.apply(plan: plan, context: ctx, save: { throw Boom() }))
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
        XCTAssertEqual(tgt.plannedLoadsBySet, [317.5, 317.5, 317.5])

        let defaults = defaultsSuite()
        M.runIfNeeded(in: ctx, dryRun: false, defaults: defaults, save: { throw Boom() })
        XCTAssertFalse(defaults.bool(forKey: M.completionKey), "flag only after a successful save")
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)

        M.runIfNeeded(in: ctx, dryRun: false, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: M.completionKey))
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    func test_runIfNeeded_dryRun_writesNothing_andOnlyLogs() throws {
        let ctx = try makeContext()
        let tgt = target()
        _ = try block(ctx, src: source(), tgt: tgt)
        let defaults = defaultsSuite()
        M.runIfNeeded(in: ctx, dryRun: true, defaults: defaults)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertFalse(defaults.bool(forKey: M.completionKey))
        XCTAssertTrue(defaults.bool(forKey: M.dryRunLoggedKey))
        XCTAssertNotNil(defaults.string(forKey: M.reportKey))
    }

    func test_shipsArmed() {
        XCTAssertFalse(M.dryRun, "this branch applies the catch-up; the working branch ships it as a dry run")
    }

    func test_runIfNeeded_editedTarget_untouchedEvenWhenApplied() throws {
        let ctx = try makeContext()
        let tgt = target(edited: true)
        _ = try block(ctx, src: source(), tgt: tgt)
        M.runIfNeeded(in: ctx, dryRun: false, defaults: defaultsSuite())
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
        XCTAssertTrue(tgt.planEdited)
    }

    // MARK: - Fixture (local only)

    func test_fixture_planAgreesWithAReplayOfCarryForward() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let url = URL(fileURLWithPath: path)
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        func load() throws -> (ModelContainer, ModelContext, MesoBlock) {
            let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: c)
            let ctx = ModelContext(c)
            ctx.autosaveEnabled = false
            let active = try ctx.fetch(FetchDescriptor<MesoBlock>()).filter { $0.status == .active && !$0.isMaintenance }
            return (c, ctx, try XCTUnwrap(active.first, "no active regular block"))
        }

        // A: the migration's plan (read-only).
        let (cA, ctxA, blockA) = try load()
        let planA = M.plan(block: blockA, context: ctxA)
        print("CATCHUP|\n\(planA.text)")
        if let out = ProcessInfo.processInfo.environment["EP_CATCHUP_REPORT_OUT"], !out.isEmpty {
            try? planA.text.write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(ctxA.hasChanges)
        let planned = Dictionary(uniqueKeysWithValues: planA.rows.compactMap { r in r.targetItem.id.map { ($0, r.newLoad) } })

        // B: carry-forward itself replayed on a copy, chronologically.
        let (cB, ctxB, blockB) = try load()
        let sessionsB = try ctxB.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        let blockIDs = Set(blockB.sessions.compactMap(\.id))
        var storedB: [UUID: (load: Double, plan: [Double])] = [:]
        for s in sessionsB where s.id.map(blockIDs.contains) == true && s.status == .planned {
            for i in s.items { if let id = i.id { storedB[id] = (i.suggestedLoad, i.plannedLoadsBySet) } }
        }
        // Targets reachable from a wave-nil source: the migration skips them by design.
        var waveNilTargets = Set<UUID>()
        for s in sessionsB where s.id.map(blockIDs.contains) == true && s.status == .completed {
            for i in s.items where (i.waveRaw ?? "").isEmpty {
                if let t = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: sessionsB), let id = t.id { waveNilTargets.insert(id) }
            }
        }
        let engine = PlanMemoryEngine(context: ctxB)
        for s in sessionsB where s.id.map(blockIDs.contains) == true && s.status == .completed {
            engine.carryForwardPlans(from: s)
        }
        var replayDiff: [UUID: Double] = [:]
        for s in sessionsB where s.id.map(blockIDs.contains) == true && s.status == .planned {
            for i in s.items {
                guard let id = i.id, let old = storedB[id],
                      abs(old.load - i.suggestedLoad) > 0.0001 || old.plan != i.plannedLoadsBySet else { continue }
                replayDiff[id] = i.suggestedLoad
            }
        }
        // Every migration row is a real engine write, with the same value.
        for (id, load) in planned {
            XCTAssertEqual(try XCTUnwrap(replayDiff[id], "row \(id) is not an engine write"), load, accuracy: 0.001)
        }
        // Every engine write is a row, unless its predecessor is wave-nil (skipped by design).
        for id in replayDiff.keys where planned[id] == nil {
            XCTAssertTrue(waveNilTargets.contains(id), "engine write \(id) missing from the plan and not wave-nil")
        }

        // Idempotent, edited-safe, rollback-safe, on copies.
        let (_, ctxC, blockC) = try load()
        let planC = M.plan(block: blockC, context: ctxC)
        XCTAssertEqual(try M.apply(plan: planC, context: ctxC), planC.rows.count)
        XCTAssertTrue(M.plan(block: blockC, context: ctxC).rows.isEmpty, "second run writes nothing")

        let (_, ctxD, blockD) = try load()
        let planD = M.plan(block: blockD, context: ctxD)
        for r in planD.rows { r.targetItem.planEdited = true }
        XCTAssertTrue(M.plan(block: blockD, context: ctxD).rows.isEmpty, "edited targets are untouched")

        let (_, ctxE, blockE) = try load()
        let planE = M.plan(block: blockE, context: ctxE)
        struct Boom: Error {}
        XCTAssertThrowsError(try M.apply(plan: planE, context: ctxE, save: { throw Boom() }))
        for r in planE.rows {
            XCTAssertEqual(r.targetItem.suggestedLoad, r.storedLoad, accuracy: 0.0001)
            XCTAssertEqual(r.targetItem.plannedLoadsBySet, r.storedPlan)
        }
        _ = (cA, cB)
    }
}
