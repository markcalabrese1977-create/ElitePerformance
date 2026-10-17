import XCTest
import SwiftData
@testable import ElitePerformance

final class HistorySeedLoadTests: XCTestCase {

    private let now = Date()
    private func daysAgo(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now)! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
            UserProfile.self, User.self, CustomExercise.self
        ])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func session(
        _ ctx: ModelContext, status: SessionStatus, daysAgo n: Int, exerciseId: String = "bench_press",
        reps: [Int] = [], loads: [Double] = [], suggested: Double = 0
    ) -> Session {
        let item = SessionItem(order: 1, exerciseId: exerciseId, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: suggested)
        item.plannedLoadsBySet = [suggested, suggested, suggested]
        item.actualReps = reps
        item.actualLoads = loads
        let s = Session(date: daysAgo(n), status: status, weekIndex: 1, items: [item])
        ctx.insert(s)
        return s
    }

    private func seed(_ sessions: [Session], id: String = "bench_press", reps: Int = 8, rir: Int = 2,
                      increment: Double = 2.5) -> Double? {
        HistorySeedLoad.load(for: id, goalReps: reps, targetRIR: rir, in: sessions,
                             loadIncrement: increment, referenceDate: now)
    }

    func test_completedHistory_seedsFromInverseEpley() throws {
        let ctx = try makeContext()
        // 100 x 10 -> e1RM 133.33; at 8 reps / 2 RIR: 133.33 / 1.2667 * 0.95 = 100.0
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [10, 8, 8], loads: [100, 100, 100])
        XCTAssertEqual(seed([s]), 100.0)
    }

    func test_roundsToTheUsersIncrement() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [102])
        XCTAssertEqual(seed([s], increment: 5), 100.0)   // raw ~102.0 -> nearest 5
        XCTAssertEqual(seed([s], increment: 2.5), 102.5)
    }

    func test_ignoresPlannedAndInProgressSessions_evenWithActuals() throws {
        let ctx = try makeContext()
        let planned = session(ctx, status: .planned, daysAgo: -3, reps: [10], loads: [300])
        let live = session(ctx, status: .inProgress, daysAgo: 0, reps: [10], loads: [300])
        XCTAssertNil(seed([planned, live]))
        let done = session(ctx, status: .completed, daysAgo: 7, reps: [10], loads: [100])
        XCTAssertEqual(seed([planned, live, done]), 100.0, "only the completed session counts")
    }

    func test_ignoresSuggestedAndPlannedLoads() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 1, suggested: 200)   // nothing actually logged
        XCTAssertNil(seed([s]))
    }

    func test_ignoresSetsWithoutRepsOrLoad() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 1, reps: [0, 10, 5], loads: [500, 0, 0])
        XCTAssertNil(seed([s]))
    }

    func test_canonicalAliasMatch() throws {
        let ctx = try makeContext()
        // Legacy UUID spelling of arnold_press in history; the catalog id on the request.
        let s = session(ctx, status: .completed, daysAgo: 0, exerciseId: "31c44a80-6c56-4e9d-aca1-ee754cd157b6",
                        reps: [10], loads: [100])
        XCTAssertEqual(seed([s], id: "arnold_press"), 100.0)
        let s2 = session(ctx, status: .completed, daysAgo: 0, exerciseId: "arnold_press", reps: [10], loads: [100])
        XCTAssertEqual(seed([s2], id: "31c44a80-6c56-4e9d-aca1-ee754cd157b6"), 100.0)
    }

    func test_doesNotMatchADifferentExercise() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, exerciseId: "bench_press", reps: [10], loads: [100])
        XCTAssertNil(seed([s], id: "arnold_press"))
    }

    func test_bodyweightReturnsZero_evenWithHistory() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, exerciseId: "pull_up", reps: [8], loads: [25])
        XCTAssertEqual(seed([s], id: "pull_up"), 0)
        XCTAssertEqual(seed([], id: "pull_up"), 0, "bodyweight is 0, not nil, with or without history")
    }

    func test_noHistory_isNil() throws {
        XCTAssertNil(seed([]))
    }

    func test_decayWeighting_favorsRecentSessions() throws {
        let ctx = try makeContext()
        let old = session(ctx, status: .completed, daysAgo: 42, reps: [10], loads: [80])
        let recent = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100])
        let both = try XCTUnwrap(seed([old, recent]))
        XCTAssertGreaterThan(both, 80)
        XCTAssertLessThan(both, 100)
        XCTAssertGreaterThan(both, 90, "a 6-week-old session carries a quarter of the recent one's weight")
    }
}
