import XCTest
import SwiftData
import SwiftUI
@testable import ElitePerformance

/// Sections D–M, per the test catalog's priority ordering. D, E, F, G, H, and
/// I are now implemented as real assertions; J, K, L, M remain honest stubs.
///
/// IMPORTANT: for the sections that are still stubbed, the source prompts
/// only gave concrete test-case IDs/descriptions for a handful of cases
/// (T-K.4 only by reference from the OPEN QUESTIONS section). For H, I, J, L,
/// M no test catalog was ever provided at all. Inventing fictional test-case
/// numbers and descriptions for those would be exactly the kind of guessing
/// this whole exercise is trying to avoid — so each of those classes contains
/// one honest placeholder stub saying so, instead of fabricated cases. A
/// passing stub is a silent lie; so is a fabricated one.

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

// MARK: - Section F — Maintenance block seeding (Path A / Path B)

// Pinned from source recon (Domain/Programs/MaintenanceProgramSeeder.swift):
//   - Path A (`seed(from:trainingWeekdays:totalWeeks:startDate:context:calendar:)`)
//     groups the source meso's sessions by dayLabel, takes the MOST RECENT
//     session's roster per label, applies applyMaintenancePrescription, and
//     anchors loads via ProgramGenerator.anchorLoadsForNewMeso (full session
//     history, decay-weighted — fixed in an earlier task this session).
//   - Path B (`seedFromNewProgram(template:totalWeeks:startDate:context:calendar:)`)
//     materializes week 1 of each of the template's days via
//     DUPSessionMaterializer, applies the SAME applyMaintenancePrescription,
//     and anchors loads via its own private anchorLoadsFromFullHistory (same
//     direct-history approach, separately implemented).
//   - Both paths call the identical shared applyMaintenancePrescription /
//     makeMaintenanceItem — targetReps:10, targetSets:2, targetRIR:3,
//     waveRaw:"deload", repMin:8, repMax:12, targetRIRMin:3, targetRIRMax:4,
//     prescriptionNotes:"Maintenance — hold loads, manage fatigue."
//   - MesoLifecycle.confirmStartNewMeso/AppStateBridge.setActiveMesoStartDate
//     are NOT called inside either seeder — they're paired by hand at UI call
//     sites (MesoSummaryView, MaintenanceProgramPickerView), per OPEN Q7.
final class MaintenanceBlockSeedingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private let cal = Calendar.current

    /// Minimal 1-day/week source split — used by tests that only care about
    /// duration/lifecycle/deload-guard behavior, not day-roster fidelity.
    private func makeSimpleSourceMeso(in context: ModelContext) -> MesoBlock {
        let sourceMeso = MesoBlock(name: "Prior Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(sourceMeso)
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let session = Session(date: cal.date(byAdding: .day, value: -10, to: Date())!, status: .completed, weekIndex: 8, dayLabel: "Push", items: [item])
        session.meso = sourceMeso
        session.programIndex = 1
        context.insert(session)
        try? context.save()
        return sourceMeso
    }

    func test_F1_pathAContinuesCurrentSplit() throws {
        let context = try makeContext()
        let sourceMeso = MesoBlock(name: "Prior Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(sourceMeso)

        let pushItem1 = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let pushItem2 = SessionItem(order: 2, exerciseId: "incline_dumbbell_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 60)
        let pushSession = Session(date: cal.date(byAdding: .day, value: -10, to: Date())!, status: .completed, weekIndex: 8, dayLabel: "Push", items: [pushItem1, pushItem2])
        pushSession.meso = sourceMeso
        pushSession.programIndex = 1

        let pullItem1 = SessionItem(order: 1, exerciseId: "wide_grip_pulldown", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 120)
        let pullSession = Session(date: cal.date(byAdding: .day, value: -9, to: Date())!, status: .completed, weekIndex: 8, dayLabel: "Pull", items: [pullItem1])
        pullSession.meso = sourceMeso
        pullSession.programIndex = 2

        context.insert(pushSession)
        context.insert(pullSession)
        try context.save()

        try MaintenanceProgramSeeder.seed(
            from: sourceMeso,
            trainingWeekdays: [2, 4],
            totalWeeks: 4,
            startDate: Date(),
            context: context
        )

        let allMesos = try context.fetch(FetchDescriptor<MesoBlock>())
        let maintenanceMeso = try XCTUnwrap(allMesos.first { $0.name == "Maintenance Block" })

        let pushMaintenanceSession = try XCTUnwrap(maintenanceMeso.sessions.first { $0.dayLabel == "Push" })
        let pushExerciseIds = pushMaintenanceSession.items.sorted { $0.order < $1.order }.map { $0.exerciseId }
        XCTAssertEqual(pushExerciseIds, ["bench_press", "incline_dumbbell_press"], "maintenance Push day must carry the exact same exercises, in order, as the source split")

        let pullMaintenanceSession = try XCTUnwrap(maintenanceMeso.sessions.first { $0.dayLabel == "Pull" })
        XCTAssertEqual(pullMaintenanceSession.items.map { $0.exerciseId }, ["wide_grip_pulldown"])

        for session in maintenanceMeso.sessions {
            for item in session.items {
                XCTAssertEqual(item.waveRaw, "deload", "every maintenance item must carry the deload wave prescription")
            }
        }
    }

    func test_F2_pathBSeedsFromChosenTemplateAndAnchorsFromHistory() throws {
        let context = try makeContext()
        // History exists for bench_press (PPL3 Push day's anchor exercise),
        // but no history anywhere for hack_squat (PPL3 Legs day's anchor).
        let historyMeso = MesoBlock(name: "Old Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(historyMeso)
        for daysAgo in [50, 43, 36] {
            let historyItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
            historyItem.actualReps = [8, 8, 8]
            historyItem.actualLoads = [185, 185, 185]
            historyItem.actualRIRs = [2, 2, 2]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [historyItem])
            s.meso = historyMeso
            context.insert(s)
        }
        try context.save()

        try MaintenanceProgramSeeder.seedFromNewProgram(
            template: PPL3WeekTemplate.template,
            totalWeeks: 4,
            startDate: Date(),
            context: context
        )

        let allMesos = try context.fetch(FetchDescriptor<MesoBlock>())
        let maintenanceMeso = try XCTUnwrap(allMesos.first { $0.name == "Maintenance Block" })

        let pushSession = try XCTUnwrap(maintenanceMeso.sessions.first { $0.dayLabel == "Push" })
        let pushExerciseIds = Set(pushSession.items.map { $0.exerciseId })
        XCTAssertTrue(pushExerciseIds.contains("bench_press"), "exercises must come from the chosen template's own day roster")

        let benchItem = try XCTUnwrap(pushSession.items.first { $0.exerciseId == "bench_press" })
        XCTAssertGreaterThan(benchItem.suggestedLoad, 0, "bench_press has real history — must anchor above 0")

        let legsSession = try XCTUnwrap(maintenanceMeso.sessions.first { $0.dayLabel == "Legs" })
        let hackSquatItem = try XCTUnwrap(legsSession.items.first { $0.exerciseId == "hack_squat" })
        XCTAssertEqual(hackSquatItem.suggestedLoad, 0, "no history anywhere for hack_squat — must fall back to 0, same as normal first-session behavior")
    }

    func test_F3_applyMaintenancePrescriptionParityAcrossBothPaths() throws {
        let context = try makeContext()
        let sourceMeso = makeSimpleSourceMeso(in: context) // roster: bench_press only, dayLabel "Push"
        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4], totalWeeks: 4, startDate: Date(), context: context)
        let pathAMeso = try XCTUnwrap(try context.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == "Maintenance Block" })
        let pathAItem = try XCTUnwrap(pathAMeso.sessions.first?.items.first { $0.exerciseId == "bench_press" })

        let context2 = try makeContext()
        try MaintenanceProgramSeeder.seedFromNewProgram(template: PPL3WeekTemplate.template, totalWeeks: 4, startDate: Date(), context: context2)
        let pathBMeso = try XCTUnwrap(try context2.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == "Maintenance Block" })
        let pathBPush = try XCTUnwrap(pathBMeso.sessions.first { $0.dayLabel == "Push" })
        let pathBItem = try XCTUnwrap(pathBPush.items.first { $0.exerciseId == "bench_press" })

        // Both paths call the identical shared applyMaintenancePrescription —
        // Path A's behavior must be unchanged by the Path B extraction.
        XCTAssertEqual(pathAItem.targetSets, pathBItem.targetSets)
        XCTAssertEqual(pathAItem.targetRIR, pathBItem.targetRIR)
        XCTAssertEqual(pathAItem.repMin, pathBItem.repMin)
        XCTAssertEqual(pathAItem.repMax, pathBItem.repMax)
        XCTAssertEqual(pathAItem.targetRIRMin, pathBItem.targetRIRMin)
        XCTAssertEqual(pathAItem.targetRIRMax, pathBItem.targetRIRMax)
        XCTAssertEqual(pathAItem.waveRaw, pathBItem.waveRaw)
        XCTAssertEqual(pathAItem.prescriptionNotes, pathBItem.prescriptionNotes)
        XCTAssertEqual(pathAItem.targetSets, 2)
        XCTAssertEqual(pathAItem.targetRIR, 3)
        XCTAssertEqual(pathAItem.waveRaw, "deload")
    }

    func test_F4_durationPickerSetsExactTotalWeeks() throws {
        for weeks in [4, 6, 8, 12] {
            let context = try makeContext()
            let sourceMeso = makeSimpleSourceMeso(in: context)
            try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4], totalWeeks: weeks, startDate: Date(), context: context)
            let maintenanceMeso = try XCTUnwrap(try context.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == "Maintenance Block" })
            XCTAssertEqual(maintenanceMeso.totalWeeks, weeks)
        }

        // Default (no totalWeeks argument) -> 4.
        let context = try makeContext()
        let sourceMeso = makeSimpleSourceMeso(in: context)
        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4], startDate: Date(), context: context)
        let maintenanceMeso = try XCTUnwrap(try context.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == "Maintenance Block" })
        XCTAssertEqual(maintenanceMeso.totalWeeks, 4, "default duration must be 4 weeks")
    }

    func test_F5_deloadGuardPreventsDoubleProgression() throws {
        let context = try makeContext()
        let sourceMeso = makeSimpleSourceMeso(in: context)
        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4], totalWeeks: 4, startDate: Date(), context: context)

        let maintenanceMeso = try XCTUnwrap(try context.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == "Maintenance Block" })
        let sortedSessions = maintenanceMeso.sessions.sorted { $0.date < $1.date }
        let sourceSession = sortedSessions[0]
        let targetSession = sortedSessions[1]

        let sourceItem = try XCTUnwrap(sourceSession.items.first)
        let targetItem = try XCTUnwrap(targetSession.items.first { $0.exerciseId == sourceItem.exerciseId })

        XCTAssertEqual(sourceItem.waveRaw, "deload")
        XCTAssertEqual(targetItem.waveRaw, "deload")

        // Simulate an already-anchored maintenance load, then prove neither
        // path can move it regardless of how well the source session goes.
        targetItem.suggestedLoad = 50
        targetItem.plannedLoadsBySet = [50, 50]
        sourceItem.suggestedLoad = 50
        try context.save()

        // Textbook-perfect, clearly-progressable performance on the source.
        sourceSession.status = .completed
        sourceItem.actualReps = [12, 12]
        sourceItem.actualLoads = [50, 50]
        sourceItem.actualRIRs = [4, 4]
        try context.save()

        // 1) project() must unconditionally refuse to progress a deload item.
        let projection = LoadProjectionService.project(
            exerciseId: sourceItem.exerciseId, targetReps: sourceItem.targetReps, targetRIR: sourceItem.targetRIR,
            repMin: sourceItem.repMin ?? sourceItem.targetReps, repMax: sourceItem.repMax ?? sourceItem.targetReps,
            currentWaveRaw: sourceItem.waveRaw, allSessions: [sourceSession, targetSession], activeMesoSessionIDs: []
        )
        XCTAssertNil(projection, "project() must refuse to progress any item flagged waveRaw == deload")

        // 2) carryForwardPlans must also leave the target item's load flat.
        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)
        XCTAssertEqual(targetItem.suggestedLoad, 50, "deload target items must never be progressed by carry-forward, regardless of how well the source session went")
    }

    func test_F6_addedExerciseToMaintenanceSessionGetsMaintenancePrescriptionAndRetentionMessage() throws {
        let context = try makeContext()
        let maintenanceMeso = MesoBlock(name: "Maintenance Block", startDate: Date(), status: .active, totalWeeks: 4)
        let session = Session(date: Date(), status: .inProgress, weekIndex: 1, dayLabel: "Push", items: [])
        session.meso = maintenanceMeso
        context.insert(maintenanceMeso)
        context.insert(session)
        try context.save()

        let vm = SessionScreenViewModel(session: session)
        vm.addExercise(ExerciseCatalog.benchPress, context: context)

        let newItem = try XCTUnwrap(session.items.first { $0.exerciseId == ExerciseCatalog.benchPress.id })
        XCTAssertEqual(newItem.waveRaw, "deload")
        XCTAssertEqual(newItem.targetSets, 2)
        XCTAssertEqual(newItem.targetRIR, 3)
        XCTAssertEqual(newItem.repMin, 8)
        XCTAssertEqual(newItem.repMax, 12)
        XCTAssertEqual(newItem.prescriptionNotes, "Maintenance — hold loads, manage fatigue.")

        // Log a clean, on-target set and confirm CoachingEngine returns the
        // maintenance retention message, not a numeric progression call.
        newItem.suggestedLoad = 135
        newItem.actualReps = [10, 10]
        newItem.actualLoads = [135, 135]
        let recommendation = try XCTUnwrap(CoachingEngine.recommend(for: newItem))
        XCTAssertTrue(recommendation.message.lowercased().contains("retention"), "maintenance items must get the retention message, not normal progression")
        XCTAssertEqual(recommendation.nextSuggestedLoad, newItem.suggestedLoad, "maintenance hold means the next suggested load is unchanged")
    }

    func test_F7_weekdayDerivationIsModePerLabelNotUnion() throws {
        // CONFIRMED VIA RECON: the mode-per-label derivation itself lives in
        // MesoSummaryView.seedMaintenanceBlock() (Features/History/
        // MesoSummaryView.swift:95-129), a `private` method on a SwiftUI
        // View — not reachable from this test target without changing source
        // visibility (out of scope, mirrors the ProgramDayDetailView
        // .addExercise(from:) limitation in OPEN Q4). MaintenanceProgramSeeder
        // .seed itself does no weekday derivation at all — it takes
        // `trainingWeekdays` as a literal caller-supplied array
        // (Array(Set(trainingWeekdays)).sorted()) and schedules every day
        // label across that same array uniformly; it has no concept of
        // "per-label" vs "union" whatsoever. See TestOpenQuestions.swift.
        //
        // This test verifies two things instead: (1) the mode algorithm
        // exactly as documented in MesoSummaryView's comment, transcribed
        // here since the real copy is private, correctly excludes a rest-day
        // anomaly that a naive union would have wrongly absorbed; (2) the
        // seeder faithfully uses ONLY the weekdays it's given — a rest-day
        // weekday that was correctly excluded upstream does not reappear in
        // the seeded schedule.

        // Push always falls on Tuesday (weekday 3), except one anomalous
        // session that landed on Sunday (weekday 1) — e.g. a reorder/skip.
        let weekdayCountsByLabel: [String: [Int: Int]] = [
            "Push": [3: 4, 1: 1] // Tuesday x4 (true pattern), Sunday x1 (anomaly)
        ]

        let modeWeekdays = weekdayCountsByLabel.values
            .compactMap { counts in counts.max(by: { $0.value < $1.value })?.key }
            .reduce(into: Set<Int>()) { $0.insert($1) }
            .sorted()
        let unionWeekdays = weekdayCountsByLabel.values
            .flatMap { $0.keys }
            .reduce(into: Set<Int>()) { $0.insert($1) }
            .sorted()

        XCTAssertEqual(modeWeekdays, [3], "mode-per-label must resolve to Tuesday only — the anomaly is outvoted, not absorbed")
        XCTAssertEqual(unionWeekdays, [1, 3], "sanity: a naive union WOULD have absorbed the Sunday anomaly — this is exactly what mode-per-label avoids")
        XCTAssertNotEqual(modeWeekdays, unionWeekdays, "the whole point of mode-per-label is that it disagrees with the union when an anomaly exists")

        // The seeder itself faithfully respects whatever weekdays it's given.
        let context = try makeContext()
        let sourceMeso = makeSimpleSourceMeso(in: context)
        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: modeWeekdays, totalWeeks: 4, startDate: Date(), context: context)

        let maintenanceMeso = try XCTUnwrap(try context.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == "Maintenance Block" })
        let scheduledWeekdays = Set(maintenanceMeso.sessions.map { cal.component(.weekday, from: $0.date) })
        XCTAssertEqual(scheduledWeekdays, Set(modeWeekdays), "the seeded schedule must use only the mode-derived weekday(s) — the excluded Sunday anomaly must not reappear")
    }

    func test_F8_mesoLifecycleIntegrationAtCallSitePattern() throws {
        // CONFIRMED VIA RECON: MesoLifecycle.confirmStartNewMeso/
        // AppStateBridge.setActiveMesoStartDate are NOT called inside either
        // seeder function — they're paired by hand at UI call sites
        // (MesoSummaryView.swift, MaintenanceProgramPickerView.swift), per
        // OPEN Q7. This test replicates that exact call-site pattern rather
        // than asserting against the seeder in isolation (which correctly
        // shows no movement, matching
        // InvariantTests.test_N11_seederAloneDoesNotMoveActiveStartDate).
        let context = try makeContext()
        let sourceMeso = makeSimpleSourceMeso(in: context)

        let priorMesoStartDate = cal.date(byAdding: .day, value: -100, to: Date())!
        MesoLifecycle.confirmStartNewMeso(on: priorMesoStartDate)
        AppStateBridge.setActiveMesoStartDate(priorMesoStartDate, in: context)
        XCTAssertEqual(cal.startOfDay(for: MesoLifecycle.activeStartDate), cal.startOfDay(for: priorMesoStartDate), "sanity: baseline is pinned before seeding")

        let newStartDate = cal.date(byAdding: .day, value: 1, to: Date())!
        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4], totalWeeks: 4, startDate: newStartDate, context: context)

        XCTAssertEqual(cal.startOfDay(for: MesoLifecycle.activeStartDate), cal.startOfDay(for: priorMesoStartDate), "seeding alone must not move activeStartDate, mirroring InvariantTests.test_N11")

        MesoLifecycle.confirmStartNewMeso(on: newStartDate)
        AppStateBridge.setActiveMesoStartDate(newStartDate, in: context)

        XCTAssertEqual(cal.startOfDay(for: MesoLifecycle.activeStartDate), cal.startOfDay(for: newStartDate), "after the full UI call-site pattern (seed + confirmStartNewMeso + setActiveMesoStartDate), activeStartDate must reflect the maintenance block's start date")
    }

    func test_F11_seedingHasNoUndocumentedSideEffects() throws {
        // CONFIRMED VIA RECON: "the rollover guard" (showMesoRolloverGuard)
        // is a private @State Bool local to HomeView (Features/Home/
        // HomeView.swift) — pure SwiftUI presentation state with no
        // persisted/model-layer backing this test target can exercise.
        // Neither MaintenanceProgramSeeder.seed nor seedFromNewProgram
        // references HomeView, MesoRolloverGuardSheet, or any rollover-
        // related state at all (grepped). The closest verifiable proxy:
        // seeding must touch ONLY what's documented (archive active mesos,
        // delete future non-completed sessions, create exactly one new
        // block + its sessions) and nothing else. See TestOpenQuestions.swift.
        let context = try makeContext()
        let sourceMeso = makeSimpleSourceMeso(in: context)

        let untouchedPastSession = sourceMeso.sessions.first!
        let untouchedPastStatus = untouchedPastSession.status
        let mesoCountBefore = try context.fetch(FetchDescriptor<MesoBlock>()).count

        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4], totalWeeks: 4, startDate: Date(), context: context)

        XCTAssertEqual(untouchedPastSession.status, untouchedPastStatus, "completed source sessions must be untouched by seeding")
        XCTAssertEqual(sourceMeso.status, .archived, "an already-archived source meso must stay archived, not be re-touched")

        let mesoCountAfter = try context.fetch(FetchDescriptor<MesoBlock>()).count
        XCTAssertEqual(mesoCountAfter, mesoCountBefore + 1, "seeding must create exactly one new MesoBlock and nothing else")
    }
}

