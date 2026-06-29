import XCTest
@testable import ElitePerformance

/// Section A — CoachingEngine.recommend's guard/decision pipeline, in the
/// REAL order confirmed by reading CoachingEngine.swift top to bottom:
///   1) Deload/maintenance (waveRaw == "deload")
///   2) No baseline (suggestedLoad <= 0)
///   3) First session / no actual data
///   4) Pain flag
///   ... downshift detection, stage-aware gating, failure+repcrash,
///   under-target-reps, harder-than-planned, over-performing (fatigue
///   override applies inside it too), general fatigue override,
///   clean-execution increase, drop-set increase, on-target repeat,
///   extra-reserve increase, catch-all.
final class CoachingEngineGuardTests: XCTestCase {

    private func item(
        exerciseId: String = "test_exercise",
        reps: [Int],
        loads: [Double],
        rirs: [Int],
        targetReps: Int = 10,
        targetRIR: Int = 2,
        targetSets: Int? = nil,
        suggestedLoad: Double,
        waveRaw: String? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        plannedTopReps: Int = 12,
        setFeedbackBySet: [String]? = nil
    ) -> SessionItem {
        let i = SessionItem(
            order: 1,
            exerciseId: exerciseId,
            targetReps: targetReps,
            targetSets: targetSets ?? reps.count,
            targetRIR: targetRIR,
            suggestedLoad: suggestedLoad,
            waveRaw: waveRaw,
            repMin: repMin,
            repMax: repMax
        )
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = rirs
        i.plannedRepsBySet = Array(repeating: plannedTopReps, count: reps.count)
        i.setFeedbackBySet = setFeedbackBySet ?? Array(repeating: "", count: reps.count)
        return i
    }

