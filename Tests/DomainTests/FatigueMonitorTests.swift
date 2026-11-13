import XCTest
import SwiftData
@testable import ElitePerformance

/// FatigueMonitor: one test group per signal (positive, then the false-positive guards), the policy, and the
/// guarantee that it never writes. Records are built directly so every case states exactly what it feeds.
final class FatigueMonitorTests: XCTestCase {

    private let incr = 5.0
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400) }
    private let policy = FatiguePolicy.default

    // MARK: - Builders

    private var counter = 0

    /// One exposure: a session with `reps` at `load` for one lift.
    private func exposure(_ n: Int, lift: String = "bench_press", name: String = "Bench Press", letter: String? = "a",
                           meso: String = "m1", load: Double = 290, reps: [Int], planned: Int? = 8, loads: [Double]? = nil,
                           feedback: [SetFeedback]? = nil, skipped: [Bool]? = nil, working: [Bool]? = nil,
                           deload: Bool = false, maint: Bool = false, inserted: Bool = false, status: SessionStatus = .completed,
                           readiness: SessionReadiness = .normal, override: LoadOverrideReason? = nil,
                           session: String? = nil) -> [SetRecord] {
        counter += 1
        let key = session ?? "s\(n)-\(lift)-\(counter)"
        return reps.enumerated().map { i, r in
            SetRecord(
                sessionKey: key, sessionDate: day(n), status: status, weekIndex: 1 + n / 7, dayLabel: "Push", mesoKey: meso,
                exerciseId: lift, exerciseName: name, muscle: nil, isBodyweight: false,
                waveLetter: letter, isDeloadWaveItem: false, isInsertedDeload: inserted, isDeloadWeek: deload, isMaintenance: maint,
                rowIndex: i, isTop: false, plannedReps: planned, reps: r, load: loads?[i] ?? load, rir: 2,
                isSkipped: skipped?[i] ?? false, isRestPause: false, isDrop: false,
                feedback: feedback?[i] ?? .none, pump: 0, loadOverride: override,
                readiness: readiness, readinessStars: 0, hkDuration: 0,
                isWorkingSet: working?[i] ?? true, isHardSetRow: !(skipped?[i] ?? false) && r > 0
            )
        }
    }

    private func snap(_ sets: [SetRecord], sessions: [SessionRecord] = []) -> AnalyticsSnapshot {
        AnalyticsSnapshot(sessions: sessions, sets: sets)
    }

    private func sessionRecord(_ n: Int, planned: Int?, status: SessionStatus = .planned, meso: String = "m1",
                               deload: Bool = false, maint: Bool = false) -> SessionRecord {
        SessionRecord(key: "p\(n)-\(counter)", date: day(n), plannedDate: planned.map(day), completedAt: status == .completed ? day(n) : nil,
                      status: status, weekIndex: 1, dayLabel: "Legs", mesoKey: meso, mesoName: nil,
                      isMaintenance: maint, isInsertedDeload: false, isDeloadWeek: deload,
                      readiness: .normal, readinessStars: 0, hkDuration: 0)
    }

    private func sigs(_ s: AnalyticsSnapshot, _ type: FatigueSignalType, policy: FatiguePolicy? = nil, asOf: Int = 400) -> [FatigueSignal] {
        FatigueMonitor.signals(in: s, policy: policy ?? self.policy, loadIncrementLb: incr, asOf: day(asOf)).filter { $0.type == type }
    }

    // MARK: - 1. Rep drop at the same load

    func test_repDrop_firesWhenTheSameLetterLosesRepsAtTheSameLoad() {
        let s = snap(exposure(0, reps: [8, 8, 8]) + exposure(7, reps: [7, 6, 5]))
        let r = sigs(s, .repDrop)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].exerciseId, "bench_press")
        XCTAssertEqual(r[0].date, day(7))
        XCTAssertTrue(r[0].evidence.contains("Bench Press A"), r[0].evidence)
        XCTAssertTrue(r[0].evidence.contains("6.0") && r[0].evidence.contains("8.0"), r[0].evidence)
    }

    func test_repDrop_loadWithinOneIncrementIsTheSameLoad_moreIsNot() {
        XCTAssertEqual(sigs(snap(exposure(0, load: 290, reps: [8, 8]) + exposure(7, load: 285, reps: [6, 6])), .repDrop).count, 1)
        XCTAssertEqual(sigs(snap(exposure(0, load: 290, reps: [8, 8]) + exposure(7, load: 280, reps: [6, 6])), .repDrop).count, 0,
                       "10 lb apart at a 5 lb step: a different load, not a drop at the same one")
    }

    func test_repDrop_falsePositiveGuards() {
        // a drop smaller than the threshold
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8, 8]) + exposure(7, reps: [8, 8, 7])), .repDrop).count, 0)
        // another letter is another chain
        XCTAssertEqual(sigs(snap(exposure(0, letter: "a", reps: [8, 8]) + exposure(7, letter: "b", reps: [5, 5])), .repDrop).count, 0)
        // the first same-letter exposure after a meso change has no earlier exposure in its chain
        XCTAssertEqual(sigs(snap(exposure(0, meso: "m1", reps: [8, 8]) + exposure(7, meso: "m2", reps: [5, 5])), .repDrop).count, 0)
        // a replaced lift is a new chain
        XCTAssertEqual(sigs(snap(exposure(0, lift: "bench_press", reps: [8, 8]) + exposure(7, lift: "dumbbell_press", name: "DB Press", reps: [5, 5])), .repDrop).count, 0)
        // the prescription itself changed between the two exposures
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8], planned: 8) + exposure(7, reps: [5, 5], planned: 5)), .repDrop).count, 0)
        // deload, inserted deload and maintenance exposures are not compared
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8]) + exposure(7, reps: [5, 5], deload: true)), .repDrop).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8]) + exposure(7, reps: [5, 5], inserted: true)), .repDrop).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8], maint: true) + exposure(7, reps: [5, 5], maint: true)), .repDrop).count, 0)
        // a layoff longer than the gap limit
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8]) + exposure(60, reps: [5, 5])), .repDrop).count, 0)
        // a load cut on purpose that day
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8]) + exposure(7, reps: [5, 5], override: .generalFatigue)), .repDrop).count, 0)
        // an in-progress session
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8]) + exposure(7, reps: [5, 5], status: .inProgress)), .repDrop).count, 0)
    }

    func test_repDrop_warmupsAndNonWorkingRowsDoNotMoveTheMean() {
        // The warm-up row (45 x 15) and an RP row are not working sets, so they neither hide nor fake a drop.
        let prev = exposure(0, reps: [15, 8, 8, 8], loads: [45, 290, 290, 290], working: [false, true, true, true])
        let same = exposure(7, reps: [15, 8, 8, 8], loads: [45, 290, 290, 290], working: [false, true, true, true])
        XCTAssertEqual(sigs(snap(prev + same), .repDrop).count, 0, "a warm-up's reps are not compared")
        let drop = exposure(7, reps: [15, 6, 6, 6], loads: [45, 290, 290, 290], working: [false, true, true, true])
        XCTAssertEqual(sigs(snap(prev + drop), .repDrop).count, 1)
    }

    // MARK: - 2. e1RM decline across lifts

    /// Three prior exposures per lift at e1RM ~ stable, then a current one `drop` lower.
    private func declining(lifts: [String], drop: Double, at current: Int = 28) -> [SetRecord] {
        var out: [SetRecord] = []
        for l in lifts {
            for d in [0, 7, 14] { out += exposure(d, lift: l, name: l, load: 200, reps: [8]) }
            out += exposure(current, lift: l, name: l, load: 200 * (1 - drop), reps: [8])
        }
        return out
    }

    func test_e1rmDecline_needsEnoughLiftsAndEnoughDrop() {
        XCTAssertEqual(sigs(snap(declining(lifts: ["a", "b", "c"], drop: 0.06)), .e1rmDecline).count, 1)
        XCTAssertEqual(sigs(snap(declining(lifts: ["a", "b"], drop: 0.06)), .e1rmDecline).count, 0, "two lifts: below the lift count")
        XCTAssertEqual(sigs(snap(declining(lifts: ["a", "b", "c"], drop: 0.04)), .e1rmDecline).count, 0, "4% is under the 5% bar")
        var p = FatiguePolicy.default; p.e1rmDeclineLiftCount = 2
        XCTAssertEqual(sigs(snap(declining(lifts: ["a", "b"], drop: 0.06)), .e1rmDecline, policy: p).count, 1, "the count is policy")
    }

    func test_e1rmDecline_guards() {
        // Only one prior exposure: no baseline, no verdict.
        var oneBase: [SetRecord] = []
        for l in ["a", "b", "c"] { oneBase += exposure(0, lift: l, name: l, load: 200, reps: [8]) + exposure(7, lift: l, name: l, load: 180, reps: [8]) }
        XCTAssertEqual(sigs(snap(oneBase), .e1rmDecline).count, 0)
        // Declines more than a window apart do not add up.
        var spread: [SetRecord] = []
        for (i, l) in ["a", "b", "c"].enumerated() {
            for d in [0, 7, 14] { spread += exposure(d, lift: l, name: l, load: 200, reps: [8]) }
            spread += exposure(28 + i * 30, lift: l, name: l, load: 180, reps: [8])
        }
        XCTAssertEqual(sigs(snap(spread), .e1rmDecline).count, 0)
        // A deload exposure is not a decline.
        var deloaded: [SetRecord] = []
        for l in ["a", "b", "c"] {
            for d in [0, 7, 14] { deloaded += exposure(d, lift: l, name: l, load: 200, reps: [8]) }
            deloaded += exposure(28, lift: l, name: l, load: 120, reps: [8], deload: true)
        }
        XCTAssertEqual(sigs(snap(deloaded), .e1rmDecline).count, 0)
        // First exposure of a new meso never compares against the old one.
        var newMeso: [SetRecord] = []
        for l in ["a", "b", "c"] {
            for d in [0, 7, 14] { newMeso += exposure(d, lift: l, name: l, load: 200, reps: [8]) }
            newMeso += exposure(28, lift: l, name: l, meso: "m2", load: 150, reps: [8])
        }
        XCTAssertEqual(sigs(snap(newMeso), .e1rmDecline).count, 0)
    }

    // MARK: - 3. Missed sessions

    func test_missed_twoUndoneSessionsWhileTheBlockContinues() {
        let sessions = [
            sessionRecord(0, planned: 0, status: .completed),
            sessionRecord(5, planned: 5), sessionRecord(9, planned: 9),
            sessionRecord(20, planned: 20, status: .completed),
        ]
        let r = sigs(snap([], sessions: sessions), .missedSessions)
        XCTAssertEqual(r.count, 1, "the 2nd miss reaches the count of 2 within the window")
        XCTAssertEqual(r[0].date, day(11), "planned day 9 + 2 grace days")
    }

    func test_missed_guards() {
        let done = sessionRecord(30, planned: 30, status: .completed)
        // one miss is life
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: 5)]), .missedSessions).count, 0)
        // unknown planned day is never guessed
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: nil), sessionRecord(9, planned: nil)]), .missedSessions).count, 0)
        // a rescheduled session carries its new planned day: in the future, not missed
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(40, planned: 500), sessionRecord(41, planned: 501)]), .missedSessions, asOf: 100).count, 0)
        // inside the grace period
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: 5), sessionRecord(9, planned: 9)]), .missedSessions, asOf: 10).count, 0)
        // an abandoned block (nothing done in it after the planned days)
        XCTAssertEqual(sigs(snap([], sessions: [sessionRecord(5, planned: 5, meso: "old"), sessionRecord(9, planned: 9, meso: "old")]), .missedSessions).count, 0)
        // deload and maintenance sessions are not counted
        XCTAssertEqual(sigs(snap([], sessions: [done, sessionRecord(5, planned: 5, deload: true), sessionRecord(9, planned: 9, maint: true)]), .missedSessions).count, 0)
        // a completed-late session is done, not missed
        XCTAssertEqual(sigs(snap([], sessions: [sessionRecord(5, planned: 1, status: .completed), sessionRecord(9, planned: 2, status: .completed)]), .missedSessions).count, 0)
    }

    // MARK: - 4. Feedback share

    /// `total` sets in sessions of four, the `flagged` ones in the LAST sessions (so the window has filled by then).
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

    func test_feedbackShare_firesAtTheShareBar_notBelow_andIgnoresSoreness() {
        XCTAssertGreaterThan(sigs(feedbackSnap(flagged: 4, total: 24), .feedbackShare).count, 0, "4/24 = 16.7%")
        XCTAssertEqual(sigs(feedbackSnap(flagged: 3, total: 24), .feedbackShare).count, 0, "3/24 = 12.5%")
        XCTAssertEqual(sigs(feedbackSnap(flagged: 4, total: 16), .feedbackShare).count, 0, "under the minimum sample")
        XCTAssertEqual(sigs(feedbackSnap(flagged: 6, total: 24, flag: .soreness), .feedbackShare).count, 0, "soreness is informational")
        XCTAssertGreaterThan(sigs(feedbackSnap(flagged: 4, total: 24, flag: .pain), .feedbackShare).count, 0)
    }

    func test_feedbackShare_skippedSetsWithAReasonCount_deloadDoesNot() {
        var sets = feedbackSnap(flagged: 0, total: 20).sets
        sets += exposure(11, lift: "x", reps: [0, 0, 0, 0], feedback: [.pain, .fatigue, .pain, .fatigue], skipped: [true, true, true, true])
        XCTAssertGreaterThan(sigs(snap(sets), .feedbackShare).count, 0, "4 skipped-for-a-reason rows over 24")
        var deloaded: [SetRecord] = []
        for i in 0..<6 { deloaded += exposure(i * 2, lift: "d\(i)", reps: [8, 8, 8, 8], feedback: [.fatigue, .fatigue, .fatigue, .fatigue], deload: true) }
        XCTAssertEqual(sigs(snap(deloaded), .feedbackShare).count, 0)
    }

    // MARK: - 5. Self report

    func test_selfReport_readinessAndOverrides() {
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], readiness: .fatigued)), .selfReport).count, 1)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8, 8, 8], readiness: .compromised)), .selfReport).count, 1, "once per session, not per set")
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], readiness: .fresh)), .selfReport).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], readiness: .normal)), .selfReport).count, 0)
        let gf = sigs(snap(exposure(0, reps: [8, 8], override: .generalFatigue)), .selfReport)
        XCTAssertEqual(gf.count, 1)
        XCTAssertEqual(gf[0].exerciseId, "bench_press")
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], override: .jointTenderness)), .selfReport).count, 1)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], override: .equipmentConstraint)), .selfReport).count, 0, "the rack dictated it, not the lifter")
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], override: .deliberateDeload)), .selfReport).count, 0)
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], deload: true, readiness: .fatigued)), .selfReport).count, 0, "a deload week is excluded")
        XCTAssertEqual(sigs(snap(exposure(0, reps: [8], maint: true, readiness: .fatigued)), .selfReport).count, 0)
    }

    // MARK: - Policy

    private func signal(_ type: FatigueSignalType, _ n: Int) -> FatigueSignal {
        FatigueSignal(type: type, date: day(n), exerciseId: nil, exerciseName: nil, evidence: "")
    }

    func test_policy_twoDistinctTypesInThreeWeeksIsADeloadSuggestion() {
        let empty = snap([])
        func assess(_ sigs: [FatigueSignal], asOf: Int, policy p: FatiguePolicy = .default) -> FatigueSuggestion {
            FatigueMonitor.assess(signals: sigs, snapshot: empty, policy: p, asOf: day(asOf)).suggestion
        }
        XCTAssertEqual(assess([], asOf: 30), .none)
        XCTAssertEqual(assess([signal(.repDrop, 25)], asOf: 30), .watch)
        XCTAssertEqual(assess([signal(.repDrop, 20), signal(.repDrop, 25)], asOf: 30), .watch, "the same kind twice is one kind")
        XCTAssertEqual(assess([signal(.repDrop, 20), signal(.selfReport, 25)], asOf: 30), .deloadSuggested)
        XCTAssertEqual(assess([signal(.repDrop, 5), signal(.selfReport, 25)], asOf: 30), .watch, "day 5 is outside the 21 days before day 30")
        XCTAssertEqual(assess([signal(.repDrop, 30), signal(.selfReport, 31)], asOf: 30), .watch, "signals after asOf do not exist yet")
        var three = FatiguePolicy.default; three.deloadTypeCount = 3
        XCTAssertEqual(assess([signal(.repDrop, 20), signal(.selfReport, 25)], asOf: 30, policy: three), .watch, "the rule is data")
        var wide = FatiguePolicy.default; wide.windowDays = 40
        XCTAssertEqual(assess([signal(.repDrop, 5), signal(.selfReport, 25)], asOf: 30, policy: wide), .deloadSuggested)
        var off = FatiguePolicy.default; off.enabledTypes = [.repDrop]
        XCTAssertEqual(assess([signal(.repDrop, 20), signal(.selfReport, 25)], asOf: 30, policy: off), .watch, "a disabled kind never counts")
    }

    func test_policy_aCompletedDeloadResetsTheClock() {
        let deload = SessionRecord(key: "dl", date: day(24), plannedDate: nil, completedAt: day(24), status: .completed, weekIndex: 9,
                                   dayLabel: "Push", mesoKey: "m1", mesoName: nil, isMaintenance: false, isInsertedDeload: false,
                                   isDeloadWeek: true, readiness: .normal, readinessStars: 0, hkDuration: 0)
        let s = snap([], sessions: [deload])
        let sigs = [signal(.repDrop, 20), signal(.selfReport, 22), signal(.feedbackShare, 26)]
        let a = FatigueMonitor.assess(signals: sigs, snapshot: s, asOf: day(30))
        XCTAssertEqual(a.suggestion, .watch, "only the signal after the deload counts")
        XCTAssertEqual(a.signals.map(\.type), [.feedbackShare])
        var keep = FatiguePolicy.default; keep.resetAfterDeload = false
        XCTAssertEqual(FatigueMonitor.assess(signals: sigs, snapshot: s, policy: keep, asOf: day(30)).suggestion, .deloadSuggested)
    }

    func test_evaluate_endToEnd_repDropPlusSelfReportSuggestsADeload() {
        let sets = exposure(0, reps: [8, 8, 8]) + exposure(7, reps: [7, 6, 5], readiness: .fatigued)
        let a = FatigueMonitor.evaluate(snapshot: snap(sets), loadIncrementLb: incr, asOf: day(8))
        XCTAssertEqual(a.suggestion, .deloadSuggested)
        XCTAssertEqual(a.distinctTypes, [.repDrop, .selfReport])
        XCTAssertEqual(FatigueMonitor.evaluate(snapshot: snap(sets), loadIncrementLb: incr, asOf: day(3)).suggestion, .none, "nothing is known on day 3")
    }

    // MARK: - Never writes

    func test_monitor_leavesTheStoreUntouched() throws {
        let container = try BackupTestSupport.makeContainer()
        let ctx = ModelContext(container)
        let meso = MesoBlock(name: "M", startDate: day(0), status: .active, totalWeeks: 10)
        ctx.insert(meso)
        for (n, reps) in [(0, [8, 8, 8]), (7, [6, 5, 5])] {
            let it = BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: reps, loads: [290, 290, 290])
            it.waveRaw = "a"
            let s = Session(date: day(n), status: .completed, weekIndex: 1 + n / 7, dayLabel: "Push", items: [it], completedAt: day(n))
            s.readiness = .fatigued
            s.meso = meso
            meso.sessions.append(s)
            ctx.insert(s)
        }
        try ctx.save()
        let before = try BackupTestSupport.exportJSON(ctx)
        let snapshot = SetRecordBuilder.build(sessions: try ctx.fetch(FetchDescriptor<Session>()))
        let a = FatigueMonitor.evaluate(snapshot: snapshot, loadIncrementLb: 5, asOf: day(8))
        XCTAssertEqual(a.suggestion, .deloadSuggested)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(NSDictionary(dictionary: try BackupTestSupport.exportJSON(ctx)), NSDictionary(dictionary: before))
    }
}
