import XCTest
import SwiftData
@testable import ElitePerformance

/// `Session.plannedDate`: set at creation, moved by Rest today and insert / remove deload with the date, never by
/// completion.
final class PlannedDateTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: scheduledKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: scheduledKey); super.tearDown() }

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

    private func item() -> SessionItem {
        SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 8, targetSets: 4, targetRIR: 2, suggestedLoad: 0,
                    setMin: 3, setMax: 5, repMin: 8, repMax: 10, targetRIRMin: 1, targetRIRMax: 2,
                    plannedRepsBySet: [8, 8, 8, 8], plannedLoadsBySet: [0, 0, 0, 0], plannedRIRsBySet: [2, 2, 2, 2])
    }

    /// One session per week (`offsets` per week when given).
    private func block(_ ctx: ModelContext, weeks: Int, start: Date, offsets: [Int] = [0]) throws -> MesoBlock {
        let b = MesoBlock(name: "B", startDate: start, status: .active, totalWeeks: weeks)
        ctx.insert(b)
        var pi = 1
        for w in 1...weeks {
            for (k, off) in offsets.enumerated() {
                let s = Session(date: plus(start, 7 * (w - 1) + off), status: .planned, weekIndex: w, dayLabel: "Day \(k + 1)",
                                items: [item()], programIndex: pi)
                s.meso = b
                ctx.insert(s)
                pi += 1
            }
        }
        try ctx.save()
        return b
    }

    private func sorted(_ b: MesoBlock) -> [Session] { b.sessions.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) } }

    func test_creation_setsPlannedDateToDate() {
        let d = date(2026, 11, 2)
        let s = Session(date: d)
        XCTAssertEqual(s.plannedDate, d)
        XCTAssertEqual(s.plannedDateExact, true, "recorded at creation: the real schedule")
    }

    func test_completion_neverMovesPlannedDate() throws {
        let ctx = try makeContext()
        let b = try block(ctx, weeks: 2, start: date(2026, 11, 2))
        let s = sorted(b)[0]
        let planned = s.date
        // What SessionView does on completion: date and completedAt become "now"; plannedDate is not written there.
        s.status = .completed
        s.completedAt = plus(planned, 2)
        s.date = plus(planned, 2)
        XCTAssertEqual(s.plannedDate, planned, "plannedDate stays the scheduled day after a late completion")
    }

    /// The only completion paths are in SessionView; none may write plannedDate.
    func test_sessionViewNeverWritesPlannedDate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Features/Session/SessionView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("plannedDate"), "completion must not move plannedDate")
    }

    func test_restToday_movesPlannedDateWithTheMovedSessions_only() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = try block(ctx, weeks: 2, start: start, offsets: [0, 2, 4])
        let before = sorted(b).map { ($0.persistentModelID, $0.date) }
        let plan = Service.planRestToday(meso: b, context: ctx, now: plus(start, 2))
        XCTAssertNil(plan.refusal)
        let movedIDs = Set(plan.moves.map { $0.session.persistentModelID })
        XCTAssertFalse(movedIDs.isEmpty)
        try Service.restToday(plan, in: ctx)
        for (id, oldDate) in before {
            let s = try XCTUnwrap(b.sessions.first { $0.persistentModelID == id })
            if movedIDs.contains(id) {
                XCTAssertEqual(s.date, plus(oldDate, 1))
                XCTAssertEqual(s.plannedDate, s.date, "moved with the date")
            } else {
                XCTAssertEqual(s.date, oldDate)
                XCTAssertEqual(s.plannedDate, oldDate, "untouched")
            }
        }
    }

    func test_insertThenRemoveDeload_movePlannedDateWithDate_andCompletedNeverMove() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let b = try block(ctx, weeks: 4, start: start)
        let first = sorted(b)[0]
        first.status = .completed
        first.completedAt = first.date
        let firstDates = (first.date, first.plannedDate)
        let before = sorted(b).map { ($0.persistentModelID, $0.date, $0.plannedDate) }

        let plan = Service.planInsertDeloadWeek(meso: b, context: ctx, now: plus(start, 7))
        XCTAssertNil(plan.refusal)
        try Service.insertDeloadWeek(plan, in: ctx)

        XCTAssertEqual(first.date, firstDates.0)
        XCTAssertEqual(first.plannedDate, firstDates.1, "a completed session never moves")
        for s in b.sessions {
            XCTAssertEqual(s.plannedDate, s.date, "every planned session's plannedDate follows its date (\(s.dayLabel ?? "?") wk\(s.weekIndex))")
        }
        let inserted = b.sessions.filter { $0.insertedDeload == true }
        XCTAssertFalse(inserted.isEmpty)
        XCTAssertTrue(inserted.allSatisfy { $0.plannedDate == $0.date }, "new deload sessions are born planned")

        let removal = Service.planRemoveInsertedDeloadWeek(meso: b, context: ctx, now: plus(start, 7))
        try Service.removeInsertedDeloadWeek(removal, in: ctx)
        for (id, d, p) in before {
            let s = try XCTUnwrap(b.sessions.first { $0.persistentModelID == id })
            XCTAssertEqual(s.date, d)
            XCTAssertEqual(s.plannedDate, p, "back where it was after the remove")
        }
    }
}
