import XCTest
import SwiftData
@testable import ElitePerformance

/// Sections D–M — stubs only, per the test catalog's priority ordering
/// (N/A/B/C implemented first; everything else deferred).
///
/// IMPORTANT: the source prompt only gave concrete test-case IDs/descriptions
/// for a handful of cases in these sections (T-D.1 explicitly; T-D.2/T-D.3,
/// T-G.6, and T-K.4 only by reference from the OPEN QUESTIONS section). For
/// the remaining sections (E, F, H, I, J, L, M) no test catalog was provided
/// at all. Inventing fictional test-case numbers and descriptions for those
/// would be exactly the kind of guessing this whole exercise is trying to
/// avoid — so each of those classes contains one honest placeholder stub
/// saying so, instead of fabricated cases. A passing stub is a silent lie;
/// so is a fabricated one.

// MARK: - Section D — Meso phase bands, cluster lookup, RIR widening, ProgressionEngine

// Pinned from source recon (Domain/Models/Session.swift:445-459):
//   var mesoPhase: MesoPhase {
//       guard let total = meso?.totalWeeks, total > 0 else { return .early }
//       let pct = Double(weekIndex) / Double(total)
//       switch pct {
//       case ..<0.30: return .early
//       case ..<0.70: return .mid
//       case ..<0.90: return .late
//       default:      return .deload
//       }
//   }
// weekIndex is 1-based (Session.weekIndex getter defaults weekInMeso ?? 1).
// Boundary ownership is LOWER-INCLUSIVE / UPPER-EXCLUSIVE per band — i.e. the
// boundary value belongs to the UPPER/LATER band, not the lower one (the
// OPEN Q3 "lower-exclusive, upper-inclusive" recommendation was a guess and
// is the OPPOSITE of the real rule). For totalWeeks=10: pct==0.30 (week 3)
// -> .mid, pct==0.70 (week 7) -> .late, pct==0.90 (week 9) -> .deload.
// totalWeeks == nil (or no meso at all) -> falls back to .early, NOT
// `.unknown` — MesoPhase (Domain/Logic/ProgressionEngine.swift:26-31) has
// exactly 4 cases (early/mid/late/deload), no nil-safe case exists.
final class MesoPhaseBandTests: XCTestCase {

