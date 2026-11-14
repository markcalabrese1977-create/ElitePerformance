import XCTest
import SwiftData
@testable import ElitePerformance

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
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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
        let last = try XCTUnwrap(off.remainingSessions.map(\.date).max())
        let lastText = last.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        XCTAssertEqual(
            Model.refusalText(.oldMesoHasRemainingSessions, remaining: off.remainingSessions.count, mesoName: block.name, lastRemaining: last),
            "10-Week DUP Meso still has 60 planned sessions (last: \(lastText)). Finish them first, or turn on \"End this meso now\" to remove them.")
        XCTAssertFalse(Model.refusalText(.oldMesoHasRemainingSessions, remaining: 60, lastRemaining: last).contains("start after"))
        XCTAssertTrue(Model.refusalText(.oldMesoHasRemainingSessions, remaining: 1, mesoName: "X", lastRemaining: last).contains("1 planned session ("))

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
