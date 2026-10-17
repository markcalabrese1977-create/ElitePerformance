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
        reps: [Int] = [], loads: [Double] = [], suggested: Double = 0,
        rirs: [Int] = [], wave: String? = nil, restPause: [String] = [], drop: [String] = [], rpFlags: [Bool] = [],
        maintenance: Bool = false
    ) -> Session {
        let item = SessionItem(order: 1, exerciseId: exerciseId, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: suggested)
        item.plannedLoadsBySet = [suggested, suggested, suggested]
        item.actualReps = reps
        item.actualLoads = loads
        item.actualRIRs = rirs
        item.waveRaw = wave
        item.restPausePatternsBySet = restPause
        item.dropSetPatternsBySet = drop
        item.usedRestPauseFlags = rpFlags
        let s = Session(date: daysAgo(n), status: status, weekIndex: 1, items: [item])
        if maintenance {
            let m = MesoBlock(name: "Maintenance Block", startDate: daysAgo(30), status: .active, totalWeeks: 4, isMaintenance: true)
            ctx.insert(m)
            s.meso = m
        }
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

    func test_roundsDownToTheUsersIncrement_neverAboveTheComputedLoad() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [104])   // raw 104.0
        XCTAssertEqual(seed([s], increment: 5), 100.0, "nearest would be 105")
        XCTAssertEqual(seed([s], increment: 2.5), 102.5, "nearest would be 105")
        let exact = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100])   // float noise: 99.99999999
        XCTAssertEqual(seed([exact], increment: 2.5), 100.0, "a whole increment is kept")
    }

    func test_RIR2History_forA4RepRIR3Target_roundsDownFromTheExactLoad() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [2])
        // e1RM 130 x (9+2) = 177.67; / (1 + 4/30) = 156.76; x 0.925 = 145.007 exact.
        XCTAssertEqual(seed([s], reps: 4, rir: 3, increment: 2.5), 145.0)
        // At a 5 lb step the same exact load floors to 145, and a 10 lb step to 140 — never 150.
        XCTAssertEqual(seed([s], reps: 4, rir: 3, increment: 5), 145.0)
        XCTAssertEqual(seed([s], reps: 4, rir: 3, increment: 10), 140.0)
    }

    func test_decay_anOldHeavySetCountsLessThanARecentLighterOne() throws {
        let ctx = try makeContext()
        let oldHeavy = session(ctx, status: .completed, daysAgo: 84, reps: [10], loads: [120])   // 4 half-lives
        let recentLight = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100])
        let blended = try XCTUnwrap(seed([oldHeavy, recentLight]))
        let recentOnly = try XCTUnwrap(seed([recentLight]))
        XCTAssertGreaterThanOrEqual(blended, recentOnly)
        XCTAssertLessThan(blended, 105, "the 84-day-old 120 carries 1/16 of the weight: it nudges, not leads")
        let equalAge = try XCTUnwrap(seed([session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [120]), recentLight]))
        XCTAssertGreaterThan(equalAge, blended, "the same heavy set, but recent, pulls much harder")
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

    // MARK: - C3b: logged RIR and non-representative sets

    func test_loggedRIR_raisesTheSeed() throws {
        let ctx = try makeContext()
        let rir0 = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [0])
        let rir2 = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [2])
        let heavy = try XCTUnwrap(seed([rir2])), light = try XCTUnwrap(seed([rir0]))
        XCTAssertGreaterThan(heavy, light, "130x9@2 is a bigger lift than 130x9@0")
        // 130 x (9+2) -> e1RM 177.67; /1.2667 * 0.95 = 133.25 -> floor 132.5
        XCTAssertEqual(heavy, 132.5)
        XCTAssertEqual(light, 125.0)   // 130 x 9 -> e1RM 169 -> 126.75 -> floor 125
    }

    func test_missingRIR_countsAsZero_andRIRIsClampedToFour() throws {
        let ctx = try makeContext()
        let none = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130])
        let zero = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [0])
        XCTAssertEqual(seed([none]), seed([zero]))
        let four = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [4])
        let seven = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [7])
        XCTAssertEqual(seed([seven]), seed([four]), "RIR above 4 is not credited")
        let negative = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [-3])
        XCTAssertEqual(seed([negative]), seed([zero]), "negative RIR floors at 0")
        XCTAssertGreaterThan(try XCTUnwrap(seed([four])), try XCTUnwrap(seed([zero])))
    }

    func test_deloadItem_andMaintenanceBlock_areExcluded() throws {
        let ctx = try makeContext()
        let deload = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100], wave: "deload")
        XCTAssertNil(seed([deload]))
        // Maintenance sessions carry the deload wave on every item.
        let maint = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100], wave: "deload", maintenance: true)
        XCTAssertNil(seed([maint]))
        let a = session(ctx, status: .completed, daysAgo: 3, reps: [10], loads: [100], wave: "a")
        XCTAssertEqual(seed([deload, maint, a]), 100.0, "only the wave-A session counts")
    }

    func test_restPauseDropSkipAndWarmupSets_areExcluded() throws {
        let ctx = try makeContext()
        let base = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100])
        let baseline = try XCTUnwrap(seed([base]))

        // Each inflating set sits beside a normal 100 x 10 set; none may move the seed.
        let rpPattern = session(ctx, status: .completed, daysAgo: 0, reps: [10, 20], loads: [100, 100], restPause: ["", "5+3+2"])
        let rpFlag = session(ctx, status: .completed, daysAgo: 0, reps: [10, 20], loads: [100, 100], rpFlags: [false, true])
        let drop = session(ctx, status: .completed, daysAgo: 0, reps: [10, 20], loads: [100, 100], drop: ["", "80x8"])
        let skip = session(ctx, status: .completed, daysAgo: 0, reps: [10, 20], loads: [100, 100], restPause: ["", "SKIP"])
        let warmup = session(ctx, status: .completed, daysAgo: 0, reps: [10, 100], loads: [100, 45])   // 45 < 50% of 100
        for (name, s) in [("rest-pause pattern", rpPattern), ("rest-pause flag", rpFlag), ("drop", drop),
                          ("skip", skip), ("warm-up", warmup)] {
            XCTAssertEqual(seed([s]), baseline, name)
        }
        // A session of only excluded sets contributes nothing.
        let onlyRP = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100], restPause: ["5+3"])
        XCTAssertNil(seed([onlyRP]))
        // 50% exactly is kept (a real light set, not a warm-up).
        let half = session(ctx, status: .completed, daysAgo: 0, reps: [10, 100], loads: [100, 50])
        XCTAssertGreaterThan(try XCTUnwrap(seed([half])), baseline)
    }
}
