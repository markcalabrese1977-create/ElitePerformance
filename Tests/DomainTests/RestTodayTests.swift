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

    func test_twelveWeekFixture_slidesTheRunUpToTheRestDay_andOnlyDates() throws {
        let (ctx, block) = try makeDUPBlock()
        let w5 = week(block, 5)                      // Fri ... Wed
        let now = cal().startOfDay(for: w5[1].date)  // Sat
        let others = sorted(block).filter { $0.weekIndex != 5 }.map { "\($0.date)|\($0.weekIndex)|\($0.programIndex ?? -1)" }
        let programIndices = w5.map(\.programIndex)
        let w5Dates = w5.map(\.date)

        let plan = Service.planRestToday(meso: block, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.map { $0.session.persistentModelID }, w5.dropFirst().map(\.persistentModelID),
                       "Sat..Wed is one unbroken run: the Thursday rest day absorbs the slide")
        XCTAssertTrue(plan.warnings.isEmpty)

        let result = try Service.applySlide(plan, in: ctx)
        XCTAssertEqual(result.sessionsMoved, 5)
        XCTAssertEqual(week(block, 5)[0].date, w5Dates[0], "the session before today stays")
        for (old, s) in zip(w5Dates.dropFirst(), plan.moves) { XCTAssertEqual(s.session.date, plus(old, 1)) }
        XCTAssertEqual(sorted(block).filter { $0.weekIndex != 5 }.map { "\($0.date)|\($0.weekIndex)|\($0.programIndex ?? -1)" }, others)
        XCTAssertEqual(week(block, 5).map(\.programIndex), programIndices)
        XCTAssertEqual(week(block, 5).map(\.dayNumberInWeek), Array(1...6))
    }

    func test_threeAndFourDayBlocks_onlyTheRunMoves() throws {
        // offsets -> (sessions that move, week 2 dates after)
        for (offsets, moved, week2) in [([0, 2, 4], 1, [8, 9, 11]), ([0, 1, 3, 4], 2, [8, 9, 10, 11])] {
            let ctx = try makeContext()
            let start = date(2026, 11, 2)
            let block = addBlock(ctx, name: "B", start: start, weeks: 3, offsets: offsets)
            let now = plus(start, 7)                               // first day of week 2
            let plan = Service.planRestToday(meso: block, context: ctx, now: now)
            XCTAssertNil(plan.refusal, "\(offsets)")
            XCTAssertEqual(plan.moves.count, moved, "\(offsets)")
            try Service.applySlide(plan, in: ctx)
            XCTAssertEqual(week(block, 2).map(\.date), week2.map { plus(start, $0) }, "\(offsets)")
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
        XCTAssertEqual(plan.moves.map { $0.session.persistentModelID }, [w1[1].persistentModelID], "day 3 is free: only today's session moves")
    }

    // MARK: - Warnings

    func test_warns_whenAMovedSessionPassesTheNextMesoStart() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        MesoLifecycle.scheduleNextMeso(on: plus(start, 1))
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
        try Service.applySlide(plan, in: ctx)
        XCTAssertEqual(sorted(active).map(\.date), before, "the other block's week 1 is untouched")
        XCTAssertEqual(sorted(archived).map(\.date), [plus(start, 1), plus(start, 2)])
    }

    // MARK: - Refusals

    func test_anotherBlocksSessionInTheChain_refuses_namesTheDayAndTheOccupant_andWritesNothing() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        let other = MesoBlock(name: "Other", startDate: start, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        let blocker = Session(date: plus(start, 1), status: .completed, weekIndex: 1, dayLabel: "Old")   // tomorrow
        blocker.meso = other; ctx.insert(blocker)
        try ctx.save()
        let before = try snapshot(ctx)

        let plan = Service.planRestToday(meso: block, context: ctx, now: start)
        XCTAssertEqual(plan.refusal, .blocked(day: plus(start, 1), occupant: "Old", kind: .otherBlock))
        let text = RestTodayModel.refusalText(try XCTUnwrap(plan.refusal))
        XCTAssertTrue(text.contains("Old") && text.contains(RestTodayModel.day(plus(start, 1))), text)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.SlideError, .refused(plan.refusal!))
        }
        XCTAssertEqual(try snapshot(ctx), before)
    }

    func test_aCompletedSessionOfTheSameBlockInTheChain_refuses() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2])
        let done = Session(date: plus(start, 1), status: .completed, weekIndex: 1, dayLabel: "Done", items: [item()], programIndex: 9)
        done.meso = block; ctx.insert(done)
        try ctx.save()
        XCTAssertEqual(Service.planRestToday(meso: block, context: ctx, now: start).refusal,
                       .blocked(day: plus(start, 1), occupant: "Done", kind: .completed))
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
        week(b3, 1)[0].items[0].actualLoads = [60]
        XCTAssertEqual(Service.planRestToday(meso: b3, context: ctx3, now: start).refusal, .unsafeSession)
    }

    // MARK: - Failure restore and staleness

    func test_forcedFailures_restoreEveryDate() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = cal().startOfDay(for: week(block, 5)[0].date)
        let before = try snapshot(ctx)
        let plan = Service.planRestToday(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx, hooks: .init(forceVerificationFailure: true))) {
            guard case .verificationFailed(let problems)? = $0 as? Service.SlideError else { return XCTFail("\($0)") }
            XCTAssertEqual(problems.count, 1, "only the forced failure: \(problems)")
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx, hooks: .init(forceSaveFailure: true))) {
            guard case .saveFailed? = $0 as? Service.SlideError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertNoThrow(try Service.applySlide(Service.planRestToday(meso: block, context: ctx, now: now), in: ctx))
    }

    func test_stalePlan_isRefusedWithoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2, 4])
        let plan = Service.planRestToday(meso: block, context: ctx, now: start)
        let late = Session(date: plus(start, 1), status: .planned, weekIndex: 1, dayLabel: "Late", items: [item()], programIndex: 99)
        late.meso = block; ctx.insert(late)              // the schedule changed after the preview: tomorrow is now taken
        try ctx.save()
        let before = try snapshot(ctx)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.SlideError, .planStale)
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
        try Service.applySlide(Service.planRestToday(meso: block, context: ctx, now: now), in: ctx)
        let after = w4.flatMap { s in s.items.map { PlanMemoryEngine.nextTargetItem(for: $0, after: s, in: sorted(block))?.persistentModelID } }
        XCTAssertEqual(before, after)
    }

    func test_sheetCopy_listsTheMoves() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = addBlock(ctx, name: "B", start: start, weeks: 1, offsets: [0, 2], labels: ["Legs B", "Pull B"])
        let plan = RestTodayModel(meso: block, context: ctx, now: start).plan()
        let lines = RestTodayModel.moveLines(plan)
        XCTAssertEqual(lines.count, 1, "tomorrow is free: only today's session moves")
        XCTAssertTrue(lines[0].hasPrefix("Legs B  "), lines[0])
        XCTAssertTrue(lines[0].contains(" → "), lines[0])
        XCTAssertEqual(RestTodayModel.headline, "Today becomes a rest day.")
        XCTAssertEqual(RestTodayModel.moveHeading(plan), "1 session moves to the next free day:")
        XCTAssertNil(RestTodayModel.blockEndLine(plan), "the last session of the block did not move")
        XCTAssertFalse(RestTodayModel.refusalText(.nothingToMove).isEmpty)
        XCTAssertEqual(RestTodayModel.primaryTitle(plan), "Move 1 session")
        XCTAssertFalse(RestTodayModel.isRefusal(plan))
        let refused = RestTodayModel(meso: block, context: ctx, now: plus(start, 1)).plan()      // nothing planned that day
        XCTAssertTrue(RestTodayModel.isRefusal(refused))
        XCTAssertEqual(RestTodayModel.primaryTitle(refused), "OK", "a refusal shows its reason and one dismiss button, never a disabled Move 0 sessions")
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

    func test_doToday_withASessionToday_slidesTheRunToTheNextFreeDay_andTheLabelsStay() throws {
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
        // Week 2 runs Nov 9-14 with Sunday Nov 15 free: today's session and the three after it slide, then the free Sunday absorbs it.
        XCTAssertEqual(plan.moves.compactMap { $0.session.programIndex }, [7, 9, 10, 11, 12], "the session, then the unbroken run after today")
        let result = try Service.applySlide(plan, in: ctx)
        XCTAssertEqual(result.sessionsMoved, 5)

        XCTAssertEqual(cal.startOfDay(for: missed.date), cal.startOfDay(for: now))
        for pi in 9...12 { XCTAssertEqual(s(b, pi).date, plus(oldDates[pi - 1], 1), "programIndex \(pi)") }
        for pi in 13...18 { XCTAssertEqual(s(b, pi).date, oldDates[pi - 1], "nothing after the free day changes") }
        for pi in 1...8 where pi != 7 { XCTAssertEqual(s(b, pi).date, oldDates[pi - 1], "earlier sessions stay") }
        let after = sorted(b).map { ($0.programIndex, $0.weekIndex, $0.dayLabel, $0.weekDayLabel) }
        XCTAssertTrue(zip(before, after).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }, "program order, weeks, names and W#D# labels all stay")
        XCTAssertEqual(missed.weekDayLabel, "W2D1", "the label follows the session even though it now sits after Legs A in date order")
        XCTAssertEqual(s(b, 8).weekDayLabel, "W2D2")
        XCTAssertEqual(missed.plannedDate, missed.date, "the schedule moved with it")
    }

    func test_move_toAFreeDay_movesOnlyThatSession_neverMore() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        let oldDates = sorted(b).map(\.date)
        let plan = Service.planPlaceOverdue(s(b, 7), on: plus(start, 13), context: ctx, now: now)   // the free Sunday, Nov 15
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.count, 1, "nothing on the day: nothing to slide")
        try Service.applySlide(plan, in: ctx)
        XCTAssertEqual(cal.startOfDay(for: s(b, 7).date), cal.startOfDay(for: plus(start, 13)))
        for pi in 1...18 where pi != 7 { XCTAssertEqual(s(b, pi).date, oldDates[pi - 1]) }
    }

    func test_doToday_whenTodayHoldsACompletedSession_refusesAndNamesIt() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        complete(s(b, 9))                                   // today's slot was used for a different session
        let before = sorted(b).map(\.date)
        let plan = Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now)
        XCTAssertEqual(plan.refusal, .blocked(day: cal.startOfDay(for: now), occupant: "Pull A", kind: .completed))
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx))
        XCTAssertEqual(sorted(b).map(\.date), before)
    }

    func test_move_toAnOccupiedDay_slidesToTheNextFreeDay_andToAFarDayThatWouldReorderTheLift_isRefusedAndRestored() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        let oldDates = sorted(b).map(\.date)
        // Legs A (week 2, Nov 10) to Fri Nov 13, a day with a session on it: that one and the next slide a day, Sunday Nov 15 absorbs it.
        let legsA = s(b, 8)
        let plan = Service.planPlaceOverdue(legsA, on: plus(start, 11), context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.compactMap { $0.session.programIndex }, [8, 11, 12], "never more than the run")
        try Service.applySlide(plan, in: ctx)
        for pi in 13...18 { XCTAssertEqual(s(b, pi).date, oldDates[pi - 1], "after the free day nothing changes") }
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
        XCTAssertThrowsError(try Service.applySlide(far, in: ctx2)) { error in
            guard case Service.SlideError.verificationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(sorted(b2).map(\.date), dates, "nothing written")
    }

    func test_previewText_listsEveryMove_andTheBlockEndOnlyWhenItMoves() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        let long = Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now)
        let lines = OverdueText.moveLines(long)
        XCTAssertEqual(lines.count, 5, "the session and the four it slides, every one named")
        XCTAssertEqual(RestTodayModel.moveHeading(long), "5 sessions move to the next free day:")
        XCTAssertNil(RestTodayModel.blockEndLine(long))
        let short = Service.planPlaceOverdue(s(b, 7), on: plus(start, 13), context: ctx, now: now)
        XCTAssertEqual(OverdueText.moveLines(short).count, 1, "the day is free: just the session")
        XCTAssertEqual(OverdueText.title(s(b, 7)), "Missed " + OverdueText.weekday(s(b, 7).date))
        XCTAssertEqual(OverdueText.subtitle(s(b, 7)), "Push A · W2D1")
        XCTAssertEqual(OverdueText.missedRow(6), "Missed (6)")
        XCTAssertEqual(OverdueText.footer, RestTodayModel.footer, "the Move sheet and the Rest today sheet say the same thing")
        XCTAssertEqual(OverdueText.footer, "Only dates change: loads, weeks, exercises and logged work stay as they are. Sessions after the first free day are untouched.")
        XCTAssertFalse(OverdueText.footer.contains("W#D#"))
    }

    func test_refusals() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = block(ctx, start: start)
        let now = plus(start, 9)
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 7), on: plus(now, -1), context: ctx, now: now).refusal, .targetInPast)
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 12), on: now, context: ctx, now: now).refusal, .notPlaceable, "a future session is not overdue")
        s(b, 7).skippedAt = now
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 7), on: now, context: ctx, now: now).refusal, .notPlaceable, "a skipped one is closed")
        s(b, 10).items[0].actualReps = [8]; s(b, 10).items[0].actualLoads = [100]    // a session in the chain with logged work cannot move
        guard case .blocked(_, _, .loggedData)? = Service.planPlaceOverdue(s(b, 8), on: now, context: ctx, now: now).refusal else { return XCTFail("expected a loggedData block") }
        s(b, 10).items[0].actualReps = []; s(b, 10).items[0].actualLoads = []
        s(b, 8).items[0].actualReps = [8]; s(b, 8).items[0].actualLoads = [100]
        XCTAssertEqual(Service.planPlaceOverdue(s(b, 8), on: now, context: ctx, now: now).refusal, .unsafeSession, "the missed session itself has logged work")
        s(b, 8).items[0].actualReps = []; s(b, 8).items[0].actualLoads = []
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
                    try Service.applySlide(plan, in: ctx)
                    let weekAfter = fresh.filter { $0.meso === s.meso && $0.weekIndex == s.weekIndex }.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }.map { "\($0.dayLabel ?? "?") \($0.weekDayLabel)" }
                    out("   Do today \(s.dayLabel ?? "?") (\(OverdueText.day(plan.moves[0].oldDate)) -> \(OverdueText.day(plan.moves[0].newDate))): slides \(plan.pushed.count) session(s) one day" + (plan.pushed.last.map { " (last \($0.session.dayLabel ?? "?") \(OverdueText.day($0.oldDate)) -> \(OverdueText.day($0.newDate)))" } ?? ""))
                    out("      label \(labelBefore) -> \(s.weekDayLabel); week \(s.weekIndex) labels before: \(weekBefore.joined(separator: ", "))")
                    out("                                  after:  \(weekAfter.joined(separator: ", "))")
                } catch { out("   Do today \(s.dayLabel ?? "?"): \(error)") }
            }
        }
    }
    private var retained: [ModelContainer] = []
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }


