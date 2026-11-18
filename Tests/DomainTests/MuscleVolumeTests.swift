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

    func test_customExercise_hasNoRowUntilTheLifterMapsIt() {
        XCTAssertNil(ExerciseMuscleShares.shares(for: "custom-xyz"), "no guess")
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "bench_press")?[.chest], 1)
        XCTAssertEqual(ExerciseMuscleShares.shares(for: "bench-press-legacy-alias-that-does-not-exist"), nil)
        let c = CustomExercise(id: "custom_a", name: "X", primaryMuscleRaw: "back", isCompound: true)
        XCTAssertNil(c.fineShares, "unmapped")
        c.fineMuscleRaw = "upperBack"
        XCTAssertEqual(c.fineShares, [.upperBack: 1])
        c.fineSecondaryShares = ["lats": 0.5, "rearDelts": 0.25, "upperBack": 0.5, "biceps": 0.9, "bogus": 0.5, "chest": 0]
        XCTAssertEqual(c.fineShares, [.upperBack: 1, .lats: 0.5, .rearDelts: 0.25], "the primary is not re-credited; out-of-range and unknown ignored")
        c.fineMuscleRaw = "notAMuscle"
        XCTAssertNil(c.fineShares)
        for g in MuscleGroup.allCases where g != .fullBody { XCTAssertNotNil(FineMuscle.primary(forCoarse: g), "\(g)") }
    }

    func test_suggester_copiesTheClosestBuiltIn_andSaysHowSure() {
        func sug(_ n: String, _ g: MuscleGroup) -> MuscleSuggestion? { MuscleSuggester.suggest(name: n, coarse: g) }
        XCTAssertEqual(sug("Smith Machine Hip Thrust", .glutes)?.primary, .glutes)
        XCTAssertEqual(sug("Smith Machine Hip Thrust", .glutes)?.confidence, .exact, "equipment words are ignored")
        XCTAssertEqual(sug("Chest Supported Barbell Row", .back)?.primary, .upperBack)
        XCTAssertEqual(sug("Single Leg Press", .quads)?.basedOn, "Leg Press")
        XCTAssertEqual(sug("Leg Press [Gym]", .quads)?.confidence, .exact, "bracketed notes are ignored")
        XCTAssertEqual(sug("Seated Smith Machine Calf Raise", .calves)?.basedOn, "Seated Calf Raise")
        XCTAssertEqual(sug("Smith Machine Romanian Deadlift", .hamstrings)?.basedOn, "Romanian Deadlift")
        XCTAssertEqual(sug("Prone Y-Raise", .shoulders)?.confidence, .keyword, "not in the catalog: the keyword table has it")
        XCTAssertNil(sug("Zercher Carry Thing", .core))
        XCTAssertNil(sug("Hip Thrust", .chest), "other muscle groups are not candidates")
        // equally good matches that disagree on the primary muscle are flagged
        XCTAssertEqual(sug("Row", .back)?.confidence, .ambiguous)
    }

    // MARK: - Suggester rules (generic names)

    func test_suggester_tag_namingAMuscleSetsThePrimary_keepingTheRestOfTheShares() {
        let row = MuscleSuggester.suggest(name: "Row [Lat Bias]", coarse: .back)
        XCTAssertEqual(row?.confidence, .tagged)
        XCTAssertEqual(row?.shares[.lats], 1, "the tagged muscle becomes the primary")
        XCTAssertEqual(row?.shares[.upperBack], 0.5, "the old primary drops to 0.5")
        XCTAssertEqual(row?.shares[.biceps], 0.5, "the other shares stay")
        XCTAssertEqual(row?.shares.values.filter { $0 == 1 }.count, 1)
        // a muscle the matched shares did not have is added as the primary
        let fly = MuscleSuggester.suggest(name: "Cable Fly [Rear Delt]", coarse: .chest)
        XCTAssertEqual(fly?.shares[.rearDelts], 1)
        XCTAssertEqual(fly?.shares[.chest], 0.5)
        // a tag naming the matched primary changes nothing but the confidence
        let ext = MuscleSuggester.suggest(name: "Single-Arm Cable Extension (Long Head)", coarse: .triceps)
        XCTAssertEqual(ext?.confidence, .tagged)
        XCTAssertEqual(ext?.primary, .triceps)
        // tags that name no muscle are ignored for matching and for the primary
        XCTAssertEqual(MuscleSuggester.suggest(name: "Leg Press [Gym]", coarse: .quads)?.confidence, .exact)
        XCTAssertEqual(MuscleSuggester.suggest(name: "Single Arm Pulldown (Kneeling)", coarse: .back)?.primary, .lats)
        XCTAssertNil(MuscleSuggester.tagMuscle("Plain Name"))
        XCTAssertEqual(MuscleSuggester.tagMuscle("Thing [Rear Delts]"), .rearDelts)
    }

    func test_suggester_straightArm_prefersPulloverBuiltIns_elseDropsElbowFlexors() {
        let s = MuscleSuggester.suggest(name: "Straight-Arm Cable Pulldown", coarse: .back)
        XCTAssertEqual(s?.basedOn, "Cable Pullover")
        XCTAssertEqual(s?.primary, .lats)
        XCTAssertNil(s?.shares[.biceps])
        XCTAssertNotNil(MuscleSuggester.suggest(name: "Straight Arm Pulldown", coarse: .back)?.shares[.lats])
        let shares: [FineMuscle: Double] = [.lats: 1, .biceps: 0.5, .upperBack: 0.25, .forearms: 0.25]
        XCTAssertEqual(MuscleSuggester.removingElbowFlexors(from: shares), [.lats: 1, .upperBack: 0.25])
        XCTAssertEqual(MuscleSuggester.removingElbowFlexors(from: [.biceps: 1, .forearms: 0.25]), [.biceps: 1, .forearms: 0.25], "a curl is all elbow flexion")
        XCTAssertTrue(MuscleSuggester.isStraightArm("Straight-Arm Thing"))
        XCTAssertTrue(MuscleSuggester.isStraightArm("straight arm thing"))
        XCTAssertFalse(MuscleSuggester.isStraightArm("Single Arm Thing"))
    }

    func test_suggester_tieStaysAmbiguous_butLandsOnTheMostCommonPrimary() {
        let row = MuscleSuggester.suggest(name: "Row", coarse: .back)
        XCTAssertEqual(row?.confidence, .ambiguous)
        XCTAssertEqual(row?.primary, .upperBack, "most rows are upper-back rows")
        XCTAssertEqual(MuscleSuggester.suggest(name: "One Arm DB Row", coarse: .back)?.primary, .upperBack)
    }

    func test_suggester_keywordTable_isOneTable_withValidRows() {
        let y = MuscleSuggester.suggest(name: "Prone Y-Raise", coarse: .shoulders)
        XCTAssertEqual(y?.confidence, .keyword)
        XCTAssertEqual(y?.shares, [.rearDelts: 1.0, .upperBack: 0.5, .sideDelts: 0.25])
        XCTAssertEqual(MuscleSuggester.suggest(name: "Cable Hip Adduction", coarse: .glutes)?.primary, .adductors, "not read as a hip thrust")
        XCTAssertEqual(MuscleSuggester.suggest(name: "Seated Reverse Fly", coarse: .shoulders)?.primary, .rearDelts)
        for row in MuscleSuggester.keywordTable {
            XCTAssertEqual(row.shares.values.filter { $0 == 1 }.count, 1, "\(row.keywords)")
            XCTAssertTrue(row.shares.values.allSatisfy { $0 > 0 && $0 <= 1 })
        }
    }

    func test_unmappedCustoms_areListedNotGuessedIntoTotals() {
        let all = sets(0, "bench_press", rows: 2) + sets(0, "custom_row", coarse: .back, rows: 3)
        let none = MuscleVolume.weekly(in: snap(all), asOf: day(30))
        XCTAssertEqual(none[0].sets[.chest], 2)
        XCTAssertNil(none[0].sets[.lats], "an unmapped custom credits no muscle")
        XCTAssertEqual(none[0].unmappedSets, 3)
        XCTAssertEqual(none[0].unmappedByExercise, ["custom_row": 3])
        let mapped = MuscleVolume.weekly(in: snap(all), asOf: day(30), customShares: ["custom_row": [.upperBack: 1, .lats: 0.5]])
        XCTAssertEqual(mapped[0].sets[.upperBack], 3)
        XCTAssertEqual(mapped[0].sets[.lats], 1.5)
        XCTAssertEqual(mapped[0].unmappedSets, 0)
        XCTAssertEqual(MuscleVolume.customShares(from: [CustomExercise(id: "c", name: "n", primaryMuscleRaw: "back", isCompound: false)]), [:])
    }

    func test_weekAdherence_flagsWeeksUnder70PercentOfPlannedSessions() {
        func rec(_ key: String, _ d: Int, _ status: SessionStatus, deload: Bool = false) -> SessionRecord {
            SessionRecord(key: key, date: day(d), plannedDate: day(d), plannedDateIsExact: true, completedAt: nil, status: status,
                          weekIndex: 1, dayLabel: nil, mesoKey: "m1", mesoName: nil, isMaintenance: false, isInsertedDeload: false,
                          isDeloadWeek: deload, readiness: .normal, readinessStars: 0, hkDuration: 0)
        }
        // week of Mon 13 Oct: 3 planned, 2 done (67%) ; week of 20 Oct: 3 planned, 3 done
        let snapshot = AnalyticsSnapshot(
            sessions: [rec("a", 4, .completed), rec("b", 6, .completed), rec("c", 8, .planned), rec("d", 11, .completed), rec("e", 13, .completed), rec("f", 15, .completed)],
            sets: sets(4, "leg_extension") + sets(6, "leg_extension") + sets(11, "leg_extension") + sets(13, "leg_extension") + sets(15, "leg_extension"))
        let w = MuscleVolume.weekly(in: snapshot, asOf: day(30))
        XCTAssertEqual(w.map(\.plannedSessions), [3, 3])
        XCTAssertEqual(w.map(\.completedSessions), [2, 3])
        XCTAssertEqual(w.map(\.isIncomplete), [true, false])
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

    // MARK: - Mapping editor: the primary is never also a secondary

    func test_setFineMapping_dropsAShareOnThePrimary_andOutOfRangeShares() {
        let c = CustomExercise(id: "custom_a", name: "DB Row [Lat Bias]", primaryMuscleRaw: "back", isCompound: true)
        c.setFineMapping(primary: .lats, secondary: [.lats: 0.5, .upperBack: 0.5, .biceps: 0.5, .rearDelts: 0.25, .triceps: 0.9, .chest: 0])
        XCTAssertEqual(c.fineMuscleRaw, "lats")
        XCTAssertEqual(c.fineSecondaryShares ?? [:], ["upperBack": 0.5, "biceps": 0.5, "rearDelts": 0.25])
        XCTAssertEqual(c.fineShares, [.lats: 1, .upperBack: 0.5, .biceps: 0.5, .rearDelts: 0.25])
        c.setFineMapping(primary: .lats, secondary: [.lats: 0.5])
        XCTAssertNil(c.fineSecondaryShares, "only a share on the primary: nothing left")
        c.setFineMapping(primary: nil, secondary: [.biceps: 0.5])
        XCTAssertNil(c.fineMuscleRaw)
        XCTAssertNil(c.fineSecondaryShares, "no primary, no mapping")
    }

    func test_sanitize_cleansMappingsSavedWithAHiddenShareOnTheirPrimary() {
        // as saved by the old editor: "Use suggestion" of Barbell Row (upper back 1, lats .5 ...), then primary changed to lats
        let c = CustomExercise(id: "custom_a", name: "DB Row [Lat Bias]", primaryMuscleRaw: "back", isCompound: true)
        c.fineMuscleRaw = "lats"
        c.fineSecondaryShares = ["lats": 0.5, "upperBack": 0.5, "biceps": 0.5, "rearDelts": 0.25]
        XCTAssertTrue(c.sanitizeFineMapping())
        XCTAssertEqual(c.fineSecondaryShares ?? [:], ["upperBack": 0.5, "biceps": 0.5, "rearDelts": 0.25])
        XCTAssertFalse(c.sanitizeFineMapping(), "idempotent")
        // an unmapped exercise is left alone
        let u = CustomExercise(id: "custom_b", name: "X", primaryMuscleRaw: "chest", isCompound: false)
        XCTAssertFalse(u.sanitizeFineMapping())
        // shares with no primary are dropped
        u.fineSecondaryShares = ["biceps": 0.5]
        XCTAssertTrue(u.sanitizeFineMapping())
        XCTAssertNil(u.fineSecondaryShares)
        // an unknown primary is no primary
        u.fineMuscleRaw = "nonsense"
        u.fineSecondaryShares = ["biceps": 0.5]
        XCTAssertTrue(u.sanitizeFineMapping())
        XCTAssertNil(u.fineMuscleRaw)
        XCTAssertNil(u.fineSecondaryShares)
    }

    // MARK: - Screen summary

    func test_summary_averagesFullWeeks_listsUnmapped_andChipText() {
        func rec(_ key: String, _ d: Int, _ status: SessionStatus = .completed) -> SessionRecord {
            SessionRecord(key: key, date: day(d), plannedDate: day(d), plannedDateIsExact: true, completedAt: nil, status: status,
                          weekIndex: 1, dayLabel: nil, mesoKey: "m1", mesoName: "Block", isMaintenance: false, isInsertedDeload: false,
                          isDeloadWeek: false, readiness: .normal, readinessStars: 0, hkDuration: 0)
        }
        // Mon-based weeks: day(4)=13 Oct, day(11)=20 Oct, day(18)=27 Oct. The middle week has 1 of 3 sessions done.
        let sessions = [rec("a", 4), rec("b", 11), rec("c", 12, .planned), rec("d", 13, .planned), rec("e", 18)]
        let all = sets(4, "leg_extension", rows: 10) + sets(11, "leg_extension", rows: 2) + sets(18, "leg_extension", rows: 12)
            + sets(18, "custom_x", coarse: .back, rows: 4)
        let sum = MuscleVolume.summary(snapshot: AnalyticsSnapshot(sessions: sessions, sets: all), customs: [], profile: nil, asOf: day(30))
        XCTAssertEqual(sum.weeks.count, 3)
        XCTAssertEqual(sum.averagedWeeks, 2, "the 1-of-3 week is held out")
        let quads = sum.rows.first { $0.muscle == .quads }
        XCTAssertEqual(quads?.average, 11, "(10 + 12) / 2")
        XCTAssertEqual(quads?.status, .within)
        XCTAssertEqual(quads?.series, [10, 2, 12])
        XCTAssertEqual(sum.unmapped.map(\.id), ["custom_x"])
        XCTAssertEqual(sum.unmapped.first?.sets, 4)
        XCTAssertEqual(sum.unmapped.first?.isEditable, false, "no saved custom exercise to edit")
        XCTAssertEqual(sum.blockName, "Block")

        let stalled = Stall(status: .stalled, exerciseId: "x", exerciseName: "X", letter: "b", isTop: false, metric: .e1RM, bestValue: 1,
                            bestDate: day(0), sinceBest: [(day(1), 1), (day(2), 1), (day(3), 1)], load: 0, evidence: "")
        XCTAssertEqual(stalled.chipText, "B: Stalled: no new best in 3 exposures")
        let gone = Stall(status: .noLongerProgrammed, exerciseId: "x", exerciseName: "X", letter: "", isTop: false, metric: .e1RM, bestValue: 1,
                         bestDate: day(0), sinceBest: [], load: 0, evidence: "")
        XCTAssertEqual(gone.chipText, "No longer programmed")
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

    // MARK: - Suggestion report (before/after of suggester changes; report only)

    func test_report_suggestionForEveryCustom() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty,
              let out = ProcessInfo.processInfo.environment["EP_SUGGEST_REPORT"], !out.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE and TEST_RUNNER_EP_SUGGEST_REPORT")
        }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let customs = try ModelContext(container).fetch(FetchDescriptor<CustomExercise>()).sorted { $0.name < $1.name }
        var lines: [String] = []
        for c in customs {
            let coarse = MuscleGroup(rawValue: c.primaryMuscleRaw) ?? .chest
            let sug = MuscleSuggester.suggest(name: c.name, coarse: coarse)
            let shares = sug?.shares.sorted { ($1.value, $0.key.rawValue) < ($0.value, $1.key.rawValue) }.map { "\($0.key.displayName) \($0.value)" }.joined(separator: ", ") ?? "-"
            lines.append("\(c.name) [\(coarse.rawValue)] | \(sug?.confidence.rawValue ?? "none") | based on \(sug?.basedOn ?? "-") | \(shares)")
        }
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
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
        let ranges = profile?.muscleSetRanges ?? MuscleVolumeRanges.defaults
        func d(_ x: Date) -> String { x.formatted(.dateTime.month(.abbreviated).day()) }
        func pad(_ x: String, _ n: Int) -> String { x.padding(toLength: n, withPad: " ", startingAt: 0) }
        func f(_ v: Double) -> String { pad(String(format: "%.1f", v), 7) }

        let explicit = MuscleVolume.customShares(from: customs)
        let suggested = MuscleVolume.suggestedShares(for: customs)
        let base = MuscleVolume.weekly(in: snapshot, mesoKey: meso, asOf: asOf, customShares: explicit)
        let last4 = Array(base.filter(\.isComplete).suffix(4))
        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent) · as of \(asOf.formatted(date: .abbreviated, time: .omitted)) · current block: \(mesoName)")
        log("last 4 elapsed weeks: " + last4.map { "wk \(d($0.weekStart)) \($0.completedSessions)/\($0.plannedSessions) sessions\($0.hasDeload ? " DELOAD" : "")\($0.isIncomplete ? " INCOMPLETE" : "")" }.joined(separator: " | "))
        log("")

        // The customs.
        let weekStarts = Set(last4.map(\.weekStart))
        let usedIds = Set(snapshot.sets.filter(\.countsAsHardSet).map(\.exerciseId)).filter { ExerciseMuscleShares.table[$0] == nil }
        log("== custom exercises with hard sets (\(usedIds.count)); mapped by you: \(usedIds.filter { explicit[$0] != nil }.count), unmapped: \(usedIds.filter { explicit[$0] == nil }.count)")
        log(pad("exercise", 42) + pad("coarse", 11) + pad("suggested primary", 19) + pad("conf.", 10) + pad("based on", 30) + "sets last4wk / all-time")
        func nameOf(_ id: String) -> String { customs.first { $0.id == id }?.name ?? id }
        for id in usedIds.sorted(by: { nameOf($0) < nameOf($1) }) {
            let c = customs.first { $0.id == id }
            let coarse = MuscleGroup(rawValue: c?.primaryMuscleRaw ?? "") ?? .chest
            let sug = MuscleSuggester.suggest(name: c?.name ?? id, coarse: coarse)
            let rows = snapshot.sets.filter { $0.exerciseId == id && $0.countsAsHardSet }
            let recent = rows.filter { weekStarts.contains(FatigueMonitor.weekStart($0.sessionDate)) && $0.mesoKey == meso }.count
            let who: String = explicit[id] != nil ? "(yours)" : (sug?.primary?.displayName ?? "none")
            var row: String = pad(c?.name ?? id, 42)
            row += pad(coarse.rawValue, 11)
            row += pad(who, 19)
            row += pad(sug?.confidence.rawValue ?? "-", 10)
            row += pad(sug?.basedOn ?? "-", 30)
            row += "\(recent) / \(rows.count)"
            log(row)
        }
        log("")

        func table(_ title: String, _ shares: [String: [FineMuscle: Double]]) {
            let weeks = MuscleVolume.weekly(in: snapshot, mesoKey: meso, asOf: asOf, customShares: shares)
            let w4 = Array(weeks.filter(\.isComplete).suffix(4))
            let full = w4.filter { !$0.isIncomplete && !$0.hasDeload }
            let held = w4.filter { $0.isIncomplete || $0.hasDeload }
            log("== \(title)")
            log(pad("muscle", 12) + w4.map { pad(d($0.weekStart) + ($0.hasDeload ? "D" : ($0.isIncomplete ? "*" : "")), 8) }.joined() + "avg(full wks: \(full.count))  direct  range    status")
            var below: [String] = [], above: [String] = []
            for m in FineMuscle.allCases {
                let vals = w4.map { $0.sets[m] ?? 0 }
                let avg = full.isEmpty ? 0 : full.map { $0.sets[m] ?? 0 }.reduce(0, +) / Double(full.count)
                let direct = full.isEmpty ? 0 : full.map { $0.directSets[m] ?? 0 }.reduce(0, +) / Double(full.count)
                let r = ranges[m] ?? MuscleVolumeRanges.defaults[m]!
                let st = MuscleVolume.status(avg, range: r)
                if st == .below { below.append(m.displayName) }
                if st == .above { above.append(m.displayName) }
                let cells: String = vals.map { pad(String(format: "%.1f", $0), 8) }.joined()
                var row: String = pad(m.displayName, 12) + cells
                row += pad(String(format: "%.1f", avg), 20)
                row += f(direct)
                row += pad("\(Int(r.min))-\(Int(r.max))", 9)
                row += st.rawValue
                log(row)
            }
            log(pad("unmapped", 12) + w4.map { pad(String(format: "%.0f", $0.unmappedSets), 8) }.joined() + "(sets in no muscle's total)")
            log("   * = fewer than 70% of planned sessions done, D = deload week: shown, not in the average. held out: \(held.map { d($0.weekStart) })")
            log("   below: \(below)   above: \(above)")
            log("")
        }
        table("A. as the app counts it today (only your own mappings; \(usedIds.filter { explicit[$0] == nil }.count) unmapped customs are in no total)", explicit)
        table("B. WITH SUGGESTIONS APPLIED (suggestion = closest built-in by name; unreviewed; \(suggested.keys.filter { usedIds.contains($0) }.count) of \(usedIds.filter { explicit[$0] == nil }.count) unmapped customs get one, the rest stay unmapped)", explicit.merging(suggested) { mine, _ in mine })
        XCTAssertFalse(base.isEmpty)
    }
}

