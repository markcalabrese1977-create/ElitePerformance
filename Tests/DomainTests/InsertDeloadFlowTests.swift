import XCTest
import SwiftData
@testable import ElitePerformance

final class InsertDeloadFlowTests: XCTestCase {

    private typealias Model = InsertDeloadModel
    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: scheduledKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: scheduledKey); super.tearDown() }

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let cal = Calendar.current
        try DUPProgramSeeder.seed(
            startDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!,
            trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal, mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        try ctx.save()
        return (ctx, try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first))
    }

    private func week(_ block: MesoBlock, _ w: Int) -> [Session] {
        block.sessions.filter { $0.weekIndex == w }.sorted { $0.date < $1.date }
    }

    private func fingerprint(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Session>())
            .sorted { ($0.date, $0.dayLabel ?? "") < ($1.date, $1.dayLabel ?? "") }
            .map { "\($0.date.timeIntervalSince1970)|\($0.weekIndex)|\($0.programIndex ?? -1)|\($0.insertedDeload.map(String.init) ?? "-")|\($0.items.count)" }
    }

    func test_preview_listsDeloadSessions_moveCount_andNewEndDate() throws {
        let (ctx, block) = try makeBlock()
        let now = Calendar.current.startOfDay(for: week(block, 3).map(\.date).min()!)
        let model = Model(meso: block, context: ctx, now: now)
        let plan = model.plan()
        XCTAssertNil(plan.refusal)

        let rows = Model.rows(plan)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.map(\.date), week(block, 3).map(\.date))
        for row in rows {
            XCTAssertFalse(row.items.isEmpty)
            for item in row.items {
                XCTAssertTrue(item.prescription.contains("@ RIR 3-4"), item.prescription)
                XCTAssertFalse(item.load.isEmpty)
            }
        }
        let moved = block.sessions.filter { $0.weekIndex >= 3 }.count
        XCTAssertEqual(Model.moveText(count: plan.shifted.count), "\(moved) sessions move one week later")
        XCTAssertEqual(Model.moveText(count: 1), "1 session moves one week later")
        let end = try XCTUnwrap(Model.endDateText(plan))
        XCTAssertTrue(end.hasPrefix("Block ends "), end)
        XCTAssertFalse(ctx.hasChanges, "previewing writes nothing")
    }

    func test_refusalsAndCollisions_haveCopy_andApplyWritesNothing() throws {
        let (ctx, block) = try makeBlock()
        let farFuture = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
        let refused = Model(meso: block, context: ctx, now: farFuture).plan()
        XCTAssertEqual(refused.refusal, .noEligibleWeek)
        XCTAssertFalse(Model.refusalText(.noEligibleWeek).isEmpty)

        // A collision: park another block's session on week 3's first day + 7.
        let start = Calendar.current.startOfDay(for: week(block, 3).map(\.date).min()!)
        let other = MesoBlock(name: "Other", startDate: start, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        let blocker = Session(date: Calendar.current.date(byAdding: .day, value: 7, to: week(block, 3)[0].date)!,
                              status: .completed, weekIndex: 1, dayLabel: "Old")
        blocker.meso = other
        ctx.insert(blocker)
        try ctx.save()
        let before = try fingerprint(ctx)

        let model = Model(meso: block, context: ctx, now: start)
        let plan = model.plan()
        XCTAssertEqual(plan.refusal, .dateCollision)
        XCTAssertEqual(Model.collisionRows(plan).count, 1)
        XCTAssertEqual(Model.collisionRows(plan)[0].occupant, "Old")
        guard case .failure(let failure) = model.apply(plan) else { return XCTFail("a refused plan must not apply") }
        XCTAssertEqual(failure.error, .refused(.dateCollision))
        XCTAssertTrue(failure.message.hasSuffix("Nothing was changed."))
        XCTAssertEqual(try fingerprint(ctx), before)
    }

    func test_apply_success_insertsTheWeek_andStaleFailureWritesNothing() throws {
        let (ctx, block) = try makeBlock()
        let now = Calendar.current.startOfDay(for: week(block, 3).map(\.date).min()!)
        let model = Model(meso: block, context: ctx, now: now)
        let stale = model.plan()

        // The schedule changes under the preview (week 3 gets logged): applying the old plan is refused, unchanged.
        week(block, 3)[0].items[0].actualLoads = [50]
        try ctx.save()
        let before = try fingerprint(ctx)
        guard case .failure(let failure) = model.apply(stale) else { return XCTFail("stale plan must not apply") }
        XCTAssertTrue(failure.needsRefresh)
        XCTAssertEqual(try fingerprint(ctx), before)

        // A fresh preview (now week 4) applies.
        let fresh = model.plan()
        XCTAssertEqual(fresh.weekIndex, 4)
        guard case .success(let result) = model.apply(fresh) else { return XCTFail("fresh plan should apply") }
        XCTAssertEqual(result.deloadSessionsCreated, 6)
        XCTAssertEqual(block.totalWeeks, 11)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.count, 6)
    }

    // MARK: - Week picker

    func test_picker_listsEligibleWeeks_defaultsToFirst_andPreviewFollowsTheChoice() throws {
        let (ctx, block) = try makeBlock()
        let now = Calendar.current.startOfDay(for: week(block, 3).map(\.date).min()!)
        var model = Model(meso: block, context: ctx, now: now)
        XCTAssertEqual(model.eligibleWeeks.first, 3)
        XCTAssertFalse(model.eligibleWeeks.contains(10), "the generated deload week isn't offered")
        XCTAssertEqual(model.effectiveWeek, 3)
        XCTAssertEqual(model.plan().weekIndex, 3)
        XCTAssertTrue(model.weekLabel(3).hasPrefix("Week 3 · "))

        model.week = 6
        let plan = model.plan()
        XCTAssertEqual(plan.weekIndex, 6)
        XCTAssertEqual(Model.rows(plan).map(\.date), week(block, 6).map(\.date))
        XCTAssertEqual(plan.shifted.count, block.sessions.filter { $0.weekIndex >= 6 }.count)

        model.week = 1                                  // no longer eligible -> falls back to the first eligible
        XCTAssertEqual(model.plan().weekIndex, 3)
        XCTAssertEqual(Model.refusalText(.weekNotEligible).isEmpty, false)
    }

    // MARK: - Remove model

    func test_removeModel_previewMoveTextEndDate_refusals_andApply() throws {
        typealias RModel = RemoveDeloadModel
        let (ctx, block) = try makeBlock()
        let now = Calendar.current.startOfDay(for: week(block, 3).map(\.date).min()!)
        let refused = RModel(meso: block, context: ctx, now: now).plan()
        XCTAssertEqual(refused.refusal, .noInsertedDeload)
        XCTAssertEqual(RModel.refusalText(.noInsertedDeload), "This block has no inserted deload week.")

        let endBefore = block.sessions.map(\.date).max()!
        XCTAssertEqual(Model(meso: block, context: ctx, now: now).apply(Model(meso: block, context: ctx, now: now).plan()).isSuccess, true)

        let model = RModel(meso: block, context: ctx, now: now)
        let plan = model.plan()
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 3)
        let moved = plan.shifted.count
        XCTAssertEqual(RModel.moveText(count: moved), "\(moved) sessions move one week earlier")
        XCTAssertEqual(RModel.moveText(count: 1), "1 session moves one week earlier")
        XCTAssertEqual(RModel.removalText(plan), "6 deload sessions removed")
        XCTAssertTrue(try XCTUnwrap(RModel.endDateText(plan)).hasPrefix("Block ends "))
        XCTAssertEqual(plan.blockEndAfter, endBefore)
        XCTAssertFalse(ctx.hasChanges, "previewing writes nothing")

        // A logged deload session refuses, with copy, and writes nothing.
        week(block, 3)[0].items[0].actualLoads = [40]
        try ctx.save()
        let before = try fingerprint(ctx)
        let blocked = model.plan()
        XCTAssertEqual(blocked.refusal, .deloadStarted)
        guard case .failure(let failure) = model.apply(blocked) else { return XCTFail("refused plan must not apply") }
        XCTAssertTrue(failure.message.hasSuffix("Nothing was changed."))
        XCTAssertEqual(try fingerprint(ctx), before)

        // Cleared, it applies.
        week(block, 3)[0].items[0].actualLoads = [0]
        try ctx.save()
        guard case .success(let result) = model.apply(model.plan()) else { return XCTFail("should apply") }
        XCTAssertEqual(result.deloadSessionsRemoved, 6)
        XCTAssertEqual(block.totalWeeks, 10)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