    private func session(weekIndex: Int, totalWeeks: Int?) -> Session {
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), status: .active, totalWeeks: totalWeeks)
        let s = Session(date: Date(), weekIndex: weekIndex, items: [])
        s.meso = meso
        return s
    }

    func test_D1_phaseBands() {
        // totalWeeks = 10: early <0.30, mid <0.70, late <0.90, deload >=0.90.
        XCTAssertEqual(session(weekIndex: 1, totalWeeks: 10).mesoPhase, .early)   // 0.10
        XCTAssertEqual(session(weekIndex: 2, totalWeeks: 10).mesoPhase, .early)   // 0.20
        XCTAssertEqual(session(weekIndex: 4, totalWeeks: 10).mesoPhase, .mid)     // 0.40
        XCTAssertEqual(session(weekIndex: 6, totalWeeks: 10).mesoPhase, .mid)     // 0.60
        XCTAssertEqual(session(weekIndex: 8, totalWeeks: 10).mesoPhase, .late)    // 0.80
        XCTAssertEqual(session(weekIndex: 9, totalWeeks: 10).mesoPhase, .deload)  // 0.90
        XCTAssertEqual(session(weekIndex: 10, totalWeeks: 10).mesoPhase, .deload) // 1.00
    }

    func test_D2_boundaryOwnership() {
        // Exact boundary values (30/70/90%) belong to the upper band, confirmed
        // via source — not a guess. Pinned: lower-inclusive, upper-exclusive
        // per band, so the boundary itself is owned by the band that STARTS
        // there, not the one that would otherwise end there.
        XCTAssertEqual(session(weekIndex: 3, totalWeeks: 10).mesoPhase, .mid, "pct==0.30 belongs to mid, not early")
        XCTAssertEqual(session(weekIndex: 7, totalWeeks: 10).mesoPhase, .late, "pct==0.70 belongs to late, not mid")
        XCTAssertEqual(session(weekIndex: 9, totalWeeks: 10).mesoPhase, .deload, "pct==0.90 belongs to deload, not late")
    }

    func test_D3_weekIndexBase() {
        // weekIndex is 1-based: week 1 of a standard meso is early, and the
        // last week (weekIndex == totalWeeks) is always deload (pct == 1.0).
        XCTAssertEqual(session(weekIndex: 1, totalWeeks: 10).mesoPhase, .early)
        XCTAssertEqual(session(weekIndex: 10, totalWeeks: 10).mesoPhase, .deload)
    }

    func test_D4_nilTotalWeeksFallsBackToEarlyNoCrash() {
        // No meso at all.
        let bare = Session(date: Date(), weekIndex: 5, items: [])
        XCTAssertEqual(bare.mesoPhase, .early)

        // Meso exists but totalWeeks is nil.
        XCTAssertEqual(session(weekIndex: 5, totalWeeks: nil).mesoPhase, .early)
    }

    func test_D5_BUG_phaseContradictsIsDeloadWeekAtLateBand() {
        // For the literal final week, the two signals DO agree:
        let lastWeek = session(weekIndex: 10, totalWeeks: 10)
        XCTAssertEqual(lastWeek.mesoPhase, .deload)
        XCTAssertTrue(lastWeek.isDeloadWeek)

        // BUG CONFIRMED: for totalWeeks == 10 (the value used by every DUP
        // template in this codebase — PPL3Week, UpperLower4Day, FullBody2Day,
        // Hybrid5Day, PPL6Day, DUP10Week all use totalWeeks: 10), week 9 has
        // mesoPhase == .deload (pct == 0.90, hits the deload band) but
        // isDeloadWeek == false (isDeloadWeek requires weekIndex == totalWeeks
        // exactly, i.e. only week 10 — see Session.swift:439-442). The two
        // signals contradict for the most common meso length in the app, not
        // just an obscure edge case. Do not fix here, flag for next task.
        let week9 = session(weekIndex: 9, totalWeeks: 10)
        XCTAssertEqual(week9.mesoPhase, .deload, "sanity: week 9 of 10 is in the deload phase band")
        XCTAssertTrue(week9.isDeloadWeek, "BUG CONFIRMED: mesoPhase says .deload but isDeloadWeek says false for week 9 of a 10-week meso — the two signals must agree and currently don't")
    }

    // MARK: - T-D.6/7/8: ProgramExerciseTemplate.sets(forWeek:wave:) — confirmed
    // live via ProgramTemplateResolver.resolveDay (Features/Programs/
    // DUPWaveModels.swift:330), not dead code.

    private func wavePrescription(setMin: Int) -> WavePrescription {
        WavePrescription(wave: .a, setMin: setMin, setMax: setMin + 2, repMin: 8, repMax: 12, targetRIRMin: 2, targetRIRMax: 3)
    }

    func test_D6_setRampWrittenPerWeek() {
        // setsByWeek index 0 = week 1. Deload entry (index 4 = week 5) is reduced.
        let template = ProgramExerciseTemplate(
            id: "ex1", order: 1, exerciseId: "bench_press", priority: .standard,
            prescriptions: [wavePrescription(setMin: 3)],
            setsByWeek: [3, 3, 4, 4, 2]
        )
        XCTAssertEqual(template.sets(forWeek: 1, wave: .a), 3)
        XCTAssertEqual(template.sets(forWeek: 3, wave: .a), 4)
        XCTAssertEqual(template.sets(forWeek: 5, wave: .a), 2, "deload week's set count should be the reduced ramp value")
    }

    func test_D7_arrayShorterThanTotalWeeksFallsBackToPrescriptionDefault() {
        // CORRECTED PREMISE: source does NOT clamp to the last array entry.
        // ProgramExerciseTemplate.sets(forWeek:wave:) (DUPWaveModels.swift:213-218):
        // if the index is out of bounds it falls through entirely to
        // `prescription(for: wave)?.defaultSetCount ?? 3`, where
        // defaultSetCount == setMin (WavePrescription.swift:255) — a value
        // that has nothing to do with the array's last entry. Use a
        // prescription default (5) that's deliberately different from the
        // array's last entry (4) so a wrongly-clamping implementation would
        // be distinguishable from the real fallback-to-default behavior.
        let template = ProgramExerciseTemplate(
            id: "ex1", order: 1, exerciseId: "bench_press", priority: .standard,
            prescriptions: [wavePrescription(setMin: 5)],
            setsByWeek: [3, 4] // only 2 entries
        )
        XCTAssertEqual(template.sets(forWeek: 1, wave: .a), 3, "in-bounds index still reads the array")
        XCTAssertEqual(template.sets(forWeek: 5, wave: .a), 5, "out-of-bounds index falls back to the wave's defaultSetCount (setMin), not the array's last entry (4)")
    }

    func test_D8_programIntentNotContaminatedByManualSessionEdit() {
        // sets(forWeek:) is a pure function of the static template — it has
        // no awareness of a live SessionItem.targetSets a user edited on a
        // specific prior session. Confirm the lookup is stateless: same
        // template + week always returns the same answer regardless of
        // unrelated SessionItem mutations.
        let template = ProgramExerciseTemplate(
            id: "ex1", order: 1, exerciseId: "bench_press", priority: .standard,
            prescriptions: [wavePrescription(setMin: 3)],
            setsByWeek: [3, 4, 4]
        )
        let before = template.sets(forWeek: 2, wave: .a)

        // Simulate a user's one-off manual extra set on an unrelated SessionItem.
        let manualEdit = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 4, targetRIR: 2, suggestedLoad: 100)
        manualEdit.targetSets = 99

        let after = template.sets(forWeek: 2, wave: .a)
        XCTAssertEqual(before, 4)
        XCTAssertEqual(after, before, "the template's per-week ramp must not be affected by an unrelated SessionItem's manual edit")
    }
}