// MARK: - Planned weekly volume (previews before seeding)

final class PlannedVolumeTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))! }
    private let template = DUP10WeekTemplate.template

    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        return ModelContext(c)
    }

    /// Seeds `template` from a Monday (Mon-Sat training) and, when `completeWeeks` is given, performs every planned set of the
    /// first that many weeks (all of them for nil).
    @discardableResult
    private func seed(_ ctx: ModelContext, start: Date, name: String, status: MesoStatus, template: ProgramTemplate? = nil,
                      completeWeeks: Int? = nil) throws -> MesoBlock {
        let t = template ?? self.template
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: [2, 3, 4, 5, 6, 7], context: ctx, template: t, calendar: cal,
                                  mesoName: name, mesoStatus: status)
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == name })
        for s in block.sessions where completeWeeks == nil || s.weekIndex <= completeWeeks! {
            for i in s.items {
                i.actualReps = Array(repeating: max(1, i.targetReps), count: i.targetSets)
                i.actualLoads = Array(repeating: 100, count: i.targetSets)
                i.actualRIRs = Array(repeating: 2, count: i.targetSets)
                i.isCompleted = true
            }
            s.status = .completed
            s.completedAt = s.date
        }
        try ctx.save()
        return block
    }

    private func actualRows(_ ctx: ModelContext, _ block: MesoBlock) throws -> [MuscleVolumeSummary.Row] {
        let sessions = try ctx.fetch(FetchDescriptor<Session>())
        let engine = AnalyticsEngine(sessions: sessions)
        return MuscleVolume.summary(snapshot: engine.snapshot, customs: [], profile: nil, asOf: date(2027, 6, 1),
                                    mesoKey: LastBlockComparison.key(for: block), wholeBlock: true).rows
    }

    // MARK: Equivalence

    func test_everyPlannedSetPerformed_plannedEqualsMesoSummarysActual_forEveryMuscle() throws {
        let ctx = try makeContext()
        let block = try seed(ctx, start: date(2026, 1, 5), name: "Block", status: .active)      // a Monday
        let actual = try actualRows(ctx, block)
        let planned = PlannedVolume.weeklyHardSets(template: template, overrides: nil).rows
        XCTAssertEqual(actual.map(\.muscle), planned.map(\.muscle))
        for (a, p) in zip(actual, planned) {
            XCTAssertEqual(a.average, p.average, accuracy: 1e-9, "\(a.muscle)")
            XCTAssertEqual(a.directAverage, p.directAverage, accuracy: 1e-9, "\(a.muscle) direct")
            XCTAssertEqual(a.status, p.status, "\(a.muscle)")
        }
        XCTAssertGreaterThan(planned.map(\.average).reduce(0, +), 0)
    }

    // MARK: Deload, modifiers, overrides, swap

    func test_deloadWeeksAreExcluded() {
        let bench = PlannedVolume.Week.Slot(exerciseId: "bench_press", sets: 10)
        let result = PlannedVolume.weeklyHardSets(weeks: [
            .init(isDeload: false, slots: [bench]),
            .init(isDeload: true, slots: [.init(exerciseId: "bench_press", sets: 100)]),
            .init(isDeload: false, slots: [bench]),
        ])
        XCTAssertEqual(result.averagedWeeks, 2)
        XCTAssertEqual(result.rows.first { $0.muscle == .chest }?.average, 10, "the 100-set deload week is not averaged")
        XCTAssertEqual(result.rows.first { $0.muscle == .triceps }?.average, 5, "synergist share 0.5")
        // The seeded template's deload week is skipped too: fewer averaged weeks than template weeks.
        let t = PlannedVolume.weeklyHardSets(template: template, overrides: nil)
        XCTAssertLessThan(t.averagedWeeks, template.totalWeeks)
    }

    private func total(_ r: PlannedVolume.Result) -> Double { r.rows.map(\.average).reduce(0, +) }

    func test_goalModifiersChangeThePlannedNumbers() {
        let base = PlannedVolume.weeklyHardSets(template: GoalModifier.apply(template, goal: .hypertrophy).0, overrides: nil)
        let general = PlannedVolume.weeklyHardSets(template: GoalModifier.apply(template, goal: .longevity).0, overrides: nil)
        let fat = PlannedVolume.weeklyHardSets(template: GoalModifier.apply(template, goal: .fatLoss).0, overrides: nil)
        XCTAssertLessThan(total(general), total(base), "general fitness: -1 set on every slot")
        XCTAssertLessThanOrEqual(total(fat), total(base), "lose fat caps the ramp")
        XCTAssertNotEqual(total(general), total(fat))
    }

    private func slot(containing needle: String) -> (SlotKey, ProgramExerciseTemplate)? {
        for day in template.dayTemplates { for (i, e) in day.exerciseTemplates.enumerated() where e.exerciseId.contains(needle) { return (SlotKey(dayId: day.id, slotIndex: i), e) } }
        return nil
    }

    func test_previewOverridesChangeThePlannedNumbers() throws {
        let base = PlannedVolume.weeklyHardSets(template: template, overrides: nil)
        let (key, e) = try XCTUnwrap(slot(containing: "lateral_raise"))
        // Removing the lateral raises lowers side delts.
        var removal = PreviewOverrides.empty
        for day in template.dayTemplates { for (i, ex) in day.exerciseTemplates.enumerated() where ex.exerciseId.contains("lateral_raise") {
            removal.slotKeyed[SlotKey(dayId: day.id, slotIndex: i)] = ExerciseWaveOverride(isDeleted: true)
        } }
        let removed = PlannedVolume.weeklyHardSets(template: template, overrides: removal)
        let side = { (r: PlannedVolume.Result) in r.rows.first { $0.muscle == .sideDelts }!.average }
        XCTAssertLessThan(side(removed), side(base))
        // More sets on one slot raises it.
        var more = PreviewOverrides.empty
        more.slotKeyed[key] = ExerciseWaveOverride(setsByWeek: Array(repeating: 6, count: template.totalWeeks))
        XCTAssertGreaterThanOrEqual(side(PlannedVolume.weeklyHardSets(template: template, overrides: more)), side(base))
        XCTAssertNotEqual(side(PlannedVolume.weeklyHardSets(template: template, overrides: more)), side(base), "\(e.exerciseId)")
    }

    func test_swappingAnExerciseMovesVolumeBetweenMuscles() throws {
        let (key, e) = try XCTUnwrap(slot(containing: "bench_press"))
        let base = PlannedVolume.weeklyHardSets(template: template, overrides: nil)
        var swap = PreviewOverrides.empty
        swap.slotKeyed[key] = ExerciseWaveOverride(substituteExerciseId: "leg_extension")
        let swapped = PlannedVolume.weeklyHardSets(template: template, overrides: swap)
        func avg(_ r: PlannedVolume.Result, _ m: FineMuscle) -> Double { r.rows.first { $0.muscle == m }!.average }
        XCTAssertLessThan(avg(swapped, .chest), avg(base, .chest), e.exerciseId)
        XCTAssertGreaterThan(avg(swapped, .quads), avg(base, .quads))
        XCTAssertEqual(avg(swapped, .hamstrings), avg(base, .hamstrings), accuracy: 1e-9, "unrelated muscles do not move")
    }

    // MARK: Unmapped

    func test_unmappedCustomSetsAreCounted_andMappingThemCreditsAMuscle() throws {
        let custom = CustomExercise(id: "custom_unmapped", name: "Odd Machine", primaryMuscleRaw: "chest", isCompound: false)
        let day = try XCTUnwrap(template.dayTemplates.first)
        var overrides = PreviewOverrides.empty
        overrides.addExercise(AddedExercise(id: "add1", exerciseId: custom.id, priority: .standard,
                                            wavePrescriptions: AddedExercise.defaultWavePrescriptions, setsByWeek: Array(repeating: 3, count: template.totalWeeks)),
                              toDay: day.id)
        let result = PlannedVolume.weeklyHardSets(template: template, overrides: overrides, customs: [custom])
        let nonDeloadWeeks = result.averagedWeeks
        XCTAssertEqual(result.unmappedSets, 3 * nonDeloadWeeks, "3 sets in each non-deload week, in no muscle")
        XCTAssertEqual(result.unmapped.first?.name, "Odd Machine")
        XCTAssertTrue(result.unmapped.first?.isEditable == true)
        let before = PlannedVolume.weeklyHardSets(template: template, overrides: nil).rows.first { $0.muscle == .chest }!.average

        custom.fineMuscleRaw = "chest"
        let mapped = PlannedVolume.weeklyHardSets(template: template, overrides: overrides, customs: [custom])
        XCTAssertEqual(mapped.unmappedSets, 0)
        XCTAssertEqual(mapped.rows.first { $0.muscle == .chest }!.average, before + 3, accuracy: 1e-9)
    }

    // MARK: Last block

    func test_noPreviousBlock_meansNoComparisonColumn() throws {
        let planned = PlannedVolume.weeklyHardSets(template: template, overrides: nil)
        let engine = AnalyticsEngine(sessions: [])
        XCTAssertNil(LastBlockComparison.source(snapshot: engine.snapshot, customs: [], profile: nil, asOf: date(2027, 1, 1), activeMesoKey: nil))
        let model = PlannedVolumeCardModel(planned: planned, last: nil)
        XCTAssertFalse(model.hasComparison)
        XCTAssertTrue(model.rows.allSatisfy { $0.lastBlock == nil })
    }

    func test_theActiveBlockIsTheComparison_onceItHasTwoCompleteWeeks_elseTheLatestCompletedBlock() throws {
        let ctx = try makeContext()
        let old = try seed(ctx, start: date(2025, 9, 1), name: "Old", status: .archived)
        // Active block: one complete week so far.
        let active = try seed(ctx, start: date(2026, 1, 5), name: "Active", status: .active, completeWeeks: 1)
        func source() throws -> LastBlockComparison.Source? {
            let engine = AnalyticsEngine(sessions: try ctx.fetch(FetchDescriptor<Session>()))
            return LastBlockComparison.source(snapshot: engine.snapshot, customs: [], profile: nil, asOf: date(2026, 1, 14),
                                              activeMesoKey: LastBlockComparison.key(for: active))
        }
        let fallback = try XCTUnwrap(try source())
        XCTAssertFalse(fallback.isActive, "one complete week is not enough: the latest completed block")
        XCTAssertEqual(fallback.blockName, "Old")
        XCTAssertEqual(LastBlockComparison.key(for: old), try XCTUnwrap(fallback.summary.rows.first).muscle == .chest ? LastBlockComparison.key(for: old) : "")

        // Three complete weeks of the active block, counted by Meso Summary's exclusions.
        for s in active.sessions where s.weekIndex <= 3 {
            for i in s.items { i.actualReps = Array(repeating: max(1, i.targetReps), count: i.targetSets); i.actualLoads = Array(repeating: 100, count: i.targetSets); i.actualRIRs = Array(repeating: 2, count: i.targetSets) }
            s.status = .completed; s.completedAt = s.date
        }
        try ctx.save()
        let engine = AnalyticsEngine(sessions: try ctx.fetch(FetchDescriptor<Session>()))
        let chosen = try XCTUnwrap(LastBlockComparison.source(snapshot: engine.snapshot, customs: [], profile: nil, asOf: date(2026, 2, 1),
                                                              activeMesoKey: LastBlockComparison.key(for: active)))
        XCTAssertTrue(chosen.isActive)
        XCTAssertEqual(chosen.blockName, "Active")
        // Exactly Meso Summary's numbers.
        let direct = MuscleVolume.summary(snapshot: engine.snapshot, customs: [], profile: nil, asOf: date(2026, 2, 1),
                                          mesoKey: LastBlockComparison.key(for: active), wholeBlock: true)
        XCTAssertEqual(chosen.summary.rows.map(\.average), direct.rows.map(\.average))
        XCTAssertGreaterThanOrEqual(chosen.summary.averagedWeeks, 2)
    }

    // MARK: Card

    func test_cardModel_ordersBelowAndAboveFirst_andWritesTheSummaryLine() {
        // 10 sets of bench each week: chest 10 (within 10-20), triceps 5 (below 6), front delts 5 (within 0-10); the rest 0.
        var profile = UserProfile()
        let result = PlannedVolume.weeklyHardSets(weeks: [.init(isDeload: false, slots: [.init(exerciseId: "bench_press", sets: 10)])], profile: profile)
        let model = PlannedVolumeCardModel(planned: result, last: nil)
        XCTAssertEqual(model.rows.prefix(model.below.count).map(\.status), Array(repeating: .below, count: model.below.count))
        XCTAssertTrue(model.below.contains { $0.muscle == .triceps })
        XCTAssertTrue(model.summaryLine.hasPrefix("\(model.below.count) muscles below range: "), model.summaryLine)
        XCTAssertTrue(model.summaryLine.contains("Triceps"))
        XCTAssertEqual(PlannedVolumeCardModel.footer, "Planned assumes every set is done. Last block shows what was actually done.")

        // Everything within the (widened) ranges: one calm line.
        var wide: [FineMuscle: MuscleSetRange] = [:]
        for m in FineMuscle.allCases { wide[m] = MuscleSetRange(min: 0, max: 100) }
        profile.muscleSetRanges = wide
        let calm = PlannedVolumeCardModel(planned: PlannedVolume.weeklyHardSets(weeks: [.init(isDeload: false, slots: [.init(exerciseId: "bench_press", sets: 10)])], profile: profile), last: nil)
        XCTAssertEqual(calm.summaryLine, "All muscles within range")
        XCTAssertEqual(PlannedVolumeCardModel(planned: PlannedVolume.weeklyHardSets(weeks: [.init(isDeload: false, slots: [.init(exerciseId: "bench_press", sets: 10)])]), last: nil).below.count > 0, true)
    }

    // MARK: Universality

    func test_noUserSpecificValues_inTheCalculationOrTheCard() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Domain/Analytics/PlannedVolume.swift", "Features/Programs/PlannedVolumeCard.swift"]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.contains("markcalabrese"), f)
            for id in ExerciseMuscleShares.table.keys { XCTAssertFalse(text.contains("\"\(id)\""), "\(f) names the exercise \(id)") }
            for m in FineMuscle.allCases { XCTAssertFalse(text.contains(".\(m.rawValue)"), "\(f) names the muscle \(m)") }
        }
        // The numbers come from the inputs alone: a different lifter's profile fields change nothing.
        let a = UserProfile(), b = UserProfile()
        b.bodyWeight = 123; b.experience = .new
        XCTAssertEqual(PlannedVolume.weeklyHardSets(template: template, overrides: nil, profile: a).rows.map(\.average),
                       PlannedVolume.weeklyHardSets(template: template, overrides: nil, profile: b).rows.map(\.average))
    }
}