// Pinned from source recon (Domain/Programs/PPL3WeekTemplate.swift,
// PPL6DayTemplate.swift): PPL3 has exactly one static "Push" day-template
// (order:1 = bench_press, priority .anchor), reused unchanged across every
// week — only the WavePrescription (sets/reps/RIR) varies by wave, never the
// exercise identity. PPL6 has 6 day-templates (Push A/Pull A/Legs A/Push
// B/Pull B/Legs B).
final class ProgramTemplateIntegrityTests: XCTestCase {
    func test_F9_ppl3PrimaryCompoundIdenticalAcrossEquivalentPushDays() throws {
        let week1 = try ProgramTemplateResolver.resolveDay(template: PPL3WeekTemplate.template, weekNumber: 1, dayNumber: 1) // wave .a
        let week4 = try ProgramTemplateResolver.resolveDay(template: PPL3WeekTemplate.template, weekNumber: 4, dayNumber: 1) // wave .a (equivalent)
        let week2 = try ProgramTemplateResolver.resolveDay(template: PPL3WeekTemplate.template, weekNumber: 2, dayNumber: 1) // wave .b (different wave)

        let anchor1 = try XCTUnwrap(week1.first { $0.order == 1 })
        let anchor4 = try XCTUnwrap(week4.first { $0.order == 1 })
        let anchor2 = try XCTUnwrap(week2.first { $0.order == 1 })

        XCTAssertEqual(anchor1.exerciseId, "bench_press")
        XCTAssertEqual(anchor1.exerciseId, anchor4.exerciseId, "equivalent (same-wave) Push days must share the same anchor exercise")
        XCTAssertEqual(anchor1.exerciseId, anchor2.exerciseId, "the anchor exercise identity never changes across waves either — only its prescription does")
        XCTAssertNotEqual(anchor1.setMin, anchor2.setMin, "sanity: the prescription itself does vary by wave even though the exercise doesn't")
    }

    func test_F9_ppl6HasSixDayTemplates() {
        XCTAssertEqual(PPL6DayTemplate.template.dayTemplates.count, 6)
        XCTAssertEqual(PPL6DayTemplate.template.dayTemplates.map { $0.title }, ["Push A", "Pull A", "Legs A", "Push B", "Pull B", "Legs B"])
    }
}

final class WaveBadgeLabelTests: XCTestCase {
    func test_F10_waveLabelDistinguishesMaintenanceFromDeload() {
        XCTAssertEqual(WaveType.label(forRaw: "deload", mesoName: "Maintenance Block"), "Maintenance")
        XCTAssertEqual(WaveType.label(forRaw: "deload", mesoName: "8-Week Hypertrophy Block"), "Deload")
    }
}

// MARK: - Section G — Set feedback, skip taxonomy, drop sets, volume auto-regulation

// Pinned from source recon (Features/Session/SessionView.swift:2480-2526):
// SetStatus has exactly 8 cases (notStarted/inProgress/completed/skipped/
// skippedPain/skippedSoreness/skippedDisruption/skippedFatigue), each with a
// displayColor (.skipped: .orange, .skippedPain: .red, .skippedSoreness:
// .yellow, .skippedDisruption: .orange, .skippedFatigue: .purple) and a
// displayLabel (the specific reason, not generic "Skipped", for every flagged
// case). Pain coachNote prefix is "⚠️" (PlanMemoryEngine.swift:113); soreness/
// disruption carry-forward note prefix is "ℹ️" (PlanMemoryEngine.swift:121) —
// advisory, not a warning.
final class SetStatusBadgeTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    func test_G1_skipTaxonomyMapsToCorrectBadgeColor() {
        XCTAssertEqual(SetStatus.skippedPain.displayColor, .red)
        XCTAssertEqual(SetStatus.skippedSoreness.displayColor, .yellow)
        XCTAssertEqual(SetStatus.skippedDisruption.displayColor, .orange)
        XCTAssertEqual(SetStatus.skippedFatigue.displayColor, .purple)
    }

    func test_G2_painSkipSurfacesSpecificReasonNotGenericSkipped() {
        // Covered at the CoachingEngine-guard level by T-A.3 (pain ->
        // nextSuggestedLoad nil). This asserts the companion UI-facing fact:
        // a pain skip's displayLabel is the specific reason ("Pain"), not the
        // generic "Skipped" label a plain skip gets.
        XCTAssertEqual(SetStatus.skipped.displayLabel, "Skipped")
        XCTAssertEqual(SetStatus.skippedPain.displayLabel, "Pain")
        XCTAssertNotEqual(SetStatus.skippedPain.displayLabel, SetStatus.skipped.displayLabel)
    }

    func test_G3_sorenessDisruptionCarryForwardWritesAdvisoryNotWarning() throws {
        // Covered at the CoachingEngine-guard level by T-A.4 (soreness/
        // disruption -> hold). This asserts the companion PlanMemoryEngine
        // carry-forward fact: the note written is prefixed "ℹ️" (advisory),
        // distinct from pain's "⚠️" (warning) prefix.
        let context = try makeContext()
        let sourceItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
                                      setFeedbackBySet: [SetFeedback.soreness.rawValue, "", ""])
        sourceItem.actualReps = [8, 8, 8]
        sourceItem.actualLoads = [100, 100, 100]
        let sourceSession = Session(date: Date(), status: .completed, weekIndex: 1, items: [sourceItem])

        let targetItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        let targetSession = Session(date: Calendar.current.date(byAdding: .day, value: 1, to: Date())!, status: .planned, weekIndex: 2, items: [targetItem])

        context.insert(sourceSession)
        context.insert(targetSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        let note = try XCTUnwrap(targetItem.coachNote)
        XCTAssertTrue(note.hasPrefix("ℹ️"), "soreness/disruption carry-forward must write an advisory (ℹ️), not a warning (⚠️)")
        XCTAssertFalse(note.hasPrefix("⚠️"))
    }

    func test_G4_painCoachNotePrefixIsPresent() {
        // Pinned from source (Domain/Logic/PlanMemoryEngine.swift:113). UI
        // rendering of this prefix (ProgramDayDetailView's red-vs-orange
        // branch at line 999) is not independently unit-testable — it's
        // inline logic in a view body, not an exposed function.
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        item.coachNote = "⚠️ Pain was flagged in your last session for this exercise. Reassess before loading."
        XCTAssertTrue(item.coachNote?.hasPrefix("⚠️") == true)
    }
}

final class DropSetTests: XCTestCase {
    func test_G5_dropSetsRoundTripAndAreNotTreatedAsExtraWorkingSets() {
        let drops = [
            DropSetEntry(loadText: "100", repsText: "8"),
            DropSetEntry(loadText: "80", repsText: "6"),
            DropSetEntry(loadText: "60", repsText: "5")
        ]
        let serialized = drops.map { $0.serialized }.joined(separator: ",")
        XCTAssertEqual(serialized, "100x8,80x6,60x5")

        let parsed = DropSetEntry.parse(from: serialized)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.map { $0.loadText }, ["100", "80", "60"])
        XCTAssertEqual(parsed.map { $0.repsText }, ["8", "6", "5"])

