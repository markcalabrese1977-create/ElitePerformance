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
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
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

// MARK: - Overdue planned sessions: Do today / Move / Skip, and the W#D# label that follows the session

final class OverdueSessionTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"
    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: scheduledKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: scheduledKey); super.tearDown() }

    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 5))! }
    private func plus(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
        return ModelContext(c)
    }

    private func item(wave: String) -> SessionItem {
        SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100, waveRaw: wave,
                    setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 1, targetRIRMax: 2,
                    plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [100, 100, 100], plannedRIRsBySet: [2, 2, 2])
    }

    /// 3 weeks x 6 days (Push A, Legs A, Pull A, Push B, Legs B, Pull B), one a day from `start`, programIndex 1...18.
    private func block(_ ctx: ModelContext, start: Date, status: MesoStatus = .active) -> MesoBlock {
        let b = MesoBlock(name: "B", startDate: start, status: status, totalWeeks: 3)
        ctx.insert(b)
        let labels = ["Push A", "Legs A", "Pull A", "Push B", "Legs B", "Pull B"]
        var pi = 1
        for w in 1...3 {
            for (k, l) in labels.enumerated() {
                let s = Session(date: plus(start, 7 * (w - 1) + k), status: .planned, weekIndex: w, dayLabel: l,
                                items: [item(wave: k < 3 ? "a" : "b")], programIndex: pi)
                s.meso = b; ctx.insert(s); pi += 1
            }
        }
        try? ctx.save()
        return b
    }

    private func sorted(_ b: MesoBlock) -> [Session] { b.sessions.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) } }
    private func s(_ b: MesoBlock, _ pi: Int) -> Session { sorted(b)[pi - 1] }
    private func complete(_ x: Session) { x.status = .completed; x.items.forEach { $0.actualReps = [8, 8, 8]; $0.actualLoads = [100, 100, 100]; $0.actualRIRs = [2, 2, 2] } }

    func test_overdueWindows_recentCardVersusOlderMissedRow_andWhoIsExcluded() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let archived = block(ctx, start: plus(start, -60), status: .archived)
        let now = plus(start, 9)                            // Wed Nov 11 = week 2, day 3 (programIndex 9)
        for pi in [1, 3] { complete(s(b, pi)) }             // done
        s(b, 2).skippedAt = now                             // skipped
        s(b, 4).items[0].actualReps = [8]; s(b, 4).items[0].actualLoads = [100]   // started: not offered
        let all = sorted(b) + sorted(archived)
        XCTAssertEqual(Service.recentlyMissed(in: all, now: now).compactMap(\.programIndex), [7, 8], "Nov 9 and Nov 10: the last two days")
        XCTAssertEqual(Service.olderMissed(in: all, now: now).compactMap(\.programIndex), [5, 6], "Nov 6 and 7: the Program tab's Missed row")
        XCTAssertTrue(Service.overdueSessions(in: all, now: now).allSatisfy { $0.meso === b }, "an archived block never")
        XCTAssertEqual(Service.recentlyMissed(in: all, now: plus(start, 12)).compactMap(\.programIndex), [10, 11], "the window slides with the day")
    }

    func test_superseded_aLaterCompletionOfTheSameDayLabelInTheSameBlock_filtersItWithoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let other = block(ctx, start: plus(start, -200), status: .active)         // another block's "Push A" never counts
        for x in sorted(other) where x.dayLabel == "Push A" { complete(x) }
        let now = plus(start, 9)                                                  // Nov 11; pi 7 (Push A, Nov 9) and pi 8 (Legs A, Nov 10) are overdue
        XCTAssertEqual(Service.overdueSessions(in: sorted(b) + sorted(other), now: now).filter { $0.meso === b }.compactMap(\.programIndex), [1, 2, 3, 4, 5, 6, 7, 8])
        // Push A of week 3 (Nov 16) is done early: every earlier Push A (pi 1 and 7) is superseded; Legs A and the rest are not.
        complete(s(b, 13))
        let before = sorted(b).map { ($0.status, $0.date, $0.skippedAt) }
        let after = Service.overdueSessions(in: sorted(b) + sorted(other), now: now).filter { $0.meso === b }.compactMap(\.programIndex)
        XCTAssertEqual(after, [2, 3, 4, 5, 6, 8])
        XCTAssertEqual(sorted(b).map { ($0.status, $0.date, $0.skippedAt) }.count, before.count)
        XCTAssertTrue(zip(before, sorted(b).map { ($0.status, $0.date, $0.skippedAt) }).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }, "no writes")
        // A completion BEFORE its date does not supersede it: Push A week 1 was done Nov 2, so Nov 9's is still genuinely missed.
        let ctx2 = try makeContext()
        let b2 = block(ctx2, start: start)
        complete(s(b2, 1))
        XCTAssertTrue(Service.overdueSessions(in: sorted(b2), now: now).compactMap(\.programIndex).contains(7))
        XCTAssertFalse(Service.overdueSessions(in: sorted(b2), now: now).compactMap(\.programIndex).contains(1), "done is done")
    }

    func test_doToday_withASessionToday_pushesTodayAndEveryLaterOne_andTheLabelsStay() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)                            // Nov 11; today's session is programIndex 9
        let missed = s(b, 7)                                // Push A, Nov 9 (W2D1)
        XCTAssertEqual(missed.weekDayLabel, "W2D1")
        let before = sorted(b).map { ($0.programIndex, $0.weekIndex, $0.dayLabel, $0.weekDayLabel) }
        let oldDates = sorted(b).map(\.date)

        let plan = Service.planPlaceOverdue(missed, on: now, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.compactMap { $0.session.programIndex }, Array(9...18), "today's session and every later one")
        let result = try Service.placeOverdue(plan, in: ctx)
        XCTAssertEqual(result.sessionsMoved, 11)

        XCTAssertEqual(cal.startOfDay(for: missed.date), cal.startOfDay(for: now))
        for (pi, old) in zip(9...18, oldDates.dropFirst(8)) { XCTAssertEqual(s(b, pi).date, plus(old, 1), "programIndex \(pi)") }
        for pi in 1...8 where pi != 7 { XCTAssertEqual(s(b, pi).date, oldDates[pi - 1], "earlier sessions stay") }
        let after = sorted(b).map { ($0.programIndex, $0.weekIndex, $0.dayLabel, $0.weekDayLabel) }
        XCTAssertTrue(zip(before, after).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }, "program order, weeks, names and W#D# labels all stay")
        XCTAssertEqual(missed.weekDayLabel, "W2D1", "the label follows the session even though it now sits after Legs A in date order")
        XCTAssertEqual(s(b, 8).weekDayLabel, "W2D2")
        XCTAssertEqual(missed.plannedDate, missed.date, "the schedule moved with it")
    }

    func test_doToday_whenTodayIsFree_movesOnlyThatSession() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        complete(s(b, 9))                                   // today's slot was used for a different session
        let oldDates = sorted(b).map(\.date)
        let plan = Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertTrue(plan.moves.isEmpty, "nothing planned on today: nothing to push")
        try Service.placeOverdue(plan, in: ctx)
        XCTAssertEqual(cal.startOfDay(for: s(b, 7).date), cal.startOfDay(for: now))
        for pi in 1...18 where pi != 7 { XCTAssertEqual(s(b, pi).date, oldDates[pi - 1]) }
    }

    func test_move_toAnOccupiedDay_pushesFromThatDay_andToAFarDayThatWouldReorderTheLift_isRefusedAndRestored() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        let oldDates = sorted(b).map(\.date)
        // Legs A (week 2, Nov 10) to Fri Nov 13, a day with Legs B on it: Legs B and everything after moves a day.
        let legsA = s(b, 8)
        let plan = Service.planPlaceOverdue(legsA, on: plus(start, 11), context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.compactMap { $0.session.programIndex }, Array(11...18))
        try Service.placeOverdue(plan, in: ctx)
        XCTAssertEqual(cal.startOfDay(for: legsA.date), cal.startOfDay(for: plus(start, 11)))
        XCTAssertEqual(s(b, 9).date, oldDates[8], "the days before the chosen one are untouched")
        XCTAssertEqual(legsA.weekDayLabel, "W2D2")

        // A day after the lift's next same-letter session (Push A week 3 is Nov 16): the lift's history order would change.
        let ctx2 = try makeContext()
        let b2 = block(ctx2, start: start)
        let push = s(b2, 7)
        let far = Service.planPlaceOverdue(push, on: plus(start, 40), context: ctx2, now: now)
        XCTAssertNil(far.refusal)
        let dates = sorted(b2).map(\.date)
        XCTAssertThrowsError(try Service.placeOverdue(far, in: ctx2)) { error in
            guard case Service.PlaceError.verificationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(sorted(b2).map(\.date), dates, "nothing written")
    }

    func test_previewText_summarisesALongPush_andNamesEveryLineOfAShortOne() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        let long = Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now)
        let lines = OverdueText.moveLines(long)
        XCTAssertEqual(lines.count, 4, "the session, two pushes, and one summary line")
        XCTAssertTrue(lines[3].hasPrefix("and 8 more, each one day later"), lines[3])
        complete(s(b, 9))
        let short = Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now)
        XCTAssertEqual(OverdueText.moveLines(short).count, 1, "today is free: just the session")
        XCTAssertEqual(OverdueText.title(s(b, 7)), "Missed " + OverdueText.weekday(s(b, 7).date))
        XCTAssertEqual(OverdueText.subtitle(s(b, 7)), "Push A · W2D1")
        XCTAssertEqual(OverdueText.missedRow(6), "Missed (6)")
    }

    func test_refusals() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 7), on: plus(now, -1), context: ctx, now: now).refusal, .targetInPast)
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 12), on: now, context: ctx, now: now).refusal, .notOverdue, "a future session is not overdue")
        s(b, 7).skippedAt = now
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now).refusal, .notOverdue, "a skipped one is closed")
        s(b, 14).items[0].actualReps = [8]; s(b, 14).items[0].actualLoads = [100]    // a later session with logged work would have to move
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 8), on: now, context: ctx, now: now).refusal, .unsafeSession)
        s(b, 14).items[0].actualReps = []; s(b, 14).items[0].actualLoads = []
        s(b, 10).status = .inProgress
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 8), on: now, context: ctx, now: now).refusal, .sessionInProgress)
    }

    func test_skip_keepsItPlannedAndDated_leavesTheOverdueSurfaces_andStillCountsAsMissed() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        complete(s(b, 4))                                   // trained later, so the block is not abandoned
        let now = plus(start, 9)
        func missedSignals() -> Int {
            let snap = SetRecordBuilder.build(sessions: sorted(b))
            return FatigueMonitor.signals(in: snap, loadIncrementLb: 5, asOf: now).filter { $0.type == .missedSessions }.count
        }
        let before = missedSignals()
        XCTAssertGreaterThan(before, 0, "pi 1-3 are missed (planned, past, a later session was done)")
        let planned = [s(b, 1), s(b, 2), s(b, 3)].map(\.plannedDate)
        for pi in 1...3 { try Service.skip(s(b, pi), now: now, in: ctx) }
        XCTAssertEqual([s(b, 1), s(b, 2), s(b, 3)].map(\.skippedAt), [now, now, now])
        XCTAssertEqual([s(b, 1), s(b, 2), s(b, 3)].map(\.status), [.planned, .planned, .planned])
        XCTAssertEqual([s(b, 1), s(b, 2), s(b, 3)].map(\.plannedDate), planned)
        XCTAssertFalse(Service.overdueSessions(in: sorted(b), now: now).contains { [1, 2, 3].contains($0.programIndex ?? 0) })
        XCTAssertEqual(missedSignals(), before, "a skipped session still counts toward the missed-session signal")
    }

    func test_dayNumber_followsProgramOrder_andFallsBackToDateOrderForOldData() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        // A completion overwrites `date`: Push A (D1) done on the day of Pull A would sort after it by date.
        s(b, 7).date = plus(start, 13)
        XCTAssertEqual(s(b, 7).weekDayLabel, "W2D1")
        XCTAssertEqual(sorted(b).filter { $0.weekIndex == 2 }.map(\.dayNumberInWeek), [1, 2, 3, 4, 5, 6])
        // Old data without a programIndex: date order, as before.
        let push = s(b, 7)
        for x in sorted(b).filter({ $0.weekIndex == 2 }) { x.programIndex = nil }
        XCTAssertEqual(push.dayNumberInWeek, 6, "date order when the program order is unknown")
    }
}


