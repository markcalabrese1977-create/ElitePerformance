import XCTest
import SwiftData
@testable import ElitePerformance

/// P1 analytics foundation: WorkingSetFilter, the SetRecord snapshot, the single PR definition, exposure chains and
/// the two MesoPerformanceAnalyzer fixes. All synthetic; the fixture-driven checks live in AnalyticsImpactReportTests.
final class AnalyticsFoundationTests: XCTestCase {

    // MARK: - Fixtures

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400) }

    /// An item with the given per-row logs. Row arrays are padded to the longest.
    private func item(_ id: String = "bench_press", reps: [Int], loads: [Double], rirs: [Int]? = nil,
                      rp: [Bool]? = nil, patterns: [String]? = nil, drops: [String]? = nil,
                      feedback: [String]? = nil, pump: [Int]? = nil, roles: [String]? = nil, wave: String? = nil) -> SessionItem {
        let n = reps.count
        let i = SessionItem(order: 1, exerciseId: id, exerciseNameSnapshot: "Snap \(id)", targetReps: 8, targetSets: n, targetRIR: 2,
                            suggestedLoad: 0, waveRaw: wave,
                            plannedRepsBySet: Array(repeating: 8, count: n), plannedLoadsBySet: Array(repeating: 0, count: n),
                            plannedRIRsBySet: Array(repeating: 2, count: n))
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = rirs ?? Array(repeating: 2, count: n)
        i.usedRestPauseFlags = rp ?? Array(repeating: false, count: n)
        i.restPausePatternsBySet = patterns ?? Array(repeating: "", count: n)
        i.dropSetPatternsBySet = drops ?? Array(repeating: "", count: n)
        i.setFeedbackBySet = feedback ?? Array(repeating: "", count: n)
        i.pumpRatingsBySet = pump ?? Array(repeating: 0, count: n)
        if let roles { i.setRolesBySet = roles }
        i.isCompleted = true
        return i
    }

    private func makeContext() throws -> ModelContext { ModelContext(try BackupTestSupport.makeContainer()) }

    @discardableResult
    private func session(_ ctx: ModelContext, meso: MesoBlock?, day d: Int, week: Int = 1, status: SessionStatus = .completed,
                         label: String = "Push", items: [SessionItem]) -> Session {
        let s = Session(date: day(d), status: status, weekIndex: week, dayLabel: label, items: items)
        if status == .completed { s.completedAt = day(d) }
        s.meso = meso
        meso?.sessions.append(s)
        ctx.insert(s)
        return s
    }

    private func meso(_ ctx: ModelContext, weeks: Int = 10, maintenance: Bool = false, name: String = "M") -> MesoBlock {
        let m = MesoBlock(name: name, startDate: day(0), status: .active, totalWeeks: weeks, isMaintenance: maintenance)
        ctx.insert(m)
        return m
    }

    // MARK: - WorkingSetFilter

    func test_qualifyingRows_dropsZeroRepsZeroLoadRestPauseDropAndSkip() {
        let it = item(reps: [8, 0, 8, 8, 8, 8, 8], loads: [100, 100, 0, 100, 100, 100, 100],
                      rp: [false, false, false, true, false, false, false],
                      patterns: ["", "", "", "", "4+3", "SKIP", ""],
                      drops: ["", "", "", "", "", "", "-20%"])
        XCTAssertEqual(WorkingSetFilter.qualifyingRows(of: it).map(\.index), [0],
                       "only the plain row 0 qualifies: zero reps, zero load, RP flag, RP pattern, SKIP and drop all fall out")
    }

    func test_workingRows_dropWarmupsUnderHalfTheHeaviestRow() {
        let it = item(reps: [10, 8, 8, 6], loads: [60, 135, 135, 270])
        XCTAssertEqual(WorkingSetFilter.workingRows(of: it).map(\.index), [1, 2, 3], "60 < 135 (half of 270) is a warm-up; 135 is exactly half and stays")
    }

    func test_roleSelection_matchesTheSeedRules() {
        let both = item(reps: [8, 8, 5], loads: [290, 290, 315], roles: ["", "", "top"])
        XCTAssertEqual(WorkingSetFilter.qualifyingRows(of: both, role: .backOff).map(\.index), [0, 1])
        XCTAssertEqual(WorkingSetFilter.qualifyingRows(of: both, role: .top).map(\.index), [2])
        XCTAssertEqual(WorkingSetFilter.qualifyingRows(of: both).map(\.index), [0, 1, 2])
        let topUnlogged = item(reps: [8, 8, 0], loads: [290, 290, 0], roles: ["", "", "top"])
        XCTAssertEqual(WorkingSetFilter.qualifyingRows(of: topUnlogged, role: .top).map(\.index), [0, 1],
                       "an item with no logged top row contributes all its rows to a top read")
    }

    func test_hardSetRows_restPauseAndDropBaseSetsCountOnce_skipAndWarmupDoNot_topCounts() {
        let it = item(reps: [8, 8, 8, 8, 8, 6, 5], loads: [135, 225, 225, 225, 225, 225, 245],
                      rp: [false, true, false, false, false, false, false],
                      patterns: ["", "", "4+3", "SKIP", "", "", ""],
                      drops: ["", "", "", "", "-20%", "", ""],
                      roles: ["", "", "", "", "", "", "top"])
        let rows = WorkingSetFilter.hardSetRows(of: it, isBodyweight: false)
        XCTAssertEqual(rows.map(\.index), [0, 1, 2, 4, 5, 6])
        XCTAssertEqual(rows.filter(\.usedRestPause).map(\.index), [1, 2], "an RP flag or pattern row is ONE set; extras are never counted")
        XCTAssertEqual(rows.filter(\.hasDrop).map(\.index), [4])
        XCTAssertEqual(rows.filter(\.isTop).map(\.index), [6])
        XCTAssertFalse(rows.map(\.index).contains(3), "SKIP row")

        let warm = item(reps: [10, 8], loads: [45, 225])
        XCTAssertEqual(WorkingSetFilter.hardSetRows(of: warm, isBodyweight: false).map(\.index), [1])
    }

    func test_bodyweightRowsCountAsHardSetsWithNoLoad_butSeedsNeverSeeThem() {
        let bw = item("pull_up", reps: [8, 7, 6], loads: [0, 0, 0])
        XCTAssertEqual(WorkingSetFilter.hardSetRows(of: bw, isBodyweight: true).count, 3)
        XCTAssertEqual(WorkingSetFilter.hardSetRows(of: bw, isBodyweight: false).count, 0)
        XCTAssertEqual(WorkingSetFilter.workingRows(of: bw, isBodyweight: true).count, 3)
        XCTAssertEqual(WorkingSetFilter.qualifyingRows(of: bw).count, 0, "the seed read keeps its load > 0 rule")
    }

    // MARK: - HistorySeedLoad pinned to its pre-extraction behaviour

    /// The code HistorySeedLoad used before WorkingSetFilter existed, verbatim.
    private enum Legacy {
        struct LoggedSet { let reps: Int; let load: Double; let rir: Int }
        static func qualifyingSets(of item: SessionItem, role: HistorySeedLoad.Role? = nil) -> [LoggedSet] {
            func at<T>(_ a: [T], _ i: Int) -> T? { a.indices.contains(i) ? a[i] : nil }
            let topRowsLogged = item.topRowIndices.contains { at(item.actualReps, $0).map { $0 > 0 } ?? false }
            return (0..<min(item.actualLoads.count, item.actualReps.count)).compactMap { i in
                switch role {
                case .backOff?: if item.isTopRow(i) { return nil }
                case .top?: if topRowsLogged && !item.isTopRow(i) { return nil }
                case nil: break
                }
                let reps = item.actualReps[i], load = item.actualLoads[i]
                guard reps > 0, load > 0 else { return nil }
                if at(item.usedRestPauseFlags, i) == true { return nil }
                if let p = at(item.restPausePatternsBySet, i), !p.isEmpty { return nil }
                if let d = at(item.dropSetPatternsBySet, i), !d.isEmpty { return nil }
                return LoggedSet(reps: reps, load: load, rir: at(item.actualRIRs, i) ?? 0)
            }
        }
        static func peakE1RM(for exerciseId: String, in sessions: [Session], role: HistorySeedLoad.Role?) -> Double? {
            let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
            var peak = 0.0
            for session in sessions where session.status == .completed {
                if session.insertedDeload == true || session.meso?.isMaintenance == true { continue }
                guard let match = session.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId }) else { continue }
                if match.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "deload" { continue }
                let sets = qualifyingSets(of: match, role: role)
                guard let heaviest = sets.map(\.load).max() else { continue }
                for set in sets where set.load >= heaviest * 0.5 {
                    let credited = set.reps + min(max(set.rir, 0), 4)
                    peak = max(peak, E1RMCalculator.e1RM(load: set.load, reps: credited))
                }
            }
            return peak > 0 ? peak : nil
        }
        static func load(for exerciseId: String, goalReps: Int, targetRIR: Int, in sessions: [Session], increment: Double,
                         reference: Date, role: HistorySeedLoad.Role) -> Double? {
            let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
            var candidates: [(e1rm: Double, date: Date)] = []
            for session in sessions where session.status == .completed {
                guard let match = session.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId }) else { continue }
                if match.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "deload" { continue }
                let sets = qualifyingSets(of: match, role: role)
                guard let heaviest = sets.map(\.load).max() else { continue }
                var best = 0.0
                for set in sets where set.load >= heaviest * 0.5 {
                    let credited = set.reps + min(max(set.rir, 0), 4)
                    best = max(best, E1RMCalculator.e1RM(load: set.load, reps: credited))
                }
                if best > 0 { candidates.append((best, session.date)) }
            }
            guard !candidates.isEmpty else { return nil }
            let e1rm = E1RMCalculator.decayWeightedE1RM(from: candidates, referenceDate: reference)
            let raw = E1RMCalculator.load(for: e1rm, reps: goalReps, targetRIR: targetRIR)
            let seeded = HistorySeedLoad.roundedDown(raw, increment: increment)
            return seeded > 0 ? seeded : nil
        }
    }

    /// Deterministic generator so a failure reproduces.
    private struct LCG { var s: UInt64
        mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) } }

    func test_seedReads_areIdenticalToTheLegacyImplementation_onGeneratedHistory() throws {
        let ctx = try makeContext()
        var g = LCG(s: 20_261_112)
        let regular = meso(ctx, name: "Regular")
        let maint = meso(ctx, weeks: 2, maintenance: true, name: "Maint")
        let ids = ["bench_press", "barbell_row", "leg_press"]
        var all: [Session] = []
        for d in 0..<120 {
            let n = 3 + g.next(5)
            var reps: [Int] = [], loads: [Double] = [], rp: [Bool] = [], pats: [String] = [], drops: [String] = [], rirs: [Int] = []
            for _ in 0..<n {
                reps.append([0, 5, 6, 8, 8, 10, 12][g.next(7)])
                loads.append([0, 45, 95, 135, 185, 225, 225, 315][g.next(8)])
                rp.append(g.next(10) == 0)
                pats.append(["", "", "", "", "4+3", "SKIP"][g.next(6)])
                drops.append(g.next(12) == 0 ? "-20%" : "")
                rirs.append(g.next(6) - 1)
            }
            let roles: [String]? = g.next(3) == 0 ? (Array(repeating: "", count: n - 1) + ["top"]) : nil
            let wave = [nil, "a", "b", "c", "deload"][g.next(5)]
            let it = item(ids[g.next(3)], reps: reps, loads: loads, rirs: rirs, rp: rp, patterns: pats, drops: drops, roles: roles, wave: wave)
            let status: SessionStatus = g.next(8) == 0 ? .planned : .completed
            let s = session(ctx, meso: g.next(6) == 0 ? maint : regular, day: d, status: status, items: [it])
            if g.next(15) == 0 { s.insertedDeload = true }
            all.append(s)
        }
        let ref = day(130)
        for id in ids {
            for role in [nil, HistorySeedLoad.Role.backOff, .top] {
                XCTAssertEqual(HistorySeedLoad.peakE1RM(for: id, in: all, role: role), Legacy.peakE1RM(for: id, in: all, role: role),
                               "peakE1RM \(id) \(String(describing: role))")
            }
            for role in [HistorySeedLoad.Role.backOff, .top] {
                for (reps, rir) in [(8, 2), (5, 1), (12, 3)] {
                    XCTAssertEqual(
                        HistorySeedLoad.load(for: id, goalReps: reps, targetRIR: rir, in: all, loadIncrement: 5, referenceDate: ref, role: role),
                        Legacy.load(for: id, goalReps: reps, targetRIR: rir, in: all, increment: 5, reference: ref, role: role),
                        "load \(id) \(reps)@\(rir) \(role)")
                }
            }
        }
    }

    // MARK: - SetRecordBuilder

    func test_builder_canonicalIdsStoredLoadsRoleWaveMesoAndFlags() throws {
        let ctx = try makeContext()
        let m = meso(ctx, weeks: 10)
        let legacy = "e8f675c1-2bc2-4eeb-a0b2-d701a6412f58"   // alias of seated_cable_press
        let it = item(legacy, reps: [8, 7, 5, 0], loads: [100, 100, 120, 0], rirs: [2, 1, 0, 0],
                      rp: [false, true, false, false], patterns: ["", "", "", "SKIP"],
                      feedback: ["", "fatigue", "", "pain"], pump: [3, 0, 4, 0], roles: ["", "", "top", ""], wave: "B")
        it.loadOverrideReasonRaw = LoadOverrideReason.generalFatigue.rawValue
        let s = session(ctx, meso: m, day: 3, week: 4, items: [it])
        s.readiness = .fatigued
        s.readinessStars = 2
        s.hkDuration = 3_300

        let snap = SetRecordBuilder.build(sessions: [s])
        XCTAssertEqual(snap.sessions.count, 1)
        let sr = snap.sessions[0]
        XCTAssertEqual(sr.mesoKey, m.id?.uuidString)
        XCTAssertEqual(sr.weekIndex, 4)
        XCTAssertEqual(sr.readiness, .fatigued)
        XCTAssertEqual(sr.hkDuration, 3_300)
        XCTAssertEqual(sr.plannedDate, day(3), "Session.init sets plannedDate = date")

        // 4 rows with data (the 0-rep SKIP row is kept as a skip record).
        XCTAssertEqual(snap.sets.count, 4)
        let rows = snap.sets.sorted { $0.rowIndex < $1.rowIndex }
        XCTAssertTrue(rows.allSatisfy { $0.exerciseId == "seated_cable_press" }, "canonical id, not the legacy alias")
        XCTAssertEqual(rows.map(\.load), [100, 100, 120, 0], "lb as stored")
        XCTAssertEqual(rows.map(\.rir), [2, 1, 0, 0])
        XCTAssertEqual(rows.map(\.isTop), [false, false, true, false])
        XCTAssertEqual(rows.map(\.waveLetter), ["b", "b", "b", "b"], "wave letters are lower-cased")
        XCTAssertEqual(rows.map(\.isRestPause), [false, true, false, false])
        XCTAssertEqual(rows.map(\.isSkipped), [false, false, false, true])
        XCTAssertEqual(rows.map(\.feedback), [.none, .fatigue, .none, .pain])
        XCTAssertEqual(rows.map(\.pump), [3, 0, 4, 0])
        XCTAssertEqual(rows[0].loadOverride, .generalFatigue)
        XCTAssertEqual(rows[0].readiness, .fatigued)
        XCTAssertEqual(rows.map(\.isWorkingSet), [true, false, true, false], "RP row and SKIP row are not working sets")
        XCTAssertEqual(rows.map(\.isHardSetRow), [true, true, true, false], "the RP base set is one hard set; SKIP is none")
        XCTAssertEqual(rows[0].muscle, ExerciseCatalog.all.first { $0.id == "seated_cable_press" }?.primaryMuscle)
        XCTAssertEqual(rows[0].e1RM, E1RMCalculator.e1RM(load: 100, reps: 8))
    }

    func test_builder_contextFlags_deloadInsertedMaintenance_andHardSetCounting() throws {
        let ctx = try makeContext()
        let regular = meso(ctx, weeks: 10, name: "R")
        let maint = meso(ctx, weeks: 2, maintenance: true, name: "Mt")
        let work = item(reps: [8, 8], loads: [200, 200], wave: "a")
        let waveDeload = item(reps: [8, 8], loads: [120, 120], wave: "deload")
        let inserted = item(reps: [8, 8], loads: [120, 120], wave: "b")
        let inMaint = item(reps: [8, 8], loads: [150, 150])
        let planned = item(reps: [0], loads: [0])
        let sWork = session(ctx, meso: regular, day: 1, week: 2, items: [work])
        let sDeload = session(ctx, meso: regular, day: 2, week: 9, items: [waveDeload])
        let sInserted = session(ctx, meso: regular, day: 3, week: 5, items: [inserted]); sInserted.insertedDeload = true
        let sMaint = session(ctx, meso: maint, day: 4, week: 1, items: [inMaint])
        let sPlanned = session(ctx, meso: regular, day: 5, week: 3, status: .planned, items: [planned])
        _ = sPlanned

        let snap = SetRecordBuilder.build(sessions: [sWork, sDeload, sInserted, sMaint])
        func rows(_ s: Session) -> [SetRecord] { snap.sets.filter { $0.sessionKey == s.id?.uuidString } }
        XCTAssertTrue(rows(sWork).allSatisfy { $0.countsAsHardSet && $0.isPerformanceSet })
        XCTAssertTrue(rows(sDeload).allSatisfy { $0.isDeloadWaveItem && $0.isDeloadContext && !$0.countsAsHardSet && !$0.isPerformanceSet })
        XCTAssertTrue(rows(sInserted).allSatisfy { $0.isInsertedDeload && !$0.countsAsHardSet })
        XCTAssertTrue(rows(sMaint).allSatisfy { $0.isMaintenance && !$0.countsAsHardSet && !$0.isPerformanceSet })
        XCTAssertEqual(snap.sets.filter(\.countsAsHardSet).count, 2)
    }

    func test_builder_inProgressSessionIsNotRegularCompleted() throws {
        let ctx = try makeContext()
        let m = meso(ctx)
        let s = session(ctx, meso: m, day: 1, status: .inProgress, items: [item(reps: [8], loads: [100])])
        let r = SetRecordBuilder.build(sessions: [s]).sets
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r[0].countsAsHardSet)
        XCTAssertFalse(r[0].isPerformanceSet)
    }

    // MARK: - One PR definition

    func test_personalRecords_bestWorkingSetE1RM_excludesWarmupRestPauseDropDeloadMaintenanceSkip() throws {
        let ctx = try makeContext()
        let m = meso(ctx, weeks: 10)
        let maint = meso(ctx, weeks: 2, maintenance: true, name: "Mt")
        // Session 1: real top working set 200x6 (e1RM 240); a warm-up 60x25 would be 110 (fine) and a 60x60 would beat it.
        let s1 = session(ctx, meso: m, day: 1, items: [item(reps: [25, 6, 8], loads: [60, 200, 180], rp: [false, false, false])])
        // Session 2: only an RP set and a drop set heavier on paper; neither may set a record.
        let s2 = session(ctx, meso: m, day: 2, items: [item(reps: [12, 12], loads: [230, 230], rp: [true, false],
                                                              patterns: ["", ""], drops: ["", "-20%"])])
        // Session 3: maintenance block heavier; deload week heavier.
        let s3 = session(ctx, meso: maint, day: 3, items: [item(reps: [10], loads: [260])])
        let s4 = session(ctx, meso: m, day: 4, week: 9, items: [item(reps: [10], loads: [260], wave: "deload")])
        // Session 5: a real improvement.
        let s5 = session(ctx, meso: m, day: 5, items: [item(reps: [6], loads: [205])])
        let snap = SetRecordBuilder.build(sessions: [s1, s2, s3, s4, s5])

        let best = try XCTUnwrap(PersonalRecords.bests(from: snap.sets)["bench_press"])
        XCTAssertEqual(best.e1RM, E1RMCalculator.e1RM(load: 205, reps: 6), accuracy: 1e-9)
        XCTAssertEqual(best.sessionKey, s5.id?.uuidString)

        let events = PersonalRecords.events(from: snap.sets)
        XCTAssertEqual(events.map(\.sessionKey), [s1.id!.uuidString, s5.id!.uuidString], "s2 (RP/drop), s3 (maintenance), s4 (deload) set nothing")
        XCTAssertEqual(events.map(\.isBaseline), [true, false])
    }

    func test_personalRecords_equalIsNotARecord_andCanonicalIdsMerge() throws {
        let ctx = try makeContext()
        let m = meso(ctx)
        let alias = "e8f675c1-2bc2-4eeb-a0b2-d701a6412f58"
        let a = session(ctx, meso: m, day: 1, items: [item("seated_cable_press", reps: [8], loads: [100])])
        let b = session(ctx, meso: m, day: 2, items: [item(alias, reps: [8], loads: [100])])
        let events = PersonalRecords.events(from: SetRecordBuilder.build(sessions: [a, b]).sets)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].exerciseId, "seated_cable_press")
    }

    // MARK: - Exposures

    func test_exposures_chainByLiftLetterRoleAndMeso_leaveOutDeloadMaintenanceAndSuppressedLoads() throws {
        let ctx = try makeContext()
        let m1 = meso(ctx, name: "One"), m2 = meso(ctx, name: "Two")
        let a1 = session(ctx, meso: m1, day: 1, items: [item(reps: [8, 7], loads: [200, 200], wave: "a")])
        let b1 = session(ctx, meso: m1, day: 4, items: [item(reps: [8], loads: [190], wave: "b")])
        let a2 = session(ctx, meso: m1, day: 8, items: [item(reps: [8, 8], loads: [205, 205], wave: "a")])
        let cut = item(reps: [8], loads: [150], wave: "a"); cut.loadOverrideReasonRaw = LoadOverrideReason.generalFatigue.rawValue
        let a3 = session(ctx, meso: m1, day: 12, items: [cut])
        let newMeso = session(ctx, meso: m2, day: 20, items: [item(reps: [8], loads: [210], wave: "a")])
        let ex = Exposures.build(from: SetRecordBuilder.build(sessions: [a1, b1, a2, a3, newMeso]).sets)
        XCTAssertEqual(ex.count, 4, "the fatigue-cut exposure is left out")
        let chains = Exposures.chains(ex)
        XCTAssertEqual(chains.count, 3, "(bench,a,m1), (bench,b,m1), (bench,a,m2)")
        XCTAssertEqual(chains.first { $0.key.letter == "a" && $0.key.mesoKey == m1.id?.uuidString }?.value.count, 2)
        XCTAssertEqual(ex.first?.sets.map(\.reps), [8, 7])
    }

    // MARK: - MesoPerformanceAnalyzer fixes

    func test_analyzer_openingAndClosingLoadUseBackOffRows_notATopSet() throws {
        let ctx = try makeContext()
        let m = meso(ctx, weeks: 8)
        // Week 1: back-off 290 x 8, 8 and a top set 315 x 5. Row 0 skipped in week 2 (the top is the first logged load).
        let w1 = item(reps: [8, 8, 5], loads: [290, 290, 315], roles: ["", "", "top"], wave: "a")
        let w2 = item(reps: [0, 8, 5], loads: [0, 300, 320], roles: ["", "", "top"], wave: "a")
        let w3 = item(reps: [0, 0, 5], loads: [0, 0, 330], roles: ["", "", "top"], wave: "a")
        session(ctx, meso: m, day: 1, week: 1, items: [w1])
        session(ctx, meso: m, day: 8, week: 2, items: [w2])
        let last = session(ctx, meso: m, day: 15, week: 3, items: [w3])
        _ = last
        let analysis = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: m, allPriorSessions: []))
        let s = try XCTUnwrap(analysis.exerciseSummaries.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual(s.openingLoad, 290)
        XCTAssertEqual(s.closingLoad, 330, "no logged back-off row: the first logged row (the top set) is the fallback")
        XCTAssertEqual(MesoPerformanceAnalyzer.representativeLoad(of: w2), 300, "first logged BACK-OFF row, not the 320 top")
    }

    func test_analyzer_itemWithoutATopSet_keepsTheFirstLoggedLoad() {
        XCTAssertEqual(MesoPerformanceAnalyzer.representativeLoad(of: item(reps: [8, 8], loads: [0, 135])), 135)
        XCTAssertNil(MesoPerformanceAnalyzer.representativeLoad(of: item(reps: [0], loads: [0])))
    }

    func test_analyzer_maintenancePeaksNeverSetAPriorRecord() throws {
        let ctx = try makeContext()
        let current = meso(ctx, weeks: 8, name: "Cur")
        let maint = meso(ctx, weeks: 2, maintenance: true, name: "Mt")
        let regularPrior = meso(ctx, weeks: 8, name: "Prior")
        let c1 = session(ctx, meso: current, day: 100, week: 1, items: [item(reps: [8], loads: [200])])
        let c2 = session(ctx, meso: current, day: 107, week: 2, items: [item(reps: [8], loads: [210])])
        _ = (c1, c2)
        let heavyMaintenance = session(ctx, meso: maint, day: 50, items: [item(reps: [10], loads: [300])])
        let modestPrior = session(ctx, meso: regularPrior, day: 10, items: [item(reps: [8], loads: [190])])

        let withMaint = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: current, allPriorSessions: [heavyMaintenance, modestPrior]))
        XCTAssertTrue(try XCTUnwrap(withMaint.exerciseSummaries.first).isPR, "maintenance 300x10 must not block a real record")
        let onlyRegular = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: current, allPriorSessions: [modestPrior]))
        XCTAssertTrue(try XCTUnwrap(onlyRegular.exerciseSummaries.first).isPR)

        let heavyRegular = session(ctx, meso: regularPrior, day: 20, items: [item(reps: [10], loads: [300])])
        let beaten = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: current, allPriorSessions: [heavyRegular]))
        XCTAssertFalse(try XCTUnwrap(beaten.exerciseSummaries.first).isPR, "a REGULAR prior still counts")
    }
}