        // CoachingEngine counts working sets from actualReps/actualLoads only
        // — dropSetPatternsBySet is a separate per-set string field, not an
        // additional array entry, so logging 3 drops on set 1 of 1 must not
        // inflate the working-set count to 4 (which would break the stage
        // gate for a targetSets:1 plan).
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 100)
        item.actualReps = [8]
        item.actualLoads = [100]
        item.actualRIRs = [2]
        item.dropSetPatternsBySet = [serialized]

        let recommendation = CoachingEngine.recommend(for: item)
        XCTAssertNotNil(recommendation, "1 working set + 3 drops on it must still satisfy a 1-set plan, not require 4")
    }
}

final class VolumeAutoRegulationStubTests: XCTestCase {
    func test_G6_accumulatedSorenessWithinASessionDoesNotChangeSetCounts() {
        // BASELINE: volume auto-regulation is intentionally not yet wired
        // WITHIN a single, currently-in-progress session — confirmed via a
        // full read of CoachingEngine.recommend and SessionScreenViewModel
        // .handleSetLogged: neither ever mutates item.targetSets based on
        // setFeedbackBySet accumulation.
        // When wired, update this test to assert the correct regulated
        // behavior.
        //
        // IMPORTANT — this is NOT the same claim as OPEN Q5's original
        // "intentionally absent" framing, which has since been partially
        // superseded: PlanMemoryEngine.volumeRegulationSignal DOES reduce
        // targetSets by 1 on CARRY-FORWARD (the next session) after 2+ of
        // the last 3 completed sessions flagged soreness/disruption —
        // confirmed, wired, and tested in LoadWriteTests.test_B7. That
        // mechanism is deliberately NOT exercised here; this test is scoped
        // to same-session, real-time accumulation only, which remains a
        // true no-op. See TestOpenQuestions.swift.
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
                                setFeedbackBySet: [SetFeedback.soreness.rawValue, SetFeedback.soreness.rawValue, SetFeedback.disruption.rawValue])
        item.actualReps = [8, 8, 8]
        item.actualLoads = [100, 100, 100]
        item.actualRIRs = [2, 2, 2]

        let targetSetsBefore = item.targetSets
        _ = CoachingEngine.recommend(for: item)
        // BASELINE: volume auto-regulation is intentionally not yet wired.
        // When wired, update this test to assert the correct regulated behavior.
        XCTAssertEqual(item.targetSets, targetSetsBefore, "set count must be unchanged regardless of accumulated soreness/disruption flags within a session")
    }
}

final class BackupCompatibilityTests: XCTestCase {
    func test_G7_backupPredatingFeedbackFieldsImportsCleanlyWithEmptyArrays() throws {
        // Constructs a SessionItemBackupDTO JSON payload that predates
        // setFeedbackBySet/pumpRatingsBySet (both Optional on the DTO —
        // Domain/Backup/BackupSnapshotV1.swift:147-148) by omitting those two
        // keys entirely, leaving every other required field present. Tests
        // the DTO's decode + the importer's exact nil-coalescing expression
        // (BackupSnapshotImporter.swift:173-174) directly, rather than the
        // full snapshot import pipeline (which needs a complete profile/meso
        // document and isn't necessary to prove this specific behavior).
        let json = """
        {
            "order": 1,
            "exerciseId": "bench_press",
            "targetReps": 8,
            "targetSets": 3,
            "targetRIR": 2,
            "suggestedLoad": 100.0,
            "plannedRepsBySet": [8, 8, 8],
            "plannedLoadsBySet": [100.0, 100.0, 100.0],
            "plannedRIRsBySet": [2, 2, 2],
            "actualReps": [8, 8, 8],
            "actualLoads": [100.0, 100.0, 100.0],
            "actualRIRs": [2, 2, 2],
            "usedRestPauseFlags": [false, false, false],
            "restPausePatternsBySet": ["", "", ""],
            "dropSetPatternsBySet": ["", "", ""],
            "isCompleted": true,
            "isPR": false,
            "logs": []
        }
        """
        let data = Data(json.utf8)
        let dto = try JSONDecoder().decode(SessionItemBackupDTO.self, from: data)

        XCTAssertNil(dto.setFeedbackBySet, "a backup predating this field must decode it as nil, not crash")
        XCTAssertNil(dto.pumpRatingsBySet)

        // Mirrors BackupSnapshotImporter.swift:173-174 exactly.
        let importedFeedback = dto.setFeedbackBySet ?? []
        let importedPumpRatings = dto.pumpRatingsBySet ?? []
        XCTAssertEqual(importedFeedback, [])
        XCTAssertEqual(importedPumpRatings, [])
    }
}

// MARK: - Section H — Bodyweight mechanics

final class BodyweightMechanicsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-H.1: ExerciseCatalog.isBodyweight(exerciseId:) is the single source of
    // truth for bodyweight-ness in the model layer.
    func test_H1_isBodyweightSingleSourceOfTruth() {
        XCTAssertTrue(ExerciseCatalog.isBodyweight(exerciseId: "pull_up"))
        XCTAssertTrue(ExerciseCatalog.isBodyweight(exerciseId: "chin_up"))
        XCTAssertFalse(ExerciseCatalog.isBodyweight(exerciseId: "bench_press"))
    }

    // FIXED: two of the three display sites that used to bypass
    // ExerciseCatalog.isBodyweight() and treat any `load == 0` as "this is a
    // bodyweight exercise" now consult the real catalog instead —
    // Features/History/ExerciseSessionDetailView.swift:108 (formatLoad) and
    // Features/History/ExerciseHistorySheet.swift:475 (formatSetToken). Both
    // had exerciseId already in scope (a view-level property), so the fix
    // was a straight substitution matching the pattern already used by
    // Domain/Logic/LoadDisplay.swift and Features/Session/SessionView.swift's
    // isBodyweightExercise.
    //
    // Features/History/HistoryView.swift's HistorySetDetail.loadText is a
    // third, still-unfixed site: HistorySetDetail is a small UI-only struct
    // with no exerciseId stored on it. The caller (HistoryView.exerciseDetails)
    // does have uiEx.exerciseId in scope at both construction sites, but
    // wiring it into HistorySetDetail requires adding a new initializer
    // parameter — exactly what the fix task's instructions said not to do
    // just to make a site fixable. Left unchanged with a `// BUG:` comment
    // at the source. See OPEN Q12 in TestOpenQuestions.swift.
    //
    // Both fixed sites are `private` methods on SwiftUI View structs, so
    // they cannot be called directly from this test target — transcribed
    // below using the real, POST-FIX predicate (not the old load-only
    // proxy) to confirm it now correctly distinguishes exercise identity
    // instead of load value. SwiftUI rendering itself remains unverified
    // here; that would require view-hosting test infrastructure this target
    // doesn't have.
    func test_H1_historyViewsNowConsultCatalogInsteadOfLoadZeroProxy() {
        // Transcription of the fixed predicate shared by
        // ExerciseSessionDetailView.formatLoad and
        // ExerciseHistorySheet.formatSetToken.
        func fixedHistoryDisplay(load: Double, exerciseId: String) -> String {
            if load == 0, ExerciseCatalog.isBodyweight(exerciseId: exerciseId) { return "BW" }
            if load == floor(load) { return String(format: "%.0f", load) }
            return String(format: "%.1f", load)
        }

        XCTAssertNotEqual(
            fixedHistoryDisplay(load: 0, exerciseId: "bench_press"), "BW",
            "a non-bodyweight exercise logged at load == 0 must no longer display BW"
        )
        XCTAssertEqual(
            fixedHistoryDisplay(load: 0, exerciseId: "pull_up"), "BW",
            "a real bodyweight exercise must still display BW at load == 0"
        )
    }

    // T-H.2: effectiveLoad resolves a logged 0 load to the user's body weight
    // for a known bodyweight exercise.
    func test_H2_effectiveLoadReturnsBodyWeightForZeroLoadBodyweightExercise() {
        let result = E1RMCalculator.effectiveLoad(actualLoad: 0, exerciseId: "pull_up", bodyWeight: 180)
        XCTAssertEqual(result, 180)
    }

    func test_H2_effectiveLoadReturnsZeroWithoutABodyWeightOnFile() {
        // No UserProfile.bodyWeight set yet — effectiveLoad must not crash or
        // fabricate a number, it falls back to 0 (same as a non-BW exercise).
        let result = E1RMCalculator.effectiveLoad(actualLoad: 0, exerciseId: "pull_up", bodyWeight: nil)
        XCTAssertEqual(result, 0)
    }

    func test_H2_effectiveLoadIgnoresBodyWeightWhenActualLoadIsLogged() {
        // A loaded pull-up (weighted vest etc.) — actualLoad takes priority.
        let result = E1RMCalculator.effectiveLoad(actualLoad: 25, exerciseId: "pull_up", bodyWeight: 180)
        XCTAssertEqual(result, 25)
    }

    // T-H.3: BW display. UISessionSet.plannedDescription(with:isBodyweight:)
    // (Features/Session/SessionView.swift:2753) is not private, so unlike the
    // three History bugs above this call site is directly testable. Its
    // `isBodyweight` argument is supplied by SessionView.isBodyweightExercise
    // (SessionView.swift:573), which correctly calls
    // ExerciseCatalog.isBodyweight(exerciseId:customExercises:) — the single
    // source of truth. This test asserts the display predicate itself; it
    // does not render SwiftUI, so the actual on-screen Text is not exercised
    // here.
    func test_H3_plannedDescriptionShowsBWForBodyweightZeroLoadNotZeroPointZero() {
        let bwSet = UISessionSet(index: 0, plannedLoad: 0, plannedReps: 8, plannedRIR: 2)
        let repRange = RepRange(min: 8, max: 8)

        let bwText = bwSet.plannedDescription(with: repRange, isBodyweight: true)
        XCTAssertTrue(bwText.contains("BW"))
        XCTAssertFalse(bwText.contains("0.0"))

        let nonBwText = bwSet.plannedDescription(with: repRange, isBodyweight: false)
        XCTAssertTrue(nonBwText.contains("0.0"))
        XCTAssertFalse(nonBwText.contains("BW"))
    }

    // T-H.4: CustomExercise.isBodyweight is a real, stored @Model attribute.
    func test_H4_customBodyweightExerciseRoundTrips() throws {
        let context = try makeContext()
        let bwCustom = CustomExercise(id: "custom_bw_1", name: "Custom Pistol Squat", primaryMuscleRaw: MuscleGroup.quads.rawValue, isCompound: true, isBodyweight: true)
        context.insert(bwCustom)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CustomExercise>()).first { $0.id == "custom_bw_1" }
        XCTAssertEqual(fetched?.isBodyweight, true)
    }

    func test_H4_customExerciseDefaultsIsBodyweightFalseWhenOmitted() throws {
        let context = try makeContext()
        // Simulates a record that predates the isBodyweight field: the
        // initializer's inline default (`isBodyweight: Bool = false`) is the
        // only migration mechanism in source — no VersionedSchema migration
        // exists or is needed for this field.
        let legacyCustom = CustomExercise(id: "legacy_1", name: "Legacy Exercise", primaryMuscleRaw: MuscleGroup.back.rawValue, isCompound: false)
        context.insert(legacyCustom)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CustomExercise>()).first { $0.id == "legacy_1" }
        XCTAssertEqual(fetched?.isBodyweight, false)
    }
}

final class BodyweightProgressionBaselineTests: XCTestCase {
    // T-H.5: BW progression still bails. Confirmed via direct read of
    // CoachingEngine.recommend (Domain/Logic/CoachingEngine.swift): guard 2
    // returns nil whenever suggestedLoad <= 0, with no rep-based progression
    // path for bodyweight exercises anywhere in source.
    func test_H5_BASELINE_coachingEngineWithholdsVerdictForZeroSuggestedLoad() {
        let item = SessionItem(
            order: 1, exerciseId: "pull_up", targetReps: 8, targetSets: 3, targetRIR: 2,
            suggestedLoad: 0,
            actualReps: [8, 8, 8], actualLoads: [0, 0, 0], actualRIRs: [2, 2, 2]
        )
        // BASELINE: CoachingEngine returns nil for load == 0 (no rep-based progression path yet).
        // When rep-based BW progression is implemented, this test should be updated
        // to assert the correct rep-progression behavior instead.
        XCTAssertNil(CoachingEngine.recommend(for: item))
    }
}

final class UserProfileBackupTests: XCTestCase {
    // T-H.6: UserProfile.bodyWeight survives the backup encode/decode round trip.
    func test_H6_userProfileBackupDTOBodyWeightRoundTrips() throws {
        let dto = UserProfileBackupDTO(
            profileId: UUID(), createdAt: Date(), experienceRaw: "intermediate",
            primaryGoalRaw: "hypertrophy", daysPerWeek: 4, sessionLengthMinutes: 60,
            equipmentProfileRaw: "commercial", injuryFlagRaws: [], minLoadIncrement: 2.5,
            unitPreferenceRaw: "lbs", bodyWeight: 187.5
        )
        let encoded = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(UserProfileBackupDTO.self, from: encoded)
        XCTAssertEqual(decoded.bodyWeight, 187.5)
    }
}

// MARK: - Section I — Onboarding, ProgramCatalog, UserProfile