// MARK: - Dry run: "Make every week the same" on a real backup (report only)

@MainActor
final class SameEveryWeekDryRunTests: XCTestCase {
    private var retained: [ModelContainer] = []

    func test_report_makeEveryWeekTheSame() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_SW_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_SW_BACKUPS (comma-separated); optional TEST_RUNNER_EP_SW_KEEP (a week letter) and TEST_RUNNER_EP_SW_REPORT")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("SW| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_SW_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        func n(_ x: Double) -> String { LoadFormatter.number(x) }
        func range(_ s: SessionItemEditService.SameWeekSnapshot) -> String {
            let reps = s.repMin != nil && s.repMax != nil ? (s.repMin == s.repMax ? "\(s.repMin!)" : "\(s.repMin!)–\(s.repMax!)") : "\(s.targetReps)"
            let rir = s.targetRIRMin != nil && s.targetRIRMax != nil && s.targetRIRMin != s.targetRIRMax ? "\(s.targetRIRMin!)–\(s.targetRIRMax!)" : "\(s.targetRIR)"
            return "\(s.targetSets)×\(reps) @ \(rir) RIR"
        }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        EffortTracking.mode = .detailed
        defer { EffortTracking.clearMirror() }
        for path in list.split(separator: ",").map(String.init) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            retained.append(container)
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            guard let meso = try ctx.fetch(FetchDescriptor<MesoBlock>()).first(where: { $0.status == .active }) else { out("no active block"); continue }
            out("================ \(URL(fileURLWithPath: path).lastPathComponent): \(meso.name)")
            let types = SessionItemEditService.sameWeekTypes(in: meso)
            out("week types: " + types.map { "\($0.letter.uppercased()) (last trained \($0.lastTrained.map { f.string(from: $0) } ?? "never"), \($0.remaining) unstarted)" }.joined(separator: "; "))
            let keep = ProcessInfo.processInfo.environment["EP_SW_KEEP"] ?? SessionItemEditService.defaultKeptWeekType(in: meso) ?? "a"
            out("keeping the \(keep.uppercased()) week's ranges")
            let before = Dictionary(uniqueKeysWithValues: meso.sessions.flatMap { s in s.items.map { ($0.persistentModelID, ($0.suggestedLoad, $0.plannedLoadsBySet)) } })
            let plan = SessionItemEditService.planSameEveryWeek(meso: meso, keep: keep, context: ctx)
            if let r = plan.refusal { out("refused: \(r)"); continue }
            out("plan: \(plan.sessionsChanged) sessions, \(plan.itemsChanged) items converted; \(plan.editedKept) kept as you edited; \(plan.unmatchedSlots) slots with no \(keep.uppercased())-week match")
            let after = Dictionary(uniqueKeysWithValues: meso.sessions.flatMap { s in s.items.map { ($0.persistentModelID, ($0.suggestedLoad, $0.plannedLoadsBySet)) } })
            XCTAssertTrue(before.allSatisfy { after[$0.key]?.0 == $0.value.0 && after[$0.key]?.1 == $0.value.1 }, "the preview wrote nothing")
            var lastSession: Session?
            if !plan.keptAsEdited.isEmpty { out("Kept as you edited (\(plan.keptAsEdited.count)):"); for c in plan.keptAsEdited.sorted(by: { ($0.session.date, $0.item.order) < ($1.session.date, $1.item.order) }) { out("   " + SameWeekText.keptLine(c)) } }
            for c in plan.converted.sorted(by: { ($0.session.date, $0.item.order) < ($1.session.date, $1.item.order) }) {
                if lastSession !== c.session {
                    lastSession = c.session
                    out("\(f.string(from: c.session.date))  \(c.session.dayLabel ?? "?")  W\(c.session.weekIndex)  (week \((c.before.waveRaw ?? "-").uppercased()) → same every week)")
                }
                let name = c.item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: c.item.exerciseId)
                let loadText = c.before.suggestedLoad == c.after.suggestedLoad ? "\(n(c.after.suggestedLoad))" : "\(n(c.before.suggestedLoad)) → \(n(c.after.suggestedLoad))"
                let rangeText = range(c.before) == range(c.after) ? range(c.after) : "\(range(c.before)) → \(range(c.after))"
                out("   \(name): \(rangeText); load \(loadText)" + (c.notes.isEmpty ? "" : "   [\(c.notes.joined(separator: "; "))]"))
            }
            // The scheduled deload: untouched by the conversion; what the refresh would then write.
            let deloads = meso.sessions.filter { $0.items.contains { $0.waveRaw?.lowercased() == "deload" } }.sorted { $0.date < $1.date }
            out("deload week (not changed by the conversion; DeloadRule still sizes it from the working loads):")
            for d in deloads { out("   \(f.string(from: d.date))  \(d.dayLabel ?? "?")  W\(d.weekIndex): " + d.items.sorted { $0.order < $1.order }.map { "\($0.exerciseNameSnapshot ?? $0.exerciseId) \(n($0.suggestedLoad))" }.joined(separator: ", ")) }
            let undoDir = FileManager.default.temporaryDirectory.appendingPathComponent("sw_dryrun_undo")
            let result = try SessionItemEditService.applySameEveryWeek(plan, backupTaken: true, in: ctx, undoDirectory: undoDir)
            out("applied in memory: \(result.sessionsChanged) sessions, \(result.itemsChanged) items")
            let refresh = PlaceholderRefresh.plan(in: ctx)
            for ch in refresh where ch.item.waveRaw?.lowercased() == "deload" {
                out("   deload \(f.string(from: ch.session.date)) \(ch.session.dayLabel ?? "?") \(ch.item.exerciseNameSnapshot ?? ch.item.exerciseId): \(n(ch.oldLoad)) → \(n(ch.newLoad))  (\(ch.reason.text))")
            }
            let undone = try SessionItemEditService.undoSameEveryWeek(meso: meso, in: ctx, undoDirectory: undoDir)
            out("undo: restored \(undone.restored), left \(undone.left)")
            let restored = Dictionary(uniqueKeysWithValues: meso.sessions.flatMap { s in s.items.map { ($0.persistentModelID, ($0.suggestedLoad, $0.plannedLoadsBySet)) } })
            XCTAssertTrue(before.allSatisfy { restored[$0.key]?.0 == $0.value.0 && restored[$0.key]?.1 == $0.value.1 }, "undo put every load back")
        }
    }
}