// Pinned from source recon (Domain/Models/ExerciseCatalog.swift:1141-1261 and
// Domain/Logic/ProgressionEngine.swift):
//   - ExerciseCluster has exactly 5 cases: primaryChestPress, secondaryPressOrArms,
//     primaryLeg, pumpIsolation, lowBackStability.
//   - cluster(for:)'s switch ends in `default: return nil` — unknown/custom
//     IDs get nil, NOT a fallback cluster. "Safe default" in the catalog's
//     description means "no crash, nil", not "sensible fallback case".
//   - No old view-layer switch duplicating this mapping was found anywhere
//     else in source (grepped every cluster-case name app-wide) — the parity
//     check in T-D.9 is N/A; ExerciseCatalog.cluster(for:) is the only mapping.
//   - actualRIRs on SessionItem is declared `[Int]` (Session.swift:233), so a
//     fractional RIR like 1.5 can never reach toSetSnapshots() in the first
//     place — there's no "truncation" possible at this layer, just a correct
//     Int -> Double widen. The originally-suspected bug doesn't exist here.
//   - ProgressionEngine.suggestNext has no "neutral config" concept anywhere
//     in source. It's wired into CoachingEngine.recommend (CoachingEngine.swift
//     :108-120) as `progressionDecision`, consulted ONLY at increase branches,
//     ONLY when `decision.action == .increaseLoad`, to override the numeric
//     step (capped at loadSanityCap = baseLoad * 2.0). The two engines use
//     independent RIR-target sources (item.targetRIR for CoachingEngine's own
//     gating vs. ChestArmsLowBackMesoProfile's baseTargetRIR for
//     ProgressionEngine's), so "parity" means: when both independently land
//     on increase, the numeric load step matches — not that the two engines
//     share config.
final class ExerciseClusterAndProgressionTests: XCTestCase {

    func test_D9_clusterLookup() {
        XCTAssertEqual(ExerciseCatalog.cluster(for: "bench_press"), .primaryChestPress, "known compound")
        XCTAssertEqual(ExerciseCatalog.cluster(for: "ez_bar_curl"), .pumpIsolation, "known isolation")
        XCTAssertNil(ExerciseCatalog.cluster(for: "totally_unknown_custom_exercise_id_12345"), "unknown/custom id -> nil, no crash, no fallback case")
    }

