import XCTest
import SwiftData
@testable import ElitePerformance

/// Negative-control / canary tests for invariantViolations (JourneyAssertions.swift).
///
/// Each canary (except the vacuity regression test) builds a fixture, runs ONE real
/// carry-forward via the production PlanMemoryEngine, then mutates the TARGET
/// session's already-written test state to violate exactly one invariant class, then
/// asserts invariantViolations(...) returns the expected violation code. Mutates test
/// models only — no production code touched.
///
/// If a canary does NOT produce its expected violation, that means the checker is
/// blind to that class — left RED with // BUG CONFIRMED, not weakened to pass.
final class JourneyCanaryTests: XCTestCase {

    /// Seeds a fresh fixture, logs the very first session cleanly, and returns the
    /// REAL carry-forward target for Day A exercises plus the full session history.
    ///
    /// The 2-day template alternates Day A / Day B, so allSessions is
    /// [w1A, w1B, w2A, w2B, w3A, w3B, w4A, ...] and the wave rotates by WEEK
    /// (A, B, C, A, ...).
    ///
    /// allSessions[0] = the just-completed Day A session (week 1, wave A).
    /// allSessions[1] = Day B (week 1) — never a target for a Day A exercise; the
    ///   two days' rosters are disjoint.
    /// allSessions[2] = Day A of week 2 — the wave-B session. This was the target
    ///   under chronological carry-forward, and is NOT one any more.
    /// allSessions[6] = the real carry-forward target — Day A of week 4, the next
    ///   session in the same block on the same day slot in the same wave (A).
    ///   PlanMemoryEngine.nextTargetItem anchors per letter, so this is where the
    ///   week-1 A result lands. Every Day A item here holds whatever
    ///   carryForwardPlans wrote when allSessions[0] completed, with allSessions[0]
    ///   as its real "previous" — and since week 1 is the only completed session,
    ///   that is also what invariantViolations' backward search finds.
    private static let carryForwardTargetIndex = 6   // week 4, Day A — the second A

    private func makeFixtureWithOneCarryForward() throws -> (target: Session, history: [Session]) {
        let fixture = try JourneyFixture.make()
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!
        try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

        let firstSession = try XCTUnwrap(fixture.currentPlannedSession())
        let logs: [JourneyExerciseLog] = firstSession.items.map { item in
            let sets = (0..<item.targetSets).map { _ in
                JourneySetLog(load: 100.0, reps: item.targetReps, rir: 2, feedback: "", pump: 0)
            }
            return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
        }
        try fixture.logAndComplete(JourneySessionScript(logs: logs))

        let allSessions = fixture.allSessionsSorted()
        guard allSessions.count > Self.carryForwardTargetIndex else {
            throw JourneyFixtureError.noPlannedSession
        }
        return (allSessions[Self.carryForwardTargetIndex], allSessions)
    }

    // MARK: - Vacuity regression

    func test_canary_vacuity_alternatingSplitProducesComparisons() throws {
        let fixture = try JourneyFixture.make()
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!
        try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

        var totalComparisons = 0
        for _ in 0..<6 {
            guard let session = fixture.currentPlannedSession() else { break }
            let isDeload = session.isDeloadWeek
            let logs: [JourneyExerciseLog]
            if isDeload {
                logs = session.items.map { item in
                    let sets = item.plannedLoadsBySet.map { load in
                        JourneySetLog(load: load, reps: item.targetReps, rir: 3, feedback: "", pump: 0)
                    }
                    return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                }
            } else {
                logs = session.items.map { item in
                    let load = item.suggestedLoad > 0 ? item.suggestedLoad : 100.0
                    let sets = (0..<item.targetSets).map { _ in
                        JourneySetLog(load: load, reps: item.targetReps, rir: 2, feedback: "", pump: 0)
                    }
                    return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                }
            }
            try fixture.logAndComplete(JourneySessionScript(logs: logs))
            let result = invariantViolations(forTarget: session, history: fixture.allSessionsSorted())
            totalComparisons += result.comparisons
        }

        XCTAssertGreaterThan(
            totalComparisons, 0,
            "direct regression test for the original vacuity defect: a 2-day alternating split must produce real comparisons and must never silently regress to 0 again"
        )
    }

    // MARK: - Positive control

    func test_canary_cleanState_noViolations_butComparisonsFired() throws {
        let (target, history) = try makeFixtureWithOneCarryForward()

        let result = invariantViolations(forTarget: target, history: history)

        XCTAssertTrue(result.violations.isEmpty, "expected a clean carry-forward to produce no violations: \(result.violations)")
        XCTAssertGreaterThan(result.comparisons, 0, "positive control: green must mean \"checked and clean,\" not \"didn't check\"")
    }

    // MARK: - Negative controls — one mutation each, one expected code each

    func test_canary_catchesZeroing() throws {
        let (target, history) = try makeFixtureWithOneCarryForward()
        let item = try XCTUnwrap(target.items.first(where: { $0.suggestedLoad > 0 }), "expected a baselined item to zero out")
        item.suggestedLoad = 0

        let result = invariantViolations(forTarget: target, history: history)

        XCTAssertTrue(
            result.violations.contains(where: { $0.code == "ZEROED" }),
            "expected ZEROED, got: \(result.violations)"
        )
    }

    func test_canary_catches2xJump() throws {
        let (target, history) = try makeFixtureWithOneCarryForward()
        let item = try XCTUnwrap(target.items.first(where: { $0.suggestedLoad > 0 }), "expected a baselined item to jump")
        item.suggestedLoad *= 3.0

        let result = invariantViolations(forTarget: target, history: history)

        XCTAssertTrue(
            result.violations.contains(where: { $0.code == "CAP_2X" }),
            "expected CAP_2X, got: \(result.violations)"
        )
    }

    func test_canary_catchesNonFinite() throws {
        let (target, history) = try makeFixtureWithOneCarryForward()
        let item = try XCTUnwrap(target.items.first)
        item.suggestedLoad = Double.nan

        let result = invariantViolations(forTarget: target, history: history)

        XCTAssertTrue(
            result.violations.contains(where: { $0.code == "NONFINITE" }),
            "expected NONFINITE, got: \(result.violations)"
        )
    }

    func test_canary_catchesDuplicateExerciseId() throws {
        let (target, history) = try makeFixtureWithOneCarryForward()
        guard target.items.count >= 2 else {
            XCTFail("expected at least 2 items in the target session")
            return
        }
        target.items[1].exerciseId = target.items[0].exerciseId

        let result = invariantViolations(forTarget: target, history: history)

        XCTAssertTrue(
            result.violations.contains(where: { $0.code == "ID_INTEGRITY" }),
            "expected ID_INTEGRITY, got: \(result.violations)"
        )
    }

    func test_canary_catchesPlanCountMismatch() throws {
        let (target, history) = try makeFixtureWithOneCarryForward()
        let item = try XCTUnwrap(target.items.first)
        item.plannedLoadsBySet = Array(repeating: item.suggestedLoad, count: item.targetSets + 1)

        let result = invariantViolations(forTarget: target, history: history)

        XCTAssertTrue(
            result.violations.contains(where: { $0.code == "PLAN_COUNT" }),
            "expected PLAN_COUNT, got: \(result.violations)"
        )
    }
}
