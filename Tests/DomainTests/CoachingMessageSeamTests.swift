import XCTest
import SwiftData
@testable import ElitePerformance

final class CoachingMessageSeamTests: XCTestCase {

    // Broken at authorship (see TestOpenQuestions.swift): this fixture logs
    // only 1 of 3 planned sets. Stage-aware gating in CoachingEngine.recommend
    // (Domain/Logic/CoachingEngine.swift) intentionally returns nil until all
    // planned sets are logged — "nothing useful to say yet" for set 1 of 3 on
    // target. The seam (handleSetLogged threading CoachingEngine's result into
    // exercise.coachMessage) is correct; the old assertion expecting a
    // populated message from a partial session was wrong.
    func testHandleSetLogged_partialSession_noMessageYet() throws {
        let schema = Schema([Session.self, SessionItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let session = Session(date: Date(), weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1,
            exerciseId: "bench_press",
            targetReps: 10,
            targetSets: 3,
            targetRIR: 2,
            suggestedLoad: 100,
            plannedRepsBySet: [10, 10, 10],
            plannedLoadsBySet: [100, 100, 100],
            plannedRIRsBySet: [2, 2, 2]
        )
        session.items = [item]
        context.insert(session)

        let vm = SessionScreenViewModel(session: session)

        vm.exercises[0].sets[0].actualLoadText = "100"
        vm.exercises[0].sets[0].actualRepsText = "10"
        vm.exercises[0].sets[0].actualRIR = 2

        vm.handleSetLogged(
            exerciseID: vm.exercises[0].id,
            setIndex: 1,
            context: context
        )

        // Stage-gating intentional — no verdict until all planned sets are logged.
        XCTAssertNil(CoachingEngine.recommend(for: item), "only 1 of 3 planned sets logged — CoachingEngine must withhold a verdict")
        XCTAssertTrue(vm.exercises[0].coachMessage.isEmpty, "Stage-gating intentional — no verdict until all planned sets are logged.")
    }

    // Companion to the partial-session case above: with all planned sets
    // logged (targetSets: 1, satisfied by the single set below), the stage
    // gate clears and CoachingEngine.recommend produces a real verdict that
    // must reach exercise.coachMessage through the same seam.
    func testHandleSetLogged_completeSession_emitsCoachMessage() throws {
        let schema = Schema([Session.self, SessionItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let session = Session(date: Date(), weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1,
            exerciseId: "bench_press",
            targetReps: 10,
            targetSets: 1,
            targetRIR: 2,
            suggestedLoad: 100,
            plannedRepsBySet: [10],
            plannedLoadsBySet: [100],
            plannedRIRsBySet: [2]
        )
        session.items = [item]
        context.insert(session)

        let vm = SessionScreenViewModel(session: session)

        vm.exercises[0].sets[0].actualLoadText = "100"
        vm.exercises[0].sets[0].actualRepsText = "10"
        vm.exercises[0].sets[0].actualRIR = 2

        vm.handleSetLogged(
            exerciseID: vm.exercises[0].id,
            setIndex: 1,
            context: context
        )

        let expected = CoachingEngine.recommend(for: item)?.message
        XCTAssertNotNil(expected, "all planned sets (1 of 1) logged on-target — CoachingEngine must produce a real verdict")
        XCTAssertEqual(vm.exercises[0].coachMessage, expected)
        XCTAssertFalse(vm.exercises[0].coachMessage.isEmpty)
    }
}