    func test_D10_clusterAwareStep() {
        let compoundStep = ChestArmsLowBackMesoProfile.config(for: .primaryChestPress).primaryLoadIncrement
        let isolationStep = ChestArmsLowBackMesoProfile.config(for: .pumpIsolation).primaryLoadIncrement
        XCTAssertEqual(compoundStep, 5.0)
        XCTAssertEqual(isolationStep, 2.5)
        XCTAssertGreaterThan(compoundStep, isolationStep)
    }

    func test_D11_toSetSnapshotsWidensIntRIRWithoutTruncation() {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 100)
        item.actualReps = [8]
        item.actualLoads = [100]
        item.actualRIRs = [2] // Int at the model layer — 1.5 is not representable here.

        let snapshots = item.toSetSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].rir, 2.0, "Int(2) widens to Double(2.0) exactly — no precision loss possible for an already-integral source value")
    }

    func test_D12_progressionEngineParityWithCoachingEngineIncreaseStep() throws {
        // bench_press -> .primaryChestPress: repRange 6...10, baseTargetRIR 2.5,
        // primaryLoadIncrement 5.0, allowSetIncrease true, maxSets 6.
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
            repMin: 6, repMax: 10
        )
        item.actualReps = [10, 10, 10]
        item.actualLoads = [100, 100, 100]
        item.actualRIRs = [3, 3, 3]
        item.plannedRepsBySet = [10, 10, 10]

        // Independently run ProgressionEngine with the same inputs CoachingEngine
        // would derive (cluster config for bench_press, phase .early).
        let cluster = try XCTUnwrap(ExerciseCatalog.cluster(for: "bench_press"))
        let config = ChestArmsLowBackMesoProfile.config(for: cluster)
        let progressionResult = ProgressionEngine.suggestNext(
            history: item.toSetSnapshots(),
            currentSets: item.targetSets,
            config: config,
            phase: .early
        )
        XCTAssertEqual(progressionResult.action, .increaseLoad, "sanity: avgRIR 3.0 >= effectiveTargetRIR(2.5)+0.3 and bestReps(10) >= repRange.upperBound(10)")
        XCTAssertEqual(progressionResult.nextLoad, 105.0, "100 base + 5.0 primaryLoadIncrement")

        // CoachingEngine independently lands on its own "extra reserve" increase
        // branch here (avgRIR 3.0 > item.targetRIR(2)+0.5), and at that branch it
        // defers to progressionDecision.nextLoad since the action is .increaseLoad.
        let coachResult = CoachingEngine.recommend(for: item, mesoPhase: .early)
        XCTAssertEqual(coachResult?.nextSuggestedLoad, progressionResult.nextLoad, "when both engines independently agree on increase, CoachingEngine's load step must equal ProgressionEngine's nextLoad (capped at loadSanityCap, not hit here)")
        XCTAssertEqual(coachResult?.nextSuggestedLoad, 105.0)
    }
}

// MARK: - Section E — Meso anchoring and MesoPerformanceAnalyzer

final class MesoAnchoringAndAnalyzerTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private let cal = Calendar.current

    func test_E1_anchorsFromPreviousPeakNotZero() throws {
        let context = try makeContext()
        let priorMeso = MesoBlock(name: "Prior Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(priorMeso)

        for daysAgo in [50, 43, 36] {
            let historyItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
            historyItem.actualReps = [8, 8, 8]
            historyItem.actualLoads = [185, 185, 185]
            historyItem.actualRIRs = [2, 2, 2]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [historyItem])
            s.meso = priorMeso
            context.insert(s)
        }
        try context.save()

        let newItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        let newMeso = MesoBlock(name: "New Meso", startDate: Date(), status: .active, totalWeeks: 10)
        let newSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [newItem])
        newSession.meso = newMeso
        context.insert(newMeso)
        context.insert(newSession)
        try context.save()

        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: newMeso, context: context)

        XCTAssertGreaterThan(newItem.suggestedLoad, 0, "must anchor from the 185-load history, not stay at the seeded 0")
    }

    func test_E2_rirAdjustedStartIsBelowRawPeakLoad() throws {
        // Peak achieved at load 300 x 5 reps -> e1RM = 300 * (1 + 5/30) = 350.
        // New meso targets the same 5 reps but at RIR 3 (more conservative).
        // E1RMCalculator.load(for:reps:targetRIR:) applies rirFactor = 1 - RIR*0.025,
        // so the back-calculated load is necessarily below the raw 300 peak.
        let context = try makeContext()
        let priorMeso = MesoBlock(name: "Prior Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(priorMeso)

        for daysAgo in [50, 43, 36] {
            let historyItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 5, targetSets: 1, targetRIR: 1, suggestedLoad: 300)
            historyItem.actualReps = [5]
            historyItem.actualLoads = [300]
            historyItem.actualRIRs = [1]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [historyItem])
            s.meso = priorMeso
            context.insert(s)
        }
        try context.save()

        let newItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 5, targetSets: 1, targetRIR: 3, suggestedLoad: 0)
        let newMeso = MesoBlock(name: "New Meso", startDate: Date(), status: .active, totalWeeks: 10)
        let newSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [newItem])
        newSession.meso = newMeso
        context.insert(newMeso)
        context.insert(newSession)
        try context.save()

        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: newMeso, context: context)

        XCTAssertGreaterThan(newItem.suggestedLoad, 0)
        XCTAssertLessThan(newItem.suggestedLoad, 300, "RIR 3 target must back off from the raw 300 peak load")
        XCTAssertEqual(newItem.suggestedLoad, 277.5, accuracy: 0.01, "(350 e1RM / (1+5/30)) * (1 - 3*0.025) = 300 * 0.925 = 277.5")
    }

    func test_E3_BUG_peakIncludesWarmupSets() throws {
        // BUG CONFIRMED: MesoPerformanceAnalyzer.analyze has NO warmup-exclusion
        // filter of any kind (confirmed via direct source read — every set with
        // load > 0 && reps > 0 contributes to sessionPeak via plain max()).
        // A genuine working top set (300 x 5, e1RM 350) and a low-load/high-rep
        // set (140 x 50, e1RM 140*(1+50/30) = 373.33) in the same session: the
        // high-rep set's e1RM exceeds the true working set's under the plain
        // Epley formula used here, and the analyzer has nothing to stop it from
        // winning. Do not fix here, flag for next task.
        let context = try makeContext()
        let meso = MesoBlock(name: "Meso", startDate: Date(), status: .active, totalWeeks: 8)
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 5, targetSets: 2, targetRIR: 2, suggestedLoad: 300)
        item.actualReps = [50, 5]
        item.actualLoads = [140, 300]
        item.actualRIRs = [5, 2]
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [item])
        session.meso = meso
        context.insert(meso)
        context.insert(session)
        try context.save()

        let analysis = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
        let benchSummary = try XCTUnwrap(analysis.exerciseSummaries.first { $0.exerciseId == "bench_press" })

        XCTAssertEqual(benchSummary.peakE1RM ?? 0, 350.0, accuracy: 0.01, "BUG CONFIRMED: peak should reflect the true 300x5 working set (e1RM 350), not the low-load/high-rep set's inflated e1RM (373.33) — analyzer has no warmup filter")
    }

    func test_E4_BUG_verdictContaminatedByTrailingDeloadSession() throws {
        // BUG CONFIRMED: MesoPerformanceAnalyzer.analyze has NO deload-exclusion
        // of any kind (confirmed via direct source read — completedSessions is
        // every `.completed` session in the block, no waveRaw/isDeloadWeek
        // filtering anywhere in this file). The verdict is first-vs-last e1RM
        // delta (see T-E.6/T-E.8 pin below); if the meso's last completed
        // session happens to be a deload week, its necessarily-lower load
        // becomes "last" and can flip a genuinely progressing meso to a false
        // "declining" verdict. Do not fix here, flag for next task.
        let context = try makeContext()
        let meso = MesoBlock(name: "Meso", startDate: Date(), status: .active, totalWeeks: 10)

        func makeSession(daysAgo: Int, week: Int, load: Double, waveRaw: String?) -> Session {
            let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 5, targetSets: 1, targetRIR: 2, suggestedLoad: load, waveRaw: waveRaw)
            item.actualReps = [5]
            item.actualLoads = [load]
            item.actualRIRs = [2]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: week, items: [item])
            s.meso = meso
            return s
        }

        // Genuine progression across two working weeks (e1RM 233.3 -> 280, +20%),
        // then a deload week with a much lighter load (e1RM 175) tacked on the end.
        let week1 = makeSession(daysAgo: 20, week: 1, load: 200, waveRaw: "a")
        let week5 = makeSession(daysAgo: 10, week: 5, load: 240, waveRaw: "a")
        let week10Deload = makeSession(daysAgo: 1, week: 10, load: 150, waveRaw: "deload")

        for s in [week1, week5, week10Deload] { context.insert(s) }
        context.insert(meso)
        try context.save()

        let analysis = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
        let benchSummary = try XCTUnwrap(analysis.exerciseSummaries.first { $0.exerciseId == "bench_press" })

        XCTAssertEqual(benchSummary.verdict, .progressing, "BUG CONFIRMED: the working-week trend (200 -> 240, +20%) is genuinely progressing, but the unfiltered deload session (150) lands as 'last' and the first-vs-last delta swings negative instead")
    }

    func test_E5_consecutiveCleanCountTracksStreakAndResetsOnPain() throws {
        let context = try makeContext()
        var sessions: [Session] = []
        for daysAgo in [30, 20, 10] {
            let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 100)
            item.actualReps = [8]
            item.actualLoads = [100]
            item.actualRIRs = [2]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [item])
            sessions.append(s)
            context.insert(s)
        }
        try context.save()

        XCTAssertEqual(
            LoadProjectionService.consecutiveCleanCount(exerciseId: "bench_press", waveRaw: nil, repMin: 8, allSessions: sessions),
            3,
            "three clean same-exercise sessions in a row"
        )

        // Most recent session (yesterday) has a pain flag — breaks the streak immediately.
        let painItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 100,
                                    setFeedbackBySet: [SetFeedback.pain.rawValue])
        painItem.actualReps = [8]
        painItem.actualLoads = [100]
        painItem.actualRIRs = [2]
        let painSession = Session(date: cal.date(byAdding: .day, value: -1, to: Date())!, status: .completed, weekIndex: 2, items: [painItem])
        context.insert(painSession)
        try context.save()

        let allSessions = sessions + [painSession]
        XCTAssertEqual(
            LoadProjectionService.consecutiveCleanCount(exerciseId: "bench_press", waveRaw: nil, repMin: 8, allSessions: allSessions),
            0,
            "the pain flag on the most recent session must reset the streak to 0, even though 3 clean sessions precede it"
        )
    }

    func test_E6_analyzerVerdictThresholds() throws {
        // CORRECTED PREMISE: the guard is `e1rmBySession.count >= 2 else { return .insufficient }`
        // (MesoPerformanceAnalyzer.swift:248) — insufficient means FEWER THAN 2
        // sessions, i.e. exactly 1. Two sessions is enough to produce a real
        // verdict, not insufficient as the catalog assumed.
        let context = try makeContext()

        func analyze(loads: [Double]) throws -> ExerciseVerdict {
            let meso = MesoBlock(name: "Meso \(loads)", startDate: Date(), status: .active, totalWeeks: 8)
            var daysAgo = loads.count * 10
            for (idx, load) in loads.enumerated() {
                let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 5, targetSets: 1, targetRIR: 2, suggestedLoad: load)
                item.actualReps = [5]
                item.actualLoads = [load]
                item.actualRIRs = [2]
                let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: idx + 1, items: [item])
                s.meso = meso
                context.insert(s)
                daysAgo -= 10
            }
            context.insert(meso)
            try context.save()
            let analysis = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
            return try XCTUnwrap(analysis.exerciseSummaries.first { $0.exerciseId == "bench_press" }).verdict
        }

        XCTAssertEqual(try analyze(loads: [100]), .insufficient, "exactly 1 session -> insufficient")
        XCTAssertEqual(try analyze(loads: [100, 130]), .progressing, "exactly 2 sessions with a clear +30% gain is enough for a real verdict, NOT insufficient")
        XCTAssertEqual(try analyze(loads: [100, 100, 100]), .plateaued, "flat e1RM across 3 sessions")
        XCTAssertEqual(try analyze(loads: [150, 130, 100]), .declining, "strictly decreasing e1RM across 3 sessions")
    }

    func test_E7_analyzerExcludesOrphanUUID_butNotDeload() throws {
        // Two halves, kept in one test because they share a fixture and
        // demonstrate the same file's inconsistent handling:
        // 1) Orphan exerciseId (not in catalog, no exerciseNameSnapshot) IS
        //    correctly excluded from exerciseSummaries (MesoPerformanceAnalyzer
        //    .swift:266-267 `guard catalog != nil || snapshotName != nil else { continue }`).
        // 2) Deload sessions are NOT excluded from anything in this file — see
        //    test_E4_BUG above. Asserted again here narrowly: the deload item's
        //    own exercise still produces a verdict drawn from the deload data,
        //    confirming no exclusion happened.
        let context = try makeContext()
        let meso = MesoBlock(name: "Meso", startDate: Date(), status: .active, totalWeeks: 8)

        let orphanItem = SessionItem(order: 1, exerciseId: "00000000-aaaa-bbbb-cccc-111111111111", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 100)
        orphanItem.actualReps = [8]
        orphanItem.actualLoads = [100]
        orphanItem.actualRIRs = [2]
        // No exerciseNameSnapshot set -> not in catalog AND no name fallback.

        let deloadItem = SessionItem(order: 2, exerciseId: "machine_hip_thrust", targetReps: 10, targetSets: 1, targetRIR: 3, suggestedLoad: 150, waveRaw: "deload")
        deloadItem.actualReps = [10]
        deloadItem.actualLoads = [150]
        deloadItem.actualRIRs = [3]

        let s = Session(date: Date(), status: .completed, weekIndex: 1, items: [orphanItem, deloadItem])
        s.meso = meso
        context.insert(meso)
        context.insert(s)
        try context.save()

        let analysis = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))

        XCTAssertNil(analysis.exerciseSummaries.first { $0.exerciseId == ExerciseCatalog.canonicalExerciseId(for: "00000000-aaaa-bbbb-cccc-111111111111") }, "orphan UUID with no name snapshot must be excluded from per-exercise summaries")
        XCTAssertNotNil(analysis.exerciseSummaries.first { $0.exerciseId == "machine_hip_thrust" }, "BUG CONFIRMED (same root cause as T-E.4): the deload-flagged item is NOT excluded — it still produces a normal exercise summary as if it were a regular working session")
    }

    func test_E8_verdictUsesFirstVsLastDeltaNotARegressionSlope() throws {
        // CORRECTED PREMISE: there is no "net slope" computation anywhere in
        // MesoPerformanceAnalyzer — verdict is purely
        // delta = (e1rmBySession.last - e1rmBySession.first) / e1rmBySession.first
        // (MesoPerformanceAnalyzer.swift:249-254). A noisy up/down/up sequence
        // still resolves correctly here, but only because the middle value is
        // structurally irrelevant to a first-vs-last comparison — not because
        // the analyzer is doing any real trend/slope analysis. A sequence
        // where the noisy middle is the true peak and last is below first
        // would NOT be "progressing" by this rule even if a real regression
        // slope might disagree; that's out of scope here, just documenting
        // the real mechanism.
        let context = try makeContext()
        let meso = MesoBlock(name: "Meso", startDate: Date(), status: .active, totalWeeks: 8)
        let loads: [Double] = [100, 80, 115] // up -> down -> up, last(115) > first(100)
        var daysAgo = 30
        for (idx, load) in loads.enumerated() {
            let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 5, targetSets: 1, targetRIR: 2, suggestedLoad: load)
            item.actualReps = [5]
            item.actualLoads = [load]
            item.actualRIRs = [2]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: idx + 1, items: [item])
            s.meso = meso
            context.insert(s)
            daysAgo -= 10
        }
        context.insert(meso)
        try context.save()

        let analysis = try XCTUnwrap(MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []))
        let summary = try XCTUnwrap(analysis.exerciseSummaries.first { $0.exerciseId == "bench_press" })

        XCTAssertEqual(summary.verdict, .progressing, "first(100) vs last(115) is +15%, clears the +3% progressing threshold regardless of the dip in between")
    }

    func test_E9_performanceGatedMesoStart_notYetImplemented() {
        // Grepped for 0.95/0.90/0.85 multipliers tied to ExerciseVerdict-gated
        // meso starting loads anywhere in source — none exist.
        // MesoPerformanceAnalyzer.analyze is only ever consumed by
        // MesoSummaryView (a read-only display screen); its verdict never
        // feeds into ProgramGenerator.anchorLoadsForNewMeso or any other
        // anchoring/seeding path. This is a roadmap item, not a shipped
        // feature — per the source prompt's own rule, stub honestly rather
        // than fabricate a test against code that doesn't exist.
        XCTFail("Function not yet implemented — no verdict-gated meso-start multiplier exists anywhere in source")
    }

    func test_E10_firstEverMesoNoPriorBlockNoCrash() throws {
        let context = try makeContext()
        let newItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        let newMeso = MesoBlock(name: "Onboarding Meso", startDate: Date(), status: .active, totalWeeks: 10)
        let newSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [newItem])
        newSession.meso = newMeso
        context.insert(newMeso)
        context.insert(newSession)
        try context.save()

        // No prior sessions exist anywhere in this context at all.
        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: newMeso, context: context)

        XCTAssertEqual(newItem.suggestedLoad, 0, "no history anywhere -> stays at the seeded 0, same as normal first-session behavior; must not crash")
    }
}

