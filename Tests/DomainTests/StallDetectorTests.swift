import XCTest
import SwiftData
@testable import ElitePerformance

/// StallDetector: per lift and wave letter, no new best over the last three exposures (e1RM, or reps at the same load for
/// capped / fixed-load / bodyweight lifts), with the exclusions. Records are built directly.
final class StallDetectorTests: XCTestCase {

    private let incr = 5.0
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400) }
    private var counter = 0

    /// One exposure of `lift`: `reps` at `load` (3 sets by default).
    private func exposure(_ n: Int, lift: String = "bench_press", letter: String? = "a", meso: String = "m1", load: Double,
                          reps: [Int] = [8, 8, 8], top: Bool = false, bodyweight: Bool = false, deload: Bool = false,
                          maint: Bool = false, override: LoadOverrideReason? = nil) -> [SetRecord] {
        counter += 1
        let key = "s\(n)-\(lift)-\(counter)"
        return reps.enumerated().map { i, r in
            SetRecord(
                sessionKey: key, sessionDate: day(n), status: .completed, weekIndex: 1 + n / 7, dayLabel: "Push", mesoKey: meso,
                exerciseId: lift, exerciseName: lift, muscle: nil, isBodyweight: bodyweight,
                waveLetter: letter, isDeloadWaveItem: false, isInsertedDeload: false, isDeloadWeek: deload, isMaintenance: maint,
                rowIndex: i, isTop: top, plannedReps: 8, plannedLoad: load, repMin: 6, repMax: 12, targetRIRMin: 1, targetRIRMax: 2,
                targetRIR: 2, reps: r, load: load, effectiveLoad: load, rir: 2, isSkipped: false, isRestPause: false, isDrop: false,
                feedback: .none, pump: 0, loadOverride: override, planEdited: false, readiness: .normal, readinessStars: 0,
                hkDuration: 0, isWorkingSet: true, isHardSetRow: true)
        }
    }

    private func series(_ lift: String = "bench_press", letter: String? = "a", loads: [Double], start: Int = 0, step: Int = 21, top: Bool = false, meso: String = "m1") -> [SetRecord] {
        loads.enumerated().flatMap { i, l in exposure(start + i * step, lift: lift, letter: letter, meso: meso, load: l, top: top) }
    }

    private func stalls(_ sets: [SetRecord], asOf: Int = 100, policy: StallPolicy = .default,
                        maxLoad: @escaping (String) -> Double? = { _ in nil }, fixed: @escaping (String) -> Bool = { _ in false }) -> [Stall] {
        StallDetector.stalls(in: AnalyticsSnapshot(sessions: [], sets: sets), policy: policy, loadIncrementLb: incr, asOf: day(asOf), maxLoad: maxLoad, isFixedLoad: fixed)
    }

    // MARK: - e1RM mode

    func test_stalled_whenTheLastThreeExposuresSetNoNewBest() {
        // e1RM follows load (x1.267): 200, 205 (best), then 203, 204, 205 (a tie): no new best in 3 exposures.
        let s = stalls(series(loads: [200, 205, 203, 204, 205]))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].exerciseId, "bench_press")
        XCTAssertEqual(s[0].letter, "a")
        XCTAssertEqual(s[0].metric, .e1RM)
        XCTAssertEqual(s[0].bestValue, E1RMCalculator.e1RM(load: 205, reps: 8), accuracy: 1e-9)
        XCTAssertEqual(s[0].bestDate, day(21))
        XCTAssertEqual(s[0].exposuresSinceBest, 3)
        XCTAssertTrue(s[0].evidence.contains("best e1RM 260") && s[0].evidence.contains("3 exposures since"), s[0].evidence)
    }

    func test_notStalled_whenAnyOfTheLastThreeIsANewBest_orThereAreTooFewExposures() {
        XCTAssertTrue(stalls(series(loads: [200, 205, 203, 204, 210])).isEmpty, "the last one is a new best")
        XCTAssertTrue(stalls(series(loads: [200, 205, 203, 204])).isEmpty, "only two since the best")
        XCTAssertTrue(stalls(series(loads: [200, 200, 200])).isEmpty, "no exposure before the three to set a record")
        XCTAssertEqual(stalls(series(loads: [200, 200, 200, 200])).count, 1, "one to set it, three that did not beat it")
    }

    func test_aGainUnderTheThresholdIsNotANewBest() {
        // 200 -> 200.5 is +0.25% (under 0.5%): not a new best.
        XCTAssertEqual(stalls(series(loads: [200, 200.5, 200.5, 200.5])).count, 1)
        XCTAssertTrue(stalls(series(loads: [200, 202, 202, 202])).isEmpty, "+1% is a new best at the second exposure, then only two since")
        XCTAssertEqual(stalls(series(loads: [200, 202, 202, 202, 202])).count, 1)
        var strict = StallPolicy.default; strict.minImprovementFraction = 0
        XCTAssertTrue(stalls(series(loads: [200, 200.5, 200.5, 200.5]), policy: strict).isEmpty, "with no threshold 200.5 is a gain")
    }

    func test_policyIsData_exposuresNeededToCallItAStall() {
        var two = StallPolicy.default; two.exposures = 2
        XCTAssertEqual(stalls(series(loads: [200, 205, 203, 204]), policy: two).count, 1)
        var four = StallPolicy.default; four.exposures = 4
        XCTAssertTrue(stalls(series(loads: [200, 205, 203, 204, 205]), policy: four).isEmpty)
    }

    func test_perLetter_aStalledLetterIsNotRescuedByAProgressingOne() {
        // A: stalled. B: still progressing. Interleaved in time.
        var sets: [SetRecord] = []
        let aLoads: [Double] = [200, 205, 203, 204, 205]
        let bLoads: [Double] = [150, 155, 160, 165, 170]
        for i in 0..<5 {
            sets += exposure(i * 21, letter: "a", load: aLoads[i])
            sets += exposure(i * 21 + 7, letter: "b", load: bLoads[i])
        }
        let s = stalls(sets)
        XCTAssertEqual(s.map(\.letter), ["a"])
    }

    func test_topSetsAreTheirOwnChain() {
        var sets = series(loads: [200, 205, 203, 204, 205], top: false)
        sets += series(loads: [220, 225, 230, 235, 240], top: true)
        let s = stalls(sets)
        XCTAssertEqual(s.count, 1)
        XCTAssertFalse(s[0].isTop)
    }

    // MARK: - Exclusions

    func test_deloadMaintenanceAndSuppressedLoadsAreNotExposures() {
        // Regular: 200, 205 (best), 203, 204 (days 0..21). Then a heavier deload-week set, a maintenance set and a set with a
        // load-cutting override, which would all be "new bests" if they counted.
        var sets = series(loads: [200, 205, 203, 204], step: 7)
        sets += exposure(30, load: 230, deload: true)
        sets += exposure(35, load: 240, maint: true)
        sets += exposure(40, load: 250, override: .generalFatigue)
        XCTAssertTrue(stalls(sets, asOf: 60).isEmpty, "only two regular exposures since the best")
        sets += exposure(45, load: 204)
        let s = stalls(sets, asOf: 60)
        XCTAssertEqual(s.count, 1, "the third regular exposure since the best makes the stall; the excluded ones neither help nor hurt")
        XCTAssertEqual(s[0].exposuresSinceBest, 3)
    }

    func test_aReplacedLiftIsADifferentLift() {
        // The old lift stalled; the replacement has only three exposures: not a stall (no prior exposure to set a record).
        var sets = series("barbell_row", loads: [200, 205, 203, 204, 205], step: 7)
        sets += series("t_bar_row", loads: [150, 150, 150], start: 35, step: 7)
        let s = stalls(sets, asOf: 80)
        XCTAssertEqual(s.map(\.exerciseId), ["barbell_row"])
    }

    func test_onlyCurrentLifts_areListed() {
        let sets = series(loads: [200, 205, 203, 204, 205])      // last exposure on day 84
        XCTAssertEqual(stalls(sets, asOf: 100).count, 1)
        XCTAssertTrue(stalls(sets, asOf: 84 + 57).isEmpty, "not trained for 57 days: gone, not stalled")
    }

    // MARK: - Current block, programmed status, letter chain

    func test_defaultIsCurrentBlockOnly_aReseededLiftIsNotStalledAgainstLastBlocksRecord() {
        XCTAssertTrue(StallPolicy.default.currentBlockOnly)
        // Block 1 reached 260 e1RM; block 2 re-seeded lower and has only three exposures, none above block 1's record.
        var sets = series(loads: [200, 220, 230], meso: "m1")
        sets += series(loads: [180, 185, 190], start: 63, step: 7, meso: "m2")
        XCTAssertTrue(stalls(sets, asOf: 100).isEmpty, "inside block 2 the three exposures are all there is")
        var across = StallPolicy.default; across.currentBlockOnly = false
        XCTAssertEqual(stalls(sets, asOf: 100, policy: across).count, 1, "compared across blocks it would be flagged (meso comparison's job)")
        // Four exposures in the block and no new best over the last three: stalled inside the block.
        let flat = series(loads: [200, 220, 230], meso: "m1") + series(loads: [180, 190, 190, 190, 190], start: 63, step: 7, meso: "m2")
        XCTAssertEqual(stalls(flat, asOf: 110).count, 1)
    }

    func test_liftWithNoRemainingPlannedSession_isNoLongerProgrammed_notStalled() {
        let sets = series(loads: [200, 205, 203, 204, 205], step: 7)    // stalled; last exposure on day 28
        func record(_ key: String, _ status: SessionStatus, _ lifts: [PrescribedLift], meso: String = "m1") -> SessionRecord {
            SessionRecord(key: key, date: day(40), plannedDate: nil, plannedDateIsExact: false, completedAt: nil, status: status,
                          weekIndex: 6, dayLabel: "Push", mesoKey: meso, mesoName: nil, isMaintenance: false, isInsertedDeload: false,
                          isDeloadWeek: false, readiness: .normal, readinessStars: 0, hkDuration: 0, prescribedLifts: lifts)
        }
        func run(_ sessions: [SessionRecord]) -> [Stall] {
            StallDetector.stalls(in: AnalyticsSnapshot(sessions: sessions, sets: sets), loadIncrementLb: incr, asOf: day(30))
        }
        let bench = PrescribedLift(exerciseId: "bench_press", letter: "a")
        XCTAssertEqual(run([record("p1", .planned, [bench])]).first?.status, .stalled, "still prescribed on A in a planned session")
        XCTAssertEqual(run([record("p1", .planned, [PrescribedLift(exerciseId: "bench_press", letter: "b")])]).first?.status,
                       .noLongerProgrammed, "only on another letter")
        XCTAssertEqual(run([record("p1", .planned, [PrescribedLift(exerciseId: "t_bar_row", letter: "a")])]).first?.status, .noLongerProgrammed)
        XCTAssertEqual(run([record("p1", .completed, [bench])]).first?.status, .noLongerProgrammed, "a completed session is not remaining")
        XCTAssertEqual(run([record("p1", .planned, [bench], meso: "other")]).first?.status, .noLongerProgrammed, "a planned session of another block")
        XCTAssertEqual(run([]).first?.status, .stalled, "no session data: unknown, treated as programmed")
    }

    func test_bodyweightItemWithoutWaveLetter_takesTheSessionsLetter_soTheChainIsKept() throws {
        let container = try BackupTestSupport.makeContainer()
        let ctx = ModelContext(container)
        func item(_ id: String, wave: String?) -> SessionItem {
            let i = SessionItem(order: 1, exerciseId: id, exerciseNameSnapshot: id, targetReps: 8, targetSets: 2, targetRIR: 2,
                                suggestedLoad: 0, waveRaw: wave, plannedRepsBySet: [8, 8], plannedLoadsBySet: [0, 0], plannedRIRsBySet: [2, 2])
            i.actualReps = [8, 8]; i.actualLoads = [100, 100]; i.actualRIRs = [2, 2]; i.isCompleted = true
            return i
        }
        func add(_ d: Int, _ items: [SessionItem]) -> Session {
            let sess = Session(date: day(d), status: .completed, weekIndex: 1, dayLabel: "Pull", items: items)
            ctx.insert(sess); return sess
        }
        let tagged = add(0, [item("barbell_row", wave: "c"), item("pull_up", wave: nil)])
        let alsoTagged = add(7, [item("barbell_row", wave: "c"), item("pull_up", wave: "c")])
        let mixed = add(14, [item("barbell_row", wave: "a"), item("lat_pulldown", wave: "b"), item("pull_up", wave: nil)])
        let deload = add(21, [item("barbell_row", wave: "deload"), item("pull_up", wave: nil)])
        let noWave = add(28, [item("barbell_row", wave: nil), item("pull_up", wave: nil)])
        let snap = SetRecordBuilder.build(sessions: [tagged, alsoTagged, mixed, deload, noWave])
        func letter(_ d: Int, _ id: String) -> String? { snap.sets.first { $0.exerciseId == id && $0.sessionDate == day(d) }?.waveLetter }
        XCTAssertEqual(letter(0, "pull_up"), "c", "an untagged bodyweight item takes the session's one letter")
        XCTAssertEqual(letter(7, "pull_up"), "c")
        XCTAssertNil(letter(14, "pull_up"), "the session's letters disagree (a, b): nothing to derive")
        XCTAssertNil(letter(21, "pull_up"), "a deload session's letter is never invented")
        XCTAssertNil(letter(28, "pull_up"), "a block with no letters keeps none")
        XCTAssertEqual(letter(0, "barbell_row"), "c")
        // and the chain is one chain across the tagged and untagged sessions
        let chains = Set(Exposures.build(from: snap.sets).filter { $0.chain.exerciseId == "pull_up" }.map(\.chain.letter))
        XCTAssertTrue(chains.contains("c"))
        XCTAssertEqual(snap.sessions.first { $0.date == day(0) }?.prescribedLifts.first { $0.exerciseId == "pull_up" }?.letter, "c")
    }

    // MARK: - Reps mode

    func test_cappedLift_isJudgedOnRepsAtTheCappedLoad() {
        // At its cap of 300 the e1RM can only move through reps: 8,9,9,9,9 mean reps -> best 9, then 3 that did not beat it.
        func capped(_ reps: [[Int]]) -> [SetRecord] { reps.enumerated().flatMap { i, r in exposure(i * 21, load: 300, reps: r) } }
        let stalled = stalls(capped([[8, 8, 8], [9, 9, 9], [9, 9, 9], [9, 9, 9], [9, 9, 8]]), maxLoad: { _ in 300 })
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled[0].metric, .reps)
        XCTAssertEqual(stalled[0].load, 300)
        XCTAssertEqual(stalled[0].bestValue, 9, accuracy: 1e-9)
        let moving = stalls(capped([[8, 8, 8], [9, 9, 9], [9, 9, 9], [9, 9, 9], [10, 10, 9]]), maxLoad: { _ in 300 })
        XCTAssertTrue(moving.isEmpty, "a rep more at the cap is progress")
        // The same data uncapped is judged on e1RM and equals-reps is a stall there too, but by e1RM.
        XCTAssertEqual(stalls(capped([[8, 8, 8], [9, 9, 9], [9, 9, 9], [9, 9, 9], [9, 9, 8]])).first?.metric, .e1RM)
    }

    func test_fixedLoadLift_andBodyweightLift_areJudgedOnReps() {
        func at(_ load: Double, _ reps: [[Int]], bw: Bool = false) -> [SetRecord] {
            reps.enumerated().flatMap { i, r in exposure(i * 21, load: load, reps: r, bodyweight: bw) }
        }
        let flat: [[Int]] = [[10, 10, 10], [12, 12, 12], [12, 12, 12], [12, 12, 12], [12, 12, 12]]
        XCTAssertEqual(stalls(at(50, flat), fixed: { _ in true }).first?.metric, .reps)
        let bw = stalls(at(0, flat, bw: true))
        XCTAssertEqual(bw.count, 1)
        XCTAssertEqual(bw[0].metric, .reps, "bodyweight: no load to move, reps are the progress")
    }

    func test_repsMode_onlyComparesExposuresAtTheCurrentLoad() {
        // Earlier exposures at 280 (more reps) are not the record at 300.
        var sets: [SetRecord] = []
        sets += exposure(0, load: 280, reps: [12, 12, 12])
        for (i, r) in [[8, 8, 8], [9, 9, 9], [9, 9, 9], [9, 9, 9], [9, 9, 8]].enumerated() { sets += exposure(21 + i * 21, load: 300, reps: r) }
        let s = stalls(sets, asOf: 120, maxLoad: { _ in 300 })
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].bestValue, 9, accuracy: 1e-9)
    }

    // MARK: - Backtest on the real backup (report only; EP_BACKUP_FIXTURE)

    func test_backtest_currentStallsOnTheRealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        var lines: [String] = []
        func log(_ x: String = "") { lines.append(x); print("STALL| \(x)") }
        defer {
            if let out = ProcessInfo.processInfo.environment["EP_STALL_REPORT"], !out.isEmpty {
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>())
        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        let snapshot = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let lastDone = (snapshot.sessions.filter { $0.status == .completed }.map(\.date).max() ?? Date()).addingTimeInterval(86_400)
        let result = StallDetector.stalls(
            in: snapshot, loadIncrementLb: incrementLb, asOf: lastDone, unit: unit,
            maxLoad: { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) },
            isFixedLoad: { UserProfile.isProgressionExempt(exerciseId: $0, profile: profile) })
        var acrossPolicy = StallPolicy.default; acrossPolicy.currentBlockOnly = false
        let across = StallDetector.stalls(
            in: snapshot, policy: acrossPolicy, loadIncrementLb: incrementLb, asOf: lastDone, unit: unit,
            maxLoad: { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) },
            isFixedLoad: { UserProfile.isProgressionExempt(exerciseId: $0, profile: profile) })
        let exposures = Exposures.build(from: snapshot.sets)
        struct K: Hashable { let id: String; let l: String; let t: Bool }
        let current = Dictionary(grouping: exposures, by: { K(id: $0.chain.exerciseId, l: $0.chain.letter, t: $0.chain.isTop) })
            .filter { ($0.value.map(\.date).max() ?? .distantPast) >= lastDone.addingTimeInterval(-56 * 86_400) }
        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent) · as of \(lastDone.formatted(date: .abbreviated, time: .omitted))")
        log("current lift x letter chains (trained in the last 8 weeks): \(current.count) · flagged: \(result.count), stalled \(result.filter { $0.status == .stalled }.count), no longer programmed \(result.filter { $0.status == .noLongerProgrammed }.count) (e1RM \(result.filter { $0.metric == .e1RM }.count), reps \(result.filter { $0.metric == .reps }.count))")
        log("")
        for x in result {
            log("   [\(x.status == .stalled ? "STALLED" : "NO LONGER PROGRAMMED")]")
            let vals = x.sinceBest.map { x.metric == .reps ? String(format: "%.1f", $0.value) : LoadFormatter(unit: unit).whole($0.value) }
            log("   \(x.evidence)")
            log("      since best: " + zip(x.sinceBest, vals).map { "\($0.0.date.formatted(.dateTime.month().day())) \($0.1)" }.joined(separator: " · ") + (x.isTop ? " · top sets" : ""))
        }
        log("")
        log("== for reference: the record compared across blocks (not the default): \(across.count) flagged")
        let onlyAcross = across.filter { r in !result.contains { $0.exerciseId == r.exerciseId && $0.letter == r.letter && $0.isTop == r.isTop } }
        log("   flags that exist only because the record is from an earlier block: \(onlyAcross.map { "\($0.exerciseName) \($0.letter.uppercased())" })")
        // Pull-Up: the items behind the reps-mode stall.
        log("")
        log("== Pull-Up items (canonical pull_up): date · raw exerciseId · item waveRaw · session day · letters of the session's other items · reps")
        for sess in all where sess.status == .completed {
            for item in sess.items where ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == "pull_up" {
                let derived = snapshot.sets.first { $0.exerciseId == "pull_up" && $0.sessionDate == sess.date && $0.waveLetter != nil }?.waveLetter ?? "-"
                log("      letter used by analytics: \(derived)")
                let others = Set(sess.items.compactMap { $0.waveRaw }).sorted()
                log("   \(sess.date.formatted(date: .abbreviated, time: .omitted)) · \(item.exerciseId) · \(item.waveRaw ?? "nil") · \(sess.dayLabel ?? "-") · \(others) · reps \(item.actualReps) loads \(item.actualLoads)")
            }
        }
        XCTAssertFalse(current.isEmpty)
    }
}
