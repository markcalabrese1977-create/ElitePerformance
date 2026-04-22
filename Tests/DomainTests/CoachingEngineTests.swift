import XCTest
@testable import ElitePerformance

final class CoachingEngineTests: XCTestCase {

    private func item(
        reps: [Int],
        loads: [Double],
        rirs: [Int],
        targetReps: Int = 10,
        targetRIR: Int = 2,
        plannedTopReps: Int = 12
    ) -> SessionItem {
        let i = SessionItem(
            order: 1,
            exerciseId: "test_exercise",
            targetReps: targetReps,
            targetSets: reps.count,
            targetRIR: targetRIR,
            suggestedLoad: loads.first ?? 0
        )
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = rirs
        i.plannedRepsBySet = Array(repeating: plannedTopReps, count: reps.count)
        return i
    }

    func testOnTargetProducesHold() {
        let i = item(reps: [10, 10, 9], loads: [100, 100, 100], rirs: [2, 2, 2])
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad, 100)
        XCTAssertFalse(result?.message.isEmpty ?? true)
    }

    func testAllAtTopProducesIncrease() {
        let i = item(
            reps: [12, 12, 12],
            loads: [100, 100, 100],
            rirs: [2, 2, 2],
            targetReps: 10,
            plannedTopReps: 12
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result?.nextSuggestedLoad ?? 0, 100)
    }

    func testDownshiftProducesRebaseline() {
        let i = item(
            reps: [8, 8, 8, 8],
            loads: [126, 106, 106, 106],
            rirs: [2, 2, 2, 2]
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad, 106)
    }

    func testUnderTargetRepsProducesHold() {
        let i = item(
            reps: [7, 7, 6],
            loads: [100, 100, 100],
            rirs: [1, 1, 0],
            targetReps: 10
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad, 100)
    }
}