// MARK: - Dry run: what the overdue surfaces would show on a real backup (report only)

@MainActor
final class OverdueDryRunTests: XCTestCase {
    func test_report_overdueSurfacesOnTheBackups() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_OD_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_OD_BACKUPS (comma-separated); optional TEST_RUNNER_EP_OD_NOW (ISO date) and TEST_RUNNER_EP_OD_REPORT")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("OD| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_OD_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        let now: Date = ProcessInfo.processInfo.environment["EP_OD_NOW"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        func load(_ path: String) throws -> (ModelContext, [Session]) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            retained.append(container)
            return (ctx, try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])))
        }
        typealias Service = SessionItemEditService
        for path in list.split(separator: ",").map(String.init) {
            let (_, sessions) = try load(path)
            out("================ \(URL(fileURLWithPath: path).lastPathComponent)   (as of \(OverdueText.day(now)))")
            let recent = Service.recentlyMissed(in: sessions, now: now), older = Service.olderMissed(in: sessions, now: now)
            out("Today card: \(recent.count) missed in the last two days")
            for s in recent { out("   \(OverdueText.title(s)) - \(OverdueText.subtitle(s))  [\(OverdueText.prompt)]") }
            out("Program tab: \(OverdueText.missedRow(older.count))\(older.isEmpty ? "" : " (collapsed)")")
            for s in older { out("   \(OverdueText.rowTitle(s))") }
            let todays = sessions.filter { Calendar.current.startOfDay(for: $0.date) == Calendar.current.startOfDay(for: now) && $0.status == .planned }
            out("Today's own session: \(todays.map { "\($0.dayLabel ?? "?") \($0.weekDayLabel)" }.joined(separator: ", ").nilIfEmpty ?? "none")")
            // Every overdue session through "Do today", each on a fresh copy of the backup.
            for target in recent + older {
                let (ctx, fresh) = try load(path)
                guard let s = fresh.first(where: { $0.id == target.id }) else { continue }
                let labelBefore = s.weekDayLabel
                let plan = Service.planPlaceOverdue(s, on: now, context: ctx, now: now)
                if let refusal = plan.refusal { out("   Do today \(s.dayLabel ?? "?") (\(OverdueText.day(s.date))): refused - \(OverdueText.refusalText(refusal))"); continue }
                let weekBefore = fresh.filter { $0.meso === s.meso && $0.weekIndex == s.weekIndex }.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }.map { "\($0.dayLabel ?? "?") \($0.weekDayLabel)" }
                do {
                    try Service.placeOverdue(plan, in: ctx)
                    let weekAfter = fresh.filter { $0.meso === s.meso && $0.weekIndex == s.weekIndex }.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }.map { "\($0.dayLabel ?? "?") \($0.weekDayLabel)" }
                    out("   Do today \(s.dayLabel ?? "?") (\(OverdueText.day(plan.oldDate)) -> \(OverdueText.day(plan.newDate))): pushes \(plan.moves.count) session(s) one day" + (plan.moves.first.map { " (\($0.session.dayLabel ?? "?") \(OverdueText.day($0.oldDate)) -> \(OverdueText.day($0.newDate)) ... last \(OverdueText.day(plan.moves.last!.newDate)))" } ?? ""))
                    out("      label \(labelBefore) -> \(s.weekDayLabel); week \(s.weekIndex) labels before: \(weekBefore.joined(separator: ", "))")
                    out("                                  after:  \(weekAfter.joined(separator: ", "))")
                } catch { out("   Do today \(s.dayLabel ?? "?"): \(error)") }
            }
        }
    }
    private var retained: [ModelContainer] = []
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