    // T-A.1: Deload guard fires before everything else, even with pain present.
    func test_A1_deloadGuardFiresFirst_evenWithPain() {
        let i = item(
            reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2],
            suggestedLoad: 100, waveRaw: "deload", repMin: 8, repMax: 12,
            setFeedbackBySet: [SetFeedback.pain.rawValue, "", ""]
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.message.contains("Maintenance") ?? false, "deload guard's own message, not the pain message")
        XCTAssertEqual(result?.nextSuggestedLoad, 100)
    }

    // T-A.2: No baseline (suggestedLoad <= 0) -> nil.
    func test_A2_noBaselineGuard() {
        let i = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 0)
        XCTAssertNil(CoachingEngine.recommend(for: i))
    }

    // T-A.3: First session / no actual data logged yet -> nil.
    func test_A3_noActualDataGuard() {
        let i = item(reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0], suggestedLoad: 100)
        XCTAssertNil(CoachingEngine.recommend(for: i))
    }

    // T-A.4: Pain flag -> message present, nextSuggestedLoad always nil, even
    // with otherwise excellent performance that would normally earn an increase.
    func test_A4_painGuardBlocksProgressionRegardlessOfPerformance() {
        let i = item(
            reps: [15, 15, 15], loads: [100, 100, 100], rirs: [4, 4, 4],
            targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 12,
            setFeedbackBySet: ["", SetFeedback.pain.rawValue, ""]
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.nextSuggestedLoad)
        XCTAssertTrue(result?.message.lowercased().contains("pain") ?? false)
    }

    // T-A.5: Extra reserve (avgRIR > targetRIR + 0.5) -> increase.
    // This is the regression guard for the June 28 "Hold this load" bug:
    // hitting target reps with RIR well above target must produce an increase,
    // not a hold/catch-all message.
    func test_A5_extraReserveProducesIncrease_notHold() {
        let i = item(
            reps: [10, 10, 10], loads: [100, 100, 100], rirs: [4, 4, 4],
            targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 10
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.message.range(of: "Extra reserve", options: .caseInsensitive), "must not regress to the generic catch-all hold message")
        XCTAssertGreaterThan(result?.nextSuggestedLoad ?? 0, 100, "extra reserve must produce an increase, not a hold")
    }

    // T-A.6: General fatigue flag overrides over-performance — a compromised
    // session isn't a reliable signal even if reps were way over target.
    // Reps here are comfortably over the top of the range (16 >= 12+2), so
    // this lands in the over-performing branch's OWN fatigue check (its
    // generic "isn't a reliable indicator" message), not the separate
    // soreness/disruption-specific fatigue-override block further down —
    // that block is only reached when comfortablyOverReps is false.
    func test_A6_fatigueFlagOverridesOverPerformance() {
        let i = item(
            reps: [16, 16, 16], loads: [100, 100, 100], rirs: [3, 3, 3],
            targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 12,
            setFeedbackBySet: [SetFeedback.soreness.rawValue, "", ""]
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad, 100, "fatigue must hold, even though reps cleared the over-performance threshold")
        XCTAssertTrue(result?.message.lowercased().contains("fatigue") ?? false)
    }

    // T-A.7: Sanity cap (2x) inside the over-performing branch specifically
    // (distinct from T-N.1's clean-execution-branch cap).
    func test_A7_sanityCapAppliesInOverPerformingBranch() {
        let i = item(
            reps: [20, 20, 20], loads: [10, 10, 10], rirs: [5, 5, 5],
            targetReps: 10, targetRIR: 2, suggestedLoad: 10, repMin: 8, repMax: 12
        )
        // comfortablyOverReps (20 >= 12+2), not to failure -> branch 4, with a
        // huge minLoadIncrement trying to blow past 2x.
        let result = CoachingEngine.recommend(for: i, minLoadIncrement: 1000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad ?? -1, 20, accuracy: 0.001)
    }

    // T-A.8 (critical): pain + deload + extra-reserve-favorable performance
    // all apply simultaneously. CONFIRMED real precedence via source: deload
    // is Guard 1, checked before pain (Guard 4) and long before the
    // extra-reserve branch (5.5) is ever reached. The catalog's assumed order
    // ("pain -> deload -> extra-reserve") is backwards for deload vs pain —
    // see OPEN Q2 in TestOpenQuestions.swift for the corrected pin.
    func test_A8_guardPrecedence_deloadBeatsPainAndExtraReserve() {
        let i = item(
            reps: [10, 10, 10], loads: [100, 100, 100], rirs: [4, 4, 4],
            targetReps: 10, targetRIR: 2, suggestedLoad: 100,
            waveRaw: "deload", repMin: 8, repMax: 10,
            setFeedbackBySet: [SetFeedback.pain.rawValue, "", ""]
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.message.contains("Maintenance") ?? false, "deload's own message wins — not the pain message, not an extra-reserve increase")
        XCTAssertEqual(result?.nextSuggestedLoad, 100, "deload holds — extra-reserve's increase branch is never reached")
    }

    // T-A.9: Downshift / re-baseline detection — load dropped >=10% across
    // working sets (no drop set) -> reset to the lower load, before any of
    // the later branches (under-target-reps, harder-than-planned, etc.) run.
    func test_A9_downshiftDetectionRebaselinesBeforeOtherBranches() {
        let i = item(
            reps: [8, 8, 8, 8], loads: [126, 106, 106, 106], rirs: [2, 2, 2, 2],
            targetReps: 10, targetRIR: 2, suggestedLoad: 126
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad, 106)
    }

    // T-A.10: Stage-aware gating — session not fully logged yet (2 of 3
    // planned sets) -> terse "finish the session" message, no real
    // recommendation, even though the logged sets look clean.
    func test_A10_incompleteSessionGatesBeforeARealRecommendation() {
        let i = item(
            reps: [10, 10, 0], loads: [100, 100, 0], rirs: [2, 2, 0],
            targetReps: 10, targetRIR: 2, targetSets: 3, suggestedLoad: 100
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.message.contains("Finish the session") ?? false)
        XCTAssertEqual(result?.nextSuggestedLoad, 100, "no progression call while the session is still incomplete")
    }

    // T-A.11: Warmup-pollution guard — a light opener below 50% of the
    // session's max working load (with reps that would otherwise read as a
    // missed rep target) must be excluded from the working-set evaluation,
    // not counted against the real working sets.
    func test_A11_warmupSetBelow50PercentIsExcludedFromEvaluation() {
        // targetSets is 3 (the real plan); the 2-rep/20-load set is an extra,
        // unplanned warmup opener on top of that — so after the warmup filter
        // removes it, exactly 3 working sets remain, matching the plan.
        let i = item(
            exerciseId: "bench",
            reps: [2, 10, 10, 10], loads: [20, 100, 100, 100], rirs: [5, 2, 2, 2],
            targetReps: 10, targetRIR: 2, targetSets: 3, suggestedLoad: 100, repMin: 8, repMax: 10
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        // If the 2-rep/20-load opener were NOT filtered out as a warmup, it would
        // drag primaryReps.allSatisfy(>= repMin) to false and this would not be
        // a clean increase at all.
        XCTAssertGreaterThan(result?.nextSuggestedLoad ?? 0, 100, "the light opener must not be treated as a failed working set")
    }
}
