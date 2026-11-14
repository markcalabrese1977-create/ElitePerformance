import XCTest
import SwiftData
@testable import ElitePerformance

/// MesoComparison: previous-block resolution, per-lift peak / top-3 change, new / dropped / replaced lifts, PRs, muscle
/// averages, adherence and the next-block notes. Records are built directly.
final class MesoComparisonTests: XCTestCase {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400) }
    private var counter = 0

    private func sets(_ n: Int, _ id: String, load: Double, reps: [Int] = [8, 8, 8], meso: String, letter: String? = "a",
                      label: String = "Push", coarse: MuscleGroup = .chest, name: String? = nil, key explicitKey: String? = nil) -> [SetRecord] {
        counter += 1
        let key = explicitKey ?? "s\(n)-\(id)-\(counter)"
        return reps.enumerated().map { i, r in
            SetRecord(
                sessionKey: key, sessionDate: day(n), status: .completed, weekIndex: 1, dayLabel: label, mesoKey: meso,
                exerciseId: id, exerciseName: name ?? id, muscle: coarse, isBodyweight: false,
                waveLetter: letter, isDeloadWaveItem: false, isInsertedDeload: false, isDeloadWeek: false, isMaintenance: false,
                rowIndex: i, isTop: false, plannedReps: 8, plannedLoad: load, repMin: 6, repMax: 12, targetRIRMin: 1, targetRIRMax: 2,
                targetRIR: 2, reps: r, load: load, effectiveLoad: load, rir: 2, isSkipped: false, isRestPause: false, isDrop: false,
                feedback: .none, pump: 0, loadOverride: nil, planEdited: false, readiness: .normal, readinessStars: 0,
                hkDuration: 0, isWorkingSet: true, isHardSetRow: true)
        }
    }

    private func info(_ key: String, start: Int, maint: Bool = false, prev: String? = nil) -> MesoInfo {
        MesoInfo(key: key, name: key, startDate: day(start), isMaintenance: maint, previousKey: prev)
    }

    private func rec(_ key: String, _ d: Int, meso: String, status: SessionStatus = .completed) -> SessionRecord {
        SessionRecord(key: key, date: day(d), plannedDate: day(d), plannedDateIsExact: true, completedAt: nil, status: status,
                      weekIndex: 1, dayLabel: "Push", mesoKey: meso, mesoName: meso, isMaintenance: false, isInsertedDeload: false,
                      isDeloadWeek: false, readiness: .normal, readinessStars: 0, hkDuration: 0)
    }

    // MARK: - Previous block

    func test_previous_followsTheLink_elseTheLatestEarlierBlockByDate() {
        let a = info("a", start: 0), b = info("b", start: 100, prev: "a"), c = info("c", start: 200)
        XCTAssertEqual(MesoInfo.previous(of: "b", in: [a, b, c])?.key, "a", "linked")
        XCTAssertEqual(MesoInfo.previous(of: "c", in: [a, b, c])?.key, "b", "no link: previous by start date")
        XCTAssertNil(MesoInfo.previous(of: "a", in: [a, b, c]), "the first block has none")
        // a link to a maintenance block continues past it
        let m = info("m", start: 150, maint: true, prev: "b")
        let d = info("d", start: 300, prev: "m")
        XCTAssertEqual(MesoInfo.previous(of: "d", in: [a, b, m, d])?.key, "b", "maintenance is skipped through its own link")
        // maintenance with no usable link falls back by date past maintenance blocks
        let m2 = info("m2", start: 250, maint: true)
        XCTAssertEqual(MesoInfo.previous(of: "e", in: [a, b, m2, info("e", start: 400)])?.key, "b")
        XCTAssertNil(MesoInfo.previous(of: "z", in: [a]), "unknown block")
    }

    // MARK: - Compare

    private func compare(_ all: [SetRecord], sessions: [SessionRecord] = [], infos: [MesoInfo]? = nil, asOf: Int = 400,
                         stalled: [String] = []) -> MesoComparison? {
        MesoComparer.compare(
            snapshot: AnalyticsSnapshot(sessions: sessions, sets: all),
            infos: infos ?? [info("old", start: 0), info("new", start: 100, prev: "old")], currentKey: "new",
            customs: [], profile: nil, asOf: day(asOf), stalledLifts: stalled)
    }

    func test_liftPeakAndTop3_andChange() throws {
        var all: [SetRecord] = []
        for (i, l) in [200.0, 210, 220, 205].enumerated() { all += sets(10 + i * 7, "bench_press", load: l, meso: "old") }
        for (i, l) in [190.0, 215, 230].enumerated() { all += sets(110 + i * 7, "bench_press", load: l, meso: "new") }
        let c = try XCTUnwrap(compare(all))
        let row = try XCTUnwrap(c.lifts.first)
        XCTAssertEqual(c.lifts.count, 1)
        XCTAssertEqual(row.previousExposures, 4)
        XCTAssertEqual(row.currentExposures, 3)
        XCTAssertGreaterThan(row.currentPeak, row.previousPeak, "230 vs 220")
        XCTAssertEqual(row.peakChange, (row.currentPeak - row.previousPeak) / row.previousPeak, accuracy: 1e-9)
        XCTAssertEqual(row.previousTop3, ([row.previousPeak] + [210.0, 205.0].map { E1RMCalculator.e1RM(load: $0, reps: 8) }).reduce(0, +) / 3, accuracy: 1e-6)
        XCTAssertLessThan(row.currentFirst, row.previousPeak, "the first exposure of the new block (a seed) starts below the old peak")
    }

    func test_lettersAreComparedOnlyWithThemselves() throws {
        var all = sets(10, "bench_press", load: 200, meso: "old", letter: "a") + sets(11, "bench_press", load: 180, meso: "old", letter: "b")
        all += sets(110, "bench_press", load: 210, meso: "new", letter: "a") + sets(111, "bench_press", load: 190, meso: "new", letter: "b")
        let rows = try XCTUnwrap(compare(all)).lifts
        XCTAssertEqual(rows.map(\.letter), ["a", "b"])
        XCTAssertTrue(rows.allSatisfy { $0.peakChange > 0 })
        // a letter only one block has is not a comparison
        let c = try XCTUnwrap(compare(all + sets(120, "bench_press", load: 150, meso: "new", letter: "c")))
        XCTAssertEqual(c.lifts.map(\.letter), ["a", "b"])
    }

    func test_newDroppedAndReplacedLifts() throws {
        var all = sets(10, "bench_press", load: 200, meso: "old", label: "Push")
        all += sets(11, "barbell_row", load: 150, meso: "old", label: "Pull", coarse: .back, name: "Barbell Row")
        all += sets(12, "leg_extension", load: 100, meso: "old", label: "Legs", coarse: .quads)
        all += sets(110, "bench_press", load: 205, meso: "new", label: "Push")
        all += sets(111, "t_bar_row", load: 140, meso: "new", label: "Pull", coarse: .back, name: "T-Bar Row")
        all += sets(112, "lateral_raise_x", load: 20, meso: "new", label: "Delts", coarse: .shoulders, name: "Lateral Raise X")
        let c = try XCTUnwrap(compare(all))
        XCTAssertEqual(c.replaced, [LiftReplacement(old: LiftRef(id: "barbell_row", name: "Barbell Row"), new: LiftRef(id: "t_bar_row", name: "T-Bar Row"))])
        XCTAssertEqual(c.droppedLifts.map(\.id), ["leg_extension"], "no new lift in that muscle and day")
        XCTAssertEqual(c.newLifts.map(\.id), ["lateral_raise_x"])
        XCTAssertEqual(c.lifts.map(\.exerciseId), ["bench_press"])
    }

    func test_replacedAcrossDifferentlyNamedDays_pairsTheOnlyLiftsWithTheSamePrimaryMuscle() throws {
        var all = sets(10, "leg_extension", load: 100, meso: "old", label: "Lower A", coarse: .quads)
        all += sets(11, "bench_press", load: 200, meso: "old", label: "Upper A")
        all += sets(110, "hack_squat", load: 300, meso: "new", label: "Legs B", coarse: .quads)
        all += sets(111, "bench_press", load: 205, meso: "new", label: "Push A")
        let c = try XCTUnwrap(compare(all))
        XCTAssertEqual(c.replaced.map { "\($0.old.id)->\($0.new.id)" }, ["leg_extension->hack_squat"])
        XCTAssertTrue(c.newLifts.isEmpty && c.droppedLifts.isEmpty)
        // two candidates for one primary muscle: left unpaired
        let two = try XCTUnwrap(compare(all + sets(112, "leg_press", load: 400, meso: "new", label: "Legs B", coarse: .quads)))
        XCTAssertTrue(two.replaced.isEmpty, "two new quad lifts for one dropped: ambiguous, so unpaired")
    }

    func test_prsAndAdherence() throws {
        var all: [SetRecord] = []
        all += sets(10, "bench_press", load: 200, meso: "old", key: "p1") + sets(17, "bench_press", load: 210, meso: "old", key: "p2")   // baseline, then 1 PR
        all += sets(110, "bench_press", load: 205, meso: "new", key: "c1") + sets(117, "bench_press", load: 225, meso: "new", key: "c2")
        all += sets(124, "bench_press", load: 235, meso: "new", key: "c3")
        let sessions = [rec("p1", 10, meso: "old"), rec("p2", 17, meso: "old"), rec("p3", 24, meso: "old", status: .planned),
                        rec("c1", 110, meso: "new"), rec("c2", 117, meso: "new"), rec("c3", 124, meso: "new"), rec("c4", 131, meso: "new", status: .planned)]
        let c = try XCTUnwrap(compare(all, sessions: sessions, asOf: 200))
        XCTAssertEqual(c.prsPrevious, 1)
        XCTAssertEqual(c.prsCurrent, 2, "205 is below the earlier 210; 225 and 235 are PRs")
        XCTAssertEqual(c.adherencePrevious, AdherenceStat(completed: 2, planned: 3))
        XCTAssertEqual(c.adherenceCurrent, AdherenceStat(completed: 3, planned: 4))
        XCTAssertEqual(c.adherenceCurrent.fraction, 0.75, accuracy: 1e-9)
    }

    func test_muscleAverages_andBelowRangeNote() throws {
        // previous block: leg extensions 12 sets/week for 4 weeks; new block: 6 sets/week
        var all: [SetRecord] = []
        for w in 0..<4 { all += sets(7 + w * 7, "leg_extension", load: 100, reps: Array(repeating: 10, count: 12), meso: "old", label: "Legs", coarse: .quads) }
        for w in 0..<4 { all += sets(107 + w * 7, "leg_extension", load: 100, reps: Array(repeating: 10, count: 6), meso: "new", label: "Legs", coarse: .quads) }
        let c = try XCTUnwrap(compare(all, asOf: 300))
        let quads = try XCTUnwrap(c.muscles.first { $0.muscle == .quads })
        XCTAssertEqual(quads.previousAverage, 12, accuracy: 1e-9)
        XCTAssertEqual(quads.currentAverage, 6, accuracy: 1e-9)
        XCTAssertTrue(c.notes.musclesBelowRange.contains { $0.muscle == .quads }, "6 < the default minimum of 8")
        XCTAssertFalse(c.notes.musclesBelowRange.contains { $0.muscle == .frontDelts }, "a range minimum of 0 is never below")
        XCTAssertEqual(c.previousWeeksAveraged, 4)
    }

    func test_stalledLiftsAreCarriedIntoTheNotes() throws {
        let all = sets(10, "bench_press", load: 200, meso: "old") + sets(110, "bench_press", load: 205, meso: "new")
        XCTAssertEqual(try XCTUnwrap(compare(all, stalled: ["Bench Press A"])).notes.stalledLifts, ["Bench Press A"])
    }

    func test_earnedSetCandidates_repsUpAtTheSameLoadAndLetter() {
        var all: [SetRecord] = []
        all += sets(110, "cable_curl", load: 50, reps: [8, 8, 7], meso: "new")
        all += sets(117, "cable_curl", load: 50, reps: [9, 9, 8], meso: "new")
        all += sets(124, "cable_curl", load: 50, reps: [11, 10, 10], meso: "new")
        // flat lift, and a lift whose load moved (not comparable)
        all += sets(110, "flat", load: 80, reps: [8, 8, 8], meso: "new") + sets(124, "flat", load: 80, reps: [8, 8, 8], meso: "new")
        all += sets(110, "moved", load: 60, reps: [8, 8, 8], meso: "new") + sets(124, "moved", load: 80, reps: [12, 12, 12], meso: "new")
        let cands = MesoComparer.earnedSetCandidates(sets: all)
        XCTAssertEqual(cands.map(\.exerciseId), ["cable_curl"])
        XCTAssertEqual(cands.first?.firstReps ?? 0, 23.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(cands.first?.lastReps ?? 0, 31.0 / 3, accuracy: 1e-9)
    }

    func test_earnedSets_excludeALiftWhoseSetCountWentUp() {
        var all: [SetRecord] = []
        all += sets(110, "cable_curl", load: 50, reps: [8, 8, 7], meso: "new")
        all += sets(117, "cable_curl", load: 50, reps: [9, 9, 8], meso: "new")
        all += sets(124, "cable_curl", load: 50, reps: [11, 10, 10, 10], meso: "new")      // a 4th set was added
        XCTAssertTrue(MesoComparer.earnedSetCandidates(sets: all).isEmpty, "the extra set was already added deliberately")
        // same-count lifts are still found
        let same = sets(110, "cable_curl", load: 50, reps: [8, 8, 7], meso: "new") + sets(124, "cable_curl", load: 50, reps: [11, 10, 10], meso: "new")
        XCTAssertEqual(MesoComparer.earnedSetCandidates(sets: same).count, 1)
    }

    func test_earnedSets_excludeALiftWhosePrescribedSetCountRoseOnAnyLetter_evenInRemainingSessions() {
        func session(_ key: String, _ d: Int, _ status: SessionStatus, _ lifts: [PrescribedLift]) -> SessionRecord {
            SessionRecord(key: key, date: day(d), plannedDate: day(d), plannedDateIsExact: true, completedAt: nil, status: status,
                          weekIndex: 1, dayLabel: "Push", mesoKey: "new", mesoName: "new", isMaintenance: false, isInsertedDeload: false,
                          isDeloadWeek: false, readiness: .normal, readinessStars: 0, hkDuration: 0, prescribedLifts: lifts)
        }
        // letter-a logged series with the SAME logged set count, but the prescription adds a set on letter c later in the block
        var all = sets(110, "decline", load: 285, reps: [8, 8, 8], meso: "new", letter: "a") + sets(124, "decline", load: 285, reps: [10, 10, 10], meso: "new", letter: "a")
        all += sets(111, "curl", load: 50, reps: [8, 8, 8], meso: "new", letter: "a") + sets(125, "curl", load: 50, reps: [10, 10, 10], meso: "new", letter: "a")
        let raised = [
            session("s1", 110, .completed, [PrescribedLift(exerciseId: "decline", letter: "a", sets: 3), PrescribedLift(exerciseId: "curl", letter: "a", sets: 3)]),
            session("s2", 117, .completed, [PrescribedLift(exerciseId: "decline", letter: "c", sets: 3)]),
            session("s3", 131, .planned, [PrescribedLift(exerciseId: "decline", letter: "c", sets: 4), PrescribedLift(exerciseId: "curl", letter: "a", sets: 3)])]
        let found = MesoComparer.earnedSetCandidates(sets: all, sessions: raised).map(\.exerciseId)
        XCTAssertEqual(found, ["curl"], "decline's prescribed sets rose 3 -> 4 (letter c, still planned): excluded on every letter")
        XCTAssertEqual(Set(MesoComparer.earnedSetCandidates(sets: all).map(\.exerciseId)), ["decline", "curl"], "no prescription data: the logged counts are all there is")
        // a one-off higher count in a COMPLETED session that is back to the baseline for the remaining ones is not a change
        let blip = [session("s1", 110, .completed, [PrescribedLift(exerciseId: "decline", letter: "a", sets: 3)]),
                    session("s2", 117, .completed, [PrescribedLift(exerciseId: "decline", letter: "a", sets: 4)]),
                    session("s3", 131, .planned, [PrescribedLift(exerciseId: "decline", letter: "a", sets: 3)])]
        XCTAssertEqual(MesoComparer.earnedSetCandidates(sets: all, sessions: blip).count, 2)
        // a deload's lower count and a first-session baseline are not an increase
        let flat = [session("s1", 110, .completed, [PrescribedLift(exerciseId: "decline", letter: "a", sets: 3)]),
                    session("s2", 124, .completed, [PrescribedLift(exerciseId: "decline", letter: "a", sets: 3)])]
        XCTAssertEqual(MesoComparer.earnedSetCandidates(sets: all, sessions: flat).count, 2)
    }

    func test_earnedSets_atTheMaxLoad_needTwoConsecutiveRepGains() {
        func series(_ reps: [[Int]]) -> [SetRecord] { reps.enumerated().flatMap { i, r in sets(110 + i * 7, "leg_press", load: 300, reps: r, meso: "new", coarse: .quads) } }
        let cap: (String) -> Double? = { _ in 300 }
        // 8 -> 10 in one step at the cap: one jump is not evidence
        XCTAssertTrue(MesoComparer.earnedSetCandidates(sets: series([[8, 8, 8], [8, 8, 8], [10, 10, 10]]), maxLoad: cap).isEmpty)
        XCTAssertTrue(MesoComparer.earnedSetCandidates(sets: series([[8, 8, 8], [10, 10, 10]]), maxLoad: cap).isEmpty, "only two exposures")
        // 8 -> 9 -> 10: two consecutive gains
        XCTAssertEqual(MesoComparer.earnedSetCandidates(sets: series([[8, 8, 8], [9, 9, 9], [10, 10, 10]]), maxLoad: cap).count, 1)
        // 9 -> 8 -> 10: not consecutive gains
        XCTAssertTrue(MesoComparer.earnedSetCandidates(sets: series([[9, 9, 9], [8, 8, 8], [10, 10, 10]]), maxLoad: cap).isEmpty)
        // below the cap the plain rule applies
        XCTAssertEqual(MesoComparer.earnedSetCandidates(sets: series([[8, 8, 8], [10, 10, 10]]), maxLoad: { _ in 400 }).count, 1)
    }

    // MARK: - What's next: remaining weeks

    func test_remaining_beforeTheFinalWeek_noVerdict_startsTheDayAfterTheLastPlannedSession() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_000_000)           // some day D
        func at(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: now))! }
        let sessions: [(date: Date, status: SessionStatus)] = [(at(-3), .completed), (at(2), .planned), (at(20), .planned), (at(-1), .planned)]
        let r = MesoRemaining.compute(sessions: sessions, now: now, calendar: cal)
        XCTAssertEqual(r.remainingSessions, 2, "a past planned session and completed ones do not count")
        XCTAssertEqual(r.lastPlannedDate, at(20))
        XCTAssertEqual(r.weeksRemaining, 3, "20 days -> 3 weeks")
        XCTAssertFalse(r.isFinalWeekOrOver)
        XCTAssertEqual(r.defaultStart, at(21), "the day after the last planned session")
    }

    func test_remaining_inTheFinalWeekOrAfter_verdictAndTomorrow() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func at(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: now))! }
        let finalWeek = MesoRemaining.compute(sessions: [(at(-5), .completed), (at(3), .planned), (at(6), .planned)], now: now, calendar: cal)
        XCTAssertTrue(finalWeek.isFinalWeekOrOver, "the last planned session is 6 days away")
        XCTAssertEqual(finalWeek.defaultStart, at(1), "tomorrow")
        XCTAssertEqual(finalWeek.weeksRemaining, 1)
        let sevenAway = MesoRemaining.compute(sessions: [(at(7), .planned)], now: now, calendar: cal)
        XCTAssertFalse(sevenAway.isFinalWeekOrOver, "7 days away is not yet the final week")
        let over = MesoRemaining.compute(sessions: [(at(-9), .completed), (at(-2), .planned)], now: now, calendar: cal)
        XCTAssertTrue(over.isFinalWeekOrOver)
        XCTAssertEqual(over.remainingSessions, 0)
        XCTAssertEqual(over.defaultStart, at(1))
    }

    // MARK: - Meso analysis: bodyweight lifts

    private func bwItem(reps: [Int], wave: String = "a") -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: "pull_up", exerciseNameSnapshot: "Pull-Up", targetReps: 8, targetSets: reps.count, targetRIR: 2,
                            suggestedLoad: 0, waveRaw: wave, plannedRepsBySet: reps, plannedLoadsBySet: Array(repeating: 0, count: reps.count), plannedRIRsBySet: Array(repeating: 2, count: reps.count))
        i.actualReps = reps; i.actualLoads = Array(repeating: 0, count: reps.count); i.actualRIRs = Array(repeating: 2, count: reps.count); i.isCompleted = true
        return i
    }

    private func analyze(bodyWeight: Double?) throws -> ExercisePerformanceSummary {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(id: UUID(), name: "M", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        for (i, reps) in [[6, 6, 5], [7, 7, 6], [8, 8, 7]].enumerated() {
            let s = Session(date: day(i * 7), status: .completed, weekIndex: i + 1, dayLabel: "Pull", items: [bwItem(reps: reps)])
            s.meso = meso; meso.sessions.append(s); ctx.insert(s)
        }
        return try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: [], bodyWeight: bodyWeight)?.exerciseSummaries.first)
    }

    func test_mesoAnalysis_bodyweightLift_isRatedAtBodyWeight_likeEveryOtherScreen() throws {
        let s = try analyze(bodyWeight: 200)
        XCTAssertFalse(s.repsBased)
        XCTAssertEqual(s.e1rmBySession.count, 3)
        XCTAssertEqual(s.peakE1RM ?? 0, E1RMCalculator.e1RM(load: 200, reps: 8), accuracy: 1e-9, "the same Epley on the body weight")
        XCTAssertEqual(s.openingLoad, 200)
        XCTAssertEqual(s.verdict, .progressing)
        XCTAssertGreaterThan(s.totalSets, 0)
        XCTAssertGreaterThan(s.totalVolume, 0)
    }

    func test_mesoAnalysis_bodyweightLiftWithoutBodyWeight_showsARepsTrend_notNothing() throws {
        let s = try analyze(bodyWeight: nil)
        XCTAssertTrue(s.repsBased)
        XCTAssertEqual(s.verdict, .progressing, "reps/set went 5.7 -> 7.7")
        XCTAssertEqual(s.openingReps ?? 0, 17.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(s.closingReps ?? 0, 23.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(s.totalSets, 9, "the sets still count")
        XCTAssertNil(s.peakE1RM)
        XCTAssertFalse(s.isPR)
    }

    // MARK: - Meso Summary rework: the 12-rep e1RM rule, the header, mid-block, empty muscle data

    func test_e1RM_onlyFromSetsOf12RepsOrFewer_elseHeaviestLoad() {
        // a 20-rep set has the higher raw Epley (150 x 20 = 250) but is not eligible; the 5 x 200 set (233) is the best set
        let best = BestSetRule.best(of: [(load: 150, reps: 20), (load: 200, reps: 5)])
        XCTAssertEqual(best?.load, 200)
        XCTAssertEqual(best?.reps, 5)
        XCTAssertNotNil(best?.e1RM)
        XCTAssertEqual(BestSetRule.e1RM(load: 150, reps: 20), 0)
        XCTAssertEqual(BestSetRule.e1RM(load: 150, reps: 12), E1RMCalculator.e1RM(load: 150, reps: 12))
        XCTAssertTrue(BestSetRule.isE1RMEligible(reps: 12))
        XCTAssertFalse(BestSetRule.isE1RMEligible(reps: 13))
        // no set of 12 or fewer: the fallback is the heaviest load (more reps on a tie), with no e1RM
        let fb = BestSetRule.best(of: [(load: 60, reps: 20), (load: 80, reps: 15), (load: 80, reps: 18)])
        XCTAssertEqual(fb?.load, 80)
        XCTAssertEqual(fb?.reps, 18)
        XCTAssertNil(fb?.e1RM)
        XCTAssertTrue(fb?.isFallback ?? false)
        XCTAssertNil(BestSetRule.best(of: []))
        XCTAssertEqual(BestSetRule.bestLoad(atLeast: 15, in: [(load: 60, reps: 20), (load: 80, reps: 15), (load: 100, reps: 8)]), 80)
    }

    private func item(_ id: String, reps: [Int], loads: [Double]) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, exerciseNameSnapshot: id, targetReps: 10, targetSets: reps.count, targetRIR: 2, suggestedLoad: 0,
                            waveRaw: "a", plannedRepsBySet: reps, plannedLoadsBySet: loads, plannedRIRsBySet: Array(repeating: 2, count: reps.count))
        i.actualReps = reps; i.actualLoads = loads; i.actualRIRs = Array(repeating: 2, count: reps.count); i.isCompleted = true
        return i
    }

    func test_mesoAnalysis_trendUsesTheSameLiftOnly_and12RepsOrFewer() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(id: UUID(), name: "M", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        // leg_extension: only high-rep sets (15-20): load-at-matched-reps trend; bench_press: 8 reps then 20-rep back-offs
        let plan: [(Int, SessionItem, SessionItem)] = [
            (0, item("leg_extension", reps: [20, 18, 15], loads: [100, 100, 100]), item("bench_press", reps: [8, 20], loads: [200, 100])),
            (7, item("leg_extension", reps: [20, 18, 15], loads: [110, 110, 110]), item("bench_press", reps: [8, 20], loads: [210, 150])),
        ]
        for (d, a, b) in plan {
            let s = Session(date: day(d), status: .completed, weekIndex: 1 + d / 7, dayLabel: "D", items: [a, b])
            s.meso = meso; meso.sessions.append(s); ctx.insert(s)
        }
        let a = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
        let leg = try XCTUnwrap(a.exerciseSummaries.first { $0.exerciseId == "leg_extension" })
        XCTAssertNil(leg.peakE1RM, "no set of 12 reps or fewer: no e1RM")
        XCTAssertEqual(leg.trendBasis, .loadAtReps(20), "the closing session's heaviest set was 110 x 20")
        XCTAssertEqual(leg.trendChange ?? 0, 0.10, accuracy: 1e-9, "100 -> 110 at 20+ reps")
        XCTAssertEqual(leg.bestSet?.load, 110)
        XCTAssertTrue(leg.bestSet?.isFallback ?? false)
        let bench = try XCTUnwrap(a.exerciseSummaries.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual(bench.trendBasis, .e1RM)
        XCTAssertEqual(bench.peakE1RM ?? 0, E1RMCalculator.e1RM(load: 210, reps: 8), accuracy: 1e-9, "the 20-rep set never counts")
        XCTAssertEqual(bench.bestSet?.load, 210)
        XCTAssertEqual(bench.bestSet?.reps, 8)
        XCTAssertEqual(bench.trendChange ?? 0, E1RMCalculator.e1RM(load: 210, reps: 8) / E1RMCalculator.e1RM(load: 200, reps: 8) - 1, accuracy: 1e-9)
        // no ranking across lifts: the rows are ordered by muscle then name, never by e1RM
        let names = a.exerciseSummaries.map { ($0.primaryMuscle ?? "", $0.exerciseName) }
        XCTAssertEqual(names.map { "\($0.0)|\($0.1)" }, names.map { "\($0.0)|\($0.1)" }.sorted())
    }

    func test_mesoSummary_midBlock_headerAndAnalysisWithPlannedSessionsRemaining() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func at(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: now))! }
        let sessions: [(date: Date, plannedDate: Date?, status: SessionStatus, weekIndex: Int)] = [
            (at(-9), at(-9), .completed, 1), (at(-2), at(-2), .completed, 2), (at(-1), at(-1), .planned, 2),
            (at(3), at(3), .planned, 3), (at(10), at(10), .planned, 4)]
        let h = MesoHeader.compute(name: "12-Week DUP", totalWeeks: 4, sessions: sessions, now: now, calendar: cal)
        XCTAssertEqual(h.weekText, "Week 3 of 4", "the next unfinished session is in week 3")
        XCTAssertEqual(h.sessionsText, "2/3 sessions", "2 done of the 3 due to date (the skipped one counts as due)")
        XCTAssertEqual(h.name, "12-Week DUP")
        // a finished block reads its last week
        let done = MesoHeader.compute(name: "X", totalWeeks: 4, sessions: [(at(-30), at(-30), .completed, 4)], now: now, calendar: cal)
        XCTAssertEqual(done.weekText, "Week 4 of 4")
        // and the analysis of an ACTIVE block with sessions still planned works from what is completed
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(id: UUID(), name: "M", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        for (d, st) in [(0, SessionStatus.completed), (7, .completed), (14, .planned), (21, .planned)] {
            let s = Session(date: day(d), status: st, weekIndex: 1 + d / 7, dayLabel: "D", items: [item("bench_press", reps: [8, 8], loads: [200, 200])])
            s.meso = meso; meso.sessions.append(s); ctx.insert(s)
        }
        let a = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
        XCTAssertEqual(a.completedSessions, 2, "planned sessions are not counted")
        XCTAssertEqual(a.exerciseSummaries.count, 1)
    }

    func test_byExerciseSetsAndVolume_countWorkingSetsOnly_noWarmups() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(id: UUID(), name: "M", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        // a 40 lb warm-up (under half of the 200 lb top weight) then two working sets
        let it = item("bench_press", reps: [10, 5, 5], loads: [40, 200, 200])
        let s = Session(date: day(0), status: .completed, weekIndex: 1, dayLabel: "D", items: [it])
        s.meso = meso; meso.sessions.append(s); ctx.insert(s)
        let e = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: [])?.exerciseSummaries.first)
        XCTAssertEqual(e.totalSets, 2, "the warm-up is not a working set")
        XCTAssertEqual(e.totalReps, 10)
        XCTAssertEqual(e.totalVolume, 2000, accuracy: 1e-9)
        XCTAssertTrue(MesoSummaryView.trendCaption.contains("working sets"))
    }

    func test_mesoHeaderTotals_countWorkingSetsOnly_andEqualTheSumOfTheRows() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(id: UUID(), name: "M", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        for d in [0, 7] {
            let s = Session(date: day(d), status: .completed, weekIndex: 1 + d / 7, dayLabel: "D", items: [
                item("bench_press", reps: [10, 5, 5], loads: [40, 200, 200]),            // a warm-up, then 2 working sets
                item("barbell_row", reps: [8, 8], loads: [150, 150])])
            s.meso = meso; meso.sessions.append(s); ctx.insert(s)
        }
        let a = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
        XCTAssertEqual(a.totalSets, 8, "(2 + 2) per session x 2 sessions; the 40 lb warm-ups are out")
        XCTAssertEqual(a.totalReps, 2 * (10 + 16))
        XCTAssertEqual(a.totalVolume, 2 * (2000 + 2400), accuracy: 1e-9)
        XCTAssertEqual(a.totalSets, a.exerciseSummaries.reduce(0) { $0 + $1.totalSets }, "header = sum of the rows")
        XCTAssertEqual(a.totalVolume, a.exerciseSummaries.reduce(0) { $0 + $1.totalVolume }, accuracy: 1e-9)
        XCTAssertEqual(a.weeklyVolume.map(\.completedSets), [4, 4])
    }

    func test_verdictChip_isTheFirstToLastE1RMChange_withPlusMinus3PercentBands() throws {
        func verdict(first: Double, last: Double) throws -> (ExerciseVerdict, Double?) {
            let ctx = ModelContext(try BackupTestSupport.makeContainer())
            let meso = MesoBlock(id: UUID(), name: "M", startDate: day(0), status: .active, totalWeeks: 4)
            ctx.insert(meso)
            // the MIDDLE session is far higher than both ends: the verdict must ignore it (first -> last, not best or recent)
            for (i, load) in [first, first * 1.5, last].enumerated() {
                let s = Session(date: day(i * 7), status: .completed, weekIndex: i + 1, dayLabel: "D", items: [item("bench_press", reps: [5, 5], loads: [load, load])])
                s.meso = meso; meso.sessions.append(s); ctx.insert(s)
            }
            let e = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: [])?.exerciseSummaries.first)
            return (e.verdict, e.trendChange)
        }
        let up = try verdict(first: 200, last: 206.2)
        XCTAssertEqual(up.0, .progressing, "+3.1% on e1RM")
        XCTAssertEqual(up.1 ?? 0, 0.031, accuracy: 1e-9)
        XCTAssertEqual(try verdict(first: 200, last: 205).0, .plateaued, "+2.5%")
        XCTAssertEqual(try verdict(first: 200, last: 194).0, .declining, "-3%")
        XCTAssertEqual(try verdict(first: 200, last: 195).0, .plateaued, "-2.5%")
        // the one caption under the header says exactly this
        XCTAssertTrue(MesoSummaryView.trendCaption.contains("first → last"))
        XCTAssertTrue(MesoSummaryView.trendCaption.contains("±3%"))
    }

    func test_mesoMuscleSection_emptyState_noCompleteWeek_andUnmappedSets() {
        // one PARTIAL week (the asOf is mid-week) of a custom exercise: no complete week, so no weekly average
        let cs = sets(4, "custom_x", load: 100, reps: [8, 8, 8], meso: "m1", coarse: .back)
        let sum = MuscleVolume.summary(snapshot: AnalyticsSnapshot(sessions: [rec("a", 4, meso: "m1")], sets: cs),
                                       customs: [], profile: nil, asOf: day(5), mesoKey: "m1", wholeBlock: true)
        XCTAssertEqual(sum.averagedWeeks, 0)
        XCTAssertTrue(sum.isEmpty, "no complete week")
        XCTAssertEqual(sum.rows.allSatisfy { $0.average == 0 }, true)
        XCTAssertEqual(sum.unmapped.map(\.sets), [3], "the unmapped sets are still reported, with a way to map them")
        // and with no training at all
        let none = MuscleVolume.summary(snapshot: AnalyticsSnapshot(sessions: [], sets: []), customs: [], profile: nil, asOf: day(5), mesoKey: "m1", wholeBlock: true)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(none.unmapped.isEmpty)
    }

    func test_mesoMuscleSection_wholeBlockAveragesEveryCompleteWeek() {
        var all: [SetRecord] = []
        for w in 0..<6 { all += sets(7 + w * 7, "leg_extension", load: 100, reps: Array(repeating: 10, count: 8), meso: "m1", coarse: .quads) }
        let sum = MuscleVolume.summary(snapshot: AnalyticsSnapshot(sessions: [], sets: all), customs: [], profile: nil, asOf: day(90), mesoKey: "m1", wholeBlock: true)
        XCTAssertEqual(sum.averagedWeeks, 6, "all six complete weeks, not the last four")
        XCTAssertEqual(sum.rows.first { $0.muscle == .quads }?.average, 8)
        XCTAssertEqual(sum.rows.first { $0.muscle == .quads }?.status, .within)
    }

    func test_groupedNumbers() {
        XCTAssertEqual(LoadFormatter.grouped(905432), "905,432")
        XCTAssertEqual(LoadFormatter.grouped(1028), "1,028")
        XCTAssertEqual(LoadFormatter.grouped(7), "7")
        XCTAssertEqual(LoadFormatter(unit: .lb).volumeIntGrouped(10572.9), "10,572")
        XCTAssertEqual(LoadFormatter(unit: .lb).wholeGrouped(1027.6), "1,028")
    }

    // MARK: - PRs under the 12-rep rule

    func test_prs_countOnlySetsOf12RepsOrFewer_acrossRecordsEventsSuspectsAndTheService() throws {
        // a 20-rep set (150 x 20: raw Epley 250) beats the 5 x 200 set (233) on raw e1RM, but is not a record
        let all = sets(10, "curl", load: 200, reps: [5], meso: "old") + sets(17, "curl", load: 150, reps: [20, 20], meso: "old")
        let best = PersonalRecords.bests(from: all)["curl"]
        XCTAssertEqual(best?.reps, 5)
        XCTAssertEqual(best?.load, 200)
        XCTAssertEqual(best?.e1RM ?? 0, E1RMCalculator.e1RM(load: 200, reps: 5), accuracy: 1e-9)
        let events = PersonalRecords.events(from: all)
        XCTAssertEqual(events.map(\.isBaseline), [true], "the 20-rep session is no record event")
        // a lift with only long sets has no record at all
        let long = sets(10, "fly", load: 30, reps: [20, 18], meso: "old")
        XCTAssertNil(PersonalRecords.bests(from: long)["fly"])
        XCTAssertTrue(PersonalRecords.events(from: long).isEmpty)
        // 12 reps is still a record set, 13 is not
        XCTAssertNotNil(PersonalRecords.bests(from: sets(10, "x", load: 100, reps: [12], meso: "old"))["x"])
        XCTAssertNil(PersonalRecords.bests(from: sets(10, "x", load: 100, reps: [13], meso: "old"))["x"])
        // suspects use the same e1RM: a long set cannot make a record look 1.25x its neighbours
        let sus = sets(10, "y", load: 100, reps: [8], meso: "old") + sets(17, "y", load: 100, reps: [8], meso: "old") + sets(24, "y", load: 100, reps: [25], meso: "old")
        XCTAssertTrue(PersonalRecords.suspects(from: sus).isEmpty)
    }

    func test_prService_bestSet_usesTheSameRule() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let it = item("cable_curl", reps: [5, 20, 20], loads: [200, 150, 150])
        ctx.insert(it)
        let best = try XCTUnwrap(PRService.bestSet(in: it))
        XCTAssertEqual(best.reps, 5)
        XCTAssertEqual(best.load, 200)
        let longOnly = item("cable_fly", reps: [20, 18], loads: [30, 30])
        XCTAssertNil(PRService.bestSet(in: longOnly), "only sets of more than 12 reps: no PR")
    }

    func test_csvExport_flagsPRsFromTheEvents_notFromTheStoredFlag_evenForASessionCompletedAfterTheBackfill() throws {
        let key = "prIndexTwelveRepRule.v1.completed"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let a = item("bench_press", reps: [5], loads: [200]); a.exerciseNameSnapshot = "Bench Press"
        let b = item("bench_press", reps: [5], loads: [210])
        ctx.insert(Session(date: day(1), status: .completed, weekIndex: 1, dayLabel: "A", items: [a]))
        ctx.insert(Session(date: day(8), status: .completed, weekIndex: 1, dayLabel: "B", items: [b]))
        try ctx.save()
        PRIndexRuleBackfill.runIfNeeded(in: ctx)
        // complete a NEW session after the backfill: nothing recomputes isPR for it
        let c = item("bench_press", reps: [5], loads: [220])
        let sc = Session(date: day(15), status: .completed, weekIndex: 1, dayLabel: "C", items: [c])
        ctx.insert(sc)
        let stale = item("bench_press", reps: [5], loads: [190]); stale.isPR = true          // a stale stored flag on a non-record
        ctx.insert(Session(date: day(22), status: .completed, weekIndex: 1, dayLabel: "D", items: [stale]))
        try ctx.save()
        XCTAssertFalse(c.isPR, "the stored flag was never written for the new session")
        let result = try SetsV1CSVExporter.exportCompletedSessionsCSV(modelContext: ctx, fileName: "pr_events_test.csv")
        defer { try? FileManager.default.removeItem(at: result.url) }
        let rows = try String(contentsOf: result.url, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = rows[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let iPR = try XCTUnwrap(header.firstIndex(of: "is_pr")), iDate = try XCTUnwrap(header.firstIndex(of: "session_date"))
        var flagsByDay: [String: String] = [:]
        for r in rows.dropFirst() {
            let f = r.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            flagsByDay[f[iDate]] = f[iPR]
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        XCTAssertEqual(flagsByDay[iso.string(from: day(1))], "false", "first-ever: baseline")
        XCTAssertEqual(flagsByDay[iso.string(from: day(8))], "true", "210 beats 200")
        XCTAssertEqual(flagsByDay[iso.string(from: day(15))], "true", "the session completed after the backfill is flagged from the events")
        XCTAssertEqual(flagsByDay[iso.string(from: day(22))], "false", "190 is no record: the stale stored flag is not read")
    }

    func test_prIndexRuleBackfill_rebuildsOnceUnderTheRule_andDoesNothingOnAnEmptyStore() throws {
        let key = "prIndexTwelveRepRule.v1.completed"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        PRIndexRuleBackfill.runIfNeeded(in: ctx)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key), "no sessions: not marked done")
        // a stale index row holding an inflated 20-rep "best"
        ctx.insert(PRIndex(exerciseId: "cable_curl", exerciseName: "Cable Curl", bestSetVolume: 3000, bestLoad: 150, bestReps: 20, bestDate: day(0)))
        let it = item("cable_curl", reps: [5, 20], loads: [200, 150])
        let sess = Session(date: day(1), status: .completed, weekIndex: 1, dayLabel: "D", items: [it])
        ctx.insert(sess)
        try ctx.save()
        PRIndexRuleBackfill.runIfNeeded(in: ctx)
        let rows = try ctx.fetch(FetchDescriptor<PRIndex>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.bestReps, 5)
        XCTAssertEqual(rows.first?.bestLoad, 200)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        XCTAssertFalse(it.isPR, "the lift\'s first-ever session: a baseline, flag recomputed")
    }

    func test_itemStats_bestE1RM_usesTheTwelveRepRule_whileSetRecordE1RMStaysRaw() throws {
        let it = item("cable_curl", reps: [5, 20, 20], loads: [200, 150, 150])
        let st = AnalyticsEngine.ItemStats.of(it, bodyWeight: nil)
        XCTAssertEqual(st.bestE1RM, E1RMCalculator.e1RM(load: 200, reps: 5), accuracy: 1e-9, "the 20-rep set (raw 250) is not the best")
        XCTAssertEqual(st.bestReps, 5)
        XCTAssertEqual(st.sets, 3, "set counts are untouched")
        let longOnly = AnalyticsEngine.ItemStats.of(item("cable_fly", reps: [20, 18], loads: [30, 30]), bodyWeight: nil)
        XCTAssertEqual(longOnly.bestE1RM, 0, "no set of 12 reps or fewer: no e1RM")
        XCTAssertEqual(longOnly.sets, 2)
        // the documented exception: SetRecord.e1RM stays raw (any reps) for self-comparison
        let rec = sets(10, "fly", load: 30, reps: [20], meso: "m")[0]
        XCTAssertEqual(rec.e1RM, E1RMCalculator.e1RM(load: 30, reps: 20), accuracy: 1e-9)
        XCTAssertEqual(rec.recordE1RM, 0)
    }

    func test_report_screenValuesThatChangeUnderTheItemStatsRule() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty,
              let out = ProcessInfo.processInfo.environment["EP_E1RM_REPORT"], !out.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE and TEST_RUNNER_EP_E1RM_REPORT")
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let all = try ctx.fetch(FetchDescriptor<Session>()).filter { $0.status == .completed }
        let bw = try ctx.fetch(FetchDescriptor<UserProfile>()).first?.bodyWeight
        var entries = 0, changed = 0, lost = 0, shownAsLoad = 0
        var perLift: [String: (changed: Int, lost: Int, entries: Int, oldMax: Double, newMax: Double, shownAsLoad: Int)] = [:]
        var recapChanged = 0
        for s in all {
            for it in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: it.exerciseId)
                let isBW = ExerciseCatalog.isBodyweight(exerciseId: it.exerciseId)
                var old = 0.0
                for r in WorkingSetFilter.workingRows(of: it, isBodyweight: isBW) {
                    let load = r.load > 0 ? r.load : (isBW ? (bw ?? 0) : 0)
                    old = max(old, E1RMCalculator.e1RM(load: load, reps: r.reps))
                }
                let new = AnalyticsEngine.ItemStats.of(it, bodyWeight: bw).bestE1RM
                guard old > 0 else { continue }
                entries += 1
                var e = perLift[id] ?? (0, 0, 0, 0, 0, 0)
                e.entries += 1; e.oldMax = max(e.oldMax, old); e.newMax = max(e.newMax, new)
                if new == 0 {
                    lost += 1; e.lost += 1
                    // the history sheet now shows this entry's top-set LOAD instead (BestSetRule fallback)
                    if BestSetRule.best(of: it, bodyWeight: bw)?.load ?? 0 > 0 { shownAsLoad += 1; e.shownAsLoad += 1 }
                } else if abs(new - old) > 1e-6 { changed += 1; e.changed += 1 }
                if abs(new - old) > 1e-6 { recapChanged += 1 }
                perLift[id] = e
            }
        }
        var lines = ["session x lift entries with an e1RM: \(entries); value changes: \(changed); e1RM disappears (long sets only): \(lost); of those, shown as a top-set load: \(shownAsLoad)",
                     "(exercise history sheet: per-entry e1RM, chart and the top e1RM; live recap: top e1RM; the Analytics tab shows no e1RM)"]
        let nm: (String) -> String = { ExerciseCatalog.displayName(for: $0) }
        for (id, e) in perLift.sorted(by: { nm($0.key) < nm($1.key) }) where e.changed + e.lost > 0 {
            lines.append("\(nm(id)): \(e.changed + e.lost) of \(e.entries) entries change (\(e.lost) lose their e1RM); best on the sheet \(Int(e.oldMax)) -> \(e.newMax > 0 ? String(Int(e.newMax)) : "none")")
        }
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    // MARK: - PR definition report (old vs new; report only)

    func test_report_badgeChanges_newVersusPR() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty,
              let out = ProcessInfo.processInfo.environment["EP_BADGE_REPORT"], !out.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE and TEST_RUNNER_EP_BADGE_REPORT")
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>()).sorted { $0.startDate < $1.startDate }
        let bw = try ctx.fetch(FetchDescriptor<UserProfile>()).first?.bodyWeight
        var lines: [String] = []
        for block in blocks where !block.isMaintenance {
            let ids = Set(block.sessions.map { $0.persistentModelID })
            let first = block.sessions.map(\.date).min() ?? block.startDate
            let prior = all.filter { !ids.contains($0.persistentModelID) && $0.date < first }
            guard let a = MesoPerformanceAnalyzer.analyze(meso: block, allPriorSessions: prior, bodyWeight: bw) else { continue }
            // OLD rule: New = no earlier 12-rep peak; PR = beat an earlier 12-rep peak
            var oldPeak: [String: Double] = [:]
            for s in prior where s.meso?.isMaintenance != true { for it in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: it.exerciseId)
                for i in 0..<min(it.actualLoads.count, it.actualReps.count) where it.actualReps[i] > 0 {
                    let load = it.actualLoads[i] > 0 ? it.actualLoads[i] : (ExerciseCatalog.isBodyweight(exerciseId: it.exerciseId) ? (bw ?? 0) : 0)
                    guard load > 0 else { continue }
                    oldPeak[id] = max(oldPeak[id] ?? 0, BestSetRule.e1RM(load: load, reps: it.actualReps[i]))
                } } }
            for e in a.exerciseSummaries {
                guard let peak = e.peakE1RM else { continue }
                let p = oldPeak[e.exerciseId] ?? 0
                let oldBadge = p <= 0 ? "New" : (peak > p ? "PR" : "-")
                let newBadge = e.isNew ? "New" : (e.isPR ? "PR" : "-")
                if oldBadge != newBadge { lines.append("\(block.name): \(e.exerciseName): \(oldBadge) -> \(newBadge)") }
            }
        }
        if let cur = blocks.last(where: { !$0.isMaintenance }) {
            let ids = Set(cur.sessions.map { $0.persistentModelID })
            let first = cur.sessions.map(\.date).min() ?? cur.startDate
            let prior = all.filter { !ids.contains($0.persistentModelID) && $0.date < first }
            if let a = MesoPerformanceAnalyzer.analyze(meso: cur, allPriorSessions: prior, bodyWeight: bw) {
                lines.append("stats tile: \(cur.name): lifts with a PR chip \(a.exerciseSummaries.filter(\.isPR).count) | record-setting sessions \(a.recordSessions)")
            }
        }
        if lines.isEmpty { lines = ["no badge changes"] }
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    func test_report_isPRFlagsBeforeAndAfterTheRecompute() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty,
              let out = ProcessInfo.processInfo.environment["EP_ISPR_REPORT"], !out.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE and TEST_RUNNER_EP_ISPR_REPORT")
        }
        // BEFORE: the flags exactly as the backup carries them (completed sessions only)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        var bItems = 0, bSessions = 0
        for s in (json["sessions"] as? [[String: Any]]) ?? [] where (s["statusRaw"] as? String) == "completed" {
            let n = ((s["items"] as? [[String: Any]]) ?? []).filter { ($0["isPR"] as? Bool) == true }.count
            bItems += n; if n > 0 { bSessions += 1 }
        }
        // AFTER: the import rebuilds the index and recomputes the flags
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        UserDefaults.standard.removeObject(forKey: "prIndexTwelveRepRule.v1.completed")
        defer { UserDefaults.standard.removeObject(forKey: "prIndexTwelveRepRule.v1.completed") }
        let after = ModelContext(container)
        PRIndexRuleBackfill.runIfNeeded(in: after)
        let all = try after.fetch(FetchDescriptor<Session>()).filter { $0.status == .completed }
        let aItems = all.flatMap(\.items).filter(\.isPR).count
        let aSessions = all.filter { $0.items.contains { $0.isPR } }.count
        try "flagged items: \(bItems) -> \(aItems); sessions with a flagged item: \(bSessions) -> \(aSessions); completed sessions \(all.count)".write(toFile: out, atomically: true, encoding: .utf8)
    }

    func test_report_prsUnderTheTwelveRepRule() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty,
              let out = ProcessInfo.processInfo.environment["EP_PR_REPORT"], !out.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE and TEST_RUNNER_EP_PR_REPORT")
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>())
        let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
        let snap = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        var lines: [String] = []
        // OLD: any rep count
        var old: [String: (e1: Double, load: Double, reps: Int)] = [:]
        for s in snap.sets where s.isRecordSet && s.e1RM > 0 { if (old[s.exerciseId]?.e1 ?? 0) < s.e1RM { old[s.exerciseId] = (s.e1RM, s.effectiveLoad, s.reps) } }
        // NEW: the engine (the rule applies there once the definition is switched; before that it equals OLD)
        let new = PersonalRecords.bests(from: snap.sets)
        var changed = 0, lost = 0
        let name: (String) -> String = { id in snap.sets.first { $0.exerciseId == id }?.exerciseName ?? id }
        for id in old.keys.sorted(by: { name($0) < name($1) }) {
            let o = old[id]!, n = new[id]
            let same = n != nil && abs(n!.e1RM - o.e1) < 1e-6
            if same { continue }
            if n == nil { lost += 1 } else { changed += 1 }
            lines.append("\(name(id)): was \(Int(o.load)) x \(o.reps) (e1RM \(Int(o.e1)))  now " + (n.map { "\(Int($0.load)) x \($0.reps) (e1RM \(Int($0.e1RM)))" } ?? "no record (no set of 12 reps or fewer)"))
        }
        let oldEvents = Dictionary(grouping: PersonalRecords.events(from: snap.sets).filter { !$0.isBaseline }, by: \.exerciseId).mapValues(\.count)
        lines.insert("lifts with a record: \(old.count); record changed: \(changed); record lost: \(lost); lifts with PR events now: \(oldEvents.count) (total \(oldEvents.values.reduce(0, +)))", at: 0)
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    // MARK: - New vs PR

    private func mesoAnalysisWith(prior: [[(Int, [Int], [Double])]], current: [(Int, [Int], [Double])], maintenancePrior: Bool = false) throws -> MesoAnalysis {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let old = MesoBlock(id: UUID(), name: "Old", startDate: day(-100), status: .archived, totalWeeks: 4, isMaintenance: maintenancePrior)
        let cur = MesoBlock(id: UUID(), name: "Cur", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(old); ctx.insert(cur)
        var priorSessions: [Session] = []
        for block in prior { for (d, reps, loads) in block {
            let s = Session(date: day(d), status: .completed, weekIndex: 1, dayLabel: "D", items: [item("curl", reps: reps, loads: loads)])
            s.meso = old; old.sessions.append(s); ctx.insert(s); priorSessions.append(s)
        } }
        for (d, reps, loads) in current {
            let s = Session(date: day(d), status: .completed, weekIndex: 1 + d / 7, dayLabel: "D", items: [item("curl", reps: reps, loads: loads)])
            s.meso = cur; cur.sessions.append(s); ctx.insert(s)
        }
        return try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: cur, allPriorSessions: priorSessions))
    }

    func test_badge_aLiftTrainedBeforeWithOnlyLongSets_showsPR_notNew_whenItsFirst12RepRecordFallsInThisMeso() throws {
        let a = try mesoAnalysisWith(prior: [[(-50, [20, 20], [100, 100])]], current: [(0, [10, 10], [120, 120])])
        let e = try XCTUnwrap(a.exerciseSummaries.first)
        XCTAssertFalse(e.isNew, "it has a completed working set (20 reps) before this meso")
        XCTAssertTrue(e.isPR, "its first set of 12 reps or fewer is a record")
    }

    func test_badge_aLiftNeverTrainedBefore_isNew_notPR() throws {
        let a = try mesoAnalysisWith(prior: [], current: [(0, [10, 10], [120, 120]), (7, [10], [125])])
        let e = try XCTUnwrap(a.exerciseSummaries.first)
        XCTAssertTrue(e.isNew)
        XCTAssertFalse(e.isPR)
        // a lift whose only sets this meso are long: no e1RM, no badge at all
        let long = try mesoAnalysisWith(prior: [], current: [(0, [20, 20], [100, 100])])
        XCTAssertFalse(try XCTUnwrap(long.exerciseSummaries.first).isNew)
    }

    func test_badge_beatingAnEarlier12RepPeak_isPR_andNotBeatingItIsNeither() throws {
        let beat = try XCTUnwrap(try mesoAnalysisWith(prior: [[(-50, [5], [200])]], current: [(0, [5], [215])]).exerciseSummaries.first)
        XCTAssertTrue(beat.isPR); XCTAssertFalse(beat.isNew)
        let held = try XCTUnwrap(try mesoAnalysisWith(prior: [[(-50, [5], [200])]], current: [(0, [5], [190])]).exerciseSummaries.first)
        XCTAssertFalse(held.isPR); XCTAssertFalse(held.isNew)
        // training in a maintenance block counts as "trained before" too
        let m = try XCTUnwrap(try mesoAnalysisWith(prior: [[(-50, [20], [100])]], current: [(0, [8], [150])], maintenancePrior: true).exerciseSummaries.first)
        XCTAssertFalse(m.isNew)
    }

    func test_statsTile_countsRecordSettingSessions_notLiftsWithAPRChip() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let old = MesoBlock(id: UUID(), name: "Old", startDate: day(-100), status: .archived, totalWeeks: 4)
        let cur = MesoBlock(id: UUID(), name: "Cur", startDate: day(0), status: .active, totalWeeks: 4)
        ctx.insert(old); ctx.insert(cur)
        func sess(_ d: Int, _ meso: MesoBlock, _ lifts: [(String, Double)]) -> Session {
            let s = Session(date: day(d), status: .completed, weekIndex: 1 + max(d, 0) / 7, dayLabel: "D",
                            items: lifts.map { item($0.0, reps: [5], loads: [$0.1]) })
            s.meso = meso; meso.sessions.append(s); ctx.insert(s); return s
        }
        let prior = sess(-50, old, [("bench_press", 200), ("squat_x", 300)])
        _ = sess(0, cur, [("bench_press", 205), ("squat_x", 305)])        // one session, two lifts beat the record
        _ = sess(7, cur, [("bench_press", 210), ("squat_x", 310)])        // a second session, the same two lifts again
        let a = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: cur, allPriorSessions: [prior]))
        XCTAssertEqual(a.exerciseSummaries.filter(\.isPR).count, 2, "two lifts carry a PR chip")
        XCTAssertEqual(a.recordSessions, 2, "two sessions set records (four lift-session events)")
    }

    func test_prEvents_aLiftFirstTrainedWithLongSets_hasNoBaselineWhenItsFirst12RepSetComes() {
        let all = sets(10, "curl", load: 100, reps: [20, 20], meso: "old", key: "a") + sets(17, "curl", load: 120, reps: [10], meso: "new", key: "b")
        let events = PersonalRecords.events(from: all)
        XCTAssertEqual(events.map(\.isBaseline), [false], "an earlier (long-set) exposure exists: the first record is a record")
        // the same lift with a 12-rep first session: baseline as before
        let plain = sets(10, "curl", load: 100, reps: [10], meso: "old", key: "a") + sets(17, "curl", load: 120, reps: [10], meso: "new", key: "b")
        XCTAssertEqual(PersonalRecords.events(from: plain).map(\.isBaseline), [true, false])
    }

    func test_noPreviousBlock_noComparison() {
        let all = sets(110, "bench_press", load: 205, meso: "new")
        XCTAssertNil(compare(all, infos: [info("new", start: 100)]))
        XCTAssertNil(compare(all, infos: [info("old", start: 0), info("new", start: 100)]), "the previous block has no training")
    }

    func test_previousMesoId_survivesABackupRoundTrip() throws {
        let container = try BackupTestSupport.makeContainer()
        let ctx = ModelContext(container)
        let a = MesoBlock(id: UUID(), name: "A", startDate: day(0), status: .archived, totalWeeks: 8)
        let b = MesoBlock(id: UUID(), name: "B", startDate: day(60), status: .active, totalWeeks: 8)
        b.previousMesoId = a.id
        ctx.insert(a); ctx.insert(b)
        try ctx.save()
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let other = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: result.url, modelContainer: other)
        let blocks = try ModelContext(other).fetch(FetchDescriptor<MesoBlock>())
        XCTAssertEqual(blocks.first { $0.name == "B" }?.previousMesoId, a.id)
        XCTAssertNil(blocks.first { $0.name == "A" }?.previousMesoId)
    }

    // MARK: - Backtest (report only)

    func test_backtest_currentBlockVsThePreviousOnTheRealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        var lines: [String] = []
        func log(_ x: String = "") { lines.append(x); print("MESO| \(x)") }
        defer {
            if let out = ProcessInfo.processInfo.environment["EP_MESO_REPORT"], !out.isEmpty {
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>())
        let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>())
        let engine = AnalyticsEngine(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let asOf = (engine.snapshot.sessions.filter { $0.status == .completed }.map(\.date).max() ?? Date()).addingTimeInterval(86_400)
        log("blocks: " + blocks.sorted { $0.startDate < $1.startDate }.map { "\($0.name) (\($0.startDate.formatted(date: .abbreviated, time: .omitted))\($0.isMaintenance ? ", maintenance" : ""), previousMesoId \($0.previousMesoId == nil ? "nil" : "set"))" }.joined(separator: " | "))
        guard let c = engine.mesoComparison(blocks: blocks, customs: customs, profile: profile, asOf: asOf) else {
            log("no comparison available"); return XCTFail("no comparison")
        }
        let unit = profile?.loadUnit ?? .lb
        let fmt = LoadFormatter(unit: unit)
        func pad(_ x: String, _ n: Int) -> String { x.padding(toLength: n, withPad: " ", startingAt: 0) }
        log("current: \(c.current.name) vs previous: \(c.previous.name)")
        log("adherence: previous \(c.adherencePrevious.completed)/\(c.adherencePrevious.planned), current \(c.adherenceCurrent.completed)/\(c.adherenceCurrent.planned) (to date)")
        log("PRs set: previous \(c.prsPrevious), current \(c.prsCurrent)")
        log("")
        log(pad("lift", 36) + pad("L", 3) + pad("prev peak", 11) + pad("cur peak", 11) + pad("peak %", 9) + pad("prev top3", 11) + pad("cur top3", 11) + pad("top3 %", 9) + "first/prev peak")
        for l in c.lifts {
            var row: String = pad(l.name, 36) + pad(l.letter.uppercased(), 3)
            row += pad(fmt.whole(l.previousPeak), 11) + pad(fmt.whole(l.currentPeak), 11) + pad(String(format: "%+.1f%%", l.peakChange * 100), 9)
            row += pad(fmt.whole(l.previousTop3), 11) + pad(fmt.whole(l.currentTop3), 11) + pad(String(format: "%+.1f%%", l.top3Change * 100), 9)
            row += String(format: "%.0f%%", l.previousPeak > 0 ? l.currentFirst / l.previousPeak * 100 : 0)
            log(row)
        }
        log("")
        log("replaced: " + c.replaced.map { "\($0.old.name) -> \($0.new.name)" }.joined(separator: "; "))
        log("new: " + c.newLifts.map(\.name).joined(separator: "; "))
        log("dropped: " + c.droppedLifts.map(\.name).joined(separator: "; "))
        log("")
        log("weekly sets per muscle (last full weeks: previous \(c.previousWeeksAveraged), current \(c.currentWeeksAveraged); unmapped customs count in no muscle)")
        for m in c.muscles {
            log(pad(m.muscle.displayName, 12) + String(format: "%5.1f -> %5.1f   range %d-%d", m.previousAverage, m.currentAverage, Int(m.range.min), Int(m.range.max)))
        }
        log("")
        log("next block notes")
        log("  below range: " + c.notes.musclesBelowRange.map { "\($0.muscle.displayName) \(String(format: "%.1f", $0.average)) < \(Int($0.minimum))" }.joined(separator: "; "))
        log("  stalled: " + c.notes.stalledLifts.joined(separator: "; "))
        log("  earned-set candidates: " + c.notes.earnedSetCandidates.map { "\($0.name)\($0.letter.isEmpty ? "" : " " + $0.letter.uppercased()) @\(fmt.compact($0.load)) \(String(format: "%.1f", $0.firstReps)) -> \(String(format: "%.1f", $0.lastReps)) reps" }.joined(separator: "; "))
        // Earned-set diagnostics: the max-load lookup and the exposures behind each candidate.
        log("")
        log("max loads on the profile: \(profile?.maxLoadByExercise ?? [:])")
        let curSets = engine.snapshot.sets.filter { $0.isPerformanceSet && $0.mesoKey == c.current.key }
        let exps = Exposures.build(from: curSets)
        for cand in c.notes.earnedSetCandidates {
            log("candidate \(cand.name) \(cand.letter) id=\(cand.exerciseId): maxLoad(for:) = \(String(describing: profile?.maxLoad(for: cand.exerciseId))), effective = \(String(describing: UserProfile.effectiveMaxLoad(for: cand.exerciseId, profile: profile, customExercises: customs)))")
            for e in exps.filter({ $0.chain.exerciseId == cand.exerciseId && $0.chain.letter == cand.letter && !$0.chain.isTop }).sorted(by: { $0.date < $1.date }) {
                log("     \(e.date.formatted(date: .abbreviated, time: .omitted)) sets \(e.sets.map { "\(fmt.compact($0.load))x\($0.reps)" }.joined(separator: ","))")
            }
        }
        for sess in all.filter({ $0.meso?.name == c.current.name }).sorted(by: { $0.date < $1.date }) {
            for it in sess.items where ExerciseCatalog.canonicalExerciseId(for: it.exerciseId) == "decline_bench_press" {
                log("  RAW \(sess.date.formatted(date: .abbreviated, time: .omitted)) \(sess.status.rawValue) wave \(it.waveRaw ?? "-") targetSets \(it.targetSets) setMin \(String(describing: it.setMin)) setMax \(String(describing: it.setMax)) plannedReps \(it.plannedRepsBySet) plannedLoads \(it.plannedLoadsBySet) actualReps \(it.actualReps)")
            }
        }
        for id in ["decline_bench_press", "leg_extension"] {
            log("prescription of \(id) in the current block:")
            for r in engine.snapshot.sessions.filter({ $0.mesoKey == c.current.key }).sorted(by: { ($0.plannedDate ?? $0.date) < ($1.plannedDate ?? $1.date) }) {
                for l in r.prescribedLifts where l.exerciseId == id {
                    log("     \((r.plannedDate ?? r.date).formatted(date: .abbreviated, time: .omitted)) \(r.status.rawValue) letter \(l.letter) prescribed sets \(l.sets)")
                }
            }
        }
        XCTAssertFalse(c.lifts.isEmpty)
        // PRs and first-time baselines per block, as the summary header counts them.
        log("")
        for info in [c.previous, c.current] {
            guard let block = blocks.first(where: { ($0.id?.uuidString ?? "\($0.persistentModelID)") == info.key }) else { continue }
            let ids = Set(block.sessions.map { $0.persistentModelID })
            let first = block.sessions.map(\.date).min() ?? block.startDate
            let prior = all.filter { !ids.contains($0.persistentModelID) && $0.date < first }
            guard let a = AnalyticsEngine.mesoAnalysis(meso: block, allPriorSessions: prior) else { continue }
            let prs = a.exerciseSummaries.filter(\.isPR), news = a.exerciseSummaries.filter(\.isNew)
            log("\(info.name): summary PRs \(prs.count) (\(prs.map(\.exerciseName).sorted().joined(separator: ", ")))")
            log("\(info.name): New (first-ever baseline) \(news.count) (\(news.map(\.exerciseName).sorted().joined(separator: ", ")))")
            XCTAssertTrue(a.exerciseSummaries.allSatisfy { !($0.isPR && $0.isNew) })
        }
        log("PR events (record-breaking sessions, baselines excluded): previous \(c.prsPrevious), current \(c.prsCurrent)")
        // Decline Bench had a set added from Nov 8 (the prescription), so it is not an earned-set candidate on any letter.
        if c.notes.earnedSetCandidates.contains(where: { $0.exerciseId == "decline_bench_press" }) { XCTFail("Decline Bench: its prescribed set count rose") }
    }
}