// MARK: - "Make every week the same"

final class SameEveryWeekTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var container: ModelContainer!
    private var undoDir: URL!
    private let cal = Calendar.current

    override func setUp() {
        super.setUp()
        undoDir = FileManager.default.temporaryDirectory.appendingPathComponent("sw_undo_\(UUID().uuidString)")
        EffortTracking.mode = .detailed
    }
    override func tearDown() { try? FileManager.default.removeItem(at: undoDir); EffortTracking.clearMirror(); super.tearDown() }

    private func ctx() throws -> ModelContext {
        let schema = AppSchema.makeSchema()
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let c = ModelContext(container)
        c.insert(User(units: .lb, progressionEnabled: true))
        return c
    }
    private func date(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 5))!)! }

    private struct Rx { let sets: Int; let lo: Int; let hi: Int; let rir: Int }
    private let push: [String: Rx] = ["a": Rx(sets: 3, lo: 12, hi: 15, rir: 0), "b": Rx(sets: 3, lo: 8, hi: 12, rir: 2), "c": Rx(sets: 4, lo: 6, hi: 10, rir: 1)]
    private let legs: [String: Rx] = ["a": Rx(sets: 4, lo: 12, hi: 15, rir: 1), "b": Rx(sets: 3, lo: 8, hi: 12, rir: 2), "c": Rx(sets: 3, lo: 6, hi: 10, rir: 1)]

    private func item(_ id: String, _ rx: Rx, wave: String, load: Double) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: rx.lo, targetSets: rx.sets, targetRIR: rx.rir, suggestedLoad: load, waveRaw: wave,
                            setMin: rx.sets, setMax: rx.sets, repMin: rx.lo, repMax: rx.hi, targetRIRMin: rx.rir, targetRIRMax: rx.rir,
                            prescriptionNotes: "note \(wave)",
                            plannedRepsBySet: Array(repeating: rx.lo, count: rx.sets), plannedLoadsBySet: Array(repeating: load, count: rx.sets),
                            plannedRIRsBySet: Array(repeating: rx.rir, count: rx.sets),
                            actualReps: Array(repeating: 0, count: rx.sets), actualLoads: Array(repeating: 0, count: rx.sets),
                            actualRIRs: RIREntry.unsetArray(count: rx.sets))
        return i
    }

    /// Weeks 1-4 letters a, b, c, a, then a deload week 5; days Push and Legs. Week 1 is completed with every set at the top of the A range
    /// (a bump is earned). Returns the block and the sessions by (week, day).
    private func block(_ c: ModelContext) throws -> (MesoBlock, [String: Session]) {
        let b = MesoBlock(name: "Wave", startDate: date(0), status: .active, totalWeeks: 5)
        c.insert(b)
        var out: [String: Session] = [:]
        var pi = 1
        for (w, letter) in ["a", "b", "c", "a", "deload"].enumerated() {
            for (k, (label, id, table)) in [("Push", "bench_press", push), ("Legs", "incline_dumbbell_press", legs)].enumerated() {
                let rx = table[letter == "deload" ? "b" : letter]!
                let it = item(id, rx, wave: letter, load: label == "Push" ? 100 : 200)
                let s = Session(date: date(7 * w + k * 2), status: .planned, weekIndex: w + 1, dayLabel: label, items: [it], programIndex: pi)
                s.meso = b; c.insert(s); out["\(w + 1)\(label)"] = s; pi += 1
            }
        }
        try c.save()
        for label in ["Push", "Legs"] {
            let s = out["1\(label)"]!
            s.status = .completed; s.completedAt = s.date
            let i = s.items[0]
            i.isCompleted = true
            i.actualReps = Array(repeating: i.repMax ?? 15, count: i.targetSets)
            i.actualLoads = Array(repeating: label == "Push" ? 100 : 200, count: i.targetSets)
            i.actualRIRs = Array(repeating: i.targetRIR, count: i.targetSets)
        }
        try c.save()
        return (b, out)
    }

    private func fingerprints(_ b: MesoBlock) -> [String: SessionItem.WriteFingerprint] {
        Dictionary(uniqueKeysWithValues: b.sessions.flatMap { s in s.items.map { ("\(s.weekIndex)\(s.dayLabel ?? "")", $0.writeFingerprint()) } })
    }

    func test_weekTypes_andTheDefaultIsTheMostRecentlyTrained() throws {
        let c = try ctx(); let (b, _) = try block(c)
        let types = Service.sameWeekTypes(in: b)
        XCTAssertEqual(types.map(\.letter), ["a", "b", "c"])
        XCTAssertEqual(types.map(\.remaining), [2, 2, 2], "unstarted sessions of each week type (the deload is not one)")
        XCTAssertEqual(Service.defaultKeptWeekType(in: b), "a")
        XCTAssertNotNil(types[0].lastTrained); XCTAssertNil(types[1].lastTrained)
    }

    func test_plan_isReadOnly_andRefuses() throws {
        let c = try ctx(); let (b, s) = try block(c)
        let before = fingerprints(b)
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.sessionsChanged, 6, "weeks 2, 3, 4 x 2 days")
        XCTAssertEqual(plan.itemsChanged, 6)
        XCTAssertEqual(fingerprints(b), before, "the preview wrote nothing")
        XCTAssertEqual(Service.planSameEveryWeek(meso: b, keep: "z", context: c).refusal, .unknownWeekType)
        s["2Push"]!.status = .inProgress
        XCTAssertEqual(Service.planSameEveryWeek(meso: b, keep: "a", context: c).refusal, .sessionInProgress)
        s["2Push"]!.status = .planned
        // a block with no letters
        let c2 = try ctx(); let (b2, _) = try block(c2)
        for x in b2.sessions { for i in x.items where i.waveRaw?.lowercased() != "deload" { i.waveRaw = nil } }
        XCTAssertEqual(Service.planSameEveryWeek(meso: b2, keep: "a", context: c2).refusal, .notAWaveBlock)
    }

    func test_apply_everyRemainingSessionTakesTheKeptPrescription_andTheCoachDecision_andNothingFinishedChanges() throws {
        let c = try ctx(); let (b, s) = try block(c)
        let done = [s["1Push"]!, s["1Legs"]!].map { $0.items[0].writeFingerprint() }
        let deloadBefore = [s["5Push"]!, s["5Legs"]!].map { $0.items[0].writeFingerprint() }
        s["3Push"]!.items[0].planEdited = true; s["3Push"]!.items[0].suggestedLoad = 95; s["3Push"]!.items[0].plannedLoadsBySet = [95, 95, 95, 95]
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        XCTAssertThrowsError(try Service.applySameEveryWeek(plan, backupTaken: false, in: c, undoDirectory: undoDir), "a backup comes first")
        let result = try Service.applySameEveryWeek(plan, backupTaken: true, backupName: "pre.json", in: c, undoDirectory: undoDir)
        XCTAssertEqual(plan.editedKept, 1); XCTAssertEqual(plan.keptAsEdited.count, 1)
        XCTAssertEqual(plan.itemsChanged, 5, "the edited one is not counted as converted")
        XCTAssertEqual(result.itemsChanged, 6, "the edited one still loses its week letter")
        let edited = s["3Push"]!.items[0]
        XCTAssertEqual([edited.targetSets, edited.repMin, edited.repMax, edited.targetRIR], [4, 6, 10, 1], "an edited item keeps its prescription entirely")
        XCTAssertEqual(edited.prescriptionNotes, "note c"); XCTAssertEqual(edited.suggestedLoad, 95); XCTAssertEqual(edited.plannedLoadsBySet, [95, 95, 95, 95])
        XCTAssertNil(edited.waveRaw, "only the week label goes, so the day still chains")
        for w in [2, 3, 4] {
            let p = s["\(w)Push"]!.items[0], l = s["\(w)Legs"]!.items[0]
            XCTAssertNil(p.waveRaw, "the letter is cleared"); XCTAssertNil(l.waveRaw)
            if w == 3 { XCTAssertEqual([l.targetSets, l.repMin, l.repMax, l.targetRIR], [4, 12, 15, 1]); XCTAssertEqual(l.suggestedLoad, 202.5); continue }
            XCTAssertEqual([p.targetSets, p.repMin, p.repMax, p.targetRIR], [3, 12, 15, 0], "week \(w) Push takes the A prescription")
            XCTAssertEqual([l.targetSets, l.repMin, l.repMax, l.targetRIR], [4, 12, 15, 1], "week \(w) Legs takes the A prescription")
            XCTAssertEqual(p.prescriptionNotes, "note a")
            XCTAssertEqual(p.plannedRepsBySet.count, 3); XCTAssertEqual(l.plannedLoadsBySet.count, 4)
            XCTAssertEqual(l.suggestedLoad, 202.5, "the coach decision of the finished Legs session (top of range at 200, one 2.5 step)")
        }
        XCTAssertEqual(s["2Push"]!.items[0].suggestedLoad, 102.5); XCTAssertEqual(s["4Push"]!.items[0].suggestedLoad, 102.5)
        XCTAssertEqual([s["1Push"]!, s["1Legs"]!].map { $0.items[0].writeFingerprint() }, done, "finished sessions are not touched")
        XCTAssertEqual([s["5Push"]!, s["5Legs"]!].map { $0.items[0].writeFingerprint() }, deloadBefore, "the deload week stays as it was")
        XCTAssertEqual(s["5Push"]!.items[0].waveRaw, "deload")
        XCTAssertEqual(s["1Push"]!.items[0].waveRaw, "a", "history keeps its letter")
        XCTAssertNotNil(Service.sameWeekUndoRecord(for: b, in: undoDir))
    }

    func test_afterTheConversion_carryForwardChainsByDayLabel() throws {
        let c = try ctx(); let (b, s) = try block(c)
        try Service.applySameEveryWeek(Service.planSameEveryWeek(meso: b, keep: "a", context: c), backupTaken: true, in: c, undoDirectory: undoDir)
        let w2 = s["2Push"]!
        w2.status = .completed; w2.completedAt = w2.date
        let i = w2.items[0]
        i.isCompleted = true
        i.actualReps = [15, 15, 15]; i.actualLoads = [102.5, 102.5, 102.5]; i.actualRIRs = [0, 0, 0]
        s["3Push"]!.items[0].planEdited = false
        PlanMemoryEngine(context: c).carryForwardPlans(from: w2)
        XCTAssertEqual(s["3Push"]!.items[0].suggestedLoad, 105, "week 2's wave-less result lands in week 3 of the same day: no letters in the way")
        XCTAssertEqual(s["3Legs"]!.items[0].suggestedLoad, 202.5, "another day is another chain (still its own decision)")
    }

    func test_undo_putsEverythingBack_andLeavesStartedSessionsAlone() throws {
        let c = try ctx(); let (b, s) = try block(c)
        let before = fingerprints(b)
        try Service.applySameEveryWeek(Service.planSameEveryWeek(meso: b, keep: "a", context: c), backupTaken: true, in: c, undoDirectory: undoDir)
        XCTAssertNotEqual(fingerprints(b), before)
        // week 2 Push is trained after the conversion: undo must not touch it
        let w2 = s["2Push"]!
        w2.status = .completed; w2.items[0].actualReps = [15, 15, 15]; w2.items[0].actualLoads = [105, 105, 105]; w2.items[0].isCompleted = true
        let started = w2.items[0].writeFingerprint()
        let r = try Service.undoSameEveryWeek(meso: b, in: c, undoDirectory: undoDir)
        XCTAssertEqual(r.left, 1); XCTAssertEqual(r.restored, 5)
        XCTAssertEqual(w2.items[0].writeFingerprint(), started)
        XCTAssertEqual(s["3Push"]!.items[0].waveRaw, "c"); XCTAssertEqual(s["3Push"]!.items[0].repMax, 10)
        XCTAssertNil(Service.sameWeekUndoRecord(for: b, in: undoDir), "the record is spent")
        // a clean undo
        let c2 = try ctx(); let (b2, _) = try block(c2)
        let before2 = fingerprints(b2)
        try Service.applySameEveryWeek(Service.planSameEveryWeek(meso: b2, keep: "a", context: c2), backupTaken: true, in: c2, undoDirectory: undoDir)
        try Service.undoSameEveryWeek(meso: b2, in: c2, undoDirectory: undoDir)
        XCTAssertEqual(fingerprints(b2), before2, "every field is back")
    }

    func test_sheetTitle_isShortEnoughToNeverTruncate() {
        XCTAssertEqual(SameWeekText.sheetTitle, "Same every week")
        XCTAssertLessThanOrEqual(SameWeekText.sheetTitle.count, 15, "the 17e at XXXL truncated a 25-character title")
        XCTAssertEqual(SameWeekText.menuTitle, "Make every week the same", "the menu and the confirmation keep the full wording")
    }

    func test_failures_leaveTheStoreAsItWas() throws {
        for hooks in [Service.ApplyHooks(forceVerificationFailure: true), Service.ApplyHooks(forceSaveFailure: true)] {
            let c = try ctx(); let (b, _) = try block(c)
            let before = fingerprints(b)
            let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
            XCTAssertThrowsError(try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir, hooks: hooks))
            XCTAssertEqual(fingerprints(b), before)
            XCTAssertNil(Service.sameWeekUndoRecord(for: b, in: undoDir))
        }
    }

    func test_startNextMeso_keepWeeksTheSame_hasNoWeekTypes_andTheKeptPrescriptionEverywhere() throws {
        let c = try ctx(); let (b, _) = try block(c)
        let start = cal.date(byAdding: .day, value: 60, to: date(0))!
        let same = Service.planNextMeso(meso: b, name: "Next", startDate: start, endOldMesoNow: true, keepWeeksTheSame: true, context: c, now: date(8))
        XCTAssertTrue(same.refusals.isEmpty, "\(same.refusals)")
        let working = same.sessions.filter { $0.letter != "deload" }
        XCTAssertFalse(working.isEmpty)
        XCTAssertTrue(working.allSatisfy { $0.letter.isEmpty && $0.items.allSatisfy { $0.waveRaw == nil } }, "no A/B/C weeks")
        var bench: [Service.NextMesoItem] = []
        for w in working { for it in w.items where it.exerciseId == "bench_press" { bench.append(it) } }
        XCTAssertFalse(bench.isEmpty)
        for it in bench {
            XCTAssertEqual(it.targetSets, 3, "the A week's set count in every week")
            XCTAssertEqual(it.repMin, 12); XCTAssertEqual(it.repMax, 15)
        }
        for d in same.sessions where d.letter == "deload" {
            for it in d.items { XCTAssertEqual(it.waveRaw?.lowercased(), "deload", "the deload stays a deload") }
        }
        let waved = Service.planNextMeso(meso: b, name: "Next", startDate: start, endOldMesoNow: true, context: c, now: date(8))
        XCTAssertTrue(waved.sessions.contains { $0.letter == "b" }, "unchanged without the option")
        XCTAssertTrue(same.keepWeeksTheSame); XCTAssertFalse(waved.keepWeeksTheSame)
    }
}

