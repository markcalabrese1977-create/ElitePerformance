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
        // Decline Bench had a set added from Nov 8 (the prescription), so it is not an earned-set candidate on any letter.
        if c.notes.earnedSetCandidates.contains(where: { $0.exerciseId == "decline_bench_press" }) { XCTFail("Decline Bench: its prescribed set count rose") }
    }
}
