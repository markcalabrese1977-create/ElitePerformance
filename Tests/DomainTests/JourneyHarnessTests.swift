import XCTest
import SwiftData
@testable import ElitePerformance

/// Journey harness smoke test — proves the real pipeline runs end-to-end.
///
/// Carry-forward note: this test exercises the "first session ever" path.
/// The source item has suggestedLoad = 100 (written by seedProgram).
/// The target item starts with suggestedLoad = 0 and plannedLoadsBySet = [0,...].
/// After carry-forward:
///   - The baseline copy sets targetItem.suggestedLoad = 100 unconditionally.
///   - LoadProjectionService.project may then OVERRIDE to a projected value
///     (capped at sourceItem.suggestedLoad * 2.0 = 200). With a single session
///     of history its projection basis will be .currentMesoPeak or similar.
///   - Either path results in suggestedLoad > 0 on the next session.
final class JourneyHarnessTests: XCTestCase {

    func test_smoke_seedThenOneSession_nextSessionHasNonZeroSuggestedLoad() throws {
        let fixture = try JourneyFixture.make()

        // Monday 2026-07-06 — ensures clean weekday alignment with Mon+Thu schedule
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!

        try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

        // Confirm the program seeded correctly
        let firstSession = try XCTUnwrap(fixture.currentPlannedSession(), "Expected at least one planned session after seeding")
        XCTAssertFalse(firstSession.items.isEmpty, "First session should have exercises")

        // Build a realistic session script: log every exercise at 100 lbs, 10 reps, RIR 2
        let logs: [JourneyExerciseLog] = firstSession.items.map { item in
            let sets = (0..<item.targetSets).map { _ in
                JourneySetLog(load: 100.0, reps: item.targetReps, rir: 2, feedback: "", pump: 0)
            }
            return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
        }
        let script = JourneySessionScript(logs: logs)

        try fixture.logAndComplete(script)

        // After completing session 1, the carry-forward engine should have written
        // nonzero suggestedLoad to the next session's matching exercises.
        let nextSession = try XCTUnwrap(fixture.nextPlannedSession(), "Expected a second planned session")
        XCTAssertFalse(nextSession.items.isEmpty, "Next session should have exercises")

        // Assert on bench press specifically (anchor lift in Day A)
        let benchId = ExerciseCatalog.benchPress.id
        let nextBench = try XCTUnwrap(
            fixture.item(benchId, in: nextSession),
            "Next session should contain bench press"
        )

        XCTAssertGreaterThan(
            nextBench.suggestedLoad, 0,
            "carry-forward must write a nonzero suggestedLoad to the next bench press item"
        )
        XCTAssertFalse(
            nextBench.plannedLoadsBySet.isEmpty,
            "carry-forward must populate plannedLoadsBySet on the next bench press item"
        )
        XCTAssertTrue(
            nextBench.plannedLoadsBySet.allSatisfy { $0 > 0 },
            "every planned load in the next session should be nonzero after carry-forward"
        )
    }
}
