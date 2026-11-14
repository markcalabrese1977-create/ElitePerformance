import XCTest
import SwiftData
@testable import ElitePerformance

final class RemoveInsertedDeloadTests: XCTestCase {

    private typealias Service = SessionItemEditService

    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: scheduledKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: scheduledKey); super.tearDown() }

    // MARK: - Fixtures

    private func cal() -> Calendar { Calendar.current }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal().date(from: DateComponents(year: y, month: m, day: d))! }
    private func day(_ d: Date) -> Date { cal().startOfDay(for: d) }
    private func plus(_ d: Date, _ n: Int) -> Date { cal().date(byAdding: .day, value: n, to: d)! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
        return ModelContext(c)
    }

    private func makeDUPBlock() throws -> (ModelContext, MesoBlock) {
        let ctx = try makeContext()
        ctx.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(
            startDate: date(2026, 9, 25), trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal(), mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        try ctx.save()
        return (ctx, try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first))
    }

    private func sorted(_ b: MesoBlock) -> [Session] { b.sessions.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) } }
    private func week(_ b: MesoBlock, _ w: Int) -> [Session] { sorted(b).filter { $0.weekIndex == w } }

    private func finish(_ s: Session, load: Double = 100) {
        for i in s.items {
            let n = max(1, i.targetSets)
            i.actualLoads = Array(repeating: load, count: n); i.actualReps = Array(repeating: 10, count: n)
            i.actualRIRs = Array(repeating: 2, count: n); i.isCompleted = true
        }
        s.status = .completed
    }

    private func makeSimpleBlock(_ ctx: ModelContext, weeks: Int, start: Date) throws -> MesoBlock {
        let block = MesoBlock(name: "Simple", startDate: start, status: .active, totalWeeks: weeks)
        ctx.insert(block)
        for w in 1...weeks {
            let it = SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 8, targetSets: 4, targetRIR: 2, suggestedLoad: 0,
                                 setMin: 3, setMax: 5, repMin: 8, repMax: 10, targetRIRMin: 1, targetRIRMax: 2,
                                 plannedRepsBySet: [8, 8, 8, 8], plannedLoadsBySet: [0, 0, 0, 0], plannedRIRsBySet: [2, 2, 2, 2])
            let s = Session(date: plus(start, 7 * (w - 1)), status: .planned, weekIndex: w, dayLabel: "Legs", items: [it], programIndex: w)
            s.meso = block
            ctx.insert(s)
        }
        try ctx.save()
        return block
    }

    private func snapshot(_ ctx: ModelContext) throws -> [String] {
        var out: [String] = []
        for s in try ctx.fetch(FetchDescriptor<Session>()).sorted(by: { ($0.date, $0.dayLabel ?? "", $0.id?.uuidString ?? "") < ($1.date, $1.dayLabel ?? "", $1.id?.uuidString ?? "") }) {
            out.append("S|\(s.id?.uuidString ?? "")|\(s.date.timeIntervalSince1970)|\(s.status.rawValue)|\(s.weekIndex)|\(s.programIndex.map(String.init) ?? "-")|\(s.insertedDeload.map(String.init) ?? "-")|\(s.items.count)")
            for i in s.items.sorted(by: { ($0.order, $0.exerciseId) < ($1.order, $1.exerciseId) }) {
                out.append("I|\(i.id?.uuidString ?? "")|\(i.exerciseId)|\(i.waveRaw ?? "-")|\(i.targetSets)|\(i.suggestedLoad)|\(i.plannedLoadsBySet)|\(i.actualLoads)")
            }
        }
        for m in try ctx.fetch(FetchDescriptor<MesoBlock>()) { out.append("M|\(m.totalWeeks.map(String.init) ?? "-")|\(m.sessions.count)") }
        return out
    }

    @discardableResult
    private func insert(_ block: MesoBlock, _ ctx: ModelContext, now: Date) throws -> Service.InsertDeloadResult {
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now), in: ctx)
    }

    // MARK: - Round trip

    func test_remove_undoesAnInsert_onTheTwelveWeekShape() throws {
        let (ctx, block) = try makeDUPBlock()
        for w in 1...3 { for s in week(block, w) { finish(s) } }
        let now = day(week(block, 4).map(\.date).min()!)
        let before = try snapshot(ctx)
        let sessionCount = block.sessions.count
        let totalBefore = block.totalWeeks
        let endBefore = sorted(block).last!.date

        try insert(block, ctx, now: now)
        XCTAssertEqual(block.sessions.count, sessionCount + 6)

        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 4)
        XCTAssertEqual(plan.removals.count, 6)
        XCTAssertEqual(plan.blockEndAfter, endBefore)
        let result = try Service.removeInsertedDeloadWeek(plan, in: ctx)
        XCTAssertEqual(result.deloadSessionsRemoved, 6)
        XCTAssertEqual(result.sessionsShifted, plan.shifted.count)

        XCTAssertEqual(block.sessions.count, sessionCount)
        XCTAssertEqual(block.totalWeeks, totalBefore)
        XCTAssertEqual(try snapshot(ctx), before, "dates, weeks, indices, loads, items: exactly as before the insert")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SessionItem>()).count, block.sessions.flatMap(\.items).count, "no orphaned items")
    }

    func test_remove_neverTouchesAGeneratedDeload() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 6, start: start)
        for i in week(block, 6).flatMap(\.items) { i.waveRaw = "deload" }   // generated deload, no marker
        try ctx.save()
        try insert(block, ctx, now: start)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.count, 1)

        try Service.removeInsertedDeloadWeek(Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start), in: ctx)
        XCTAssertEqual(block.sessions.count, 6)
        XCTAssertEqual(week(block, 6).first?.items.first?.waveRaw, "deload", "the generated deload stays")
        XCTAssertNil(week(block, 6).first?.insertedDeload)
        XCTAssertEqual(block.totalWeeks, 6)
    }

    func test_remove_chainsStayIntact() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 5, start: start)
        finish(week(block, 1)[0])
        try ctx.save()
        let source = week(block, 1)[0]
        let target = PlanMemoryEngine.nextTargetItem(for: source.items[0], after: source, in: sorted(block))
        try insert(block, ctx, now: plus(start, 7))
        try Service.removeInsertedDeloadWeek(Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: plus(start, 7)), in: ctx)
        let after = PlanMemoryEngine.nextTargetItem(for: source.items[0], after: source, in: sorted(block))
        XCTAssertTrue(after === target)
    }

    func test_insertSkipsAWeekThatIsAlreadyADeload_andRemoveTakesTheFirstInsertedWeek() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        try insert(block, ctx, now: start)                    // deload at week 1
        let second = Service.planInsertDeloadWeek(meso: block, context: ctx, now: start)
        XCTAssertEqual(second.weekIndex, 2, "week 1 is already a deload, so the next one goes in front of week 2")
        try Service.insertDeloadWeek(second, in: ctx)
        XCTAssertEqual(block.totalWeeks, 6)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.map(\.weekIndex).sorted(), [1, 2])

        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start)
        XCTAssertEqual(plan.weekIndex, 1)
        try Service.removeInsertedDeloadWeek(plan, in: ctx)
        XCTAssertEqual(block.totalWeeks, 5)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.map(\.weekIndex), [1])
        XCTAssertEqual(Set(block.sessions.map(\.weekIndex)), Set(1...5))
    }

    // MARK: - Refusals

    func test_refuses_whenThereIsNothingToRemove() throws {
        let ctx = try makeContext()
        let block = try makeSimpleBlock(ctx, weeks: 3, start: date(2026, 11, 2))
        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: date(2026, 11, 2))
        XCTAssertEqual(plan.refusal, .noInsertedDeload)
        XCTAssertThrowsError(try Service.removeInsertedDeloadWeek(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.RemoveDeloadError, .refused(.noInsertedDeload))
        }
    }

    func test_refuses_whenTheDeloadHasStarted_orALaterSessionIsDone_orMixedWeek() throws {
        let start = date(2026, 11, 2)

        let ctx1 = try makeContext()
        let b1 = try makeSimpleBlock(ctx1, weeks: 4, start: start)
        try insert(b1, ctx1, now: start)
        week(b1, 1)[0].items[0].actualLoads = [40]               // started logging the deload
        XCTAssertEqual(Service.planRemoveInsertedDeloadWeek(meso: b1, context: ctx1, now: start).refusal, .deloadStarted)

        let ctx2 = try makeContext()
        let b2 = try makeSimpleBlock(ctx2, weeks: 4, start: start)
        try insert(b2, ctx2, now: start)
        finish(week(b2, 3)[0])                                   // a later session was completed
        XCTAssertEqual(Service.planRemoveInsertedDeloadWeek(meso: b2, context: ctx2, now: start).refusal, .laterSessionCompleted)

        let ctx3 = try makeContext()
        let b3 = try makeSimpleBlock(ctx3, weeks: 4, start: start)
        try insert(b3, ctx3, now: start)
        let extra = Session(date: plus(start, 3), status: .planned, weekIndex: 1, dayLabel: "Extra")
        extra.meso = b3; ctx3.insert(extra)
        XCTAssertEqual(Service.planRemoveInsertedDeloadWeek(meso: b3, context: ctx3, now: start).refusal, .mixedWeek)

        let ctx4 = try makeContext()
        let b4 = try makeSimpleBlock(ctx4, weeks: 4, start: start)
        try insert(b4, ctx4, now: start)
        week(b4, 2)[0].status = .inProgress
        XCTAssertEqual(Service.planRemoveInsertedDeloadWeek(meso: b4, context: ctx4, now: start).refusal, .sessionInProgress)
    }

    func test_refuses_andListsCollisions_withoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        try insert(block, ctx, now: start)     // deload Nov 2; old week 1 -> Nov 9 ...
        let other = MesoBlock(name: "Other", startDate: start, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        // Moving back a week puts the Nov 9 session on Nov 2 (freed), Nov 16 on Nov 9 (freed) ... a blocker
        // on Nov 16 is hit by the Nov 23 session.
        let blocker = Session(date: plus(start, 14), status: .completed, weekIndex: 1, dayLabel: "Old")
        blocker.meso = other; ctx.insert(blocker)
        try ctx.save()
        let before = try snapshot(ctx)

        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start)
        XCTAssertEqual(plan.refusal, .dateCollision)
        XCTAssertFalse(plan.collisions.isEmpty)
        XCTAssertTrue(plan.collisions.allSatisfy { $0.occupant === blocker })
        XCTAssertThrowsError(try Service.removeInsertedDeloadWeek(plan, in: ctx))
        XCTAssertEqual(try snapshot(ctx), before)
    }

    func test_stalePlan_isRefusedWithoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        try insert(block, ctx, now: start)
        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start)
        block.sessions.first { $0.weekIndex == 4 }?.status = .planned   // no change in scope...
        let extra = Session(date: plus(start, 30), status: .planned, weekIndex: 5, dayLabel: "Legs")   // ...but a new later session appears
        extra.meso = block; ctx.insert(extra); block.sessions.append(extra)
        try ctx.save()
        let before = try snapshot(ctx)
        XCTAssertThrowsError(try Service.removeInsertedDeloadWeek(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.RemoveDeloadError, .planStale)
        }
        XCTAssertEqual(try snapshot(ctx), before)
    }

    // MARK: - Rollback

    func test_forcedFailures_leaveEveryFieldUnchanged_includingTheInsertedSessions() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = day(week(block, 4).map(\.date).min()!)
        try insert(block, ctx, now: now)
        MesoLifecycle.scheduleNextMeso(on: date(2027, 2, 1))
        let before = try snapshot(ctx)
        let nextBefore = MesoLifecycle.scheduledStartDate

        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.removeInsertedDeloadWeek(plan, in: ctx, hooks: .init(forceVerificationFailure: true))) {
            guard case .verificationFailed(let problems)? = $0 as? Service.RemoveDeloadError else { return XCTFail("\($0)") }
            XCTAssertEqual(problems.count, 1, "only the forced failure: \(problems)")
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertFalse(ctx.hasChanges)

        XCTAssertThrowsError(try Service.removeInsertedDeloadWeek(plan, in: ctx, hooks: .init(forceSaveFailure: true))) {
            guard case .saveFailed? = $0 as? Service.RemoveDeloadError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, nextBefore)
        // The same plan still applies afterwards.
        XCTAssertNoThrow(try Service.removeInsertedDeloadWeek(Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: now), in: ctx))
    }

    // MARK: - Next block start

    func test_nextMesoStart_movesBackAWeek() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        MesoLifecycle.scheduleNextMeso(on: date(2027, 1, 4))
        try insert(block, ctx, now: start)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, day(date(2027, 1, 11)))
        try Service.removeInsertedDeloadWeek(Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start), in: ctx)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, day(date(2027, 1, 4)))
    }
}