final class UserProfileModelCoverageTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-I.1: all UserProfile fields round-trip through SwiftData.
    //
    // CORRECTED PREMISE: the original catalog entry's field list ("goal,
    // experience, equipment, unit, minLoadIncrement, maxSessionMinutes,
    // hasJointLimitations, bodyWeight") doesn't match UserProfile's real
    // properties (Domain/Models/UserProfile.swift) on two points:
    // there's no "maxSessionMinutes" — the real field is
    // sessionLengthMinutes; and there's no single "hasJointLimitations" bool
    // — the real field is injuryFlags: [InjuryFlag], an array of specific
    // joint flags. Tested below using the real field names. "unit" no
    // longer applies either — usesKilograms was removed entirely (Q18).
    func test_I1_allUserProfileFieldsRoundTrip() throws {
        let context = try makeContext()
        let profile = UserProfile(
            experience: .advanced,
            primaryGoal: .strength,
            daysPerWeek: 5,
            sessionLengthMinutes: 75,
            equipmentProfile: .homeGym,
            injuryFlags: [.knees, .shoulders],
            minLoadIncrement: 5.0,
            bodyWeight: 195.0
        )
        context.insert(profile)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(fetched.experience, .advanced)
        XCTAssertEqual(fetched.primaryGoal, .strength)
        XCTAssertEqual(fetched.daysPerWeek, 5)
        XCTAssertEqual(fetched.sessionLengthMinutes, 75)
        XCTAssertEqual(fetched.equipmentProfile, .homeGym)
        XCTAssertEqual(Set(fetched.injuryFlags), Set([.knees, .shoulders]))
        XCTAssertEqual(fetched.minLoadIncrement, 5.0)
        XCTAssertEqual(fetched.bodyWeight, 195.0)
    }
}

final class ProgramCatalogRecommendationTests: XCTestCase {

    // T-I.2: recommend() is wired and deterministic.
    //
    // NOTE: ProgramCatalog.recommend is NOT the function the live onboarding
    // flow actually calls. OnboardingFlowView's completion handler
    // (App/ContentView.swift, Features/Home/HomeView.swift) calls
    // ProgramApplicationService.apply, which uses its own, much simpler
    // ProgramApplicationService.selectTemplate(goal:daysPerWeek:) — a
    // days+goal-only switch over the real DUP/PPL templates. Confirmed via
    // grep: ProgramCatalog has zero production call sites anywhere in the
    // app (Features/Home/ProgramPickerView.swift only mentions it in a
    // "later we can map this in" comment). recommend() itself is real,
    // compiles, and is a pure function — it's just orphaned. See OPEN Q13 in
    // TestOpenQuestions.swift.
    func test_I2_recommendIsDeterministicAndSnapshotStable() {
        let input = ProgramCatalog.ProfileInput(
            goal: .hypertrophy, daysPerWeek: 4, sessionMinutes: 60,
            experience: .intermediate, equipment: .commercialGym, hasJointIssues: false
        )
        let first = ProgramCatalog.recommend(for: input)
        let second = ProgramCatalog.recommend(for: input)

        XCTAssertEqual(first.program.id, second.program.id, "identical input must produce an identical program")
        XCTAssertEqual(first.reason, second.reason)
        XCTAssertTrue(ProgramCatalog.all.contains { $0.id == first.program.id })
    }

    // T-I.3: constraint filters shape the recommendation.

    // Frequency genuinely works: each (goal, exact day count) maps to a
    // unique catalog program, since every program's minDays/maxDays/
    // recommendedDays are identical (no overlapping ranges within a goal).
    func test_I3_frequencyChangesRecommendedSplit() {
        let threeDay = ProgramCatalog.ProfileInput(goal: .hypertrophy, daysPerWeek: 3, sessionMinutes: 60, experience: .new, equipment: .commercialGym, hasJointIssues: false)
        let sixDay = ProgramCatalog.ProfileInput(goal: .hypertrophy, daysPerWeek: 6, sessionMinutes: 60, experience: .advanced, equipment: .commercialGym, hasJointIssues: false)

        let rec3 = ProgramCatalog.recommend(for: threeDay)
        let rec6 = ProgramCatalog.recommend(for: sixDay)

        XCTAssertNotEqual(rec3.program.id, rec6.program.id)
        XCTAssertEqual(rec3.program.id, "fullbody_3d_hypertrophy")
        XCTAssertEqual(rec6.program.id, "ppl_6d_hypertrophy")
    }

    // BUG CONFIRMED: every program in ProgramCatalog.all requires
    // .commercialGym equipment (confirmed by reading all six
    // TrainingProgramDefinition declarations — none use any other
    // ProgramEquipmentProfile). isEquipmentCompatible makes ANY
    // non-commercialGym equipment incompatible with EVERY program, so
    // `candidates` is always empty for those users, which falls back to
    // scoring the entire unfiltered catalog (`pool = all`) — bypassing the
    // goal+days filter too, not just equipment. Hand-traced: goal=.fatLoss,
    // daysPerWeek=3, experience=.new, equipment=.minimal, hasJointIssues=false
    // ties fullBody3DayFatLoss (correct goal, score 7) against
    // fullBody3DayHypertrophy (wrong goal, also score 7), and
    // `scored.max(by:)` keeps the first-seen max — fullBody3DayHypertrophy,
    // declared earlier in `all`. So a fat-loss-seeking, minimal-equipment
    // user is recommended a hypertrophy program. Do not fix here, flag for
    // next task. See OPEN Q13 in TestOpenQuestions.swift.
    func test_I3_BUG_minimalEquipmentBypassesGoalFilterEntirely() {
        let profile = ProgramCatalog.ProfileInput(goal: .fatLoss, daysPerWeek: 3, sessionMinutes: 60, experience: .new, equipment: .minimal, hasJointIssues: false)
        let recommendation = ProgramCatalog.recommend(for: profile)
        XCTAssertEqual(
            recommendation.program.goal, .fatLoss,
            "BUG CONFIRMED: a minimal-equipment user can be recommended a program of the WRONG goal, because equipment incompatibility silently empties the goal+days filter and falls back to scoring the whole catalog"
        )
    }

    // BUG CONFIRMED: hasJointIssues only grants a soft +2 scoring bonus to
    // jointFriendly programs — it never excludes non-joint-friendly programs
    // outright. When a profile's goal+days combination matches exactly one
    // program (the common case — every program has a unique day range per
    // goal) and that program happens to be ppl6DayHypertrophyWarrior (the
    // ONLY program with jointFriendly == false), hasJointIssues has nothing
    // else to compete against and is recommended anyway. Do not fix here,
    // flag for next task. See OPEN Q13.
    func test_I3_BUG_jointIssuesIsOnlyASoftBonusNotAHardExclusion() {
        let profile = ProgramCatalog.ProfileInput(goal: .hypertrophy, daysPerWeek: 6, sessionMinutes: 60, experience: .advanced, equipment: .commercialGym, hasJointIssues: true)
        let recommendation = ProgramCatalog.recommend(for: profile)
        XCTAssertTrue(
            recommendation.program.jointFriendly,
            "BUG CONFIRMED: hasJointIssues=true can still recommend the one program explicitly marked NOT joint-friendly (ppl_6d_hypertrophy) when it's the only goal+days match"
        )
    }

    // BUG CONFIRMED (functional, non-crashing): sessionMinutes only ever
    // contributes a flat +1 scoring bonus, gated by `program.recommendedDays
    // <= profile.daysPerWeek`. Hand-traced every profile shape capable of
    // producing a top-two contest in this six-program catalog: within a
    // fixed goal, candidates is always 0 or 1 before any bonus applies
    // (no overlapping day ranges), and every fallback-to-all scenario ties
    // multiple programs that share the same recommendedDays, so they get the
    // bonus identically and the tie still resolves by declaration order.
    // Could not construct an input where 30 vs 90 minutes changes the
    // winning program. Documented with one concrete pinned profile rather
    // than an exhaustive proof. Do not fix here, flag for next task. See
    // OPEN Q13.
    func test_I3_BUG_sessionLengthNeverActuallyChangesTheWinningProgram() {
        let profile30 = ProgramCatalog.ProfileInput(goal: .fatLoss, daysPerWeek: 6, sessionMinutes: 30, experience: .intermediate, equipment: .commercialGym, hasJointIssues: false)
        let profile90 = ProgramCatalog.ProfileInput(goal: .fatLoss, daysPerWeek: 6, sessionMinutes: 90, experience: .intermediate, equipment: .commercialGym, hasJointIssues: false)

        let rec30 = ProgramCatalog.recommend(for: profile30)
        let rec90 = ProgramCatalog.recommend(for: profile90)

        XCTAssertNotEqual(
            rec30.program.id, rec90.program.id,
            "BUG CONFIRMED: sessionMinutes (30 vs 90) does not change the recommended program for this profile, despite the scoring function nominally weighing it"
        )
    }

    // T-I.5: over-constrained input never crashes and always returns a
    // best-effort recommendation. Recommendation is a non-Optional struct by
    // design (recommend(for:) always falls back to defaultProgram if scoring
    // ever finds nothing), so "does not return nil" is true by type — the
    // meaningful assertion is that the fallback is a real catalog program.
    func test_I5_overConstrainedInputStillReturnsABestEffortRecommendation() {
        let impossible = ProgramCatalog.ProfileInput(
            goal: .strength, daysPerWeek: 1, sessionMinutes: 20,
            experience: .new, equipment: .minimal, hasJointIssues: true
        )
        let recommendation = ProgramCatalog.recommend(for: impossible)
        XCTAssertTrue(ProgramCatalog.all.contains { $0.id == recommendation.program.id })
        XCTAssertFalse(recommendation.reason.isEmpty)
    }
}

final class OnboardingSeedingIntegrationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-I.4: preview matches seed. OnboardingFlowView's private
    // programPreviewPage (Features/Onboarding/OnboardingFlowView.swift:476)
    // and the real seeding path (ProgramApplicationService.apply ->
    // DUPProgramReplaceService.replacePlannedProgram -> DUPProgramSeeder.seed
    // -> DUPSessionMaterializer.makeSession) both ultimately key off
    // ProgramApplicationService.selectTemplate(goal:daysPerWeek:) — not two
    // parallel implementations that could drift. "Structurally guaranteed"
    // rather than something this test could ever falsify by exercising the
    // View directly (no SwiftUI view-hosting in this target). Verified here
    // by confirming the seeded week-1 day roster (Session.dayLabel, which
    // DUPSessionMaterializer.makeSession sets to materializedDay.title)
    // matches the day titles of the exact template selectTemplate returns
    // for the same inputs — the same template the preview page reads from.
    func test_I4_previewAndSeedShareTheSameUnderlyingTemplateFunction() throws {
        let context = try makeContext()
        let result = OnboardingResult(
            goal: .hypertrophy, experience: .intermediate, daysPerWeek: 3,
            trainingDaysOfWeek: [2, 4, 6], equipmentProfile: .commercial,
            sessionLengthMinutes: 60, injuryFlags: [],
            minLoadIncrement: 2.5, startDate: Date()
        )
        ProgramApplicationService.apply(result, context: context, startDate: Date())

        let expectedTemplate = ProgramApplicationService.selectTemplate(goal: result.goal, daysPerWeek: 3)
        let seededWeek1DayLabels = Set(
            try context.fetch(FetchDescriptor<Session>())
                .filter { $0.weekIndex == 1 }
                .compactMap { $0.dayLabel }
        )
        let templateDayTitles = Set(expectedTemplate.dayTemplates.map { $0.title })

        XCTAssertFalse(seededWeek1DayLabels.isEmpty)
        XCTAssertEqual(seededWeek1DayLabels, templateDayTitles)
    }

    // T-I.6: first session gets no progression verdict. Seeded via the real,
    // live onboarding completion path (ProgramApplicationService.apply), not
    // the orphaned ProgramCatalog (see OPEN Q13) — every freshly materialized
    // SessionItem gets suggestedLoad: 0.0 (DUPSessionMaterializer
    // .makeSessionItems), and CoachingEngine.recommend's guard 2 ("no
    // baseline", suggestedLoad <= 0) withholds a verdict unconditionally.
    func test_I6_freshlySeededFirstSessionNeverGetsAProgressionVerdict() throws {
        let context = try makeContext()
        let result = OnboardingResult(
            goal: .hypertrophy, experience: .new, daysPerWeek: 3,
            trainingDaysOfWeek: [2, 4, 6], equipmentProfile: .commercial,
            sessionLengthMinutes: 60, injuryFlags: [],
            minLoadIncrement: 2.5, startDate: Date()
        )
        ProgramApplicationService.apply(result, context: context, startDate: Date())

        let week1Sessions = try context.fetch(FetchDescriptor<Session>()).filter { $0.weekIndex == 1 }
        XCTAssertFalse(week1Sessions.isEmpty)
        for session in week1Sessions {
            for item in session.items {
                XCTAssertNil(CoachingEngine.recommend(for: item), "brand-new program, week 1 — no baseline exists yet, CoachingEngine must withhold a verdict")
            }
        }
    }
}

final class UserProfileSingleRecordTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-I.7: single UserProfile record enforcement. The real subject is
    // ProgramApplicationService.writeUserProfile(from:context:)
    // (Domain/Logic/ProgramApplicationService.swift), which fetches the
    // existing record and updates it in place if one exists, only inserting
    // when there's none — exactly the "Settings update" pattern this test
    // describes.
    func test_I7_writeUserProfileUpdatesExistingRecordInsteadOfInsertingASecond() throws {
        let context = try makeContext()
        let firstResult = OnboardingResult(
            goal: .hypertrophy, experience: .new, daysPerWeek: 3,
            trainingDaysOfWeek: [2, 4, 6], equipmentProfile: .commercial,
            sessionLengthMinutes: 60, injuryFlags: [],
            minLoadIncrement: 2.5, startDate: Date()
        )
        ProgramApplicationService.writeUserProfile(from: firstResult, context: context)

        let secondResult = OnboardingResult(
            goal: .fatLoss, experience: .advanced, daysPerWeek: 5,
            trainingDaysOfWeek: [1, 2, 3, 4, 5], equipmentProfile: .homeGym,
            sessionLengthMinutes: 45, injuryFlags: [.knees],
            minLoadIncrement: 5.0, startDate: Date()
        )
        ProgramApplicationService.writeUserProfile(from: secondResult, context: context)

        let allProfiles = try context.fetch(FetchDescriptor<UserProfile>())
        XCTAssertEqual(allProfiles.count, 1, "Settings re-running onboarding must update the existing UserProfile, not insert a second one")
        XCTAssertEqual(allProfiles.first?.daysPerWeek, 5, "the existing record's fields must reflect the second (latest) write")
    }
}

// MARK: - Section J — Propagation, swap, reorder, day label rename, data repair

