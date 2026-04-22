import XCTest
import SwiftData
@testable import ElitePerformance

final class CoachingMessageSeamTests: XCTestCase {

    func testHandleSetLoggedWritesCoachingEngineMessage() throws {
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

        let expected = CoachingEngine.recommend(for: item)?.message
        XCTAssertEqual(vm.exercises[0].coachMessage, expected)
        XCTAssertFalse(vm.exercises[0].coachMessage.isEmpty)
    }
}
