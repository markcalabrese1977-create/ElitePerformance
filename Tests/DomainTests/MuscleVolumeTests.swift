import XCTest
import SwiftData
@testable import ElitePerformance

/// Muscle taxonomy + share table coverage, weekly hard sets per muscle, adjustable ranges, and a backtest on a real backup.
final class MuscleVolumeTests: XCTestCase {

    // MARK: - Share table

    /// Primary muscles that deliberately differ from the exercise's coarse group (fine muscle's coarse parent != catalog muscle).
    private let coarseExceptions: [String: String] = [
        "close_grip_bench_press": "triceps-dominant press",
        "sumo_deadlift": "glute/adductor-dominant pull",
        "farmer_carry": "grip is the limiter",
        "ez_bar_reverse_curl": "brachioradialis/forearm curl",
        "back_extension_45": "lower back",
        "bench_back_extension": "lower back",
        "cable_pull_through": "glute hinge",
    ]

    func test_everyBuiltInExerciseHasShares_onePrimary_secondariesInRange() {
        var problems: [String] = []
        for e in ExerciseCatalog.builtIn {
            guard let row = ExerciseMuscleShares.table[e.id], !row.isEmpty else { problems.append("\(e.id): no row"); continue }
            if row.values.filter({ $0 == 1 }).count != 1 { problems.append("\(e.id): needs exactly one primary (1.0)") }
            for (m, v) in row where v != 1 && ![0.25, 0.5].contains(v) { problems.append("\(e.id): \(m) share \(v) not 0.25/0.5") }
            let primary = row.first { $0.value == 1 }?.key
            if let primary, primary.coarseParent != e.primaryMuscle, coarseExceptions[e.id] == nil {
                problems.append("\(e.id): primary \(primary) is under \(primary.coarseParent), catalog says \(e.primaryMuscle)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func test_noStaleRows_everyTableIdIsABuiltIn() {
        let ids = Set(ExerciseCatalog.builtIn.map(\.id))
        XCTAssertEqual(Set(ExerciseMuscleShares.table.keys).subtracting(ids), [], "a row for an exercise that is not in the catalog")
        XCTAssertEqual(Set(coarseExceptions.keys).subtracting(ids), [])
    }

    func test_everyFineMuscleIsTrainedByAtLeastOnePrimary() {
        let primaries = Set(ExerciseMuscleShares.table.values.compactMap { $0.first { $0.value == 1 }?.key })
        // adductors have no exercise of their own: they are credited as a synergist (squat/lunge/deadlift patterns)
        XCTAssertEqual(Set(FineMuscle.allCases).subtracting(primaries), [.adductors])
        XCTAssertTrue(ExerciseMuscleShares.table.values.contains { $0[.adductors] != nil })
    }

    func test_customExercise_mapsItsCoarseGroupToAFinePrimary() {
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "custom-xyz", coarse: .back), [.lats: 1])
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "custom-xyz", coarse: .shoulders), [.sideDelts: 1])
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "custom-xyz", coarse: .core), [.abs: 1])
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "custom-xyz", coarse: .fullBody), [:], "no single muscle: not attributed")
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "custom-xyz", coarse: nil), [:])
        for g in MuscleGroup.allCases where g != .fullBody { XCTAssertNotNil(FineMuscle.primary(forCoarse: g), "\(g)") }
        // a built-in keeps its row even when a coarse group is passed
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "bench_press", coarse: .back)[.chest], 1)
    }

    func test_csvHasOneRowPerBuiltIn_andTheMuscleColumns() {
        let csv = ExerciseMuscleShares.csv().split(separator: "\n").map(String.init)
        XCTAssertEqual(csv.count, ExerciseCatalog.builtIn.count + 1)
        XCTAssertEqual(csv[0].split(separator: ",").count, 4 + FineMuscle.allCases.count)
        XCTAssertTrue(csv.contains { $0.hasPrefix("bench_press,\"Bench Press\",chest,yes,1,") })
    }

    // MARK: - Weekly hard sets

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400) }   // 2025-10-09 (a Thursday)
    private var counter = 0

    private func sets(_ n: Int, _ id: String, coarse: MuscleGroup? = nil, rows: Int = 3, meso: String = "m1", hard: Bool = true,
                      deload: Bool = false, maint: Bool = false, status: SessionStatus = .completed) -> [SetRecord] {
        counter += 1
        let key = "s\(n)-\(id)-\(counter)"
        return (0..<rows).map { i in
            SetRecord(
                sessionKey: key, sessionDate: day(n), status: status, weekIndex: 1, dayLabel: "D", mesoKey: meso,
                exerciseId: id, exerciseName: id, muscle: coarse, isBodyweight: false,
                waveLetter: "a", isDeloadWaveItem: false, isInsertedDeload: false, isDeloadWeek: deload, isMaintenance: maint,
                rowIndex: i, isTop: false, plannedReps: 8, plannedLoad: 100, repMin: 6, repMax: 12, targetRIRMin: 1, targetRIRMax: 2,
                targetRIR: 2, reps: 8, load: 100, effectiveLoad: 100, rir: 2, isSkipped: false, isRestPause: false, isDrop: false,
                feedback: .none, pump: 0, loadOverride: nil, planEdited: false, readiness: .normal, readinessStars: 0,
                hkDuration: 0, isWorkingSet: hard, isHardSetRow: hard)
        }
    }

    private func snap(_ s: [SetRecord]) -> AnalyticsSnapshot { AnalyticsSnapshot(sessions: [], sets: s) }

    func test_weightedAndDirectSets_perMuscle() {
        let w = MuscleVolume.weekly(in: snap(sets(0, "bench_press")), asOf: day(30))
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].sets[.chest], 3)
        XCTAssertEqual(w[0].sets[.triceps], 1.5)
        XCTAssertEqual(w[0].sets[.frontDelts], 1.5)
        XCTAssertEqual(w[0].directSets[.chest], 3)
        XCTAssertNil(w[0].directSets[.triceps], "a synergist is not a direct set")
        XCTAssertEqual(w[0].sessions, 1)
    }

    func test_onlyHardSetsOfRegularCompletedTraining_count() {
        var all = sets(0, "bench_press", rows: 2)
        all += sets(0, "bench_press", rows: 4, hard: false)                 // warm-ups / rest-pause add-ons / skips
        all += sets(1, "bench_press", rows: 5, deload: true)
        all += sets(1, "bench_press", rows: 5, maint: true)
        all += sets(1, "bench_press", rows: 5, status: .planned)
        let w = MuscleVolume.weekly(in: snap(all), asOf: day(30))
        XCTAssertEqual(w.first?.sets[.chest], 2)
    }

    func test_customExerciseIsCreditedByItsCoarseGroup_andFullBodyNotAtAll() {
        let w = MuscleVolume.weekly(in: snap(sets(0, "my-row", coarse: .back) + sets(0, "my-complex", coarse: .fullBody)), asOf: day(30))
        XCTAssertEqual(w[0].sets, [.lats: 3])
    }

    func test_weeksAreIsoWeeks_blockFilter_andCompleteness() {
        // day(0) is Thursday 9 Oct 2025; day(4) Monday 13 Oct starts the next week.
        let all = sets(0, "leg_extension", rows: 2) + sets(4, "leg_extension", rows: 3) + sets(5, "leg_extension", rows: 1, meso: "m2")
        let w = MuscleVolume.weekly(in: snap(all), asOf: day(8))
        XCTAssertEqual(w.map { $0.sets[.quads] }, [2, 4])
        XCTAssertEqual(w.map(\.isComplete), [true, false], "the second week has not elapsed at day 8")
        let m2 = MuscleVolume.weekly(in: snap(all), mesoKey: "m2", asOf: day(8))
        XCTAssertEqual(m2.map { $0.sets[.quads] }, [1])
    }

    func test_currentMesoKey_isTheLatestCompletedRegularSessionsBlock() {
        func rec(_ key: String, _ d: Int, _ meso: String, maint: Bool = false, status: SessionStatus = .completed) -> SessionRecord {
            SessionRecord(key: key, date: day(d), plannedDate: nil, plannedDateIsExact: false, completedAt: nil, status: status,
                          weekIndex: 1, dayLabel: nil, mesoKey: meso, mesoName: nil, isMaintenance: maint, isInsertedDeload: false,
                          isDeloadWeek: false, readiness: .normal, readinessStars: 0, hkDuration: 0)
        }
        let s = AnalyticsSnapshot(sessions: [rec("a", 0, "m1"), rec("b", 10, "m2"), rec("c", 20, "mx", maint: true), rec("d", 30, "m3", status: .planned)], sets: [])
        XCTAssertEqual(MuscleVolume.currentMesoKey(in: s), "m2")
    }

    // MARK: - Ranges

    func test_defaultRanges_coverEveryMuscle_andAreOrdered() {
        for m in FineMuscle.allCases {
            let r = MuscleVolumeRanges.defaults[m]
            XCTAssertNotNil(r, "\(m)")
            XCTAssertTrue((r?.min ?? 1) <= (r?.max ?? 0), "\(m)")
        }
        XCTAssertEqual(MuscleVolume.status(9, range: .init(min: 10, max: 20)), .below)
        XCTAssertEqual(MuscleVolume.status(10, range: .init(min: 10, max: 20)), .within)
        XCTAssertEqual(MuscleVolume.status(20, range: .init(min: 10, max: 20)), .within)
        XCTAssertEqual(MuscleVolume.status(20.5, range: .init(min: 10, max: 20)), .above)
    }

    func test_rangesAreAdjustable_andOnlyOverridesAreStored() {
        let p = UserProfile()
        XCTAssertNil(p.muscleSetRangesStored)
        XCTAssertEqual(p.muscleSetRanges[.chest], MuscleVolumeRanges.defaults[.chest])
        var r = p.muscleSetRanges
        r[.chest] = .init(min: 12, max: 24)
        p.muscleSetRanges = r
        XCTAssertEqual(p.muscleSetRangesStored ?? [:], ["chest.min": 12, "chest.max": 24])
        XCTAssertEqual(p.muscleSetRanges[.chest], MuscleSetRange(min: 12, max: 24))
        XCTAssertEqual(p.muscleSetRanges[.lats], MuscleVolumeRanges.defaults[.lats], "untouched muscles keep the default")
        p.muscleSetRanges = MuscleVolumeRanges.defaults
        XCTAssertNil(p.muscleSetRangesStored, "back to defaults stores nothing")
    }

    func test_malformedOverridesAreIgnored() {
        let r = MuscleVolumeRanges.resolved(stored: ["chest.min": 30, "chest.max": 5, "lats.min": -4, "bogus.min": 1])
        XCTAssertEqual(r[.chest], MuscleVolumeRanges.defaults[.chest], "min above max")
        XCTAssertEqual(r[.lats], MuscleVolumeRanges.defaults[.lats], "negative")
    }

    func test_rangesSurviveABackupRoundTrip() throws {
        let container = try BackupTestSupport.makeContainer()
        let ctx = ModelContext(container)
        let p = UserProfile()
        p.muscleSetRanges = [.chest: .init(min: 12, max: 24)]
        ctx.insert(p)
        try ctx.save()
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let other = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: result.url, modelContainer: other)
        let back = try ModelContext(other).fetch(FetchDescriptor<UserProfile>()).first
        XCTAssertEqual(back?.muscleSetRangesStored ?? [:], ["chest.min": 12, "chest.max": 24])
    }

    // MARK: - Backtest on a real backup (report only)

    func test_backtest_last4WeeksPerMuscleOnTheRealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        var lines: [String] = []
        func log(_ x: String = "") { lines.append(x); print("MUSCLE| \(x)") }
        defer {
            if let out = ProcessInfo.processInfo.environment["EP_MUSCLE_REPORT"], !out.isEmpty {
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
            if let out = ProcessInfo.processInfo.environment["EP_MUSCLE_CSV"], !out.isEmpty {
                try? ExerciseMuscleShares.csv().write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>())
        let snapshot = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let asOf = (snapshot.sessions.filter { $0.status == .completed }.map(\.date).max() ?? Date()).addingTimeInterval(86_400)
        guard let meso = MuscleVolume.currentMesoKey(in: snapshot) else { return XCTFail("no completed session") }
        let mesoName = snapshot.sessions.first { $0.mesoKey == meso }?.mesoName ?? "?"
        let ranges = (profile?.muscleSetRanges) ?? MuscleVolumeRanges.defaults

        // Which logged exercises have no share row (customs, unknown)?
        let ids = Set(snapshot.sets.filter(\.countsAsHardSet).map(\.exerciseId))
        let unmapped = ids.filter { ExerciseMuscleShares.table[$0] == nil }
        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent) · as of \(asOf.formatted(date: .abbreviated, time: .omitted)) · current block: \(mesoName)")
        log("exercises with hard sets: \(ids.count) · without a share row (custom: credited 1.0 to the fine primary of its coarse group): \(unmapped.count)")
        for id in unmapped.sorted() {
            let rec = snapshot.sets.first { $0.exerciseId == id }
            let n = snapshot.sets.filter { $0.exerciseId == id && $0.countsAsHardSet }.count
            let fine = ExerciseMuscleShares.shares(for: id, coarse: rec?.muscle).keys.first?.displayName ?? "not attributed"
            log("   \(rec?.exerciseName ?? id) · \(rec?.muscle?.rawValue ?? "?") -> \(fine) · \(n) hard sets all time")
        }
        log("")

        let weeks = MuscleVolume.weekly(in: snapshot, mesoKey: meso, asOf: asOf)
        let complete = weeks.filter(\.isComplete)
        let last4 = Array(complete.suffix(4))
        let partial = weeks.first { !$0.isComplete }
        func d(_ x: Date) -> String { x.formatted(.dateTime.month(.abbreviated).day()) }
        log("weeks in the current block: \(weeks.count) (complete \(complete.count)); reporting the last \(last4.count) complete weeks: " + last4.map { "wk of \(d($0.weekStart)) (\($0.sessions) sessions)" }.joined(separator: ", "))
        if let partial { log("current partial week of \(d(partial.weekStart)): \(partial.sessions) sessions so far (not in the averages)") }
        log("")
        let header = "muscle".padding(toLength: 12, withPad: " ", startingAt: 0) + last4.map { d($0.weekStart).padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
            + "avg    direct  range      status"
        log(header)
        var below: [String] = [], above: [String] = []
        for m in FineMuscle.allCases {
            let vals = last4.map { $0.sets[m] ?? 0 }
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            let direct = last4.isEmpty ? 0 : last4.map { $0.directSets[m] ?? 0 }.reduce(0, +) / Double(last4.count)
            let r = ranges[m] ?? MuscleVolumeRanges.defaults[m]!
            let st = MuscleVolume.status(avg, range: r)
            if st == .below { below.append(m.displayName) }
            if st == .above { above.append(m.displayName) }
            func f(_ v: Double) -> String { String(format: "%.1f", v).padding(toLength: 7, withPad: " ", startingAt: 0) }
            log(m.displayName.padding(toLength: 12, withPad: " ", startingAt: 0) + vals.map(f).joined() + f(avg) + f(direct)
                + "\(Int(r.min))-\(Int(r.max))".padding(toLength: 10, withPad: " ", startingAt: 0) + st.rawValue)
        }
        log("")
        log("below range: \(below)")
        log("above range: \(above)")
        XCTAssertFalse(weeks.isEmpty)
    }
}