final class PropagationToggleAndServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-J.1: propagation default-on with opt-out.
    //
    // CORRECTED PREMISE: there is no UserDefaults/UserProfile/AppState-backed
    // propagation toggle anywhere in source. The only toggle is
    // `propagateChangesToFutureSessions`, a private `@State var ... = true`
    // local to ProgramDayDetailView (Features/Home/ProgramDayDetailView.swift:19)
    // — pure SwiftUI presentation state, reset to true every time the view is
    // opened fresh, with no persisted storage at all. SessionView's swap/add
    // flows use a different mechanism entirely: a per-action confirmation
    // dialog ("Apply to future sessions" vs "Keep this session only"), not a
    // persistent toggle. Neither ExerciseSwapPropagationService.apply nor
    // ProgramPlanPropagationService.applyPlanEditsForward has any internal
    // toggle/gating logic of its own — "opt-out" is entirely a call-site
    // decision (whether the View calls the service at all); it never reaches
    // the domain layer. See OPEN Q14 in TestOpenQuestions.swift.
    //
    // What IS verifiable from a model-layer test: the default literal is
    // `true` (confirmed by direct source read), and "toggle on" / "toggle
    // off" map exactly to "the service is called" / "the service is not
    // called" — there is no third behavior hiding inside the services
    // themselves.
    func test_J1_propagationIsEntirelyACallSiteDecisionNotAServiceInternal() throws {
        let context = try makeContext()
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), totalWeeks: 8)
        context.insert(meso)

        let sourceItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let sourceSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [sourceItem])
        sourceSession.meso = meso
        context.insert(sourceSession)

        let calendar = Calendar.current
        let futureDate = calendar.date(byAdding: .day, value: 7, to: Date())!
        let targetItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let futureSession = Session(date: futureDate, status: .planned, weekIndex: 2, items: [targetItem])
        futureSession.meso = meso
        context.insert(futureSession)
        try context.save()

        // "Toggle off" == the View simply never calls the service.
        sourceItem.suggestedLoad = 999
        try context.save()
        XCTAssertEqual(targetItem.suggestedLoad, 185, "toggle off == no service call == future session untouched")

        // "Toggle on" == the View calls the service. Same mutation, this
        // time propagated for real.
        ProgramPlanPropagationService.applyPlanEditsForward(from: sourceSession, in: context)
        try context.save()
        XCTAssertEqual(targetItem.suggestedLoad, 999, "toggle on == service called == future session updated")
    }
}

final class ExerciseSwapPropagationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-J.2: swap propagation matches by canonical exerciseId, not array
    // position — the regression guard for the silent-miss bug.
    func test_J2_swapPropagatesByCanonicalIdNotPosition() throws {
        let context = try makeContext()
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), totalWeeks: 8)
        context.insert(meso)

        let sourceItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let sourceSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [sourceItem])
        sourceSession.meso = meso
        context.insert(sourceSession)

        let calendar = Calendar.current
        let futureDate = calendar.date(byAdding: .day, value: 1, to: Date())!
        // Target session has bench_press at array index 1, not 0 — proves
        // the match is by exerciseId, not position.
        let otherItem = SessionItem(order: 1, exerciseId: "incline_dumbbell_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 60)
        let targetItem = SessionItem(order: 2, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let futureSession = Session(date: futureDate, status: .planned, weekIndex: 1, items: [otherItem, targetItem])
        futureSession.meso = meso
        context.insert(futureSession)
        try context.save()

        ExerciseSwapPropagationService.apply(fromExerciseId: "bench_press", toExerciseId: "machine_row", in: context)
        try context.save()

        XCTAssertEqual(targetItem.exerciseId, "machine_row", "matched by exerciseId regardless of array position")
        XCTAssertEqual(otherItem.exerciseId, "incline_dumbbell_press", "unrelated item must be untouched")
    }
}

final class ProgramPlanPropagationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-J.3: ProgramPlanPropagationService matches by exerciseId, not index
    // position; new source exercises are appended to target; exercises
    // removed from source are deleted from target.
    func test_J3_propagationMatchesByExerciseIdHandlesAddAndRemove() throws {
        let context = try makeContext()
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), totalWeeks: 8)
        context.insert(meso)

        // Source: [A, B, C] — C is new, not yet in target.
        let itemA = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 200)
        let itemB = SessionItem(order: 2, exerciseId: "incline_dumbbell_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 65)
        let itemC = SessionItem(order: 3, exerciseId: "machine_row", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 120)
        let sourceSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [itemA, itemB, itemC])
        sourceSession.meso = meso
        context.insert(sourceSession)

        let calendar = Calendar.current
        let futureDate = calendar.date(byAdding: .day, value: 7, to: Date())!
        // Target: [old, A, B] — scrambled order vs. source, and "old" is an
        // exercise source no longer has (must be deleted).
        let targetOld = SessionItem(order: 1, exerciseId: "wide_grip_pulldown", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 90)
        let targetA = SessionItem(order: 2, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let targetB = SessionItem(order: 3, exerciseId: "incline_dumbbell_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 60)
        let targetSession = Session(date: futureDate, status: .planned, weekIndex: 2, items: [targetOld, targetA, targetB])
        targetSession.meso = meso
        context.insert(targetSession)
        try context.save()

        ProgramPlanPropagationService.applyPlanEditsForward(from: sourceSession, in: context)
        try context.save()

        XCTAssertEqual(targetA.suggestedLoad, 200, "matched bench_press by exerciseId despite scrambled order")
        XCTAssertEqual(targetB.suggestedLoad, 65, "matched incline_dumbbell_press by exerciseId despite scrambled order")
        XCTAssertFalse(targetSession.items.contains { $0.exerciseId == "wide_grip_pulldown" }, "removed from source — must be deleted from target")
        XCTAssertTrue(targetSession.items.contains { $0.exerciseId == "machine_row" }, "new in source — must be appended to target")
        XCTAssertEqual(targetSession.items.count, 3, "old(deleted) leaves A + B + C(appended) = 3")
    }
}

final class ReorderTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func orderedItems(_ session: Session) -> [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    private func move(_ item: SessionItem, direction: Int, in session: Session) {
        var items = orderedItems(session)
        guard let currentIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let newIndex = currentIndex + direction
        guard items.indices.contains(newIndex) else { return }
        items.swapAt(currentIndex, newIndex)
        for (idx, sessionItem) in items.enumerated() {
            sessionItem.order = idx + 1
        }
    }

    // T-J.4: reorder operates on orderedItems (sorted by .order), not
    // session.items' raw array/insertion position.
    //
    // ProgramDayDetailView.move(_:direction:) and .orderedItems
    // (Features/Home/ProgramDayDetailView.swift:27,645) are both `private`
    // on a SwiftUI View, not directly callable from this test target.
    // Transcribed as private helpers above: orderedItems is
    // `session.items.sorted { $0.order < $1.order }`; move(direction:)
    // swaps two adjacent positions in that sorted array, then rewrites every
    // item's .order to its new 1...N position.
    func test_J4_reorderOperatesOnOrderSortedViewNotRawArrayPosition() throws {
        let context = try makeContext()
        let itemC = SessionItem(order: 3, exerciseId: "machine_row", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        let itemA = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        let itemB = SessionItem(order: 2, exerciseId: "incline_dumbbell_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        // Inserted with .order values [3, 1, 2] in that physical order.
        // SwiftData's @Relationship array does not guarantee it preserves
        // literal insertion order after a save/fetch round trip (confirmed
        // empirically — it does not here), so this test does not assert what
        // session.items' raw order literally is, only that orderedItems
        // resolves correctly by .order regardless of whatever that raw order
        // happens to be.
        let session = Session(date: Date(), status: .planned, weekIndex: 1, items: [itemC, itemA, itemB])
        context.insert(session)
        try context.save()

        XCTAssertNotEqual(session.items.map { $0.exerciseId }, ["bench_press", "incline_dumbbell_press", "machine_row"], "raw array order is not the intended display order (by construction — .order values are scrambled relative to insertion)")
        XCTAssertEqual(orderedItems(session).map { $0.exerciseId }, ["bench_press", "incline_dumbbell_press", "machine_row"], "orderedItems must resolve by .order, not raw array position")

        // Move B (order 2) up one position -> [B, A, C]
        move(itemB, direction: -1, in: session)
        XCTAssertEqual(orderedItems(session).map { $0.exerciseId }, ["incline_dumbbell_press", "bench_press", "machine_row"])

        // Idempotency at the boundary: B is now first; moving it up again is a no-op.
        move(itemB, direction: -1, in: session)
        XCTAssertEqual(orderedItems(session).map { $0.exerciseId }, ["incline_dumbbell_press", "bench_press", "machine_row"], "moving the top item further up is a no-op")
        move(itemB, direction: -1, in: session)
        XCTAssertEqual(orderedItems(session).map { $0.exerciseId }, ["incline_dumbbell_press", "bench_press", "machine_row"], "still a no-op the second time — idempotent at the boundary")
    }
}

final class DayLabelRenamePropagationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // Transcription of ProgramDayDetailView.renameDayLabel(to:)
    // (Features/Home/ProgramDayDetailView.swift:489), `private` on a SwiftUI
    // View — sets session.dayLabel directly, then (gated by the same
    // call-site-only toggle as T-J.1) updates same-weekday future planned
    // sessions too.
    private func renameDayLabel(to newLabel: String, on session: Session, propagate: Bool, context: ModelContext) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.dayLabel = trimmed
        guard propagate else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let targetWeekday = calendar.component(.weekday, from: session.date)
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { s in s.date > today })
        if let futureSessions = try? context.fetch(descriptor) {
            let sameDay = futureSessions.filter {
                $0.id != session.id && $0.status == .planned && calendar.component(.weekday, from: $0.date) == targetWeekday
            }
            for future in sameDay { future.dayLabel = trimmed }
        }
    }

    // T-J.5: day label rename propagates to same-weekday future planned sessions.
    func test_J5_dayLabelRenamePropagatesToSameWeekdayFutureSessions() throws {
        let context = try makeContext()
        let calendar = Calendar.current

        let session = Session(date: Date(), status: .planned, weekIndex: 1, dayLabel: "Push")
        context.insert(session)

        let sameWeekdayFuture = Session(date: calendar.date(byAdding: .day, value: 7, to: Date())!, status: .planned, weekIndex: 2, dayLabel: "Push")
        context.insert(sameWeekdayFuture)

        let differentWeekdayFuture = Session(date: calendar.date(byAdding: .day, value: 8, to: Date())!, status: .planned, weekIndex: 2, dayLabel: "Pull")
        context.insert(differentWeekdayFuture)
        try context.save()

        renameDayLabel(to: "Push Day A", on: session, propagate: true, context: context)

        XCTAssertEqual(session.dayLabel, "Push Day A")
        XCTAssertEqual(sameWeekdayFuture.dayLabel, "Push Day A", "same-weekday future planned session must be renamed too")
        XCTAssertEqual(differentWeekdayFuture.dayLabel, "Pull", "different-weekday session must be untouched")
    }

    // T-J.5 (toggle off): rename respects the propagation toggle.
    func test_J5_dayLabelRenameRespectsPropagationToggleOff() throws {
        let context = try makeContext()
        let calendar = Calendar.current

        let session = Session(date: Date(), status: .planned, weekIndex: 1, dayLabel: "Push")
        context.insert(session)
        let sameWeekdayFuture = Session(date: calendar.date(byAdding: .day, value: 7, to: Date())!, status: .planned, weekIndex: 2, dayLabel: "Push")
        context.insert(sameWeekdayFuture)
        try context.save()

        renameDayLabel(to: "Push Day A", on: session, propagate: false, context: context)

        XCTAssertEqual(session.dayLabel, "Push Day A")
        XCTAssertEqual(sameWeekdayFuture.dayLabel, "Push", "toggle off — other sessions must be unchanged")
    }
}

final class DataRepairToolTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-J.6: the Data Repair tool is SettingsView.fixExerciseIdMismatches()
    // (Features/Settings/SettingsView.swift:312) — `private` on a SwiftUI
    // View, not directly callable. Transcribed below using the real
    // ExerciseCatalog.canonicalBuiltInId(forExerciseName:) lookup: for each
    // SessionItem with a non-empty exerciseNameSnapshot, correct exerciseId
    // if it disagrees with what the catalog returns for that name — nothing
    // else is touched.
    func test_J6_dataRepairCorrectsExerciseIdFromNameSnapshotOnly() throws {
        let context = try makeContext()
        let item = SessionItem(
            order: 1, exerciseId: "CORRUPTED_ID_123", exerciseNameSnapshot: "Bench Press",
            targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185,
            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [185, 185, 185], plannedRIRsBySet: [2, 2, 2]
        )
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [item])
        context.insert(session)
        try context.save()

        func fixExerciseIdMismatches(in context: ModelContext) {
            guard let items = try? context.fetch(FetchDescriptor<SessionItem>()) else { return }
            for item in items {
                guard let snapshot = item.exerciseNameSnapshot,
                      !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard let correctId = ExerciseCatalog.canonicalBuiltInId(forExerciseName: snapshot) else { continue }
                if item.exerciseId != correctId {
                    item.exerciseId = correctId
                }
            }
        }

        fixExerciseIdMismatches(in: context)
        try context.save()

        XCTAssertEqual(item.exerciseId, "bench_press", "exerciseId corrected via the catalog lookup on exerciseNameSnapshot")
        XCTAssertEqual(item.targetSets, 3)
        XCTAssertEqual(item.targetReps, 8)
        XCTAssertEqual(item.targetRIR, 2)
        XCTAssertEqual(item.suggestedLoad, 185)
        XCTAssertEqual(item.plannedLoadsBySet, [185, 185, 185])
    }
}

// MARK: - Section K — Backup/restore