// MARK: - Start next meso flow (M4)

final class StartNextMesoFlowTests: XCTestCase {

    private typealias Model = StartNextMesoModel
    private typealias Service = SessionItemEditService
    private var container: ModelContainer!
    private let keys = ["meso.scheduledStartDateEpoch", "meso.activeStartDateEpoch", "meso.promptSnoozeEpoch",
                        "meso.anchorDate", "meso.anchorDayNumber"]
    private var savedDefaults: [(String, Any?)] = []

    override func setUp() {
        super.setUp()
        savedDefaults = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }
    override func tearDown() {
        for (k, v) in savedDefaults { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        super.tearDown()
    }

    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
    private var before: Date { date(2026, 9, 20) }

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self, AppState.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(
            startDate: date(2026, 9, 25), trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal, mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        try ctx.save()
        return (ctx, try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first))
    }

    func test_defaults_nameAndStart() throws {
        let (ctx, block) = try makeBlock()
        let last = try XCTUnwrap(block.sessions.map(\.date).max())
        let model = Model(meso: block, context: ctx, now: before)
        XCTAssertEqual(model.name, "10-Week DUP Meso (next)")
        XCTAssertEqual(model.startDate, cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: last)!), "the day after the last session")
        // Once that day has passed the default is today, never a refused past date.
        let late = date(2027, 2, 3).addingTimeInterval(3600 * 15)
        XCTAssertEqual(Model.defaultStart(for: block, now: late), cal.startOfDay(for: late))
        XCTAssertFalse(Model(meso: block, context: ctx, now: late).plan().refusals.contains(.startInPast))
    }

    func test_endToggle_onlyCountsWhileSessionsAreLeft() throws {
        let (ctx, block) = try makeBlock()
        let needed = Model(meso: block, context: ctx, now: before, endOldMesoNow: true)
        XCTAssertTrue(needed.needsEndNow)
        XCTAssertEqual(needed.remainingSessions.count, 60)
        XCTAssertTrue(needed.effectiveEndNow)
        XCTAssertTrue(needed.plan().isApplicable, "\(needed.plan().refusals)")
        XCTAssertEqual(Model.removalText(needed.plan()), "60 planned sessions removed from \"10-Week DUP Meso\"")

        let off = Model(meso: block, context: ctx, now: before, endOldMesoNow: false)
        XCTAssertTrue(off.plan().refusals.contains(.oldMesoHasRemainingSessions))
        XCTAssertNil(Model.removalText(off.plan()))
        XCTAssertTrue(Model.refusalText(.oldMesoHasRemainingSessions, remaining: 60).contains("60 planned sessions"))

        for s in block.sessions { s.status = .completed }
        try ctx.save()
        let done = Model(meso: block, context: ctx, now: Model.defaultStart(for: block, now: before), endOldMesoNow: true)
        XCTAssertFalse(done.needsEndNow)
        XCTAssertFalse(done.effectiveEndNow, "nothing to end, so the toggle is ignored")
        XCTAssertFalse(done.plan().endOldMesoNow)
        XCTAssertTrue(done.plan().isApplicable, "\(done.plan().refusals)")
    }

    func test_preview_summaryAndFirstWeekRows() throws {
        let (ctx, block) = try makeBlock()
        let model = Model(meso: block, context: ctx, now: before, endOldMesoNow: true)
        let plan = model.plan()
        XCTAssertTrue(Model.summaryText(plan).hasPrefix("10 weeks · 60 sessions · "), Model.summaryText(plan))
        let rows = Model.firstWeekRows(plan)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.map(\.date), rows.map(\.date).sorted())
        XCTAssertTrue(rows.allSatisfy { $0.letter == "A" && !$0.items.isEmpty })
        for row in rows {
            for item in row.items {
                XCTAssertTrue(item.prescription.contains(" x "), item.prescription)
                XCTAssertFalse(item.load.isEmpty)
            }
        }
        // No history in this store: loads are entered on the day; bodyweight shows BW.
        let loads = Set(rows.flatMap { $0.items.map(\.load) })
        XCTAssertTrue(loads.contains("enter on the day"))
        XCTAssertEqual(Model.sourceText(try XCTUnwrap(plan.sessions.first?.items.first), factor: 0.95), "no history yet")
    }

    func test_seedCopy_forEachSource() throws {
        let (ctx, block) = try makeBlock()
        let first = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let bench = try XCTUnwrap(first.items.first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) })
        bench.actualLoads = [150, 150, 150, 150]; bench.actualReps = [6, 6, 6, 6]; bench.actualRIRs = [2, 2, 2, 2]
        bench.isCompleted = true
        first.status = .completed
        try ctx.save()
        let plan = Model(meso: block, context: ctx, now: first.date.addingTimeInterval(86400), endOldMesoNow: true).plan()
        let item = try XCTUnwrap(plan.sessions.first?.items.first { $0.exerciseId == bench.exerciseId })
        XCTAssertEqual(Model.sourceText(item, factor: plan.peakFactor), "95% of your best")
        XCTAssertTrue(Model.loadText(item).hasSuffix(LoadFormatter.unitLabel))
        XCTAssertEqual(Model.sourceText(item, factor: 0.9), "90% of your best")
    }

    func test_refusalText_coversEveryCase() {
        let all: [Service.NextMesoRefusal] = [.nothingToCopy, .sessionInProgress, .startInPast, .oldMesoHasRemainingSessions,
                                              .remainingSessionHasLoggedData, .duplicateDayLabelInWeek, .dateCollision]
        for r in all { XCTAssertFalse(Model.refusalText(r, remaining: 2).isEmpty, "\(r)") }
        XCTAssertEqual(Set(all.map { Model.refusalText($0, remaining: 2) }).count, all.count, "each reads differently")
    }

    func test_applyFailure_messagesAndRefresh() {
        for e: Service.NextMesoError in [.refused([.startInPast]), .planStale, .verificationFailed(["x"]), .saveFailed("x")] {
            let f = Model.ApplyFailure(error: e)
            XCTAssertTrue(f.message.contains("Nothing was changed") || f.message.contains("nothing was written"), f.message)
            XCTAssertEqual(f.needsRefresh, e == .planStale)
        }
    }

    func test_canCreate_needsAName_andApplyCreatesTheMeso() throws {
        let (ctx, block) = try makeBlock()
        XCTAssertFalse(Model(meso: block, context: ctx, now: before, name: "   ").canCreate)
        let model = Model(meso: block, context: ctx, now: before, name: " Block 2 ", endOldMesoNow: true)
        XCTAssertTrue(model.canCreate)
        guard case .success(let result) = model.apply(model.plan()) else { return XCTFail("apply failed") }
        XCTAssertEqual(result.meso.name, "Block 2", "the name is trimmed")
        XCTAssertEqual(result.meso.status, .active)
        XCTAssertEqual(block.status, .archived)
        // The same plan can't be applied twice.
        guard case .failure(let failure) = model.apply(model.plan()) else { return XCTFail("a second apply should be refused") }
        XCTAssertFalse(failure.message.isEmpty)
    }
}
