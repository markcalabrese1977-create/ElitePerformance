import XCTest
import SwiftData
@testable import ElitePerformance

final class ReplaceExerciseFlowTests: XCTestCase {

    private typealias Model = ReplaceExerciseModel
    private var container: ModelContainer!

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let cal = Calendar(identifier: .gregorian)
        try DUPProgramSeeder.seed(
            startDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!,
            trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal, mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        try ctx.save()
        return (ctx, try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first))
    }

    /// A planned session with a lift to replace, a replacement the block doesn't use, and a model for it.
    private func model(_ ctx: ModelContext, _ block: MesoBlock, now: Date = Date(timeIntervalSince1970: 0)) throws -> Model {
        let session = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(session.items.sorted { $0.order < $1.order }.first {
            !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId)
        })
        let used = Set(block.sessions.flatMap(\.items).map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        let y = try XCTUnwrap(ExerciseCatalog.all.first { !used.contains($0.id) && !ExerciseCatalog.isBodyweight(exerciseId: $0.id) })
        return Model(session: session, item: item, replacementId: y.id, context: ctx, now: now)
    }

    // MARK: Scope availability

    func test_scopes_todayInSession_isThisSessionOnly_programTabOffersBoth() throws {
        let (_, block) = try makeBlock()
        let session = try XCTUnwrap(block.sessions.first)
        XCTAssertEqual(Model.availableScopes(surface: .todayInSession, session: session), [.thisSession])
        XCTAssertEqual(Model.availableScopes(surface: .programTab, session: session), [.thisSession, .allRemaining])
    }

    func test_scopes_programTab_needsABlockAndADayLabelForAllRemaining() throws {
        let (_, block) = try makeBlock()
        let session = try XCTUnwrap(block.sessions.first)
        session.dayLabel = "  "
        XCTAssertEqual(Model.availableScopes(surface: .programTab, session: session), [.thisSession])
        session.dayLabel = "Pull A"
        session.meso = nil
        XCTAssertEqual(Model.availableScopes(surface: .programTab, session: session), [.thisSession])
    }

    // MARK: Preview == apply

    func test_previewCountEqualsAppliedCount_andRowsComeFromThePlan() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)

        let plan = try XCTUnwrap(m.plan(for: .allRemaining))
        let rows = Model.rows(plan)
        XCTAssertEqual(rows.count, plan.targets.count)
        XCTAssertGreaterThan(rows.count, 3)
        XCTAssertEqual(m.title(for: .allRemaining, plan: plan), "All remaining \(m.dayLabel ?? "") sessions (\(plan.targets.count))")
        XCTAssertEqual(Model.confirmTitle(count: plan.targets.count), "Replace \(plan.targets.count)")
        XCTAssertEqual(Model.enterOnTheDay, "No load history — enter on the day")
        XCTAssertTrue(rows.allSatisfy { $0.load == "No load history — enter on the day" }, "no history for the new lift")
        XCTAssertEqual(Model.loadText(132.5), "Starts at 132.5 lb")
        XCTAssertEqual(Model.loadText(135), "Starts at 135 lb")
        XCTAssertTrue(Set(rows.map(\.wave)).isSubset(of: ["A", "B", "C", "Deload", "–"]))
        XCTAssertTrue(rows.allSatisfy { $0.prescription.contains(" x ") && $0.prescription.contains("RIR") })

        guard case .success(let applied) = m.apply(plan) else { return XCTFail("apply failed") }
        XCTAssertEqual(applied.sessionsChanged, rows.count, "preview count == applied count")
        let nowHolding = block.sessions.filter { s in s.items.contains { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == m.replacementId } }
        XCTAssertEqual(nowHolding.count, rows.count)
    }

    func test_thisSession_previewIsOneRow_andCarriesTheCarryForwardNote() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        let plan = try XCTUnwrap(m.plan(for: .thisSession))
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(m.title(for: .thisSession, plan: plan), "This session only")
        XCTAssertEqual(m.thisSessionNote(), "Later \(m.dayLabel ?? "") sessions keep \(m.fromName); carry-forward won't connect them.")
        guard case .success(let applied) = m.apply(plan) else { return XCTFail("apply failed") }
        XCTAssertEqual(applied.sessionsChanged, 1)
        XCTAssertEqual(block.sessions.filter { s in s.items.contains { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == m.replacementId } }.count, 1)
    }

    func test_seedShowsAsALoad_whenCompletedHistoryExists() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        let other = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first { $0.dayLabel != m.session.dayLabel })
        other.items.append(SessionItem(order: 99, exerciseId: m.replacementId, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0,
                                       actualReps: [10], actualLoads: [100], actualRIRs: [2]))
        other.status = .completed
        try ctx.save()
        var withNow = m; withNow.now = other.date.addingTimeInterval(86400)
        let rows = Model.rows(try XCTUnwrap(withNow.plan(for: .allRemaining)))
        XCTAssertTrue(rows.allSatisfy { $0.load.hasPrefix("Starts at ") && $0.load.hasSuffix(" lb") }, "\(rows.map(\.load))")
    }

    // MARK: Failures show a message and write nothing

    func test_sessionInProgress_failsWithAMessageAndWritesNothing() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        let plan = try XCTUnwrap(m.plan(for: .allRemaining))
        let other = try XCTUnwrap(block.sessions.first { $0 !== m.session })
        other.status = .inProgress

        guard case .failure(let failure) = m.apply(plan) else { return XCTFail("should refuse") }
        XCTAssertEqual(failure.error, .sessionInProgress)
        XCTAssertFalse(failure.needsRefresh)
        XCTAssertTrue(failure.message.contains("Nothing was changed"))
        XCTAssertTrue(plan.targets.allSatisfy { $0.item.exerciseId != m.replacementId })
    }

    func test_stalePlan_failsWithRefreshHint() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        let plan = try XCTUnwrap(m.plan(for: .allRemaining))
        plan.targets[1].item.actualLoads = [135]; plan.targets[1].item.actualReps = [5]
        guard case .failure(let failure) = m.apply(plan) else { return XCTFail("should be stale") }
        XCTAssertTrue(failure.needsRefresh)
        XCTAssertTrue(failure.message.contains("Nothing was changed"))
        XCTAssertTrue(plan.targets.allSatisfy { $0.item.exerciseId != m.replacementId })
    }

    func test_todayNote_text() {
        XCTAssertEqual(Model.todayInSessionNote, "Finish the session, then replace the rest from the Program tab.")
        XCTAssertEqual(Model.unchangedFooter, "Unchanged: completed sessions, other days, every other exercise.")
    }

    // MARK: Today swap writes back by identity

    func test_todaySwap_writeBackResolvesTheSwappedItemByIdentity_notByExerciseId() throws {
        let c = try ModelContainer(for: Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                                                UserProfile.self, User.self, CustomExercise.self]),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let first = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        let second = SessionItem(order: 2, exerciseId: "bench_press", targetReps: 12, targetSets: 2, targetRIR: 3, suggestedLoad: 80)
        let session = Session(date: Date(), status: .planned, weekIndex: 1, items: [first, second])

        func row(_ item: SessionItem) -> UISessionExercise {
            UISessionExercise(exerciseId: item.exerciseId, name: "Bench Press", detail: "", weekInMeso: 1,
                              targetSets: item.targetSets, sets: [], itemID: item.id)
        }
        // Both rows share an exerciseId; the identity picks the right item either way.
        XCTAssertTrue(SessionScreenViewModel.sessionItem(for: row(second), in: session) === second)
        XCTAssertTrue(SessionScreenViewModel.sessionItem(for: row(first), in: session) === first)
        // exerciseId alone would have returned `first` for the second row.
        XCTAssertTrue(session.items.first(where: { $0.exerciseId == "bench_press" }) === first)
        // A row with no item identity resolves to nothing rather than guessing.
        let anonymous = UISessionExercise(exerciseId: "bench_press", name: "Bench Press", detail: "", weekInMeso: 1,
                                          targetSets: 3, sets: [])
        XCTAssertNil(SessionScreenViewModel.sessionItem(for: anonymous, in: session))
    }
}