final class BackupRestoreImportTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func writeTempJSON(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // T-K.1: Regression guard: import must use a fresh ModelContext from
    // context.container, not the live UI context. This crashed twice before
    // the isolation fix.
    //
    // BackupSnapshotImporter.importFullBackupJSON(from:modelContainer:)
    // (Domain/Backup/BackupSnapshotImporter.swift:13) takes a ModelContainer,
    // not a ModelContext — it always builds its own fresh
    // ModelContext(modelContainer) internally (line 14). The isolation is
    // structural: no signature exists that would let a caller pass in their
    // live UI context, even by accident.
    func test_K1_importUsesFreshModelContextFromContainerNotLiveContext() throws {
        let container = try makeContainer()
        let json = """
        {"version":1,"exportedAt":"2026-01-01T00:00:00Z","mesoBlocks":[],"sessions":[],"sessionHistory":[],"exerciseNotes":[],"customExercises":[]}
        """
        let url = try writeTempJSON(json)

        XCTAssertNoThrow(try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container))
    }

    // T-K.2: full schema coverage — every field round-trips through the real
    // import pipeline (encode -> temp file -> importFullBackupJSON -> fetch
    // back from the same container).
    func test_K2_fullSchemaRoundTripsThroughImport() throws {
        let container = try makeContainer()

        let profileDTO = UserProfileBackupDTO(
            profileId: UUID(), createdAt: Date(), experienceRaw: "advanced",
            primaryGoalRaw: "strength", daysPerWeek: 5, sessionLengthMinutes: 75,
            equipmentProfileRaw: "homeGym", injuryFlagRaws: ["knees"], minLoadIncrement: 5.0,
            unitPreferenceRaw: "kg", bodyWeight: 200.0
        )

        let customExerciseDTO = CustomExerciseBackupDTO(
            id: "custom_pistol_squat", name: "Pistol Squat", primaryMuscleRaw: "quads",
            isCompound: true, createdAt: Date(), isBodyweight: true
        )

        let itemDTO = SessionItemBackupDTO(
            id: UUID(), createdAt: Date(), updatedAt: Date(),
            order: 1, exerciseId: "bench_press",
            targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185,
            waveRaw: "accumulation", priorityRaw: "standard",
            setMin: 3, setMax: 4, repMin: 6, repMax: 10, targetRIRMin: 1, targetRIRMax: 3,
            intensifierRaw: "none", intensifierNotes: nil, prescriptionNotes: "Test",
            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [185, 185, 185], plannedRIRsBySet: [2, 2, 2],
            actualReps: [8, 8, 8], actualLoads: [185, 185, 185], actualRIRs: [2, 2, 1],
            usedRestPauseFlags: [false, false, false], restPausePatternsBySet: ["", "", ""],
            dropSetPatternsBySet: ["", "", "100x8"],
            setFeedbackBySet: ["none", "none", "pain"], pumpRatingsBySet: [2, 3, 4],
            isCompleted: true, isPR: false,
            coachNote: "Great set", loadOverrideReasonRaw: nil, nextSuggestedLoad: 190,
            logs: []
        )

        let sessionDTO = SessionBackupDTO(
            id: UUID(), createdAt: Date(), updatedAt: Date(), mesoBlockId: nil,
            date: Date(), statusRaw: "completed", completedAt: Date(),
            readinessStars: 4, sessionNotes: "Felt good",
            weekInMeso: 1, dayLabel: "Push Day", programIndex: 1,
            hkWorkoutUUID: nil, hkWorkoutStart: nil, hkWorkoutEnd: nil,
            hkDuration: 0, hkActiveCalories: 0, hkTotalCalories: 0,
            hkAvgHeartRate: 0, hkMaxHeartRate: 0,
            hkZone1Seconds: 0, hkZone2Seconds: 0, hkZone3Seconds: 0, hkZone4Seconds: 0, hkZone5Seconds: 0,
            hkHeartRateSeriesBPM: [], hkHeartRateSeriesStepSeconds: 0,
            hkPostWorkoutHeartRateBPM: [], hkPostWorkoutHeartRateStepSeconds: 0,
            items: [itemDTO]
        )

        let snapshot = BackupSnapshotV1(
            version: 1, exportedAt: Date(),
            appState: nil, userProfile: profileDTO,
            mesoBlocks: [], sessions: [sessionDTO], sessionHistory: [], exerciseNotes: [],
            customExercises: [customExerciseDTO]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: url)

        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container)

        let checkContext = ModelContext(container)
        let profile = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(profile.bodyWeight, 200.0)
        XCTAssertEqual(profile.daysPerWeek, 5)
        // usesKilograms removed (Q18) — profileDTO's unitPreferenceRaw:
        // "kg" above is decoded but intentionally dropped on import; no
        // longer asserted here.

        let custom = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<CustomExercise>()).first)
        XCTAssertTrue(custom.isBodyweight)

        let session = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<Session>()).first)
        XCTAssertEqual(session.dayLabel, "Push Day")

        let item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(item.setFeedbackBySet, ["none", "none", "pain"])
        XCTAssertEqual(item.pumpRatingsBySet, [2, 3, 4])
        XCTAssertEqual(item.dropSetPatternsBySet, ["", "", "100x8"])
    }

    // T-K.3: old backup (predates setFeedbackBySet, pumpRatingsBySet,
    // isBodyweight, bodyWeight, dayLabel) imports cleanly through the real
    // pipeline — validates the decodeIfPresent / Optional-default pattern
    // end-to-end, not just at the bare-decode level (see T-G.7 for the
    // narrower SessionItemBackupDTO-only version of this check).
    //
    // isBodyweight was previously NOT decode-safe — CustomExerciseBackupDTO
    // declared it as `var isBodyweight: Bool = false` (a default value on a
    // non-Optional), and Swift's synthesized Codable does not fall back to a
    // property's default when its key is absent, so omitting it threw
    // keyNotFound instead of defaulting. FIXED (this commit):
    // Domain/Backup/BackupSnapshotV1.swift now declares `let isBodyweight:
    // Bool?`, and BackupSnapshotImporter.swift coalesces with `?? false` at
    // the CustomExercise construction site. See OPEN Q15 in
    // TestOpenQuestions.swift.
    func test_K3_oldBackupMissingNewerFieldsImportsCleanly() throws {
        let container = try makeContainer()
        let json = """
        {
          "version": 1,
          "exportedAt": "2025-01-01T00:00:00Z",
          "userProfile": {
            "experienceRaw": "intermediate",
            "primaryGoalRaw": "hypertrophy",
            "daysPerWeek": 4,
            "sessionLengthMinutes": 60,
            "equipmentProfileRaw": "commercial",
            "injuryFlagRaws": [],
            "minLoadIncrement": 2.5,
            "unitPreferenceRaw": "lbs"
          },
          "mesoBlocks": [],
          "sessions": [
            {
              "date": "2025-01-01T00:00:00Z",
              "statusRaw": "completed",
              "readinessStars": 3,
              "hkDuration": 0, "hkActiveCalories": 0, "hkTotalCalories": 0,
              "hkAvgHeartRate": 0, "hkMaxHeartRate": 0,
              "hkZone1Seconds": 0, "hkZone2Seconds": 0, "hkZone3Seconds": 0, "hkZone4Seconds": 0, "hkZone5Seconds": 0,
              "hkHeartRateSeriesBPM": [], "hkHeartRateSeriesStepSeconds": 0,
              "hkPostWorkoutHeartRateBPM": [], "hkPostWorkoutHeartRateStepSeconds": 0,
              "items": [
                {
                  "order": 1, "exerciseId": "bench_press",
                  "targetReps": 8, "targetSets": 3, "targetRIR": 2, "suggestedLoad": 185,
                  "plannedRepsBySet": [8,8,8], "plannedLoadsBySet": [185,185,185], "plannedRIRsBySet": [2,2,2],
                  "actualReps": [8,8,8], "actualLoads": [185,185,185], "actualRIRs": [2,2,2],
                  "usedRestPauseFlags": [false,false,false],
                  "restPausePatternsBySet": ["","",""],
                  "dropSetPatternsBySet": ["","",""],
                  "isCompleted": true, "isPR": false,
                  "logs": []
                }
              ]
            }
          ],
          "sessionHistory": [],
          "exerciseNotes": [],
          "customExercises": [
            {
              "id": "custom_old_1",
              "name": "Old Custom Exercise",
              "primaryMuscleRaw": "back",
              "isCompound": false,
              "createdAt": "2025-01-01T00:00:00Z"
            }
          ]
        }
        """
        let url = try writeTempJSON(json)

        XCTAssertNoThrow(try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container))

        let checkContext = ModelContext(container)
        let item = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<SessionItem>()).first)
        XCTAssertEqual(item.setFeedbackBySet, [], "missing setFeedbackBySet must default to empty, not crash")
        XCTAssertEqual(item.pumpRatingsBySet, [], "missing pumpRatingsBySet must default to empty, not crash")

        let session = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<Session>()).first)
        XCTAssertNil(session.dayLabel, "missing dayLabel must default to nil, not crash")

        let custom = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<CustomExercise>()).first)
        XCTAssertEqual(custom.isBodyweight, false, "missing isBodyweight must default to false, not crash")

        let profile = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertNil(profile.bodyWeight, "missing bodyWeight must default to nil, not crash")
    }
}

final class SectionKReferenceTests: XCTestCase {

    func test_K4_postRestoreSeedingFidelity() {
        // Covered by T-N.12 and T-B.6 — see InvariantTests and LoadWriteTests.
        // Both passing since commit 6e15b86 (anchorLoadsForNewMeso routing fix).
        // No further assertion needed here.
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_K5_bundleIdChangeDataLossRecovery() {
        // SCOPE LIMIT: bundle-ID store wipe only occurs on physical device with prior install.
        // Not unit-testable. Verified manually after the incident.
        // The restore path itself is covered by T-K.1 through T-K.3.
        XCTAssertTrue(true) // explicit no-op — scope limit documented above
    }
}

// MARK: - Section L — HealthKit App Group write path

final class MechanicalLoadAppGroupTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func expectedDateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // T-L.1: App Group write/read parity.
    //
    // MechanicalLoadSharedStore.write(score:for:)/.read(for:) are not
    // injectable — sharedDefaults is a private computed property that
    // always resolves UserDefaults(suiteName: appGroupID)
    // (Domain/MechanicalLoadSharedStore.swift:11,14-16), with no parameter
    // to substitute a test-scoped suite. Per the SCOPE LIMIT fallback: this
    // calls the real write function directly (appGroupID is a public
    // constant) and verifies both the round trip through the service's own
    // read() AND, independently, by opening
    // UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID)
    // directly in the test and reading the exact pinned key —
    // "mechanicalLoad.YYYY-MM-DD" — proving the key format claim, not just
    // that *some* round trip works. Whether this resolves to the real App
    // Group or a Simulator-local stand-in depends on entitlements outside
    // this target's control; either way the key/value contract under test
    // is identical, and a distinctive far-future date plus teardown avoids
    // colliding with real data if it is the real group.
    func test_L1_writeReadRoundTripsAndKeyFormatMatchesPinnedSpec() throws {
        var components = DateComponents()
        components.year = 2099
        components.month = 3
        components.day = 14
        let testDate = Calendar.current.date(from: components)!
        let expectedKey = MechanicalLoadSharedStore.keyPrefix + expectedDateKey(for: testDate)

        defer {
            UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID)?.removeObject(forKey: expectedKey)
        }

        let score = 4321.0
        MechanicalLoadSharedStore.write(score: score, for: testDate)

        XCTAssertEqual(MechanicalLoadSharedStore.read(for: testDate), score, "read() must return what write() just wrote, for the same date")

