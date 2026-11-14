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
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
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
                      increment: Double = 2.5, credit: Bool = false) -> Double? {
        HistorySeedLoad.load(for: id, goalReps: reps, targetRIR: rir, in: sessions,
                             loadIncrement: increment, referenceDate: now, creditRIR: credit)
    }

    func test_completedHistory_seedsFromInverseEpley() throws {
        let ctx = try makeContext()
        // 100 x 10 -> e1RM 133.33; at 8 reps / 2 RIR: 133.33 / 1.2667 * 0.95 = 100.0
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [10, 8, 8], loads: [100, 100, 100])
        XCTAssertEqual(seed([s]), 100.0)
    }

    func test_roundsDownToTheUsersIncrement_exceptANearMiss() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [104])   // raw 104.0
        XCTAssertEqual(seed([s], increment: 5), 100.0, "1 short of 105 is exactly a fifth of the step: floor")
        XCTAssertEqual(seed([s], increment: 2.5), 102.5, "1.0 short of 105 is more than 0.5: floor")
        let near = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [104.2])   // raw 104.2
        XCTAssertEqual(seed([near], increment: 5), 105.0, "0.8 short of 105 is under a fifth of the step")
        XCTAssertEqual(seed([near], increment: 2.5), 102.5, "0.8 short of 105 at 2.5 is not under 0.5: floor")
        let exact = session(ctx, status: .completed, daysAgo: 0, reps: [10], loads: [100])   // float noise: 99.99999999
        XCTAssertEqual(seed([exact], increment: 2.5), 100.0, "a whole increment is kept")
    }

    func test_RIR2History_forA4RepRIR3Target_roundsDownFromTheExactLoad() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [2])
        // e1RM 130 x (9+2) = 177.67; / (1 + 4/30) = 156.76; x 0.925 = 145.007 exact.
        XCTAssertEqual(seed([s], reps: 4, rir: 3, increment: 2.5, credit: true), 145.0)
        // At a 5 lb step the same exact load floors to 145, and a 10 lb step to 140 — never 150.
        XCTAssertEqual(seed([s], reps: 4, rir: 3, increment: 5, credit: true), 145.0)
        XCTAssertEqual(seed([s], reps: 4, rir: 3, increment: 10, credit: true), 140.0)
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

    // EEE: seeding is reps-only by default. Old RIRs are plan-prefilled (84% equal the plan) and must not inflate loads.
    func test_defaultSeeds_ignoreRIR_entirely() throws {
        let ctx = try makeContext()
        let rirs: [[Int]] = [[0], [2], [4], [9], [-1]]
        let seeds = try rirs.map { try XCTUnwrap(seed([session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: $0)])) }
        XCTAssertEqual(Set(seeds).count, 1, "130 x 9 seeds the same load whatever RIR was logged: \(seeds)")
        let none = try XCTUnwrap(seed([session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130])]))
        XCTAssertEqual(seeds[0], none)
        let peaks = try rirs.map { try XCTUnwrap(peak([session(ctx, status: .completed, daysAgo: 1, reps: [9], loads: [130], rirs: $0)])) }
        XCTAssertEqual(Set(peaks).count, 1, "the peak seed ignores RIR too: \(peaks)")
        // And the credited number really is higher, so the default is a real change.
        let credited = try XCTUnwrap(seed([session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [2])], credit: true))
        XCTAssertGreaterThan(credited, seeds[0])
    }

    func test_missedSourceSeeding_andNextMesoPlan_useRepsOnlyE1RM() throws {
        // 100 x 10 @ RIR 4 and @ RIR 0 must produce identical next-meso seeds.
        let ctx = try makeContext()
        let a = session(ctx, status: .completed, daysAgo: 1, reps: [10], loads: [100], rirs: [4])
        let b = session(ctx, status: .completed, daysAgo: 1, reps: [10], loads: [100], rirs: [0])
        for (x, y) in [(a, b)] {
            let sa = HistorySeedLoad.nextMesoSeed(for: "bench_press", goalReps: 8, targetRIR: 2, previousMeso: [x], allSessions: [x], loadIncrement: 2.5, isFixedLoad: false, referenceDate: now)
            let sb = HistorySeedLoad.nextMesoSeed(for: "bench_press", goalReps: 8, targetRIR: 2, previousMeso: [y], allSessions: [y], loadIncrement: 2.5, isFixedLoad: false, referenceDate: now)
            XCTAssertEqual(sa.load, sb.load)
        }
    }

    func test_loggedRIR_raisesTheSeed() throws {
        let ctx = try makeContext()
        let rir0 = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [0])
        let rir2 = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [2])
        let heavy = try XCTUnwrap(seed([rir2], credit: true)), light = try XCTUnwrap(seed([rir0], credit: true))
        XCTAssertGreaterThan(heavy, light, "130x9@2 is a bigger lift than 130x9@0")
        // 130 x (9+2) -> e1RM 177.67; /1.2667 * 0.95 = 133.25 -> floor 132.5
        XCTAssertEqual(heavy, 132.5)
        XCTAssertEqual(light, 125.0)   // 130 x 9 -> e1RM 169 -> 126.75, 0.75 short of 127.5 (more than half a step window of 0.5) -> floor 125
    }

    func test_missingRIR_countsAsZero_andRIRIsClampedToFour() throws {
        let ctx = try makeContext()
        let none = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130])
        let zero = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [0])
        XCTAssertEqual(seed([none], credit: true), seed([zero], credit: true))
        let four = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [4])
        let seven = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [7])
        XCTAssertEqual(seed([seven], credit: true), seed([four], credit: true), "RIR above 4 is not credited")
        let negative = session(ctx, status: .completed, daysAgo: 0, reps: [9], loads: [130], rirs: [-3])
        XCTAssertEqual(seed([negative], credit: true), seed([zero], credit: true), "negative RIR floors at 0")
        XCTAssertGreaterThan(try XCTUnwrap(seed([four], credit: true)), try XCTUnwrap(seed([zero], credit: true)))
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

    // MARK: - Peak seed (next meso)

    private func peak(_ sessions: [Session], id: String = "bench_press", reps: Int = 8, rir: Int = 2,
                      factor: Double = 0.95, increment: Double = 2.5, credit: Bool = false) -> Double? {
        HistorySeedLoad.peakLoad(for: id, goalReps: reps, targetRIR: rir, in: sessions,
                                 loadIncrement: increment, factor: factor, creditRIR: credit)
    }

    private func expectedPeak(load: Double, reps: Int, rir: Int, goalReps: Int = 8, goalRIR: Int = 2,
                              factor: Double = 0.95, increment: Double = 2.5, credit: Bool = false) -> Double {
        let e = E1RMCalculator.e1RM(load: load, reps: reps + (credit ? rir : 0))
        return HistorySeedLoad.roundedDown(E1RMCalculator.load(for: e, reps: goalReps, targetRIR: goalRIR) * factor, increment: increment)
    }

    func test_peak_picksTheBestSession_notTheMean() throws {
        let ctx = try makeContext()
        let heavy = session(ctx, status: .completed, daysAgo: 60, reps: [6, 6], loads: [140, 140], rirs: [1, 1], wave: "a")
        let light = session(ctx, status: .completed, daysAgo: 1, reps: [10, 10], loads: [100, 100], rirs: [2, 2], wave: "b")
        let p = try XCTUnwrap(peak([heavy, light], credit: true))
        XCTAssertEqual(p, expectedPeak(load: 140, reps: 6, rir: 1, credit: true))
        XCTAssertGreaterThan(p, try XCTUnwrap(seed([heavy, light], credit: true)), "recent light work does not pull a peak down")
    }

    func test_peak_creditsRIR_andClampsIt() throws {
        let ctx = try makeContext()
        let a = session(ctx, status: .completed, daysAgo: 1, reps: [8], loads: [100], rirs: [4])
        let b = session(ctx, status: .completed, daysAgo: 1, reps: [8], loads: [100], rirs: [9])
        XCTAssertEqual(peak([a], credit: true), peak([b], credit: true), "RIR above 4 is not credited")
        XCTAssertEqual(peak([a], credit: true), expectedPeak(load: 100, reps: 8, rir: 4, credit: true))
    }

    func test_peak_excludesDeloadInsertedMaintenanceAndPlanned() throws {
        let ctx = try makeContext()
        let deload = session(ctx, status: .completed, daysAgo: 1, reps: [10], loads: [200], wave: "deload")
        let inserted = session(ctx, status: .completed, daysAgo: 1, reps: [10], loads: [200], wave: "a")
        inserted.insertedDeload = true
        let maint = session(ctx, status: .completed, daysAgo: 1, reps: [10], loads: [200], wave: "a", maintenance: true)
        let planned = session(ctx, status: .planned, daysAgo: 1, reps: [10], loads: [200], wave: "a")
        XCTAssertNil(peak([deload, inserted, maint, planned], credit: true))
        let real = session(ctx, status: .completed, daysAgo: 5, reps: [8], loads: [100], rirs: [2], wave: "a")
        XCTAssertEqual(peak([deload, inserted, maint, planned, real], credit: true), expectedPeak(load: 100, reps: 8, rir: 2, credit: true))
    }

    func test_peak_excludesRestPauseDropSkipAndWarmupSets() throws {
        let ctx = try makeContext()
        let base = session(ctx, status: .completed, daysAgo: 1, reps: [10], loads: [100])
        let baseline = try XCTUnwrap(peak([base]))
        let rp = session(ctx, status: .completed, daysAgo: 1, reps: [10, 20], loads: [100, 100], restPause: ["", "5+3+2"])
        let drop = session(ctx, status: .completed, daysAgo: 1, reps: [10, 20], loads: [100, 100], drop: ["", "80x8"])
        let skip = session(ctx, status: .completed, daysAgo: 1, reps: [10, 20], loads: [100, 100], restPause: ["", "SKIP"])
        let warmup = session(ctx, status: .completed, daysAgo: 1, reps: [10, 100], loads: [100, 45])
        for s in [rp, drop, skip, warmup] { XCTAssertEqual(peak([s]), baseline) }
    }

    func test_peak_factorIsApplied_andRoundsDown() throws {
        let ctx = try makeContext()
        let s = session(ctx, status: .completed, daysAgo: 1, reps: [8, 8], loads: [137, 137], rirs: [2, 2])
        let full = try XCTUnwrap(peak([s], factor: 1.0, credit: true))
        let ninety = try XCTUnwrap(peak([s], factor: 0.90, credit: true))
        XCTAssertEqual(full, expectedPeak(load: 137, reps: 8, rir: 2, factor: 1.0, credit: true))
        XCTAssertEqual(ninety, expectedPeak(load: 137, reps: 8, rir: 2, factor: 0.90, credit: true))
        XCTAssertLessThan(ninety, full)
        XCTAssertEqual(full.truncatingRemainder(dividingBy: 2.5), 0)
        let exact = E1RMCalculator.load(for: E1RMCalculator.e1RM(load: 137, reps: 10), reps: 8, targetRIR: 2)
        XCTAssertLessThanOrEqual(full, exact * 1.025, "at most a near miss above the computed load")
    }

    func test_nextMesoSeed_fallsBackToHistory_thenZero() throws {
        let ctx = try makeContext()
        let older = session(ctx, status: .completed, daysAgo: 90, reps: [8], loads: [100], rirs: [2])
        func resolve(previous: [Session], all: [Session], fixed: Bool = false, id: String = "bench_press") -> (load: Double, source: HistorySeedLoad.SeedSource) {
            HistorySeedLoad.nextMesoSeed(for: id, goalReps: 8, targetRIR: 2, previousMeso: previous, allSessions: all,
                                         loadIncrement: 2.5, isFixedLoad: fixed, referenceDate: now)
        }
        let viaHistory = resolve(previous: [], all: [older])
        XCTAssertEqual(viaHistory.source, .history)
        XCTAssertEqual(viaHistory.load, seed([older]))
        let viaPeak = resolve(previous: [older], all: [older])
        XCTAssertEqual(viaPeak.source, .peak)
        XCTAssertEqual(viaPeak.load, peak([older]))
        let none = resolve(previous: [], all: [], id: "squat")
        XCTAssertEqual(none.source, .none)
        XCTAssertEqual(none.load, 0)
        XCTAssertEqual(HistorySeedLoad.SeedSource.peak.label(factor: 0.95), "peak95")
    }

    func test_nextMesoSeed_fixedLoad_usesLastLiftedLoad_notPeak() throws {
        let ctx = try makeContext()
        let heavy = session(ctx, status: .completed, daysAgo: 30, reps: [6], loads: [200], rirs: [1], wave: "a")
        let last = session(ctx, status: .completed, daysAgo: 2, reps: [10, 10], loads: [110, 112.5], rirs: [2, 2], wave: "b")
        let r = HistorySeedLoad.nextMesoSeed(for: "bench_press", goalReps: 8, targetRIR: 2, previousMeso: [heavy, last],
                                             allSessions: [heavy, last], loadIncrement: 2.5, isFixedLoad: true, referenceDate: now)
        XCTAssertEqual(r.source, .fixed)
        XCTAssertEqual(r.load, 112.5)
        let nothing = HistorySeedLoad.nextMesoSeed(for: "squat", goalReps: 8, targetRIR: 2, previousMeso: [], allSessions: [],
                                                   loadIncrement: 2.5, isFixedLoad: true, referenceDate: now)
        XCTAssertEqual(nothing.load, 0)
        XCTAssertEqual(nothing.source, .none)
    }

    func test_nextMesoSeed_bodyweightIsZero() throws {
        let ctx = try makeContext()
        let id = try XCTUnwrap(ExerciseCatalog.all.first { ExerciseCatalog.isBodyweight(exerciseId: $0.id) }).id
        let s = session(ctx, status: .completed, daysAgo: 1, exerciseId: id, reps: [10], loads: [25])
        let r = HistorySeedLoad.nextMesoSeed(for: id, goalReps: 8, targetRIR: 2, previousMeso: [s], allSessions: [s],
                                             loadIncrement: 2.5, isFixedLoad: false, referenceDate: now)
        XCTAssertEqual(r.load, 0)
        XCTAssertEqual(r.source, .bodyweight)
    }

    func test_roundedDown_nearMissRule() {
        func r(_ v: Double, _ inc: Double) -> Double { HistorySeedLoad.roundedDown(v, increment: inc) }
        XCTAssertEqual(r(14.9, 5), 15)
        XCTAssertEqual(r(33.1, 5), 30)
        XCTAssertEqual(r(316.0, 5), 315)
        XCTAssertEqual(r(318.5, 5), 315, "1.5 short of 320 is more than a fifth of the step")
        XCTAssertEqual(r(319.2, 5), 320)
        XCTAssertEqual(r(104, 5), 100, "exactly a fifth of the step short is not a near miss")
        XCTAssertEqual(r(104.01, 5), 105)
        XCTAssertEqual(r(315.0, 5), 315, "a whole increment stays")
        // 2.5-lb increments: the window is 0.5.
        XCTAssertEqual(r(102.0, 2.5), 100, "exactly half a step short is not a near miss")
        XCTAssertEqual(r(102.1, 2.5), 102.5)
        XCTAssertEqual(r(101.9, 2.5), 100)
        XCTAssertEqual(r(102.4, 2.5), 102.5)
        XCTAssertEqual(r(126.75, 2.5), 125)
        XCTAssertEqual(r(127.2, 2.5), 127.5)
        XCTAssertEqual(r(99.99999999, 2.5), 100)
        XCTAssertEqual(r(0, 5), 0)
        XCTAssertEqual(r(2.49, 2.5), 2.5)
        XCTAssertEqual(r(2.0, 2.5), 0, "exactly half a step short is not a near miss")
        XCTAssertEqual(r(1.0, 2.5), 0)
        XCTAssertEqual(r(42.3, 0), 42.3, "no increment, no rounding")
    }
}
