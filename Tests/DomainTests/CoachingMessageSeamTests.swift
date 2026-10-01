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

// MARK: - Earned-volume characterization (Add Set rows + 4-set coaching gates)
//
// CHARACTERIZATION ONLY: these pin what the code does today. A comment marked
// "SURPRISING" flags a result that may not match intent; nothing here is a fix.

final class EarnedVolumeCharacterizationTests: XCTestCase {

    // MARK: Helpers

    /// Held for the test's lifetime: a ModelContext does not retain its container.
    private var container: ModelContainer?

    /// SessionScreenViewModel has a known deinit crash (abrt) when released. Objects
    /// built by these tests are parked here for the life of the test process.
    private static var parked: [AnyObject] = []
    private func park(_ objects: AnyObject...) { Self.parked.append(contentsOf: objects) }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        park(c)
        return ModelContext(c)
    }

    /// 3-set item, planned 8 reps @ 100, repMin/Max 6-8, RIR 2 (arrays length 3, as the materializer sizes them).
    private func threeSetSession(in context: ModelContext, plannedLoads: [Double] = [100, 100, 100]) -> (Session, SessionItem) {
        let session = Session(date: Date(), weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
            repMin: 6, repMax: 8,
            plannedRepsBySet: Array(repeating: 8, count: plannedLoads.count),
            plannedLoadsBySet: plannedLoads,
            plannedRIRsBySet: Array(repeating: 2, count: plannedLoads.count)
        )
        session.items = [item]
        context.insert(session)
        return (session, item)
    }

    private func log(_ vm: SessionScreenViewModel, _ ctx: ModelContext, set: Int, load: String?, reps: String = "8") {
        let id = vm.exercises[0].id
        if let load { vm.exercises[0].sets[vm.exercises[0].sets.firstIndex { $0.index == set }!].actualLoadText = load }
        vm.exercises[0].sets[vm.exercises[0].sets.firstIndex { $0.index == set }!].actualRepsText = reps
        vm.exercises[0].sets[vm.exercises[0].sets.firstIndex { $0.index == set }!].actualRIR = 2
        vm.handleSetLogged(exerciseID: id, setIndex: set, context: ctx)
    }

    // MARK: 1. Today-tab Add Set

    func test_addSet_explicitLoadOnVisibleFourthRow() throws {
        let ctx = try makeContext()
        let (session, item) = threeSetSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)
        for s in 1...3 { log(vm, ctx, set: s, load: "100") }

        XCTAssertEqual(vm.exercises[0].sets.count, 4, "init always builds max(4, targetSets) rows")
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        XCTAssertEqual(vm.exercises[0].targetSets, 4)
        XCTAssertEqual(vm.exercises[0].sets.map(\.index), [1, 2, 3, 4, 5], "Add Set appends index max+1 = 5; the visible 4th row is the pre-existing one")
        XCTAssertEqual(item.targetSets, 4, "addSet persists targetSets on this item")

        let row4 = vm.exercises[0].sets[3]
        let row5 = vm.exercises[0].sets[4]

        log(vm, ctx, set: 4, load: "105")

        XCTAssertEqual(row4.plannedLoad, 0, "SURPRISING: visible 4th row planned load is 0")
        XCTAssertEqual(row5.plannedLoad, 100, "SURPRISING: the set-3 seed (load 100) landed on the HIDDEN 5th row")
        XCTAssertEqual(item.plannedLoadsBySet, [100, 100, 100, 0, 100])
        XCTAssertEqual(item.actualLoads[3], 105)
        XCTAssertEqual(item.actualReps[3], 8)
        XCTAssertEqual(item.actualReps.count, 5, "arrays are sized to UI rows (5), not targetSets (4)")
        XCTAssertEqual(item.actualReps[4], 0, "hidden 5th row stays unlogged")
        XCTAssertEqual(item.actualLoads[4], 0)
    }

    func test_addSet_prefilledLoadLeftAlone() throws {
        let ctx = try makeContext()
        let (session, item) = threeSetSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)
        for s in 1...3 { log(vm, ctx, set: s, load: "100") }
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)

        let prefilled = vm.exercises[0].sets[3].actualLoadText
        log(vm, ctx, set: 4, load: nil)   // leave the prefilled text untouched

        XCTAssertEqual(prefilled, "0", "SURPRISING: the visible 4th row's planned/prefilled load is 0 (built before targetSets was bumped)")
        XCTAssertEqual(item.actualLoads[3], 0, "SURPRISING: logging with the prefilled text stores load 0 with reps > 0")
        XCTAssertEqual(item.actualReps[3], 8)
        XCTAssertEqual(item.actualReps[4], 0, "hidden 5th row stays unlogged")
        // Coaching: a 0-load set is not a working set, so the engine sees 3 of 4 -> RULE 3 hold.
        let r = CoachingEngine.recommend(for: item)
        XCTAssertEqual(r?.nextSuggestedLoad, 100)
        XCTAssertTrue(r?.message.contains("3 sets in") ?? false, "SURPRISING: bump withheld because the prefilled 0-load 4th set does not count")
    }

    func test_addSet_programTabPaddedPlannedLoad() throws {
        // Item whose plannedLoadsBySet was padded to 4 with a 0 tail (Program-tab normalize).
        let ctx = try makeContext()
        let (session, item) = threeSetSession(in: ctx, plannedLoads: [100, 100, 100, 0])
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)
        for s in 1...3 { log(vm, ctx, set: s, load: "100") }
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        let prefilled = vm.exercises[0].sets[3].actualLoadText
        log(vm, ctx, set: 4, load: nil)
        XCTAssertEqual(prefilled, "0")
        XCTAssertEqual(item.actualLoads[3], 0, "same as the unpadded case: padded 0 planned load prefills 0")
        XCTAssertEqual(item.plannedLoadsBySet.count, 5)
    }

    func test_addSet_loggedTopSetIsWhatCoachingReads() throws {
        let ctx = try makeContext()
        let (session, item) = threeSetSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)
        for s in 1...3 { log(vm, ctx, set: s, load: "100") }
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        log(vm, ctx, set: 4, load: "100")
        let rec = CoachingEngine.recommend(for: item)
        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual(rec?.nextSuggestedLoad, 105.0, "a 4th set with an explicit load counts; bump earned off the primary sets")
    }

    // MARK: 2/3. CoachingEngine gates

    private func coachItem(targetSets: Int, reps: [Int], loads: [Double]) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 8, targetSets: targetSets, targetRIR: 2, suggestedLoad: 100,
            repMin: 6, repMax: 8
        )
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = Array(repeating: 2, count: reps.count)
        i.plannedRepsBySet = Array(repeating: 8, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    private func rec(_ targetSets: Int, _ reps: [Int], _ loads: [Double], _ tag: String) -> CoachingRecommendation? {
        let r = CoachingEngine.recommend(for: coachItem(targetSets: targetSets, reps: reps, loads: loads))
        return r
    }

    // Controls
    func test_control_fourOfFour_allAtTop_bumps() {
        let r = rec(4, [8, 8, 8, 8], [100, 100, 100, 100], "ctl 4/4")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0, "increase earned by primary sets (bench cluster increment is 5.0)")
    }

    func test_control_threeOfThree_allAtTop_bumps() {
        let r = rec(3, [8, 8, 8], [100, 100, 100], "ctl 3/3")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0)
    }

    // targetSets = 4
    func test_2a_fourSetTarget_threeLogged_holdsNoBump() {
        let r = rec(4, [8, 8, 8, 0], [100, 100, 100, 0], "2a")
        XCTAssertEqual(r?.nextSuggestedLoad, 100, "RULE 3: incomplete -> hold at baseLoad")
        XCTAssertTrue(r?.message.contains("3 sets in") ?? false)
        // SURPRISING: all three primary sets topped the range, yet the bump is withheld
        // solely because the 4th (non-primary) set was not logged.
    }

    func test_2b_fourSetTarget_fourthTenPercentLower_rebaselines() {
        let r = rec(4, [8, 8, 8, 8], [100, 100, 100, 89], "2b")
        XCTAssertEqual(r?.nextSuggestedLoad, 89, "RULE 1d re-baseline to the 4th set's load")
        // SURPRISING: a lighter non-primary 4th set pulls the next load DOWN to 89
        // even though every primary set hit the top at 100.
    }

    func test_2c_fourSetTarget_fourthFivePercentLower_noChange() {
        let r = rec(4, [8, 8, 8, 8], [100, 100, 100, 95], "2c")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0, "below the 10% threshold: same outcome as the control")
    }

    func test_2d_fourSetTarget_fourthFewerReps_noChange() {
        let r = rec(4, [8, 8, 8, 5], [100, 100, 100, 100], "2d")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0, "4th-set reps are not primary: same outcome as the control")
    }

    // targetSets = 3 plus one extra logged set
    func test_3a_threeSetTarget_extraSetLoggedSameLoad() {
        let r = rec(3, [8, 8, 8, 8], [100, 100, 100, 100], "3a")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0)
    }

    func test_3b_threeSetTarget_extraSetTenPercentLower() {
        let r = rec(3, [8, 8, 8, 8], [100, 100, 100, 89], "3b")
        XCTAssertEqual(r?.nextSuggestedLoad, 89, "RULE 1d reads all working sets, including the extra one")
        // SURPRISING: same pull-down for an extra set beyond targetSets.
    }

    func test_3c_threeSetTarget_extraSetFivePercentLower() {
        let r = rec(3, [8, 8, 8, 8], [100, 100, 100, 95], "3c")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0)
    }

    func test_3d_threeSetTarget_extraSetFewerReps() {
        let r = rec(3, [8, 8, 8, 5], [100, 100, 100, 100], "3d")
        XCTAssertEqual(r?.nextSuggestedLoad, 105.0)
    }
}