// MARK: - The one slide rule (Rest today and the overdue Move): pure cases, safety nets, and the real backups

@MainActor
final class SlideRuleTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var retained: [ModelContainer] = []
    private let scheduledKey = "meso.scheduledStartDateEpoch"
    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: scheduledKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: scheduledKey); super.tearDown() }

    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 5))! }
    private func plus(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
    private func day(_ d: Date) -> Date { cal.startOfDay(for: d) }

    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        retained.append(c)
        return ModelContext(c)
    }

    private func item(wave: String? = nil) -> SessionItem {
        SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100, waveRaw: wave,
                    setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 1, targetRIRMax: 2,
                    plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [100, 100, 100], plannedRIRsBySet: [2, 2, 2])
    }

    /// One planned session per entry of `offsets` (days from `start`), week = `weeks[i]`, programIndex 1...N, labels "S1"...
    @discardableResult
    private func block(_ ctx: ModelContext, start: Date, offsets: [Int], weeks: [Int]? = nil, wave: String? = nil) -> MesoBlock {
        let b = MesoBlock(name: "B", startDate: start, status: .active, totalWeeks: (weeks?.max() ?? 1))
        ctx.insert(b)
        for (i, off) in offsets.enumerated() {
            let s = Session(date: plus(start, off), status: .planned, weekIndex: weeks?[i] ?? 1, dayLabel: "S\(i + 1)", items: [item(wave: wave)], programIndex: i + 1)
            s.meso = b; ctx.insert(s)
        }
        try? ctx.save()
        return b
    }

    private func sessions(_ b: MesoBlock) -> [Session] { b.sessions.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) } }
    private func s(_ b: MesoBlock, _ pi: Int) -> Session { sessions(b)[pi - 1] }

    /// What may never change under a slide, and the invariants that must hold after one.
    private func fingerprint(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Session>()).sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }.map { s in
            "\(s.id?.uuidString ?? "")|\(s.status.rawValue)|\(s.weekInMeso ?? -1)|\(s.programIndex ?? -1)|\(s.dayLabel ?? "")|\(s.skippedAt != nil)|\(s.completedAt?.timeIntervalSince1970 ?? 0)|"
                + s.items.map { "\($0.exerciseId)/\($0.planEdited)/\($0.suggestedLoad)/\($0.waveRaw ?? "-")/\($0.actualLoads)" }.joined(separator: ";")
        }
    }
    private func dates(_ ctx: ModelContext) throws -> [PersistentIdentifier: Date] {
        Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<Session>()).map { ($0.persistentModelID, $0.date) })
    }

    private func assertSlideInvariants(_ plan: Service.SlidePlan, _ ctx: ModelContext, file: StaticString = #filePath, line: UInt = #line) throws {
        let fpBefore = try fingerprint(ctx), datesBefore = try dates(ctx)
        let occupiedBefore = Set(datesBefore.values.map { day($0) })
        let moving = Set(plan.moves.map { $0.session.persistentModelID })
        let lastNew = try XCTUnwrap(plan.moves.last).newDate
        XCTAssertFalse(occupiedBefore.contains(day(lastNew)) && !plan.moves.contains { day($0.oldDate) == day(lastNew) },
                       "the absorbing day held no session before", file: file, line: line)
        try Service.applySlide(plan, in: ctx)
        XCTAssertEqual(try fingerprint(ctx), fpBefore, "only dates change: status, weekInMeso, programIndex, label, skippedAt, items, planEdited", file: file, line: line)
        let after = try dates(ctx)
        let days = after.values.map { day($0) }
        XCTAssertEqual(Set(days).count, days.count, "never two sessions on one day (any block, any status)", file: file, line: line)
        for (id, old) in datesBefore where !moving.contains(id) { XCTAssertEqual(after[id], old, "a session outside the slide moved", file: file, line: line) }
        for m in plan.moves { XCTAssertEqual(after[m.session.persistentModelID], m.newDate, file: file, line: line) }
        for m in plan.pushed { XCTAssertEqual(day(m.newDate), day(plus(m.oldDate, 1)), "each pushed session moves exactly one day", file: file, line: line) }
    }

    // MARK: Pure cases

    func test_tomorrowFree_onlyTodaysSessionMoves() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 2, 4])
        let plan = Service.planRestToday(meso: b, context: ctx, now: start)
        XCTAssertEqual(plan.moves.count, 1)
        try assertSlideInvariants(plan, ctx)
        XCTAssertEqual(day(s(b, 1).date), day(plus(start, 1)))
    }

    func test_theSlideStopsAtTheFirstFreeDay_andNothingAfterItChanges() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 2, 4, 5])          // day 3 is free
        let plan = Service.planRestToday(meso: b, context: ctx, now: start)
        XCTAssertEqual(plan.moves.map { $0.session.dayLabel }, ["S1", "S2", "S3"])
        try assertSlideInvariants(plan, ctx)
        XCTAssertEqual([s(b, 1), s(b, 2), s(b, 3), s(b, 4), s(b, 5)].map { day($0.date) }, [1, 2, 3, 4, 5].map { day(plus(start, $0)) })
    }

    func test_aSlideCrossesTheWeekBoundary_andEveryWeekAndIndexStays() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: Array(0...13), weeks: Array(repeating: 1, count: 7) + Array(repeating: 2, count: 7))
        let labels = sessions(b).map(\.weekDayLabel)
        let plan = Service.planRestToday(meso: b, context: ctx, now: plus(start, 5))
        XCTAssertEqual(plan.moves.count, 9, "day 5 through day 13")
        XCTAssertEqual(Set(plan.moves.map { $0.session.weekIndex }), [1, 2], "crosses into the next block week")
        XCTAssertTrue(plan.blockEndMoves)
        XCTAssertNotNil(RestTodayModel.blockEndLine(plan))
        try assertSlideInvariants(plan, ctx)
        XCTAssertEqual(sessions(b).map(\.weekDayLabel), labels, "W#D# labels follow the sessions")
    }

    func test_theLastSessionOfTheBlockMoves_theBlockEndsADayLater() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1])
        let plan = Service.planRestToday(meso: b, context: ctx, now: plus(start, 1))
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(plan.blockEndBefore.map(day), day(plus(start, 1)))
        XCTAssertEqual(plan.blockEndAfter.map(day), day(plus(start, 2)))
        XCTAssertNotNil(RestTodayModel.blockEndLine(plan))
        try assertSlideInvariants(plan, ctx)
        XCTAssertEqual(b.totalWeeks, 1, "no stored end to update")
    }

    func test_aNilPlannedDateStaysNil_andASetOneMoves() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 3])
        s(b, 1).plannedDate = s(b, 1).date
        s(b, 2).plannedDate = nil
        try Service.applySlide(Service.planRestToday(meso: b, context: ctx, now: start), in: ctx)
        XCTAssertEqual(s(b, 1).plannedDate, s(b, 1).date)
        XCTAssertNil(s(b, 2).plannedDate)
    }

    func test_aDeloadWeekSessionKeepsItsWeek_whenItSlidesAcrossTheBoundary() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 2, 3], weeks: [1, 1, 2, 2], wave: "deload")
        let phases = sessions(b).map { "\($0.weekIndex)|\($0.mesoPhase)|\($0.items.map { $0.waveRaw ?? "" })" }
        try Service.applySlide(Service.planRestToday(meso: b, context: ctx, now: start), in: ctx)
        XCTAssertEqual(sessions(b).map { "\($0.weekIndex)|\($0.mesoPhase)|\($0.items.map { $0.waveRaw ?? "" })" }, phases)
    }

    func test_planEditedItemsAreNotTouched() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 3])
        s(b, 2).items[0].planEdited = true
        s(b, 2).items[0].suggestedLoad = 135
        try assertSlideInvariants(Service.planRestToday(meso: b, context: ctx, now: start), ctx)
        XCTAssertTrue(s(b, 2).items[0].planEdited)
        XCTAssertEqual(s(b, 2).items[0].suggestedLoad, 135)
    }

    // MARK: Refusals (each writes nothing and names the day and the occupant)

    private func assertRefusal(_ b: MesoBlock, _ ctx: ModelContext, now: Date, _ expected: Service.SlideRefusal, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try dates(ctx), fp = try fingerprint(ctx)
        let plan = Service.planRestToday(meso: b, context: ctx, now: now)
        XCTAssertEqual(plan.refusal, expected, file: file, line: line)
        XCTAssertFalse(plan.isApplicable, file: file, line: line)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx), file: file, line: line)
        XCTAssertEqual(try dates(ctx), before, "nothing written", file: file, line: line)
        XCTAssertEqual(try fingerprint(ctx), fp, file: file, line: line)
    }

    func test_refuses_aCompletedSessionInTheChain() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 2])
        s(b, 3).status = .completed
        try assertRefusal(b, ctx, now: start, .blocked(day: day(plus(start, 2)), occupant: "S3", kind: .completed))
        XCTAssertTrue(RestTodayModel.refusalText(.blocked(day: day(plus(start, 2)), occupant: "S3", kind: .completed)).contains("S3"))
    }

    func test_refuses_aSessionWithLoggedDataInTheChain() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 2])
        s(b, 2).items[0].actualLoads = [100]
        try assertRefusal(b, ctx, now: start, .blocked(day: day(plus(start, 1)), occupant: "S2", kind: .loggedData))
    }

    func test_refuses_anInProgressSession() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 5])
        s(b, 3).status = .inProgress
        try assertRefusal(b, ctx, now: start, .sessionInProgress)
    }

    func test_refuses_anotherBlocksSessionInTheChain() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1])
        let other = MesoBlock(name: "Other", startDate: start, status: .active, totalWeeks: 1)
        ctx.insert(other)
        let o = Session(date: plus(start, 2), status: .planned, weekIndex: 1, dayLabel: "Theirs", items: [item()], programIndex: 1)
        o.meso = other; ctx.insert(o); try ctx.save()
        try assertRefusal(b, ctx, now: start, .blocked(day: day(plus(start, 2)), occupant: "Theirs", kind: .otherBlock))
    }

    func test_refuses_twoSessionsAlreadySharingAChainDay() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 1])
        let r = Service.planRestToday(meso: b, context: ctx, now: start).refusal
        guard case .blocked(_, _, .sharedDay)? = r else { return XCTFail("\(String(describing: r))") }
        try assertRefusal(b, ctx, now: start, r!)
    }

    func test_refuses_whenTodaysSessionHasLoggedData_andWhenThereIsNone() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 3])
        try assertRefusal(b, ctx, now: plus(start, 1), .nothingToMove)
        s(b, 1).items[0].actualLoads = [60]
        try assertRefusal(b, ctx, now: start, .unsafeSession)
    }

    func test_warnsWhenASessionReachesTheNextBlockStart_andForcedFailuresRestoreEveryDate() throws {
        let ctx = try makeContext(); let start = date(2026, 11, 2)
        let b = block(ctx, start: start, offsets: [0, 1, 3])
        MesoLifecycle.scheduleNextMeso(on: plus(start, 2))
        let plan = Service.planRestToday(meso: b, context: ctx, now: start)
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(RestTodayModel.warningLines(plan)[0].contains("next block"))
        let before = try dates(ctx)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx, hooks: .init(forceVerificationFailure: true)))
        XCTAssertEqual(try dates(ctx), before)
        XCTAssertThrowsError(try Service.applySlide(plan, in: ctx, hooks: .init(forceSaveFailure: true)))
        XCTAssertEqual(try dates(ctx), before)
        XCTAssertNoThrow(try Service.applySlide(plan, in: ctx))
    }

    // MARK: The real backups

    private func load(_ name: String) throws -> (ModelContext, MesoBlock) {
        let path = NSHomeDirectory().components(separatedBy: "/Library").first! + "/Downloads/" + name
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("backup not found: \(path)") }
        let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        retained.append(container)
        let ctx = ModelContext(container)
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>()).filter { $0.status == .active && !$0.isMaintenance }
        return (ctx, try XCTUnwrap(blocks.first))
    }

    private let angelaFile = "ElitePerformance_Backup_v1_2026-11-25_19-04-35.json"
    private let markFile = "ElitePerformance_Backup_v1_2026-11-25_18-57-55.json"

    func test_angela_nov27_oneMove_whereTheOldRuleRefused() throws {
        let (ctx, b) = try load(angelaFile)
        let plan = Service.planRestToday(meso: b, context: ctx, now: date(2026, 11, 27))
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.count, 1, "Saturday is free: the rest of the week stays")
        XCTAssertEqual(plan.moves[0].session.dayLabel, "Lower A")
        try assertSlideInvariants(plan, ctx)
    }

    func test_angela_nov30_fiveMoves_acrossTheWeek() throws {
        let (ctx, b) = try load(angelaFile)
        let plan = Service.planRestToday(meso: b, context: ctx, now: date(2026, 11, 30))
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.count, 5)
        XCTAssertEqual(Set(plan.moves.map { $0.session.weekIndex }), [2, 3], "the slide crosses into week 3 and keeps each session's week")
        try assertSlideInvariants(plan, ctx)
    }

    func test_mark_nov25Morning_eightMoves_endingOnTheThursdayRestDay() throws {
        let (ctx, b) = try load(markFile)
        // The backup was taken after the day's session: put Pull B (programIndex 54) back to how it stood that morning.
        let pull = try XCTUnwrap(b.sessions.first { $0.programIndex == 54 })
        pull.status = .planned; pull.completedAt = nil
        for i in pull.items {
            i.actualLoads = []; i.actualReps = []; i.actualRIRs = []; i.isCompleted = false
            i.setFeedbackBySet = []; i.pumpRatingsBySet = []; i.restPausePatternsBySet = []
            for l in i.logs { ctx.delete(l) }
        }
        try ctx.save()
        let plan = Service.planRestToday(meso: b, context: ctx, now: date(2026, 11, 25))
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.moves.count, 8)
        XCTAssertEqual(day(try XCTUnwrap(plan.moves.last).newDate), day(date(2026, 12, 3)), "ends on Thursday Dec 3, his rest day")
        try assertSlideInvariants(plan, ctx)
    }
}

