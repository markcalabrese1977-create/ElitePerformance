import XCTest
import SwiftData
@testable import ElitePerformance

/// FatigueMonitor (P2b policy): per-lift persistent regression and its exclusions, breadth against the lifter's own
/// norm, missed sessions (exact dates only), feedback share, self report, the level rules, and the guarantee that it
/// never writes. Records are built directly so every case states exactly what it feeds.
final class FatigueMonitorTests: XCTestCase {

    private let incr = 5.0
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400) }
    private let policy = FatiguePolicy.default
    /// The policy with performance allowed to drive `deloadSuggested` (off by default).
    private var armed: FatiguePolicy { var p = FatiguePolicy.default; p.performanceDrivesDeload = true; return p }
    private var counter = 0

    // MARK: - Builders

    /// One exposure: a session with `reps` at `load` for one lift.
    private func exposure(_ n: Int, lift: String = "bench_press", name: String = "Bench Press", letter: String? = "a",
                           meso: String = "m1", load: Double = 290, reps: [Int] = [8, 8, 8], planned: Int? = 8,
                           loads: [Double]? = nil, feedback: [SetFeedback]? = nil, skipped: [Bool]? = nil,
                           working: [Bool]? = nil, bodyweight: Bool = false, deload: Bool = false, maint: Bool = false,
                           inserted: Bool = false, status: SessionStatus = .completed, readiness: SessionReadiness = .normal,
                           override: LoadOverrideReason? = nil, plannedLoad: Double? = nil, repMin: Int? = 6, repMax: Int? = 12,
                           rirMin: Int? = 1, rirMax: Int? = 2, targetRIR: Int = 2, rirs: [Int]? = nil, planEdited: Bool = false) -> [SetRecord] {
        counter += 1
        let key = "s\(n)-\(lift)-\(counter)"
        return reps.enumerated().map { i, r in
            SetRecord(
                sessionKey: key, sessionDate: day(n), status: status, weekIndex: 1 + n / 7, dayLabel: "Push", mesoKey: meso,
                exerciseId: lift, exerciseName: name, muscle: nil, isBodyweight: bodyweight,
                waveLetter: letter, isDeloadWaveItem: false, isInsertedDeload: inserted, isDeloadWeek: deload, isMaintenance: maint,
                rowIndex: i, isTop: false, plannedReps: planned, plannedLoad: plannedLoad ?? (loads?[i] ?? load), repMin: repMin, repMax: repMax,
                targetRIRMin: rirMin, targetRIRMax: rirMax, targetRIR: targetRIR, reps: r, load: loads?[i] ?? load, rir: rirs?[i] ?? 2,
                isSkipped: skipped?[i] ?? false, isRestPause: false, isDrop: false,
                feedback: feedback?[i] ?? .none, pump: 0, loadOverride: override, planEdited: planEdited,
                readiness: readiness, readinessStars: 0, hkDuration: 0,
                isWorkingSet: working?[i] ?? true, isHardSetRow: !(skipped?[i] ?? false) && r > 0
            )
        }
    }

    /// A lift trained on `days`, `reps` per exposure at `loads` per exposure (3 sets each).
    private func lift(_ id: String, days: [Int], loads: [Double], reps: [[Int]]? = nil, meso: String = "m1") -> [SetRecord] {
        days.enumerated().flatMap { i, d in
            exposure(d, lift: id, name: id, meso: meso, load: loads[i], reps: reps?[i] ?? [8, 8, 8])
        }
    }

    private func snap(_ sets: [SetRecord], sessions: [SessionRecord] = []) -> AnalyticsSnapshot { AnalyticsSnapshot(sessions: sessions, sets: sets) }

    private func sessionRecord(_ n: Int, planned: Int?, exact: Bool = true, status: SessionStatus = .planned, meso: String = "m1",
                               deload: Bool = false, maint: Bool = false) -> SessionRecord {
        SessionRecord(key: "p\(n)-\(counter)", date: day(n), plannedDate: planned.map(day), plannedDateIsExact: exact && planned != nil,
                      completedAt: status == .completed ? day(n) : nil, status: status, weekIndex: 1, dayLabel: "Legs", mesoKey: meso,
                      mesoName: nil, isMaintenance: maint, isInsertedDeload: false, isDeloadWeek: deload,
                      readiness: .normal, readinessStars: 0, hkDuration: 0)
    }

    private func judged(_ s: AnalyticsSnapshot, _ id: String = "bench_press", policy p: FatiguePolicy? = nil, maxLoad: @escaping (String) -> Double? = { _ in nil }) -> [FatigueMonitor.Judgement] {
        FatigueMonitor.judgements(in: s, policy: p ?? policy, loadIncrementLb: incr, asOf: day(500), maxLoad: maxLoad).filter { $0.exerciseId == id }
    }
    private func regressions(_ s: AnalyticsSnapshot, _ id: String = "bench_press", policy p: FatiguePolicy? = nil, maxLoad: @escaping (String) -> Double? = { _ in nil }) -> [FatigueMonitor.Judgement] {
        judged(s, id, policy: p, maxLoad: maxLoad).filter(\.regressing)
    }
    private func sigs(_ s: AnalyticsSnapshot, _ type: FatigueSignalType, policy p: FatiguePolicy? = nil, asOf: Int = 500) -> [FatigueSignal] {
        FatigueMonitor.signals(in: s, policy: p ?? policy, loadIncrementLb: incr, asOf: day(asOf)).filter { $0.type == type }
    }

    // MARK: - Calendar helpers

    /// A Monday far enough into the series for calm history before it.
    private var monday: Date { FatigueMonitor.weekStart(day(40)) }
    /// Day index (relative to `day(0)`) of weekday `dow` (0 = Monday) of week `w` counted from `monday`.
    private func at(_ w: Int, _ dow: Int) -> Int { Int((monday.timeIntervalSince(day(0)) / 86_400).rounded()) + 7 * w + dow }

    /// `n` lifts trained once a week in weeks -3...-1 exactly on plan (deviation 0): the lifter's calm history.
    private func calm(lifts n: Int) -> [SetRecord] {
        (0..<n).flatMap { i in (-3...(-1)).flatMap { w in exposure(at(w, i % 3), lift: "L\(i)", name: "L\(i)", load: 200, reps: [8, 8, 8]) } }
    }

    /// Week `w`: the `calm` lifts of `n` are trained on plan on Mon–Wed, then `short` of them (the last ones) fall `drop` reps
    /// short of plan together on Saturday.
    private func week(_ w: Int, lifts n: Int, short: Int, drop: Int = 2) -> [SetRecord] {
        (0..<n).flatMap { i -> [SetRecord] in
            let isShort = i >= n - short
            return exposure(at(w, isShort ? 5 : i % 3), lift: "L\(i)", name: "L\(i)", load: 200, reps: Array(repeating: 8 - (isShort ? drop : 0), count: 3))
        }
    }

    // MARK: - 1. Plan-relative shortfall

    func test_shortfall_isADeviationBelowTheLiftersOwnNorm() {
        let base = calm(lifts: 10)
        let two = judged(snap(base + exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [6, 6, 6])), "X")
        XCTAssertEqual(two.count, 1)
        XCTAssertTrue(two[0].regressing)
        XCTAssertEqual(two[0].deviation, -2)
        XCTAssertEqual(two[0].norm, 0)
        XCTAssertTrue(two[0].evidence.contains("-2.0 reps/set against plan"), two[0].evidence)
        let one = judged(snap(base + exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [7, 7, 7])), "X")
        XCTAssertFalse(one[0].regressing, "exactly one rep under the norm is not MORE than one rep")
    }

    func test_shortfall_theNormIsTheLiftersOwn_aLifterWhoBeatsPlanIsJudgedAgainstThat() {
        // This lifter habitually does 9 against a plan of 8 (norm +1): 8 is on plan but is a shortfall against their own norm… of exactly 1 under.
        var base: [SetRecord] = []
        for i in 0..<10 { for w in -3...(-1) { base += exposure(at(w, i % 3), lift: "L\(i)", name: "L\(i)", load: 200, reps: [9, 9, 9]) } }
        XCTAssertFalse(judged(snap(base + exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [8, 8, 8])), "X")[0].regressing)
        let j = judged(snap(base + exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [7, 7, 7])), "X")
        XCTAssertTrue(j[0].regressing)
        XCTAssertEqual(j[0].norm, 1)
    }

    func test_shortfall_needsEnoughHistoryAndOnlyLooksSixWeeksBack() {
        XCTAssertTrue(judged(snap(calm(lifts: 2) + exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [4, 4, 4])), "X").isEmpty, "6 prior exposures: under the minimum of 8")
        // Exposures older than six weeks are not the norm: a calm month, then a long break, then nothing to compare with.
        var old: [SetRecord] = []
        for i in 0..<10 { old += exposure(at(-12, i % 3), lift: "L\(i)", name: "L\(i)", load: 200, reps: [8, 8, 8]) }
        XCTAssertTrue(judged(snap(old + exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [4, 4, 4])), "X").isEmpty)
    }

    func test_shortfall_onlySetsAtThePlannedLoadAreJudged() {
        let base = calm(lifts: 10)
        // Lifted 20 lb under the plan: not comparable to the plan's reps, so not judged.
        let under = exposure(at(0, 0), lift: "X", name: "X", load: 180, reps: [4, 4, 4], plannedLoad: 200)
        XCTAssertTrue(judged(snap(base + under), "X").isEmpty)
        // Within one step (5 lb) of the plan: judged.
        let near = exposure(at(0, 0), lift: "X", name: "X", load: 196, reps: [4, 4, 4], plannedLoad: 200)
        XCTAssertEqual(judged(snap(base + near), "X").count, 1)
        // A mixed exposure is judged on its matching sets only: 2 matching sets at −2, one off-plan set ignored.
        let mixed = exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [6, 6, 1], loads: [200, 200, 100], plannedLoad: 200)
        XCTAssertEqual(judged(snap(base + mixed), "X")[0].deviation, -2)
    }

    func test_shortfall_exclusions() {
        let base = calm(lifts: 10)
        let bad: [Int] = [4, 4, 4]
        func count(_ x: [SetRecord]) -> Int { judged(snap(base + x), "X").count }
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 0, reps: bad, bodyweight: true)), 0, "bodyweight")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 5, reps: bad)), 0, "near-zero load")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, deload: true)), 0, "deload")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, inserted: true)), 0, "inserted deload")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, maint: true)), 0, "maintenance")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, status: .inProgress)), 0, "not completed")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, override: .generalFatigue)), 0, "a deliberate cut is a self report")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, working: [false, false, false])), 0, "warm-ups")
        XCTAssertEqual(count(exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: bad, planned: nil)), 0, "no planned reps: nothing to compare with")
    }

    func test_shortfall_reachedTopOfRangeAtTargetIsNeverAShortfall() {
        // The plan said 12; the range tops out at 10 and the lifter hit 10 on every set at target RIR: not a shortfall.
        let base = calm(lifts: 10)
        let top = exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [10, 10, 10], planned: 12, repMax: 10)
        XCTAssertFalse(judged(snap(base + top), "X")[0].regressing)
        let notAtTarget = exposure(at(0, 0), lift: "X", name: "X", load: 200, reps: [10, 10, 10], planned: 12, repMax: 10, rirs: [2, 2, 0])
        XCTAssertTrue(judged(snap(base + notAtTarget), "X")[0].regressing, "one set below the target reserve")
        var off = FatiguePolicy.default; off.exemptReachedTop = false
        XCTAssertTrue(judged(snap(base + top), "X", policy: off)[0].regressing, "the guard is policy")
    }

    // MARK: - 2. Breadth (per calendar week)

    func test_breadth_needsCountAndShareOfTheLiftsTrainedThatWeek() {
        let b = sigs(snap(calm(lifts: 10) + week(0, lifts: 10, short: 4)), .breadth)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].date, day(at(0, 5)), "the day the third lift fell short with 30% of the week")
        XCTAssertTrue(b[0].evidence.contains("4 of 10 lifts trained this week (40%)"), b[0].evidence)
        XCTAssertEqual(sigs(snap(calm(lifts: 10) + week(0, lifts: 10, short: 2)), .breadth).count, 0, "two lifts: under the minimum")
        XCTAssertEqual(sigs(snap(calm(lifts: 12) + week(0, lifts: 12, short: 3)), .breadth).count, 0, "3 of 12 = 25%: under 30%")
        XCTAssertEqual(sigs(snap(calm(lifts: 10) + week(0, lifts: 10, short: 3)), .breadth).count, 1, "3 of 10 = 30%")
    }

    func test_breadth_isPerCalendarWeek_notARollingWindow() {
        // Two shortfalls in week 0 and two in week 1: neither week reaches 3 lifts, even though a rolling week would.
        var sets = calm(lifts: 10)
        for i in 0..<10 { sets += exposure(at(0, i % 3), lift: "L\(i)", name: "L\(i)", load: 200, reps: Array(repeating: i >= 8 ? 6 : 8, count: 3)) }
        for i in 0..<10 { sets += exposure(at(1, i % 3), lift: "L\(i)", name: "L\(i)", load: 200, reps: Array(repeating: (i == 0 || i == 1) ? 6 : 8, count: 3)) }
        XCTAssertEqual(sigs(snap(sets), .breadth).count, 0)
    }

    func test_breadth_needsANewShortfallOnTheDay() {
        // 4 of 10 fall short on Saturday; the calm lifts are trained again on Sunday: no new breadth signal.
        var sets = calm(lifts: 10) + week(0, lifts: 10, short: 4)
        for i in 0..<6 { sets += exposure(at(0, 6), lift: "L\(i)", name: "L\(i)", load: 200, reps: [8, 8, 8]) }
        XCTAssertEqual(sigs(snap(sets), .breadth).map(\.date), [day(at(0, 5))])
    }

    func test_shortfallEvidence_andRepDropEvidenceNeverSetALevelAlone() {
        let s = snap(calm(lifts: 10) + week(0, lifts: 10, short: 4))
        let a = FatigueMonitor.evaluate(snapshot: s, loadIncrementLb: incr, asOf: day(at(0, 6)))
        XCTAssertEqual(a.suggestion, .watch, "breadth alone is a watch")
        var p = armed; p.enabledTypes.remove(.breadth)
        XCTAssertEqual(FatigueMonitor.evaluate(snapshot: s, policy: p, loadIncrementLb: incr, asOf: day(at(0, 6))).suggestion, .none, "shortfalls alone are evidence, not a level")
    }

    // MARK: - 3. Same-load rep drop (evidence)

    private func repDrops(_ s: AnalyticsSnapshot, policy p: FatiguePolicy? = nil) -> [FatigueSignal] { sigs(s, .repDrop, policy: p) }

    func test_repDrop_sameLetterSameLoad_isEvidence() {
        let s = snap(lift("bench_press", days: [0, 7, 14], loads: [290, 290, 290], reps: [[8, 8, 8], [8, 8, 8], [7, 7, 7]]))
        let r = repDrops(s)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].date, day(14))
        XCTAssertTrue(r[0].evidence.contains("7.0 reps per set, down from 8.0"), r[0].evidence)
        XCTAssertEqual(repDrops(snap(lift("bench_press", days: [0, 7, 14], loads: [290, 285, 290], reps: [[8, 8, 8], [8, 8, 8], [7, 7, 7]]))).count, 1, "within one load step")
        XCTAssertEqual(repDrops(snap(lift("bench_press", days: [0, 7, 14], loads: [290, 280, 270], reps: [[8, 8, 8], [8, 8, 8], [7, 7, 7]]))).count, 0, "different load")
        XCTAssertEqual(repDrops(snap(lift("bench_press", days: [0, 7, 14], loads: [290, 290, 290], reps: [[8, 8, 8], [8, 8, 8], [8, 8, 7]]))).count, 0, "a third of a rep")
    }

    func test_repDrop_guards() {
        // The seed (first exposure of the lift in a block) is never compared.
        var seed: [SetRecord] = exposure(0, reps: [8, 8, 8]) + exposure(7, meso: "m2", reps: [5, 5, 5])
        XCTAssertEqual(repDrops(snap(seed)).count, 0)
        seed.removeAll()
        // Different letters are different chains.
        XCTAssertEqual(repDrops(snap(exposure(0, letter: "a", reps: [8, 8, 8]) + exposure(7, letter: "b", reps: [5, 5, 5]))).count, 0)
        // A layoff longer than six weeks starts the chain again.
        XCTAssertEqual(repDrops(snap(exposure(0, reps: [8, 8, 8]) + exposure(70, reps: [5, 5, 5]))).count, 0)
        // Changed prescription.
        XCTAssertEqual(repDrops(snap(exposure(0, reps: [8, 8, 8], repMin: 6, repMax: 10) + exposure(7, reps: [5, 5, 5], repMin: 8, repMax: 12))).count, 0)
        // Reached the top of the range at target RIR.
        XCTAssertEqual(repDrops(snap(exposure(0, reps: [12, 12, 12]) + exposure(7, reps: [10, 10, 10], repMax: 10))).count, 0)
        // Deload / maintenance / overrides / in progress.
        XCTAssertEqual(repDrops(snap(exposure(0, reps: [8, 8, 8]) + exposure(7, reps: [5, 5, 5], deload: true))).count, 0)
        XCTAssertEqual(repDrops(snap(exposure(0, reps: [8, 8, 8]) + exposure(7, reps: [5, 5, 5], override: .generalFatigue))).count, 0)
    }

    func test_repDrop_aPlannedLoadCut_resetsOnlyWhenDeliberate() {
        func chain(planEdited: Bool = false, previousUnderperformed: Bool) -> AnalyticsSnapshot {
            // exposures: 0 and 7 (7 may under-perform by a rep drop), then 14 planned lighter and with another drop.
            var s = exposure(0, load: 200, reps: [8, 8, 8], plannedLoad: 200)
            s += exposure(7, load: 200, reps: previousUnderperformed ? [7, 7, 7] : [8, 8, 8], plannedLoad: 200)
            s += exposure(14, load: 200, reps: [6, 6, 6], plannedLoad: 190, planEdited: planEdited)
            return snap(s)
        }
        XCTAssertEqual(repDrops(chain(previousUnderperformed: false)).filter { $0.date == day(14) }.count, 0, "a cut after a good exposure was the lifter's")
        XCTAssertEqual(repDrops(chain(planEdited: true, previousUnderperformed: true)).filter { $0.date == day(14) }.count, 0, "an edit is deliberate")
        XCTAssertEqual(repDrops(chain(previousUnderperformed: true)).filter { $0.date == day(14) }.count, 1, "the engine's own cut after a bad exposure is not forgiven")
    }

    // MARK: - 4. Missed sessions

    func test_missed_onlyDatesRecordedAtCreation() {
        let done = sessionRecord(20, planned: 20, status: .completed)
        let exact = [done, sessionRecord(5, planned: 5), sessionRecord(9, planned: 9)]
        let r = sigs(snap([], sessions: exact), .missedSessions)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].date, day(11), "planned day 9 + 2 grace days")
        let backfilled = [done, sessionRecord(5, planned: 5, exact: false), sessionRecord(9, planned: 9, exact: false)]
        XCTAssertEqual(sigs(snap([], sessions: backfilled), .missedSessions).count, 0, "a derived date is never a miss")
    }

    func test_missed_guards() {
        let done = sessionRecord(30, planned: 30, status: .completed)
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: 5)]), .missedSessions).count, 0, "one miss is life")
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(40, planned: 500), sessionRecord(41, planned: 501)]), .missedSessions, asOf: 100).count, 0, "rescheduled into the future")
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: 5), sessionRecord(9, planned: 9)]), .missedSessions, asOf: 10).count, 0, "inside the grace period")
        XCTAssertEqual(sigs(snap([], sessions: [sessionRecord(5, planned: 5, meso: "old"), sessionRecord(9, planned: 9, meso: "old")]), .missedSessions).count, 0, "abandoned block")
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: 5, deload: true), sessionRecord(9, planned: 9, maint: true)]), .missedSessions).count, 0)
        XCTAssertEqual(sigs(snap([], sessions: [sessionRecord(5, planned: 1, status: .completed), sessionRecord(9, planned: 2, status: .completed)]), .missedSessions).count, 0, "done late is done")
    }

    // MARK: - Feedback share

    private func feedbackSnap(flagged: Int, total: Int, flag: SetFeedback = .fatigue) -> AnalyticsSnapshot {
        let n = total / 4
        var perSession = Array(repeating: 0, count: n)
        var left = flagged
        for i in stride(from: n - 1, through: 0, by: -1) { let c = min(4, left); perSession[i] = c; left -= c }
        var sets: [SetRecord] = []
        for i in 0..<n {
            let fb: [SetFeedback] = (0..<4).map { $0 < perSession[i] ? flag : .none }
            sets += exposure(i * 2, lift: "l\(i)", reps: [8, 8, 8, 8], feedback: fb)
        }
        return snap(sets)
    }

    func test_feedbackShare_barSampleAndSoreness() {
        XCTAssertGreaterThan(sigs(feedbackSnap(flagged: 4, total: 24), .feedbackShare).count, 0, "4/24 = 16.7%")
        XCTAssertEqual(sigs(feedbackSnap(flagged: 3, total: 24), .feedbackShare).count, 0, "12.5%")
        XCTAssertEqual(sigs(feedbackSnap(flagged: 4, total: 16), .feedbackShare).count, 0, "under the minimum sample")
        XCTAssertEqual(sigs(feedbackSnap(flagged: 6, total: 24, flag: .soreness), .feedbackShare).count, 0, "soreness is informational")
        XCTAssertGreaterThan(sigs(feedbackSnap(flagged: 4, total: 24, flag: .pain), .feedbackShare).count, 0)
        var sets = feedbackSnap(flagged: 0, total: 20).sets
        sets += exposure(11, lift: "x", reps: [0, 0, 0, 0], feedback: [.pain, .fatigue, .pain, .fatigue], skipped: [true, true, true, true])
        XCTAssertGreaterThan(sigs(snap(sets), .feedbackShare).count, 0, "skipped-for-a-reason rows count")
        var deloaded: [SetRecord] = []
        for i in 0..<6 { deloaded += exposure(i * 2, lift: "d\(i)", reps: [8, 8, 8, 8], feedback: [.fatigue, .fatigue, .fatigue, .fatigue], deload: true) }
        XCTAssertEqual(sigs(snap(deloaded), .feedbackShare).count, 0)
    }

    // MARK: - Self report

    func test_selfReport_readinessAndOverrides() {
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], readiness: .fatigued)), .selfReport).count, 1)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8, 8], readiness: .compromised)), .selfReport).count, 1, "once per session")
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], readiness: .fresh)), .selfReport).count, 0)
        let gf = sigs(snap(exposure(0, reps: [8, 8], override: .generalFatigue)), .selfReport)
        XCTAssertEqual(gf.count, 1)
        XCTAssertEqual(gf[0].exerciseId, "bench_press")
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], override: .jointTenderness)), .selfReport).count, 1)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], override: .equipmentConstraint)), .selfReport).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], override: .deliberateDeload)), .selfReport).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], deload: true, readiness: .fatigued)), .selfReport).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], maint: true, readiness: .fatigued)), .selfReport).count, 0)
    }

    // MARK: - Levels

    private func signal(_ type: FatigueSignalType, _ n: Int) -> FatigueSignal {
        FatigueSignal(type: type, date: day(n), exerciseId: nil, exerciseName: nil, evidence: "")
    }
    private func level(_ s: [FatigueSignal], asOf: Int, policy p: FatiguePolicy? = nil, sessions: [SessionRecord] = []) -> FatigueSuggestion {
        FatigueMonitor.assess(signals: s, snapshot: snap([], sessions: sessions), policy: p ?? armed, asOf: day(asOf)).suggestion
    }

    func test_levels_watchIsAnyOneLevelSignalType_shortfallAndRepDropAreNot() {
        let now = at(1, 4)
        XCTAssertEqual(level([], asOf: now), .none)
        XCTAssertEqual(level([signal(.shortfall, now - 1)], asOf: now), .none)
        XCTAssertEqual(level([signal(.repDrop, now - 1)], asOf: now), .none)
        for t in [FatigueSignalType.breadth, .missedSessions, .feedbackShare, .selfReport] {
            XCTAssertEqual(level([signal(t, now - 2)], asOf: now), .watch, "\(t)")
        }
        XCTAssertEqual(level([signal(.selfReport, now - 25)], asOf: now), .none, "outside the 21 days")
        XCTAssertEqual(level([signal(.selfReport, now - 10)], asOf: now), .none, "a lone report lapses after 7 days")
        XCTAssertEqual(level([signal(.selfReport, now - 14), signal(.selfReport, now - 10)], asOf: now), .watch, "two in the window keep both")
        XCTAssertEqual(level([signal(.selfReport, now + 1)], asOf: now), .none, "after asOf")
    }

    func test_levels_deloadNeedsBreadthInTwoConsecutiveWeeks_orBreadthPlusCorroboration() {
        let now = at(1, 4)
        XCTAssertEqual(level([signal(.breadth, at(1, 2))], asOf: now), .watch, "breadth in one week")
        XCTAssertEqual(level([signal(.breadth, at(0, 5)), signal(.breadth, at(1, 2))], asOf: now), .deloadSuggested, "two consecutive calendar weeks")
        XCTAssertEqual(level([signal(.breadth, at(0, 1)), signal(.breadth, at(0, 5))], asOf: now), .watch, "twice in the same week")
        XCTAssertEqual(level([signal(.breadth, at(-1, 5)), signal(.breadth, at(1, 2))], asOf: now), .watch, "weeks that are not consecutive")
        XCTAssertEqual(level([signal(.breadth, at(1, 2)), signal(.selfReport, at(1, 3))], asOf: now), .deloadSuggested, "breadth + a fresh self report")
        XCTAssertEqual(level([signal(.breadth, at(1, 2)), signal(.selfReport, at(0, 1))], asOf: now), .watch, "breadth + a lapsed self report")
        XCTAssertEqual(level([signal(.breadth, at(1, 2)), signal(.missedSessions, at(0, 6))], asOf: now), .deloadSuggested, "breadth + missed sessions")
        XCTAssertEqual(level([signal(.breadth, at(1, 2)), signal(.feedbackShare, at(1, 3))], asOf: now), .watch, "feedback does not corroborate")
        XCTAssertEqual(level([signal(.selfReport, at(1, 3)), signal(.missedSessions, at(1, 2))], asOf: now), .watch, "never a deload on self report and misses alone")
    }

    func test_levels_performanceIsWatchOnlyByDefault() {
        let now = at(1, 4)
        let sigs = [signal(.breadth, at(0, 5)), signal(.breadth, at(1, 2)), signal(.selfReport, at(1, 3))]
        XCTAssertEqual(level(sigs, asOf: now, policy: .default), .watch, "the shipped default never suggests a deload from performance")
        XCTAssertEqual(level(sigs, asOf: now, policy: armed), .deloadSuggested)
        XCTAssertFalse(FatiguePolicy.default.performanceDrivesDeload)
    }

    func test_levels_aCompletedDeloadResetsTheClock_andPolicyIsData() {
        let now = at(1, 4)
        let deload = SessionRecord(key: "dl", date: day(at(0, 6)), plannedDate: nil, plannedDateIsExact: false, completedAt: day(at(0, 6)), status: .completed,
                                   weekIndex: 9, dayLabel: "Push", mesoKey: "m1", mesoName: nil, isMaintenance: false, isInsertedDeload: false,
                                   isDeloadWeek: true, readiness: .normal, readinessStars: 0, hkDuration: 0)
        let sigs = [signal(.breadth, at(0, 2)), signal(.breadth, at(0, 5)), signal(.selfReport, at(1, 3)), signal(.feedbackShare, at(1, 3))]
        XCTAssertEqual(level(sigs, asOf: now, sessions: [deload]), .watch, "only what came after the deload counts")
        var keep = armed; keep.resetAfterDeload = false
        XCTAssertEqual(level(sigs, asOf: now, policy: keep, sessions: [deload]), .deloadSuggested)
        var off = armed; off.enabledTypes.remove(.breadth)
        XCTAssertEqual(level([signal(.breadth, at(1, 2)), signal(.selfReport, at(1, 3))], asOf: now, policy: off), .watch)
        var three = armed; three.breadthWeeksForDeload = 3
        XCTAssertEqual(level([signal(.breadth, at(0, 5)), signal(.breadth, at(1, 2))], asOf: now, policy: three), .watch)
    }

    func test_evaluate_endToEnd_breadthInTwoConsecutiveWeeks() {
        let sets = calm(lifts: 10) + week(0, lifts: 10, short: 4) + week(1, lifts: 10, short: 4)
        let a = FatigueMonitor.evaluate(snapshot: snap(sets), policy: armed, loadIncrementLb: incr, asOf: day(at(1, 6)))
        XCTAssertEqual(a.suggestion, .deloadSuggested)
        XCTAssertEqual(FatigueMonitor.evaluate(snapshot: snap(sets), loadIncrementLb: incr, asOf: day(at(1, 6))).suggestion, .watch, "default: watch only")
        XCTAssertEqual(a.signals.filter { $0.type == .breadth }.count, 2)
        XCTAssertEqual(FatigueMonitor.evaluate(snapshot: snap(sets), policy: armed, loadIncrementLb: incr, asOf: day(at(0, 4))).suggestion, .none, "nothing is known on Friday of week 0")
        XCTAssertEqual(FatigueMonitor.evaluate(snapshot: snap(sets), policy: armed, loadIncrementLb: incr, asOf: day(at(0, 6))).suggestion, .watch, "after week 0 alone")
    }

    func test_evaluate_aSingleBadSessionIsAtMostAWatch() {
        // Everything on plan except one session in which seven lifts fall 3 reps short.
        var sets = calm(lifts: 10)
        for i in 0..<10 { sets += exposure(at(0, 2), lift: "L\(i)", name: "L\(i)", load: 200, reps: Array(repeating: i < 7 ? 5 : 8, count: 3)) }
        for w in 1...2 { sets += week(w, lifts: 10, short: 0) }
        for d in 0...14 {
            let a = FatigueMonitor.evaluate(snapshot: snap(sets), policy: armed, loadIncrementLb: incr, asOf: day(at(0, 2) + d))
            XCTAssertNotEqual(a.suggestion, .deloadSuggested, "day +\(d)")
        }
    }

    // MARK: - Never writes

    func test_monitor_leavesTheStoreUntouched() throws {
        let container = try BackupTestSupport.makeContainer()
        let ctx = ModelContext(container)
        let meso = MesoBlock(name: "M", startDate: day(0), status: .active, totalWeeks: 10)
        ctx.insert(meso)
        for (n, reps) in [(0, [8, 8, 8]), (7, [8, 8, 8]), (14, [6, 6, 6])] {
            let it = BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: reps, loads: [290, 290, 290])
            it.waveRaw = "a"
            it.plannedLoadsBySet = [290, 290, 290]
            let s = Session(date: day(n), status: .completed, weekIndex: 1 + n / 7, dayLabel: "Push", items: [it], completedAt: day(n))
            s.readiness = .fatigued
            s.meso = meso
            meso.sessions.append(s)
            ctx.insert(s)
        }
        try ctx.save()
        let before = try BackupTestSupport.exportJSON(ctx)
        let snapshot = SetRecordBuilder.build(sessions: try ctx.fetch(FetchDescriptor<Session>()))
        let a = FatigueMonitor.evaluate(snapshot: snapshot, loadIncrementLb: 5, asOf: day(15))
        XCTAssertEqual(a.suggestion, .watch, "a self report is in the window; one lift is not breadth")
        XCTAssertTrue(a.signals.contains { $0.type == .repDrop })
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(NSDictionary(dictionary: try BackupTestSupport.exportJSON(ctx)), NSDictionary(dictionary: before))
    }
}
