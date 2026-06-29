import XCTest
@testable import ElitePerformance

/// Section C — E1RMCalculator pure math. No mocks, no SwiftData — every
/// function here is a free function over primitives.
final class E1RMCalculatorTests: XCTestCase {

    // T-C.1: e1RM Epley formula correctness.
    func test_C1_e1RMEpleyFormula() {
        // 100 x 10 -> 100 * (1 + 10/30) = 133.333...
        XCTAssertEqual(E1RMCalculator.e1RM(load: 100, reps: 10), 133.333, accuracy: 0.01)
        // 1 rep -> e1RM == load (within Epley's own rounding behavior at reps=1).
        XCTAssertEqual(E1RMCalculator.e1RM(load: 200, reps: 1), 200 * (1.0 + 1.0/30.0), accuracy: 0.0001)
    }

    // T-C.2: e1RM guard — load <= 0 or reps <= 0 -> 0.
    func test_C2_e1RMGuardsAgainstNonPositiveInputs() {
        XCTAssertEqual(E1RMCalculator.e1RM(load: 0, reps: 10), 0)
        XCTAssertEqual(E1RMCalculator.e1RM(load: -50, reps: 10), 0)
        XCTAssertEqual(E1RMCalculator.e1RM(load: 100, reps: 0), 0)
    }

    // T-C.3: load(for:reps:targetRIR:) inverse Epley + RIR adjustment direction.
    func test_C3_loadForE1RMWithRIRAdjustment() {
        let e1rm = E1RMCalculator.e1RM(load: 100, reps: 10) // 133.333...
        let atRIR0 = E1RMCalculator.load(for: e1rm, reps: 10, targetRIR: 0)
        XCTAssertEqual(atRIR0, 100, accuracy: 0.01, "RIR 0 should reconstruct the original load almost exactly")

        let atRIR4 = E1RMCalculator.load(for: e1rm, reps: 10, targetRIR: 4)
        XCTAssertEqual(atRIR4, 90, accuracy: 0.01, "each RIR step is a 2.5% reduction: 100 * (1 - 4*0.025) = 90")
        XCTAssertLessThan(atRIR4, atRIR0, "higher target RIR must always produce a lower prescribed load")
    }

    // T-C.4: load(for:) guard — e1rm <= 0 or reps <= 0 -> 0.
    func test_C4_loadForGuardsAgainstNonPositiveInputs() {
        XCTAssertEqual(E1RMCalculator.load(for: 0, reps: 10, targetRIR: 2), 0)
        XCTAssertEqual(E1RMCalculator.load(for: 100, reps: 0, targetRIR: 2), 0)
    }

    // T-C.5: rounded(_:increment:) rounds to the nearest increment, and is a
    // no-op pass-through (not a divide-by-zero) when increment <= 0.
    func test_C5_roundedToNearestIncrement() {
        XCTAssertEqual(E1RMCalculator.rounded(123.4, increment: 2.5), 122.5, accuracy: 0.0001)
        XCTAssertEqual(E1RMCalculator.rounded(124.0, increment: 2.5), 125.0, accuracy: 0.0001)
        XCTAssertEqual(E1RMCalculator.rounded(123.4, increment: 0), 123.4, accuracy: 0.0001, "increment <= 0 must return the input unchanged, not divide by zero")
        XCTAssertEqual(E1RMCalculator.rounded(123.4, increment: -5), 123.4, accuracy: 0.0001)
    }

    // T-C.6: effectiveLoad — a real logged actual load always wins, regardless
    // of bodyweight status.
    func test_C6_effectiveLoadPrefersActualLoadWhenPresent() {
        let result = E1RMCalculator.effectiveLoad(actualLoad: 50, exerciseId: "push_up", bodyWeight: 200)
        XCTAssertEqual(result, 50)
    }

    // T-C.7: effectiveLoad — falls back to bodyweight only for a known
    // bodyweight exercise with actualLoad == 0; otherwise 0.
    func test_C7_effectiveLoadFallsBackToBodyweightOnlyWhenApplicable() {
        XCTAssertEqual(E1RMCalculator.effectiveLoad(actualLoad: 0, exerciseId: "push_up", bodyWeight: 180), 180)
        XCTAssertEqual(E1RMCalculator.effectiveLoad(actualLoad: 0, exerciseId: "push_up", bodyWeight: nil), 0, "no bodyWeight on file -> 0, not a crash")
        XCTAssertEqual(E1RMCalculator.effectiveLoad(actualLoad: 0, exerciseId: "barbell_bench_press", bodyWeight: 180), 0, "non-bodyweight exercise must not fall back to bodyweight")
    }

    // T-C.8: rirWeightedE1RM — sets harder than target RIR are downweighted
    // (floored at 0.5), sets at/above target get full weight.
    func test_C8_rirWeightedE1RMDownweightsHarderSets() {
        // One set at target RIR (full weight), one set far below target RIR (floored at 0.5).
        let sets: [(load: Double, reps: Int, actualRIR: Int)] = [
            (load: 100, reps: 10, actualRIR: 2), // at target -> weight 1.0
            (load: 100, reps: 10, actualRIR: 0)  // below target -> weight floored at 0.5
        ]
        let weighted = E1RMCalculator.rirWeightedE1RM(from: sets, targetRIR: 2)
        let setE1RM = E1RMCalculator.e1RM(load: 100, reps: 10)
        // Both sets have the same e1RM, so regardless of weighting the result must equal that e1RM.
        XCTAssertEqual(weighted, setE1RM, accuracy: 0.01)

        // Empty / all-invalid input -> 0, not a crash.
        XCTAssertEqual(E1RMCalculator.rirWeightedE1RM(from: [], targetRIR: 2), 0)
        XCTAssertEqual(E1RMCalculator.rirWeightedE1RM(from: [(load: 0, reps: 10, actualRIR: 2)], targetRIR: 2), 0)
    }

    // T-C.9: decayWeightedE1RM — recent sessions outweigh older ones at the
    // documented half-life (default 21 days).
    func test_C9_decayWeightedE1RMHonorsHalfLife() {
        let referenceDate = Date()
        let exactlyOneHalfLifeAgo = referenceDate.addingTimeInterval(-21 * 86400)

        let candidates: [(e1rm: Double, date: Date)] = [
            (e1rm: 200, date: exactlyOneHalfLifeAgo), // weight 0.5
            (e1rm: 100, date: referenceDate)          // weight 1.0
        ]
        let weighted = E1RMCalculator.decayWeightedE1RM(from: candidates, referenceDate: referenceDate, halfLifeDays: 21.0)
        // (200*0.5 + 100*1.0) / (0.5 + 1.0) = 200/1.5 = 133.333...
        XCTAssertEqual(weighted, 133.333, accuracy: 0.01)

        XCTAssertEqual(E1RMCalculator.decayWeightedE1RM(from: [], referenceDate: referenceDate), 0)
        XCTAssertEqual(E1RMCalculator.decayWeightedE1RM(from: candidates, referenceDate: referenceDate, halfLifeDays: 0), 0, "halfLifeDays <= 0 must not divide by zero")
    }
}