// MARK: - "Make every week the same": stable references (Commit G)

@MainActor
final class SameEveryWeekReferenceTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var container: ModelContainer!
    private var retained: [ModelContainer] = []
    private var undoDir: URL!
    private let cal = Calendar.current

    override func setUp() {
        super.setUp()
        undoDir = FileManager.default.temporaryDirectory.appendingPathComponent("sw_ref_undo_\(UUID().uuidString)")
        EffortTracking.mode = .detailed
    }
    override func tearDown() { try? FileManager.default.removeItem(at: undoDir); EffortTracking.clearMirror(); super.tearDown() }

    private func ctx() throws -> ModelContext {
        container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let c = ModelContext(container)
        c.insert(User(units: .lb, progressionEnabled: true))
        return c
    }
    private func date(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 5))!)! }

    private struct Rx { let sets: Int; let lo: Int; let hi: Int; let rir: Int }
    private let table: [String: Rx] = ["a": Rx(sets: 3, lo: 8, hi: 12, rir: 3), "b": Rx(sets: 3, lo: 8, hi: 12, rir: 2), "c": Rx(sets: 3, lo: 6, hi: 10, rir: 1)]

    private func item(_ id: String, _ letter: String, order: Int = 1) -> SessionItem {
        let rx = table[letter == "deload" ? "b" : letter]!
        return SessionItem(order: order, exerciseId: id, targetReps: rx.lo, targetSets: rx.sets, targetRIR: rx.rir, suggestedLoad: 0, waveRaw: letter,
                           setMin: rx.sets, setMax: rx.sets, repMin: rx.lo, repMax: rx.hi, targetRIRMin: rx.rir, targetRIRMax: rx.rir,
                           plannedRepsBySet: Array(repeating: rx.lo, count: rx.sets), plannedLoadsBySet: Array(repeating: 0, count: rx.sets),
                           plannedRIRsBySet: Array(repeating: rx.rir, count: rx.sets),
                           actualReps: Array(repeating: 0, count: rx.sets), actualLoads: Array(repeating: 0, count: rx.sets),
                           actualRIRs: RIREntry.unsetArray(count: rx.sets))
    }

    /// Angela's shape: Upper B weeks 1-9 letters a b c a b c a b c, week 1 completed. Hammer Curl is NOT in week 1 (a swap put another exercise there), so
    /// its only A-week items are planned, in weeks 4 and 7. "lat_pulldown" exists only in B weeks (2, 5, 8): it has no A-week version anywhere.
    private func hammerBlock(_ c: ModelContext) throws -> MesoBlock {
        let b = MesoBlock(name: "Wave", startDate: date(0), status: .active, totalWeeks: 9)
        c.insert(b)
        let letters = ["a", "b", "c", "a", "b", "c", "a", "b", "c"]
        for (w, l) in letters.enumerated() {
            var items: [SessionItem] = []
            items.append(item(w == 0 ? "combination_curl" : "hammer_curl", l, order: 1))
            items.append(item("bench_press", l, order: 2))
            if l == "b" { items.append(item("lat_pulldown", l, order: 3)) }
            let s = Session(date: date(7 * w), status: .planned, weekIndex: w + 1, dayLabel: "Upper B", items: items, programIndex: w + 1)
            s.meso = b; c.insert(s)
        }
        try c.save()
        let w1 = b.sessions.first { $0.weekIndex == 1 }!
        w1.status = .completed; w1.completedAt = w1.date
        for i in w1.items { i.isCompleted = true; i.suggestedLoad = 20; i.plannedLoadsBySet = Array(repeating: 20, count: i.targetSets); i.actualReps = Array(repeating: i.repMax ?? 12, count: i.targetSets); i.actualLoads = Array(repeating: 20, count: i.targetSets); i.actualRIRs = Array(repeating: i.targetRIR, count: i.targetSets) }
        try c.save()
        return b
    }

    private func items(_ b: MesoBlock, _ exercise: String) -> [(week: Int, item: SessionItem)] {
        b.sessions.sorted { $0.weekIndex < $1.weekIndex }.compactMap { s in s.items.first { $0.exerciseId == exercise }.map { (s.weekIndex, $0) } }
    }

    /// The property: after a conversion, no group (day, exercise) of unstarted, non-deload, non-edited items that were converted holds two prescriptions.
    /// Items with no kept-week version and items whose top-set shape differs are reported separately. Returns the divergent groups.
    private func divergentGroups(_ b: MesoBlock, plan: Service.SameWeekPlan) -> [String] {
        let skip = Set(plan.unmatched.map(\.itemID))
        struct K: Hashable { let d: String; let e: String }
        var groups: [K: [(Int, String)]] = [:]
        for s in b.sessions where SessionEditSafety.isSafeToModify(s) {
            for i in s.items where i.waveRaw?.lowercased() != "deload" && !i.planEdited {
                if skip.contains(i.id?.uuidString ?? "\(i.persistentModelID)") { continue }
                let sig = "\(i.effectivePrescribedSets)x\(i.repMin ?? -1)-\(i.repMax ?? -1)@\(i.targetRIR)"
                groups[K(d: (s.dayLabel ?? "").lowercased(), e: ExerciseCatalog.canonicalExerciseId(for: i.exerciseId)), default: []].append((s.weekIndex, sig))
            }
        }
        return groups.compactMap { k, v in
            Set(v.map(\.1)).count > 1 ? "\(k.d) / \(k.e): " + v.map { "W\($0.0) \($0.1)" }.joined(separator: ", ") : nil
        }.sorted()
    }

    // MARK: Adoption never writes to a completed item (the swap that carries no planned load)

    /// The hammer block whose completed week-1 Combination Curl is a swap with a zero plan: performed 20 x 10, nothing planned, edited by hand.
    private func swapBlock(_ c: ModelContext) throws -> (MesoBlock, Session, SessionItem) {
        let b = try hammerBlock(c)
        let w1 = try XCTUnwrap(b.sessions.first { $0.weekIndex == 1 })
        let swap = try XCTUnwrap(w1.items.first { $0.exerciseId == "combination_curl" })
        swap.suggestedLoad = 0; swap.plannedLoadsBySet = Array(repeating: 0, count: swap.targetSets); swap.planEdited = true
        try c.save()
        return (b, w1, swap)
    }

    /// The completed session exactly as a backup would write it (every stored field), so "byte-identical" means the exported bytes.
    private func exported(_ c: ModelContext, _ s: Session) throws -> Data {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: c)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        let mine = try XCTUnwrap(sessions.first { ($0["id"] as? String) == s.id?.uuidString }, "the session is in the export")
        return try JSONSerialization.data(withJSONObject: mine, options: [.sortedKeys])
    }

    func test_conversion_ofABlockWhoseCompletedWeekOneItemIsAZeroPlanSwap_convertsAndLeavesThatItemByteIdentical() throws {
        let c = try ctx(); let (b, w1, swap) = try swapBlock(c)
        let before = try exported(c, w1)
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        XCTAssertNil(plan.refusal, "the swap on a completed item must not read as touching history")
        XCTAssertGreaterThan(plan.itemsChanged, 0)
        try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
        XCTAssertEqual(try exported(c, w1), before, "the completed week-1 session is byte-identical")
        XCTAssertEqual(swap.suggestedLoad, 0); XCTAssertEqual(swap.waveRaw, "a"); XCTAssertTrue(swap.planEdited)
        XCTAssertEqual(items(b, "hammer_curl").map(\.week), [2, 3, 4, 5, 6, 7, 8, 9], "and the unstarted weeks converted")
    }

    func test_theSameCompletedItem_staysByteIdenticalThroughEveryPathThatCanReachIt() throws {
        let c = try ctx(); let (b, w1, swap) = try swapBlock(c)
        let initial = try exported(c, w1)

        // 1. Re-saving the completed session (the SessionView save passes adoptBaseline: false for a session already completed).
        PlanMemoryEngine(context: c).carryForwardPlans(from: w1, adoptBaseline: false); try c.save()
        XCTAssertEqual(try exported(c, w1), initial, "byte-identical after: carry-forward on a re-save"); XCTAssertEqual(swap.suggestedLoad, 0)
        // The view model's save also pads a fixture's short per-set arrays to the set count (it does that on every first save of any session, adoption or not),
        // so it gets one settling save; what matters is that it writes no load: suggested and planned loads are the zero plan still, and a second save changes nothing.
        let vm = SessionScreenViewModel(session: w1)
        vm.persist(using: c); try c.save()
        XCTAssertEqual(swap.suggestedLoad, 0, "the save wrote no baseline"); XCTAssertTrue(swap.plannedLoadsBySet.allSatisfy { $0 == 0 })
        let settled = try exported(c, w1)
        vm.persist(using: c); try c.save()
        XCTAssertEqual(try exported(c, w1), settled, "a second save of the completed session changes nothing")
        let before = settled
        func unchanged(_ path: String) throws { XCTAssertEqual(try exported(c, w1), before, "byte-identical after: \(path)"); XCTAssertEqual(swap.suggestedLoad, 0, path) }

        // 2. PlaceholderRefresh: the launch run and the after-completion run.
        _ = PlaceholderRefresh.run(in: c); try c.save()
        try unchanged("PlaceholderRefresh.run")
        PlaceholderRefresh.afterCompletion(in: c); try c.save()
        try unchanged("PlaceholderRefresh.afterCompletion")

        // 3. Every registered startup backfill, with its completion flags cleared (a first launch).
        var saved: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasSuffix(".completed") { saved[k] = v; UserDefaults.standard.removeObject(forKey: k) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        for backfill in StartupBackfills.registered { backfill.run(c); try unchanged("startup backfill \(backfill.name)") }

        // 4. The conversion replay (planning replays it too; applying runs it for real).
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        XCTAssertNil(plan.refusal)
        try unchanged("planSameEveryWeek")
        try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
        try unchanged("applySameEveryWeek")
    }

    func test_theCompletingSave_stillAdoptsTheLoggedLoad_asBaseline() throws {
        // The one place adoption is allowed: the save that completes the session (the item is still the lifter's live session).
        let c = try ctx(); let (b, w1, swap) = try swapBlock(c)
        w1.status = .inProgress; w1.completedAt = nil; try c.save()
        PlanMemoryEngine(context: c).carryForwardPlans(from: w1, adoptBaseline: true)
        XCTAssertEqual(swap.suggestedLoad, 20, "the load lifted became its baseline")
        _ = b
    }

    func test_hammerCurl_everyWeekBecomesTheAWeek_whenTheOnlyAItemsArePlanned() throws {
        let c = try ctx(); let b = try hammerBlock(c)
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        XCTAssertNil(plan.refusal)
        try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
        let hammer = items(b, "hammer_curl")
        XCTAssertEqual(hammer.map(\.week), [2, 3, 4, 5, 6, 7, 8, 9])
        for (w, i) in hammer {
            XCTAssertEqual(i.repMin, 8, "W\(w)"); XCTAssertEqual(i.repMax, 12, "W\(w)")
            XCTAssertEqual(i.targetRIR, 3, "W\(w) takes the A week's effort target, including W8 and W9")
            XCTAssertEqual(i.effectivePrescribedSets, 3, "W\(w)")
            XCTAssertNil(i.waveRaw, "W\(w)")
        }
        XCTAssertEqual(divergentGroups(b, plan: plan), [])
        XCTAssertEqual(items(b, "combination_curl").first?.item.waveRaw, "a", "the completed week-1 item is history")
    }

    func test_anExerciseWithNoKeptWeekVersion_isNamed_andLeftExactlyAsItIs() throws {
        let c = try ctx(); let b = try hammerBlock(c)
        let before = Dictionary(uniqueKeysWithValues: items(b, "lat_pulldown").map { ($0.week, Service.SameWeekSnapshot($0.item)) })
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        XCTAssertEqual(plan.unmatched.map { $0.session.weekIndex }.sorted(), [2, 5, 8], "each unmatched item is listed, by week and day")
        XCTAssertEqual(Set(plan.unmatched.map { $0.item.exerciseId }), ["lat_pulldown"])
        let lines = plan.unmatched.sorted { $0.session.date < $1.session.date }.map { SameWeekText.unmatchedLine($0) }
        XCTAssertTrue(lines.allSatisfy { $0.contains("Upper B") && $0.contains("(B week)") && $0.localizedCaseInsensitiveContains("pulldown") }, "\(lines)")
        XCTAssertFalse(plan.changes.contains { $0.item.exerciseId == "lat_pulldown" }, "not a change")
        XCTAssertTrue(SameWeekText.confirmMessage(plan).contains("3 that can't be changed to it stay exactly as they are"))
        XCTAssertTrue(SameWeekText.footer.contains("left exactly as it is, label included"))
        XCTAssertFalse(SameWeekText.footer.hasPrefix("Every unstarted session takes"), "the footer no longer promises every item")
        try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
        for (w, i) in items(b, "lat_pulldown") where w != 1 {
            XCTAssertEqual(i.waveRaw, "b", "the letter stays")
            XCTAssertEqual(Service.SameWeekSnapshot(i), before[w], "W\(w) is exactly as it was")
        }
        XCTAssertEqual(divergentGroups(b, plan: plan), [])
    }

    func test_everyKeptLetter_leavesNoDivergentGroup_onTheFixture() throws {
        for keep in ["a", "b", "c"] {
            let c = try ctx(); let b = try hammerBlock(c)
            let plan = Service.planSameEveryWeek(meso: b, keep: keep, context: c)
            XCTAssertNil(plan.refusal, keep)
            try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
            XCTAssertEqual(divergentGroups(b, plan: plan), [], "keep \(keep)")
        }
    }

    func test_planEdited_andDeloadItemsAreNotInTheGroupsTheyDontJoin() throws {
        let c = try ctx(); let b = try hammerBlock(c)
        let w3 = b.sessions.first { $0.weekIndex == 3 }!
        let edited = w3.items.first { $0.exerciseId == "hammer_curl" }!
        edited.planEdited = true; edited.repMin = 5; edited.repMax = 7
        try c.save()
        let plan = Service.planSameEveryWeek(meso: b, keep: "a", context: c)
        try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
        XCTAssertEqual(edited.repMin, 5); XCTAssertEqual(edited.repMax, 7, "the lifter's own plan keeps its prescription")
        XCTAssertNil(edited.waveRaw)
        XCTAssertEqual(divergentGroups(b, plan: plan), [])
    }

    /// The real backups, keep = A, B and C: zero divergent groups outside unmatched / planEdited / deload. Runs on the golden test's backups
    /// (TEST_RUNNER_EP_POLICY_BACKUPS, which the gate exports) or on TEST_RUNNER_EP_SW_BACKUPS; the report lists what was checked.
    func test_property_onTheRealBackups_forEveryKeptLetter() throws {
        // The same backups the golden CoachingPolicy test uses (the gate exports them), unless TEST_RUNNER_EP_SW_BACKUPS names others.
        let env = ProcessInfo.processInfo.environment
        let list = [env["EP_SW_BACKUPS"], env["EP_POLICY_BACKUPS"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        guard !list.isEmpty else { throw XCTSkip("set TEST_RUNNER_EP_POLICY_BACKUPS (the gate does) or TEST_RUNNER_EP_SW_BACKUPS") }
        var checked = 0
        for path in list.split(separator: ",").map(String.init) {
            for keep in ["a", "b", "c"] {
                let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                retained.append(container)
                _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
                let c = ModelContext(container)
                guard let meso = try c.fetch(FetchDescriptor<MesoBlock>()).first(where: { $0.status == .active }),
                      !Service.sameWeekTypes(in: meso).isEmpty else { print("PROP| \(path): no wave block"); continue }
                let plan = Service.planSameEveryWeek(meso: meso, keep: keep, context: c)
                if plan.refusal == .noUnstartedSessions || plan.refusal == .unknownWeekType {
                    // A backup taken after the conversion (Angela's Nov 27 19:06): no unstarted session still carries a letter (so no letter to keep, nothing to convert).
                    print("PROP| \(URL(fileURLWithPath: path).lastPathComponent) keep=\(keep): already converted (\(plan.refusal.map { "\($0)" } ?? ""))"); continue
                }
                XCTAssertNil(plan.refusal, "\(path) keep \(keep)")
                let names = plan.unmatched.map { SameWeekText.unmatchedLine($0) }
                try Service.applySameEveryWeek(plan, backupTaken: true, in: c, undoDirectory: undoDir)
                let divergent = divergentGroups(meso, plan: plan)
                print("PROP| \(URL(fileURLWithPath: path).lastPathComponent) keep=\(keep): converted \(plan.itemsChanged), edited \(plan.editedKept), unmatched \(names.count), divergent \(divergent.count)")
                for n in names { print("PROP|    unmatched: \(n)") }
                XCTAssertEqual(divergent, [], "\(path) keep \(keep)")
                XCTAssertTrue(plan.changes.allSatisfy { $0.notes.isEmpty }, "an item that can't be converted is listed as unmatched, never as a note")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