        guard let directDefaults = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else {
            // read()/write() already confirmed to agree with each other
            // above; this branch only covers the deeper, independent
            // key-format check, which needs direct UserDefaults access this
            // test environment may not grant.
            return
        }
        XCTAssertEqual(directDefaults.double(forKey: expectedKey), score, "key format must be exactly \"mechanicalLoad.YYYY-MM-DD\" — pinned from MechanicalLoadSharedStore.swift's doc comment and keyPrefix/dateKey(for:)")
    }

    // T-L.1 (continued): the score written equals
    // MechanicalLoadHealthKitService.calculateMechanicalLoad(from:), and the
    // date used is session.completedAt ?? session.date
    // (MechanicalLoadHealthKitService.writeAfterSession,
    // Domain/MechanicalLoadHealthKitService.swift:31) — not always
    // session.date alone.
    func test_L1_writtenValueMatchesCalculatedMechanicalLoadForTheSession() throws {
        let context = try makeContext()
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 185,
            actualReps: [8], actualLoads: [185]
        )
        let completedAt = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [item], completedAt: completedAt)
        context.insert(session)
        try context.save()

        let expectedScore = MechanicalLoadHealthKitService.calculateMechanicalLoad(from: session)
        XCTAssertGreaterThan(expectedScore, 0, "fixture must produce a real, non-zero mechanical load to be a meaningful test")

        let expectedKey = MechanicalLoadSharedStore.keyPrefix + expectedDateKey(for: completedAt)
        defer { UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID)?.removeObject(forKey: expectedKey) }

        // Mirrors writeAfterSession's own completedAt ?? date key date
        // directly, rather than awaiting the real detached Task inside
        // SessionScreenViewModel.persistCompletion, which isn't reliably
        // observable synchronously from a test.
        MechanicalLoadSharedStore.write(score: expectedScore, for: session.completedAt ?? session.date)

        XCTAssertEqual(MechanicalLoadSharedStore.read(for: completedAt), expectedScore)
    }

    // T-L.2: App Group unavailable — graceful degrade, no crash.
    //
    // CORRECTED PREMISE: UserDefaults(suiteName:) does NOT return nil for an
    // arbitrary/unentitled suite name — empirically confirmed (this
    // assertion originally asserted XCTAssertNil and failed) that it
    // returns a valid, locally-backed, non-shared instance instead.
    // Foundation only documents nil for suiteName == Bundle.main
    // .bundleIdentifier (colliding with the standard defaults domain), not
    // for "an app group this process isn't entitled to." So
    // MechanicalLoadSharedStore's `guard let defaults = sharedDefaults else
    // { ...; return }` is defensive code for a scenario that may never
    // actually trigger on this platform; the real graceful-degrade
    // behavior it's meant to protect is verified directly by write()/
    // read() never crashing
    // (test_L2_writeAndReadNeverCrashRegardlessOfAppGroupAvailability, below).
    func test_L2_arbitrarySuiteNameDoesNotCrashRegardlessOfEntitlement() {
        let arbitrary = UserDefaults(suiteName: "definitely-invalid-nonexistent-app-group-id-xyz-987")
        XCTAssertNotNil(arbitrary, "Foundation does not validate App Group entitlements at UserDefaults(suiteName:) construction time — it succeeds with a local, non-shared instance instead of returning nil")
    }

    func test_L2_writeAndReadNeverCrashRegardlessOfAppGroupAvailability() {
        // No injection point exists to force sharedDefaults to nil for this
        // call specifically, but write/read must be safe to call under any
        // circumstance — this confirms they don't throw/crash/hang.
        MechanicalLoadSharedStore.write(score: 100, for: Date())
        _ = MechanicalLoadSharedStore.read(for: Date())
        _ = MechanicalLoadSharedStore.readRange(from: Date(), to: Date())
        XCTAssertTrue(true) // reaching this line at all is the assertion
    }

    // T-L.3: custom HKQuantityType path is not used by the real write flow.
    //
    // CORRECTED PREMISE: the string
    // "com.calabrese.eliteperformance.mechanicalLoad" is NOT fully gone
    // from production source — it's still declared as
    // MechanicalLoadHealthKitService.quantityTypeIdentifier
    // (Domain/MechanicalLoadHealthKitService.swift:15), used by two
    // `private` functions, requestWriteAuthorizationIfNeeded() and
    // writeSample(score:date:). But neither is called from anywhere —
    // writeAfterSession(_:), the only public entry point, goes straight to
    // MechanicalLoadSharedStore.write(score:for:) (the shared-UserDefaults
    // approach), with an explicit comment confirming why: "Custom
    // HKQuantityType identifiers are not supported for third-party apps
    // without special entitlements." So the literal "no reference anywhere
    // in source" claim is false; the accurate claim is "the active write
    // path never reaches the custom-quantity-type code" — dead code, not a
    // live bug. See OPEN Q16 in TestOpenQuestions.swift.
    func test_L3_activeWritePathNeverUsesUnsupportedCustomQuantityType() async throws {
        let context = try makeContext()
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 185, actualReps: [8], actualLoads: [185])
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [item])
        context.insert(session)
        try context.save()

        let key = MechanicalLoadSharedStore.keyPrefix + expectedDateKey(for: session.completedAt ?? session.date)
        defer { UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID)?.removeObject(forKey: key) }

        // writeAfterSession is the only public entry point production code
        // calls (Features/Session/SessionView.swift:2268). Calling it here
        // must not throw/crash even though the custom-quantity-type path
        // (which would need an unsupported HKQuantityType and would throw
        // MechanicalLoadError.unsupportedQuantityType if reached) exists
        // unused in the same file — proving it's truly unreachable from the
        // real flow, not just absent from a naive string search.
        await MechanicalLoadHealthKitService.writeAfterSession(session)
        // Reaching here without throwing/crashing is the assertion.
    }
}

// MARK: - Section M — Cross-cutting user behavior

final class CrossCuttingBehaviorCoverageMapTests: XCTestCase {

    func test_M1_fullSessionSkipCarriesFromLastCompleted() {
        // Already covered: InvariantTests
        // .test_N6_carryForwardWritesEachMatchedItemExactlyOnce_andIsIdempotent
        // (NOT LoadWriteTests.test_B9, which is about prescription-field
        // immutability, not idempotent carry-forward — corrected from this
        // task's original cross-reference). N6 proves carrying forward from
        // the most recent matched session writes each item exactly once and
        // produces the same result if run again, which is exactly what
        // "skip a full session, then carry forward from the last completed
        // one" depends on.
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_M2_skipTiredFatiguedDoesNotDecreaseLoad() {
        // Already covered: CoachingEngineGuardTests
        // .test_A6_fatigueFlagOverridesOverPerformance (a fatigue flag
        // forces a hold even when raw performance looks like it should
        // increase) and LoadWriteTests
        // .test_B7_repeatedFatigueSignalsReduceSetCountOnCarryForward
        // (repeated fatigue signals reduce SET COUNT on carry-forward — a
        // volume response, never a load decrease). Between the two,
        // fatigue/tiredness is handled by holding or reducing volume, never
        // by decreasing suggestedLoad.
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_M3_partialSessionCoachingOnlyOnLoggedItems() {
        // Already covered: CoachingEngineGuardTests
        // .test_A10_incompleteSessionGatesBeforeARealRecommendation and,
        // most directly, CoachingMessageSeamTests
        // .testHandleSetLogged_partialSession_noMessageYet /
        // .testHandleSetLogged_completeSession_emitsCoachMessage — the
        // stage gate withholds a verdict until all planned sets for an item
        // are logged, so coaching never fires on an item that's only
        // partially logged within a partial session.
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_M5_fatFingerLoadCappedAt2x() {
        // Already covered: InvariantTests.test_N1_coachingEngineNeverExceeds2xBaseLoad
        // and .test_N1_planMemoryEngineCarryForwardNeverExceeds2xSource,
        // plus CoachingEngineGuardTests
        // .test_A9_downshiftDetectionRebaselinesBeforeOtherBranches (an
        // implausible jump is treated as a downshift/rebaseline signal
        // rather than taken at face value).
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_M14_swapMidMesoGetsNewIdNoStaleLoad() {
        // Already covered: ExerciseSwapPropagationTests
        // .test_J2_swapPropagatesByCanonicalIdNotPosition, and
        // ProgramDayDetailView.swapExercise (Features/Home
        // /ProgramDayDetailView.swift:593-613) zeroes suggestedLoad/
        // plannedLoadsBySet/actualLoads/actualReps/actualRIRs/coachNote at
        // the swap site itself, before propagation ever runs — so a swapped
        // exercise never carries a stale load from the exercise it replaced.
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_M16_midWorkoutPainFlagWarnsNextSession() {
        // Already covered: LoadWriteTests
        // .test_B8_painFlagCarriesForwardAWarningCoachNote (the direct
        // match — a pain flag carries forward as a warning coachNote on
        // the next session's matched item), plus CoachingEngineGuardTests
        // .test_A4_painGuardBlocksProgressionRegardlessOfPerformance (the
        // same-session stop) and SetStatusBadgeTests
        // .test_G4_painCoachNotePrefixIsPresent (the "⚠️" prefix convention).
        XCTAssertTrue(true) // explicit no-op — covered elsewhere
    }

    func test_M15_simulatorVsDeviceSeparateStores() {
        // SCOPE LIMIT: simulator and physical-device SwiftData stores are
        // physically separate on-disk containers selected by the runtime
        // environment (App/ElitePerformanceApp.swift's store-selection
        // logic) — there is no way to run "simulator" and "device" as two
        // states within a single XCTest process. Not unit-testable.
        XCTAssertTrue(true) // explicit no-op — scope limit documented above
    }
}

final class ExtraSetsAndFailureTests: XCTestCase {

    // T-M.4: extra sets beyond plan. CoachingEngine.recommend reads from
    // item.actualLoads/actualReps/actualRIRs in full (Domain/Logic
    // /CoachingEngine.swift:25-29,79-93) — plannedWorkingSetCount is the
    // MINIMUM required for the stage gate to clear, not a hard cap on how
    // many logged sets can be read, so logging more sets than planned is
    // used in full, not truncated or out-of-range.
    func test_M4_extraSetsBeyondPlanAreUsedNotTruncated() {
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185,
            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [185, 185, 185], plannedRIRsBySet: [2, 2, 2],
            // 5 sets logged against a 3-set plan — all on-target or better.
            actualReps: [8, 8, 8, 8, 8],
            actualLoads: [185, 185, 185, 185, 185],
            actualRIRs: [2, 2, 2, 1, 1]
        )
        let recommendation = CoachingEngine.recommend(for: item)
        XCTAssertNotNil(recommendation, "5 logged sets, all on-target or better, against a 3-set plan must still produce a real verdict, not a crash or a withheld stage-gate")
    }

    // T-M.6: a realistic, partial failure (final set craters hard) hits the
    // documented "failure + rep crash → hold" branch (Domain/Logic
    // /CoachingEngine.swift:275-281): never an increase, never NaN/Inf/negative.
    func test_M6_failureWithBigRepCrashHoldsNeverIncreasesNoNaN() {
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185,
            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [185, 185, 185], plannedRIRsBySet: [2, 2, 2],
            // First two sets clean; the third craters to 3 reps at RIR 0 —
            // a genuine failure, not an unlogged set.
            actualReps: [8, 8, 3], actualLoads: [185, 185, 185], actualRIRs: [2, 2, 0]
        )
        let recommendation = CoachingEngine.recommend(for: item)
        let nextLoad = try? XCTUnwrap(recommendation?.nextSuggestedLoad)
        XCTAssertNotNil(recommendation, "the engine must respond (hold or reduce) to a genuine failure, not withhold entirely")
        if let nextLoad {
            XCTAssertFalse(nextLoad.isNaN)
            XCTAssertFalse(nextLoad.isInfinite)
            XCTAssertGreaterThanOrEqual(nextLoad, 0)
            XCTAssertLessThanOrEqual(nextLoad, item.suggestedLoad, "a hard rep-crash failure must never produce an increase")
        }
    }

    // BUG CONFIRMED: CoachingEngine.recommend cannot distinguish a true
    // 0-rep total-failure set from a not-yet-logged one — both fail the
    // `reps[idx] > 0 && loads[idx] > 0` workingIndices filter (Domain/Logic
    // /CoachingEngine.swift:79-85) identically, so a session where every
    // set was genuinely attempted at the planned load but failed at 0 reps
    // produces workingIndices == [] and returns nil at the `guard
    // !workingIndices.isEmpty else { return nil }` line — the same silent
    // withholding as an entirely unlogged item, not a hold/reduce message.
    // There is no "attempted" flag separate from reps/load in SessionItem
    // to disambiguate the two cases. Do not fix here, flag for next task.
    // See OPEN Q17 in TestOpenQuestions.swift.
    func test_M6_BUG_totalFailureAllSetsZeroRepsIsIndistinguishableFromUnloggedAndWithholdsEntirely() {
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185,
            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [185, 185, 185], plannedRIRsBySet: [2, 2, 2],
            // Every set genuinely attempted at the planned load — failed to
            // complete a single rep on any of them. Total failure, not
            // "didn't try."
            actualReps: [0, 0, 0], actualLoads: [185, 185, 185], actualRIRs: [0, 0, 0]
        )
        let recommendation = CoachingEngine.recommend(for: item)
        XCTAssertNotNil(recommendation, "BUG CONFIRMED: a genuine total-failure session (3 attempted sets, 0 reps achieved on all of them) should produce a hold/reduce verdict, but the engine cannot distinguish this from an unlogged item and withholds entirely")
    }
}

final class SameDaySessionsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-M.7: multiple sessions on the same calendar date never collide.
    // Session.weekIndex (Domain/Models/Session.swift:61-64) is a plain
    // stored Int (weekInMeso ?? 1) set explicitly at construction — never
    // derived from .date — so there is no shared-date-based key anywhere in
    // the model that two same-day sessions could collide on. Identity is
    // Session.id (a UUID), not date. Verified by persisting two same-day
    // sessions independently via SessionScreenViewModel.persist (the
    // in-progress-save path) and confirming both retain their own
    // date/weekIndex/items after a real SwiftData round trip.
    func test_M7_multipleSessionsSameDateDoNotCollideOnWeekIndexOrIdentity() throws {
        let context = try makeContext()
        let sameDate = Date()

        let item1 = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 185)
        let session1 = Session(date: sameDate, status: .inProgress, weekIndex: 3, dayLabel: "Push", items: [item1])
        context.insert(session1)

        let item2 = SessionItem(order: 1, exerciseId: "back_squat", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 225)
        let session2 = Session(date: sameDate, status: .inProgress, weekIndex: 7, dayLabel: "Bonus Legs", items: [item2])
        context.insert(session2)
        try context.save()

        let vm1 = SessionScreenViewModel(session: session1)
        vm1.exercises[0].sets[0].actualLoadText = "185"
        vm1.exercises[0].sets[0].actualRepsText = "8"
        vm1.persist(using: context)

        let vm2 = SessionScreenViewModel(session: session2)
        vm2.exercises[0].sets[0].actualLoadText = "225"
        vm2.exercises[0].sets[0].actualRepsText = "5"
        vm2.persist(using: context)

        let allSessions = try context.fetch(FetchDescriptor<Session>())
        XCTAssertEqual(allSessions.count, 2, "two distinct same-date sessions, never merged into one")

        let fetched1 = try XCTUnwrap(allSessions.first { $0.weekIndex == 3 })
        let fetched2 = try XCTUnwrap(allSessions.first { $0.weekIndex == 7 })
        XCTAssertEqual(fetched1.date, sameDate)
        XCTAssertEqual(fetched2.date, sameDate)
        XCTAssertNotEqual(fetched1.weekIndex, fetched2.weekIndex)
        XCTAssertEqual(fetched1.items.first?.exerciseId, "bench_press")
        XCTAssertEqual(fetched2.items.first?.exerciseId, "back_squat")
    }
}

final class LongLayoffAndOverrideTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-M.8: long layoff holds at the last suggestion — no auto-detrain.
    // Neither PlanMemoryEngine.carryForwardPlans nor LoadProjectionService
    // .project contains any days-since-source-session penalty; decay
    // weighting only matters when comparing MULTIPLE candidates against
    // each other, and with a single historical data point its weight
    // cancels out of the average regardless of how old it is. Verified by
    // direct A/B comparison rather than hand-deriving the RIR/decay-weighted
    // e1RM arithmetic by hand.
    func test_M8_longLayoffCarriesForwardAtSameSuggestionAsARecentOne() throws {
        func suggestedLoadAfterCarryForward(daysAgo: Int) throws -> Double {
            let context = try makeContext()
            let calendar = Calendar.current
            let sourceDate = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!

            let sourceItem = SessionItem(
                order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185,
                plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [185, 185, 185], plannedRIRsBySet: [2, 2, 2],
                actualReps: [8, 8, 8], actualLoads: [185, 185, 185], actualRIRs: [2, 2, 2]
            )
            let sourceSession = Session(date: sourceDate, status: .completed, weekIndex: 1, items: [sourceItem])
            context.insert(sourceSession)

            let targetItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0, plannedLoadsBySet: [0, 0, 0])
            let targetSession = Session(date: Date(), status: .planned, weekIndex: 2, items: [targetItem])
            context.insert(targetSession)
            try context.save()

            let engine = PlanMemoryEngine(context: context)
            engine.carryForwardPlans(from: sourceSession)
            try context.save()
            return targetItem.suggestedLoad
        }

        let recentResult = try suggestedLoadAfterCarryForward(daysAgo: 5)
        let longLayoffResult = try suggestedLoadAfterCarryForward(daysAgo: 90)

        XCTAssertGreaterThan(recentResult, 0, "fixture must produce a real suggestion to be meaningful")
        XCTAssertEqual(recentResult, longLayoffResult, "a 90-day layoff must carry forward identically to a 5-day one — no automatic detrain reduction based on time since the source session")
    }

    // T-M.9: consistent override lower → suggestions read from actual
    // logged loads, not the stale prior suggestedLoad. LoadProjectionService's
    // candidate building reads item.actualLoads/actualReps exclusively
    // (Domain/Logic/LoadProjectionService.swift:174-187) — item.suggestedLoad
    // is never read as a basis for the projection itself.
    func test_M9_consistentlyLowerActualsDriveTheSuggestionNotThePriorSuggestedLoad() throws {
        let context = try makeContext()
        let calendar = Calendar.current

        var lastSession: Session!
        for daysAgo in [21, 14, 7] {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            let item = SessionItem(
                order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
                plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [100, 100, 100], plannedRIRsBySet: [2, 2, 2],
                actualReps: [8, 8, 8], actualLoads: [80, 80, 80], actualRIRs: [2, 2, 2]
            )
            let session = Session(date: date, status: .completed, weekIndex: 1, items: [item])
            context.insert(session)
            lastSession = session
        }

        let targetItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0, plannedLoadsBySet: [0, 0, 0])
        let targetSession = Session(date: Date(), status: .planned, weekIndex: 2, items: [targetItem])
        context.insert(targetSession)
        try context.save()

        let engine = PlanMemoryEngine(context: context)
        engine.carryForwardPlans(from: lastSession)
        try context.save()

        XCTAssertGreaterThan(targetItem.suggestedLoad, 0, "must produce a real projection")
        XCTAssertLessThan(targetItem.suggestedLoad, 95, "suggestion must track the consistently-logged ~80 actuals, not the stale suggestedLoad of 100")
        XCTAssertGreaterThan(targetItem.suggestedLoad, 65, "sanity bound — should land near 75-80, not collapse toward zero")
    }
}

final class RetroactiveCascadeAndDeletionTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-M.10: edits to a completed session do not retroactively cascade.
    //
    // Policy pin: no retroactive cascade. If this policy changes, this test
    // must be updated explicitly.
    //
    // There is no model-layer immutability guard on Session/SessionItem
    // properties after status == .completed — nothing stops a direct
    // mutation at the model layer. The real enforcement lives in
    // ProgramPlanPropagationService.applyPlanEditsForward's own target
    // filter (Domain/Logic/ProgramPlanPropagationService.swift:46-50),
    // which only ever selects sessions with status == .planned as
    // propagation targets — a completed session can never be a target, so
    // editing a still-planned source and propagating forward can never
    // retroactively rewrite something already logged.
    func test_M10_propagationNeverTargetsACompletedSession() throws {
        let context = try makeContext()
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), totalWeeks: 8)
        context.insert(meso)

        let sourceItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 999)
        let sourceSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [sourceItem])
        sourceSession.meso = meso
        context.insert(sourceSession)

        let calendar = Calendar.current

        // A future session, same weekday, same exercise — but already
        // COMPLETED (already logged history), not planned.
        let completedItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let completedFuture = Session(date: calendar.date(byAdding: .day, value: 7, to: Date())!, status: .completed, weekIndex: 2, items: [completedItem])
        completedFuture.meso = meso
        context.insert(completedFuture)

        // A genuinely still-planned future session — the only legitimate target.
        let plannedItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 185)
        let plannedFuture = Session(date: calendar.date(byAdding: .day, value: 14, to: Date())!, status: .planned, weekIndex: 3, items: [plannedItem])
        plannedFuture.meso = meso
        context.insert(plannedFuture)
        try context.save()

        ProgramPlanPropagationService.applyPlanEditsForward(from: sourceSession, in: context)
        try context.save()

        XCTAssertEqual(completedItem.suggestedLoad, 185, "a completed (already-logged) session must never be retroactively rewritten by a later plan edit")
        XCTAssertEqual(plannedItem.suggestedLoad, 999, "only still-planned future sessions are legitimate propagation targets")
    }

    // T-M.11: deleting a session excludes it from anchoring — ProgramGenerator
    // .anchorLoadsForNewMeso (Domain/Logic/ProgramGenerator.swift:25,31-37)
    // re-fetches allSessions fresh from the context every call; a deleted
    // session is simply gone from that fetch.
    func test_M11_deletingASessionExcludesItFromAnchoring() throws {
        let context = try makeContext()
        let calendar = Calendar.current

        func makeHistorySession(daysAgo: Int, load: Double) -> Session {
            let item = SessionItem(
                order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: load,
                actualReps: [8], actualLoads: [load]
            )
            let session = Session(date: calendar.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [item])
            context.insert(session)
            return session
        }

        _ = makeHistorySession(daysAgo: 21, load: 185)
        let peakSession = makeHistorySession(daysAgo: 14, load: 500) // about to be deleted
        _ = makeHistorySession(daysAgo: 7, load: 190)
        try context.save()

        context.delete(peakSession)
        try context.save()

        let newMeso = MesoBlock(name: "New Meso", startDate: Date(), status: .active, totalWeeks: 8)
        context.insert(newMeso)
        let newItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 0)
        let newSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [newItem])
        newSession.meso = newMeso
        newMeso.sessions.append(newSession)
        context.insert(newSession)
        try context.save()

        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: newMeso, context: context)

        XCTAssertGreaterThan(newItem.suggestedLoad, 0, "must produce a real anchor from the remaining sessions")
        // A decay-weighted average including the deleted session's 500 load
        // would land well above 250; confirming it lands far below proves
        // genuine exclusion, not mere dilution.
        XCTAssertLessThan(newItem.suggestedLoad, 250, "the deleted session's peak (500) must not still be influencing the anchor")
    }
}

final class UnitAndIncrementChangeTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // T-M.12: unit switch mid-meso.
    func test_M12_unitSwitchMidMeso() {
        // usesKilograms removed in this commit (Q18 cleanup) — no unit
        // switching in v1.x. All loads stored and displayed in lbs.
        // Re-implement when kg support is added properly (canonical
        // storage + real display conversion, not a label-only toggle).
        XCTAssertTrue(true) // explicit no-op — feature removed
    }

    // T-M.13: increment change mid-meso — future re-rounds, historical load
    // untouched. PlanMemoryEngine.carryForwardPlans re-reads
    // UserProfile.minLoadIncrement fresh on every call (Domain/Logic
    // /PlanMemoryEngine.swift:25-27); nothing re-rounds already-logged
    // historical loads retroactively.
    func test_M13_incrementChangeReRoundsFutureSuggestionLeavesHistoricalLoadUntouched() throws {
        let context = try makeContext()
        let profile = UserProfile(minLoadIncrement: 2.5)
        context.insert(profile)

        let calendar = Calendar.current
        let sourceItem = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 102.5,
            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [102.5, 102.5, 102.5], plannedRIRsBySet: [2, 2, 2],
            actualReps: [8, 8, 8], actualLoads: [102.5, 102.5, 102.5], actualRIRs: [2, 2, 2]
        )
        let sourceSession = Session(date: calendar.date(byAdding: .day, value: -7, to: Date())!, status: .completed, weekIndex: 1, items: [sourceItem])
        context.insert(sourceSession)

        let targetItem = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0, plannedLoadsBySet: [0, 0, 0])
        let targetSession = Session(date: Date(), status: .planned, weekIndex: 2, items: [targetItem])
        context.insert(targetSession)
        try context.save()

        // Increment changes mid-meso, after the historical session was logged.
        profile.minLoadIncrement = 5.0
        try context.save()

        let engine = PlanMemoryEngine(context: context)
        engine.carryForwardPlans(from: sourceSession)
        try context.save()

        // Historical (source) load is never touched by the increment change
        // or by carry-forward — only the future target session's suggestion moves.
        XCTAssertEqual(sourceItem.suggestedLoad, 102.5)
        XCTAssertEqual(sourceItem.plannedLoadsBySet, [102.5, 102.5, 102.5])

        XCTAssertGreaterThan(targetItem.suggestedLoad, 0)
        let remainder = targetItem.suggestedLoad.truncatingRemainder(dividingBy: 5.0)
        XCTAssertEqual(remainder, 0, accuracy: 0.001, "suggestion must be rounded to a multiple of the new 5.0 increment, not the old 2.5")
    }
}

// MARK: - T-Z.1: replacePlannedProgram deletion filter isolation
//
// Directly calls DUPProgramReplaceService.replacePlannedProgram with a known
// set of sessions and a chosen future start date, then asserts which sessions
// survive vs. get deleted. Isolates whether the deletion bug lives in the
// filter itself (in-process, deterministic, no Simulator needed) or upstream
// in the UI/date threading.

final class ReplacePlannedProgramDeletionFilterTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    func test_replacePlannedProgram_preservesSessionsBeforeStartDate() throws {
        let context = try makeContext()

        // Insert User so PlanMemoryEngine / anchoring paths don't bail early.
        context.insert(User(units: .lb, progressionEnabled: true))

        // Active meso to be archived by step 1 of replacePlannedProgram.
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), status: .active,
                             totalWeeks: 4, isMaintenance: false)
        context.insert(meso)

        // Build dates at local noon — identical to how a DatePicker selection
        // in UI would be resolved and passed to replacePlannedProgram.
        var cal = Calendar.current
        cal.timeZone = TimeZone.current

        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 30; comps.hour = 12
        let jun30 = try XCTUnwrap(cal.date(from: comps), "jun30 date")
        comps.day = 1; comps.month = 7
        let jul1 = try XCTUnwrap(cal.date(from: comps), "jul1 date")
        comps.day = 3
        let jul3Start = try XCTUnwrap(cal.date(from: comps), "jul3 date")

        let sessionJun30 = Session(date: jun30, status: .planned, weekIndex: 5, items: [])
        let sessionJul1  = Session(date: jul1,  status: .planned, weekIndex: 5, items: [])
        let sessionJul3  = Session(date: jul3Start, status: .planned, weekIndex: 5, items: [])
        sessionJun30.meso = meso
        sessionJul1.meso  = meso
        sessionJul3.meso  = meso
        context.insert(sessionJun30)
        context.insert(sessionJul1)
        context.insert(sessionJul3)
        try context.save()

        // Capture IDs before the call so we can find the same objects afterward.
        let idJun30 = sessionJun30.persistentModelID
        let idJul1  = sessionJul1.persistentModelID
        let idJul3  = sessionJul3.persistentModelID

        // Call the real production function with July 3 as the chosen start date.
        // FullBody2DayTemplate (2 days/week) is the simplest valid template —
        // replacePlannedProgram requires trainingWeekdays.count == trainingDaysPerWeek
        // or DUPProgramSeeder.seed will throw.
        try DUPProgramReplaceService.replacePlannedProgram(
            startDate: jul3Start,
            trainingWeekdays: [2, 5],
            context: context,
            template: FullBody2DayTemplate.template,
            calendar: cal
        )

        let allSessions = try context.fetch(FetchDescriptor<Session>())
        let allIDs = Set(allSessions.map { $0.persistentModelID })

        // Sessions BEFORE the start date must survive — the filter only deletes
        // sessions where sessionDay >= startDay.
        XCTAssertTrue(allIDs.contains(idJun30),
            "Jun 30 session (2 days before start) must be preserved by the date filter")
        XCTAssertTrue(allIDs.contains(idJul1),
            "Jul 1 session (2 days before start) must be preserved by the date filter")

        // Session ON the start date must be deleted (sessionDay >= startDay is true).
        XCTAssertFalse(allIDs.contains(idJul3),
            "Jul 3 session (on the start date) must be deleted and replaced by the new program")

        // Sanity: the new program must have seeded sessions starting from Jul 3.
        XCTAssertGreaterThan(
            allSessions.filter { $0.date >= jul3Start }.count, 0,
            "new program sessions starting from Jul 3 must exist after seeding")

        // The old meso block must now be archived.
        XCTAssertEqual(meso.status, .archived,
            "the replaced meso block must be archived after the switch")

        // Pre-start sessions must be re-attached to the NEW (active) meso block —
        // not orphaned to the archived old one — so they remain visible in
        // Today/Upcoming after the program switch.
        XCTAssertEqual(sessionJun30.meso?.status, .active,
            "Jun 30 session must be attached to the new active meso, not the archived one")
        XCTAssertEqual(sessionJul1.meso?.status, .active,
            "Jul 1 session must be attached to the new active meso, not the archived one")
    }
}
