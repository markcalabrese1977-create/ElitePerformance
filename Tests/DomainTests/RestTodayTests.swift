import XCTest
import SwiftData
@testable import ElitePerformance

final class RestTodayTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: scheduledKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: scheduledKey); super.tearDown() }

    // MARK: - Fixtures

    private func cal() -> Calendar { Calendar.current }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal().date(from: DateComponents(year: y, month: m, day: d))! }
    private func plus(_ d: Date, _ n: Int) -> Date { cal().date(byAdding: .day, value: n, to: d)! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        for k in [TwelveWeekMesoConversionMigration.completionKey, TwelveWeekMesoConversionMigration.dryRunLoggedKey,
                  TwelveWeekMesoConversionMigration.reportKey, TwelveWeekMesoConversionMigration.shapeWarnedKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        try ctx.save()
        return (ctx, block)
    }

    private func sorted(_ b: MesoBlock) -> [Session] { b.sessions.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) } }
    private func week(_ b: MesoBlock, _ w: Int) -> [Session] { sorted(b).filter { $0.weekIndex == w } }

    private func item(_ id: String = "leg_extension", wave: String? = nil) -> SessionItem {
        SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100, waveRaw: wave,
                    setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 1, targetRIRMax: 2,
                    plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [100, 100, 100], plannedRIRsBySet: [2, 2, 2])
    }

    /// `weeks` weeks of sessions at `offsets` days from the block start (+7 per week).
    @discardableResult
    private func addBlock(_ ctx: ModelContext, name: String, start: Date, weeks: Int, offsets: [Int],
                          status: MesoStatus = .active, labels: [String]? = nil) -> MesoBlock {
        let block = MesoBlock(name: name, startDate: start, status: status, totalWeeks: weeks)
        ctx.insert(block)
        var pi = 1
        for w in 1...weeks {
            for (k, off) in offsets.enumerated() {
                let s = Session(date: plus(start, 7 * (w - 1) + off), status: .planned, weekIndex: w,
                                dayLabel: labels?[k] ?? "Day \(k + 1)", items: [item()], programIndex: pi)
                s.meso = block
                ctx.insert(s)
                pi += 1
            }
        }
        try? ctx.save()
        return block
    }

    private func snapshot(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Session>())
            .sorted { ($0.date, $0.dayLabel ?? "", $0.id?.uuidString ?? "") < ($1.date, $1.dayLabel ?? "", $1.id?.uuidString ?? "") }
            .map { "\($0.id?.uuidString ?? "")|\($0.date.timeIntervalSince1970)|\($0.status.rawValue)|\($0.weekIndex)|\($0.programIndex ?? -1)|\($0.items.count)" }
    }

    // MARK: - Shapes

    func test_twelveWeekFixture_movesTheRestOfTheWeekOneDay_andOnlyDates() throws {
        let (ctx, block) = try makeDUPBlock()
        let w5 = week(block, 5)                      // Fri ... Wed
        let now = cal().startOfDay(for: w5[1].date)  // Sat
        let others = sorted(block).filter { $0.weekIndex != 5 }.map { "\($0.date)|\($0.weekIndex)|\($0.programIndex ?? -1)" }
        let programIndices = w5.map(\.programIndex)
        let w5Dates = w5.map(\.date)

        let plan = Service.planRestToday(meso: block, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 5)
        XCTAssertEqual(plan.moves.map { $0.session.persistentModelID }, w5.dropFirst().map(\.persistentModelID))
        XCTAssertTrue(plan.warnings.isEmpty, "Wed -> Thu stays inside the week")

        let result = try Service.restToday(plan, in: ctx)
        XCTAssertEqual(result.sessionsMoved, 5)
        XCTAssertEqual(week(block, 5)[0].date, w5Dates[0], "the session before today stays")
        for (old, s) in zip(w5Dates.dropFirst(), plan.moves) { XCTAssertEqual(s.session.date, plus(old, 1)) }
        XCTAssertEqual(sorted(block).filter { $0.weekIndex != 5 }.map { "\($0.date)|\($0.weekIndex)|\($0.programIndex ?? -1)" }, others)
        XCTAssertEqual(week(block, 5).map(\.programIndex), programIndices)
        XCTAssertEqual(week(block, 5).map(\.dayNumberInWeek), Array(1...6))
    }

    func test_threeAndFourDayBlocks() throws {
        for offsets in [[0, 2, 4], [0, 1, 3, 4]] {
            let ctx = try makeContext()
            let start = date(2026, 11, 2)
            let block = addBlock(ctx, name: "B", start: start, weeks: 3, offsets: offsets)
            let now = plus(start, 7)                               // first day of week 2
            let plan = Service.planRestToday(meso: block, context: ctx, now: now)
            XCTAssertNil(plan.refusal, "\(offsets)")
            XCTAssertEqual(plan.moves.count, offsets.count)
            try Service.restToday(plan, in: ctx)
            XCTAssertEqual(week(block, 2).map(\.date), offsets.map { plus(start, 7 + $0 + 1) }, "\(offsets)")
            XCTAssertEqual(week(block, 1).map(\.date), offsets.map { plus(start, $0) })
            XCTAssertEqual(week(block, 3).map(\.date), offsets.map { plus(start, 14 + $0) })
        }
    }

    func test_pastDaysOfTheWeek_andCompletedSessionsDoNotMove() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 2, offsets: [0, 2, 4])
        let w1 = week(block, 1)
        w1[0].status = .completed                                   // already trained
        let plan = Service.planRestToday(meso: block, context: ctx, now: plus(start, 2))
        XCTAssertEqual(plan.moves.map { $0.session.persistentModelID }, [w1[1].persistentModelID, w1[2].persistentModelID])
    }

    // MARK: - Warnings

    func test_warns_whenAMovedSessionReachesNextWeek() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = MesoBlock(name: "Odd", startDate: start, status: .active, totalWeeks: 2)
        ctx.insert(block)
        // Week 2 has a session on day 7 and one on day 14; week 3 begins on day 13 (overlapping weeks).
        for (w, off) in [(2, 7), (2, 14), (3, 13)] {
            let s = Session(date: plus(start, off), status: .planned, weekIndex: w, dayLabel: "D\(off)", items: [item()], programIndex: off)
            s.meso = block; ctx.insert(s)
        }
        try ctx.save()
        let plan = Service.planRestToday(meso: block, context: ctx, now: plus(start, 7))
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.warnings, [.reachesNextWeek(date: plus(start, 15), dayLabel: "D14")])
        XCTAssertTrue(RestTodayModel.warningLines(plan)[0].contains("next week"))
    }

    func test_warns_whenAMovedSessionPassesTheNextMesoStart() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        MesoLifecycle.scheduleNextMeso(on: plus(start, 5))
        let plan = Service.planRestToday(meso: block, context: ctx, now: start)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.warnings.count, 1)
        guard case .pastNextMesoStart? = plan.warnings.first else { return XCTFail("\(plan.warnings)") }
        XCTAssertTrue(RestTodayModel.warningLines(plan)[0].contains("next block"))
    }

    // MARK: - Scope: carry-over leak blocked

    func test_onlyTodaysBlockMoves_evenWhenAnotherBlockSharesTheWeekNumber() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let archived = addBlock(ctx, name: "Old", start: start, weeks: 1, offsets: [0, 1], status: .archived)
        let active = addBlock(ctx, name: "New", start: plus(start, 3), weeks: 1, offsets: [0, 1])   // also week 1, days 3-4
        let before = sorted(active).map(\.date)

        let plan = Service.planRestToday(meso: archived, context: ctx, now: start)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertTrue(plan.moves.allSatisfy { $0.session.meso === archived })
        try Service.restToday(plan, in: ctx)
        XCTAssertEqual(sorted(active).map(\.date), before, "the other block's week 1 is untouched")
        XCTAssertEqual(sorted(archived).map(\.date), [plus(start, 1), plus(start, 2)])
    }

    // MARK: - Refusals

    func test_collisionWithAnyOtherSession_refuses_andWritesNothing() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        let other = MesoBlock(name: "Other", startDate: start, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        let blocker = Session(date: plus(start, 3), status: .completed, weekIndex: 1, dayLabel: "Old")   // day 2 -> 3
        blocker.meso = other; ctx.insert(blocker)
        try ctx.save()
        let before = try snapshot(ctx)

        let plan = Service.planRestToday(meso: block, context: ctx, now: start)
        XCTAssertEqual(plan.refusal, .dateCollision)
        XCTAssertEqual(plan.collisions.count, 1)
        XCTAssertTrue(plan.collisions[0].occupant === blocker)
        XCTAssertFalse(RestTodayModel.collisionLines(plan).isEmpty)
        XCTAssertThrowsError(try Service.restToday(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.RestTodayError, .refused(.dateCollision))
        }
        XCTAssertEqual(try snapshot(ctx), before)
    }

    func test_sameBlockNonMovingSessionOnTheDestinationDay_refuses() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2])
        let done = Session(date: plus(start, 1), status: .completed, weekIndex: 1, dayLabel: "Done", items: [item()], programIndex: 9)
        done.meso = block; ctx.insert(done)
        try ctx.save()
        XCTAssertEqual(Service.planRestToday(meso: block, context: ctx, now: start).refusal, .dateCollision)
    }

    func test_refuses_inProgress_noPlannedToday_andLoggedWork() throws {
        let start = date(2026, 11, 2)
        let ctx1 = try makeContext()
        let b1 = addBlock(ctx1, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        week(b1, 1)[2].status = .inProgress
        XCTAssertEqual(Service.planRestToday(meso: b1, context: ctx1, now: start).refusal, .sessionInProgress)

        let ctx2 = try makeContext()
        let b2 = addBlock(ctx2, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        XCTAssertEqual(Service.planRestToday(meso: b2, context: ctx2, now: plus(start, 1)).refusal, .nothingToMove)

        let ctx3 = try makeContext()
        let b3 = addBlock(ctx3, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        week(b3, 1)[1].items[0].actualLoads = [60]
        XCTAssertEqual(Service.planRestToday(meso: b3, context: ctx3, now: start).refusal, .unsafeSession)
    }

    // MARK: - Failure restore and staleness

    func test_forcedFailures_restoreEveryDate() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = cal().startOfDay(for: week(block, 5)[0].date)
        let before = try snapshot(ctx)
        let plan = Service.planRestToday(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.restToday(plan, in: ctx, hooks: .init(forceVerificationFailure: true))) {
            guard case .verificationFailed(let problems)? = $0 as? Service.RestTodayError else { return XCTFail("\($0)") }
            XCTAssertEqual(problems.count, 1, "only the forced failure: \(problems)")
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertThrowsError(try Service.restToday(plan, in: ctx, hooks: .init(forceSaveFailure: true))) {
            guard case .saveFailed? = $0 as? Service.RestTodayError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertNoThrow(try Service.restToday(Service.planRestToday(meso: block, context: ctx, now: now), in: ctx))
    }

    func test_stalePlan_isRefusedWithoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        let plan = Service.planRestToday(meso: block, context: ctx, now: start)
        week(block, 1)[2].status = .completed            // the schedule changed after the preview
        try ctx.save()
        let before = try snapshot(ctx)
        XCTAssertThrowsError(try Service.restToday(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.RestTodayError, .planStale)
        }
        XCTAssertEqual(try snapshot(ctx), before)
    }

    // MARK: - Chains and the sheet's copy

    func test_chainsAreUntouched_onAWaveBlock() throws {
        let (ctx, block) = try makeDUPBlock()
        let w4 = week(block, 4)
        for s in w4 { for i in s.items { i.actualLoads = [100]; i.actualReps = [8]; i.actualRIRs = [2]; i.isCompleted = true }; s.status = .completed }
        let now = cal().startOfDay(for: week(block, 5)[0].date)
        let all = sorted(block)
        let before = w4.flatMap { s in s.items.map { PlanMemoryEngine.nextTargetItem(for: $0, after: s, in: all)?.persistentModelID } }
        try Service.restToday(Service.planRestToday(meso: block, context: ctx, now: now), in: ctx)
        let after = w4.flatMap { s in s.items.map { PlanMemoryEngine.nextTargetItem(for: $0, after: s, in: sorted(block))?.persistentModelID } }
        XCTAssertEqual(before, after)
    }

    func test_sheetCopy_listsTheMoves() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2], labels: ["Legs B", "Pull B"])
        let plan = RestTodayModel(meso: block, context: ctx, now: start).plan()
        let lines = RestTodayModel.moveLines(plan)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Legs B  "), lines[0])
        XCTAssertTrue(lines[0].contains(" -> "), lines[0])
        XCTAssertEqual(RestTodayModel.refusalText(.dateCollision).isEmpty, false)
    }
}