// MARK: - Section F

final class SectionFStubTests: XCTestCase {
    func test_F_noCatalogProvided() {
        XCTFail("Not yet implemented — stub (no catalog provided for Section F)")
    }
}

// MARK: - Section G — Volume auto-regulation

final class VolumeAutoRegulationStubTests: XCTestCase {
    func test_G6_accumulatedSorenessDoesNotYetChangeSetCounts() {
        // T-G.6: per OPEN Q5, accumulated soreness does NOT yet change set
        // counts as a baseline/ongoing behavior — confirm intentionally inert.
        // Note: PlanMemoryEngine.volumeRegulationSignal (confirmed via recon
        // while building Section B/N) DOES reduce set count by 1 after 2+
        // recent fatigue-flagged sessions (see LoadWriteTests.test_B7). Whether
        // that's the same "accumulated soreness" this case means, or a
        // different/longer-horizon signal that's still a no-op, needs to be
        // confirmed before this can be implemented for real.
        XCTFail("Not yet implemented — stub")
    }
}

// MARK: - Section H

final class SectionHStubTests: XCTestCase {
    func test_H_noCatalogProvided() {
        XCTFail("Not yet implemented — stub (no catalog provided for Section H)")
    }
}

// MARK: - Section I

final class SectionIStubTests: XCTestCase {
    func test_I_noCatalogProvided() {
        XCTFail("Not yet implemented — stub (no catalog provided for Section I)")
    }
}

// MARK: - Section J

final class SectionJStubTests: XCTestCase {
    func test_J_noCatalogProvided() {
        XCTFail("Not yet implemented — stub (no catalog provided for Section J)")
    }
}

// MARK: - Section K — referenced alongside the post-restore seeding bug

final class SectionKStubTests: XCTestCase {
    func test_K4_placeholder() {
        // T-K.4: referenced in OPEN Q1 alongside T-B.6/T-N.12 (post-restore
        // seeding fidelity) but no further Section K detail was given.
        XCTFail("Not yet implemented — stub")
    }
}

// MARK: - Section L

final class SectionLStubTests: XCTestCase {
    func test_L_noCatalogProvided() {
        XCTFail("Not yet implemented — stub (no catalog provided for Section L)")
    }
}

// MARK: - Section M

final class SectionMStubTests: XCTestCase {
    func test_M_noCatalogProvided() {
        XCTFail("Not yet implemented — stub (no catalog provided for Section M)")
    }
}
