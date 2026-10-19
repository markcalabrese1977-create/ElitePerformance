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
}
