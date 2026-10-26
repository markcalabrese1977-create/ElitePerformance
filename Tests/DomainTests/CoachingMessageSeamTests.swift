import XCTest
import SwiftData
@testable import ElitePerformance

/// SessionScreenViewModel aborts the test host when it is released from a plain XCTest method
/// (SIGABRT in swift_task_deinitOnExecutorMainActorBackDeploy). Objects built by tests that
/// create one are parked here for the life of the process.
private var parkedForProcessLifetime: [AnyObject] = []
private func parkForProcessLifetime(_ objects: AnyObject...) { parkedForProcessLifetime.append(contentsOf: objects) }

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
        parkForProcessLifetime(vm, session, item, container)

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
        parkForProcessLifetime(vm, session, item, container)

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
        XCTAssertTrue(r?.message.contains("3 of 4 planned sets logged") ?? false, "SURPRISING: bump withheld because the prefilled 0-load 4th set does not count")
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
        XCTAssertTrue(r?.message.contains("3 of 4 planned sets logged") ?? false)
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


    // MARK: A1. Planned rows only (extra rows past targetSets are not evidence)

    /// Device repro a): 3 planned back-offs, a top set logged FIRST in extra row 4.
    func test_A1a_onlyExtraRowLogged_noMessage() {
        let r = rec(3, [0, 0, 0, 5], [0, 0, 0, 315], "A1a")
        XCTAssertNil(r, "an extra row alone is judged against nothing: no message")
    }

    /// Device repro b): extra row plus planned rows. The gate counts planned rows only and the
    /// carried load is the planned row's, never the extra row's.
    func test_A1b_extraRowDoesNotCountTowardSetsLogged() {
        let r = rec(3, [7, 7, 0, 5], [290, 290, 0, 315], "A1b")
        XCTAssertEqual(r?.message, "2 of 3 planned sets logged.")
        XCTAssertEqual(r?.nextSuggestedLoad, 290, "not the 315 of the extra row")
    }

    /// One planned row on target plus the extra row: nothing to say yet (was "2 sets in. Finish").
    func test_A1b2_onePlannedRowOnTargetPlusExtra_noMessage() {
        XCTAssertNil(rec(3, [7, 0, 0, 5], [290, 0, 0, 315], "A1b2"))
    }

    func test_A1_setLabelUsesTheRealRowNumber() {
        let r = rec(3, [0, 5, 0], [0, 100, 0], "A1 label")
        XCTAssertTrue(r?.message.hasPrefix("Set 2 came in short") ?? false, r?.message ?? "nil")
    }

    /// Rows 1, 2 and 4 logged, row 3 skipped: 3 working rows exist but only 2 are planned.
    func test_A1_rows1_2_4_isInsufficientEvidence() {
        let i = coachItem(targetSets: 3, reps: [8, 8, 0, 8], loads: [100, 100, 0, 100])
        XCTAssertEqual(CoachingEngine.workingSetIndices(for: i), [0, 1, 3])
        XCTAssertEqual(CoachingEngine.plannedWorkingSetIndices(for: i), [0, 1])
        XCTAssertFalse(CoachingEngine.hasSufficientPrimaryEvidence(i), "an extra row must not complete the evidence")
        let r = CoachingEngine.recommend(for: i)
        XCTAssertEqual(r?.message, "2 of 3 planned sets logged.")
        XCTAssertEqual(r?.nextSuggestedLoad, 100)
    }

    /// Rows 1-3 plus extra row 4: evidence is sufficient and the extra row never becomes primary.
    func test_A1_rows1to3_plusExtra_unchanged() {
        let i = coachItem(targetSets: 3, reps: [8, 8, 8, 5], loads: [100, 100, 100, 100])
        XCTAssertTrue(CoachingEngine.hasSufficientPrimaryEvidence(i))
        XCTAssertEqual(CoachingEngine.recommend(for: i)?.nextSuggestedLoad, 105.0)
    }

    /// Rule 1d is untouched for an item with no extra rows.
    func test_A1_rule1d_unchangedWithoutExtraRows() {
        let r = rec(3, [8, 8, 8], [100, 100, 88], "A1 1d")
        XCTAssertEqual(r?.nextSuggestedLoad, 88)
        XCTAssertTrue(r?.message.contains("Load dropped from 100 to 88") ?? false, r?.message ?? "nil")
    }


    // MARK: A2. Padded slots and the stored-0 RIR sentinel

    /// Device repro c): a Program-tab-padded item (4th slot is 0 load / 0 reps / 0 RIR), Add Set,
    /// top set logged in the visible 4th row. The pre-existing 4th row was built from the padded
    /// 0 RIR; after logging, a rebuilt screen shows the row as a planned working row.
    func test_A2_paddedZeroRIR_isUnset_onTheAddedRowBeforeAndAfterLogging() throws {
        let ctx = try makeContext()
        let session = Session(date: Date(), weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
            repMin: 6, repMax: 8,
            plannedRepsBySet: [7, 7, 7, 0],
            plannedLoadsBySet: [290, 290, 290, 0],
            plannedRIRsBySet: [2, 2, 2, 0]
        )
        session.items = [item]
        ctx.insert(session)
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)

        XCTAssertEqual(vm.exercises[0].sets[3].plannedRIR, 2, "padded 0 RIR is unset: show the base RIR, not '@ 0 RIR'")
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        log(vm, ctx, set: 4, load: "315", reps: "5")
        XCTAssertEqual(item.actualLoads[3], 315)

        let reopened = SessionScreenViewModel(session: session)
        park(reopened)
        let row4 = reopened.exercises[0].sets[3]
        XCTAssertEqual(row4.plannedRIR, 2, "after logging, the row must not read '@ 0 RIR' either")
        // Cause of "SUGGESTED 290": row 4 is inside targetSets (Add Set made it 4) and its stored
        // per-set load is 0, so the rebuild falls back to the item's suggested load.
        XCTAssertEqual(item.plannedLoadsBySet[3], 0)
        XCTAssertEqual(row4.plannedLoad, 290, "planned row with no per-set load takes the item's suggested load")
    }

    /// A carry-forward write onto a materialized target must not fill padded slots past targetSets.
    func test_A2_propagation_doesNotFillPaddedExtraSlots() throws {
        let fixture = try JourneyFixture.make()
        var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = 6
        try fixture.seedProgram(startDate: Calendar.current.date(from: comps)!, startingLoad: 100.0)
        let first = try XCTUnwrap(fixture.currentPlannedSession())
        let sessions = fixture.allSessionsSorted()
        let benchId = ExerciseCatalog.benchPress.id
        let source = try XCTUnwrap(fixture.item(benchId, in: first))
        let target = try XCTUnwrap(fixture.item(benchId, in: sessions[6]))
        let sets = target.targetSets
        // A materialized, unedited plan whose arrays the Program tab padded to 4.
        target.suggestedLoad = 95
        target.plannedLoadsBySet = Array(repeating: 95, count: sets) + [0]
        XCTAssertGreaterThan(sets, 0)

        let reps = (source.repMax ?? source.targetReps) + 2
        let logs = first.items.map { it in
            JourneyExerciseLog(exerciseId: it.exerciseId, sets: (0..<it.targetSets).map { _ in
                JourneySetLog(load: 100, reps: reps, rir: it.targetRIR, feedback: "", pump: 0)
            })
        }
        try fixture.logAndComplete(JourneySessionScript(logs: logs))

        XCTAssertNotEqual(target.suggestedLoad, 95, "the write must have happened for this test to mean anything")
        XCTAssertEqual(Array(target.plannedLoadsBySet.prefix(sets)), Array(repeating: target.suggestedLoad, count: sets))
        XCTAssertEqual(target.plannedLoadsBySet.dropFirst(sets).filter { $0 != 0 }.count, 0,
                       "padded slots past targetSets must stay 0: \(target.plannedLoadsBySet)")
    }


    func test_A2_extraSetLabel_andZeroLoadShowsDash() {
        XCTAssertEqual(UISessionSet.extraSetLabel(repRange: RepRange(min: 6, max: 8), rir: 2), "EXTRA SET  6-8 reps @ 2 RIR")
        XCTAssertEqual(UISessionSet.extraSetLabel(repRange: RepRange(min: 8, max: 8), rir: 1), "EXTRA SET  8 reps @ 1 RIR")
        let row = UISessionSet(index: 4, exerciseId: "bench_press", plannedLoad: 0, plannedReps: 6, plannedRIR: 2)
        XCTAssertEqual(row.plannedDescription(with: RepRange(min: 6, max: 8)), "— × 6–8 · goal 8 @ 2 RIR")
        XCTAssertEqual(row.plannedDescription(with: RepRange(min: 6, max: 8), isBodyweight: true), "BW × 6–8 · goal 8 @ 2 RIR")
    }


    // MARK: A3. History and CSV include every logged row

    func test_A3_loggedRowSelection_plannedRowsPlusLoggedExtras() {
        let logged: Set<Int> = [3]   // an extra row 4 with a logged set; row 5 is unlogged padding
        XCTAssertEqual(LoggedRowSelection.indices(targetSets: 3, rowCount: 5, isLogged: { logged.contains($0) }), [0, 1, 2, 3])
        XCTAssertEqual(LoggedRowSelection.indices(targetSets: 3, rowCount: 5, isLogged: { _ in false }), [0, 1, 2])
        XCTAssertEqual(LoggedRowSelection.indices(targetSets: 4, rowCount: 3, isLogged: { _ in false }), [0, 1, 2], "never past rowCount")
        XCTAssertEqual(LoggedRowSelection.indices(targetSets: 0, rowCount: 2, isLogged: { _ in false }), [0], "at least one planned row")
    }

    func test_A3_csvExport_includesLoggedExtraRow_butNotUnloggedPadding() throws {
        let ctx = try makeContext()
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
            plannedRepsBySet: [8, 8, 8, 0, 0], plannedLoadsBySet: [290, 290, 290, 0, 0], plannedRIRsBySet: [2, 2, 2, 0, 0],
            actualReps: [8, 7, 6, 5, 0], actualLoads: [290, 290, 290, 315, 0], actualRIRs: [2, 2, 2, 2, 0]
        )
        session.items = [item]
        ctx.insert(session)
        try ctx.save()

        let name = "a3_\(UUID().uuidString).csv"
        let result = try SetsV1CSVExporter.exportCompletedSessionsCSV(modelContext: ctx, fileName: name)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let lines = try String(contentsOf: result.url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(result.rowCount, 4, "3 planned rows + the logged extra row; the unlogged padding row is not exported")
        XCTAssertEqual(lines.count, 5, "header + 4 rows")
        XCTAssertTrue(lines[4].contains(",4,3,"), "set_index 4, target_sets 3: \(lines[4])")
        XCTAssertTrue(lines[4].contains("315"), lines[4])
    }

    // MARK: 4. Top-set pattern, persistent 4-set items, Skip

    private func benchTopSetItem(reps: [Int], loads: [Double]) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 6, targetSets: 4, targetRIR: 2, suggestedLoad: 290,
            repMin: 6, repMax: 8
        )
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = Array(repeating: 2, count: reps.count)
        i.plannedRepsBySet = Array(repeating: 7, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    /// 4a. Three back-offs at 290 x 7 plus a 315 x 5 top set in row 4.
    func test_4a_benchTopSetPattern_backOffsMidRange_holdsAtThirdBackOffLoad() {
        let r = CoachingEngine.recommend(for: benchTopSetItem(reps: [7, 7, 7, 5], loads: [290, 290, 290, 315]))
        XCTAssertEqual(r?.nextSuggestedLoad, 290, "baseLoad is the 3rd working set (a back-off), not the 315 top set")
        XCTAssertTrue(r?.message.contains("hold 290.0") ?? false, r?.message ?? "nil")
        // The 315 row is the 4th set, so it is not a primary set: it neither earns a bump nor
        // appears in baseLoad. Primary reps (7,7,7) are below repMax 8, so the outcome is a hold.
    }

    /// 4b. Same, but the back-offs top the range.
    func test_4b_benchTopSetPattern_backOffsAtTop_bumpComputesFrom290Not315() {
        let r = CoachingEngine.recommend(for: benchTopSetItem(reps: [8, 8, 8, 5], loads: [290, 290, 290, 315]))
        XCTAssertEqual(r?.nextSuggestedLoad, 295, "bump = 290 + one 5.0 bench step, computed from the 3rd back-off")
        XCTAssertTrue(r?.message.contains("increase earned") ?? false, r?.message ?? "nil")
        // SURPRISING: the top set's 315 is ignored for next load; the next session's load is
        // 295 even though the lifter just did 315 x 5.
    }

    /// Four-set item sized the way a repair would size it: every planned array non-zero, length 4.
    private func persistentFourSetSession(in context: ModelContext) -> (Session, SessionItem) {
        let session = Session(date: Date(), weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 8, targetSets: 4, targetRIR: 2, suggestedLoad: 100,
            repMin: 6, repMax: 8,
            plannedRepsBySet: [8, 8, 8, 8],
            plannedLoadsBySet: [100, 100, 100, 100],
            plannedRIRsBySet: [2, 2, 2, 2]
        )
        session.items = [item]
        context.insert(session)
        return (session, item)
    }

    /// 4c. Persistent 4-set item, all four rows logged normally (compare with the Add Set path).
    func test_4c_persistentFourSetItem_logAllFour() throws {
        let ctx = try makeContext()
        let (session, item) = persistentFourSetSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)

        XCTAssertEqual(vm.exercises[0].sets.count, 4, "no hidden 5th row: rows = max(4, targetSets)")
        XCTAssertEqual(vm.exercises[0].sets[3].plannedLoad, 100, "row 4 is a planned working set: planned load comes from the array")
        XCTAssertEqual(vm.exercises[0].sets[3].actualLoadText, "100.0", "prefilled with the planned load, not 0")
        for s in 1...4 { log(vm, ctx, set: s, load: nil) }

        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual(item.actualLoads, [100, 100, 100, 100])
        XCTAssertEqual(item.actualReps, [8, 8, 8, 8])
        XCTAssertEqual(item.plannedLoadsBySet, [100, 100, 100, 100])
        XCTAssertEqual(CoachingEngine.recommend(for: item)?.nextSuggestedLoad, 105, "same bump as the control; no 0-load trap")
        // Contrast with the Add Set path: there row 4 prefills 0 and the seed lands on a hidden 5th row.
    }

    /// 4d. Persistent 4-set item: 3 sets logged, then Skip on row 4.
    func test_4d_skipFourthRow_stillTripsNSetsInHold() throws {
        let ctx = try makeContext()
        let (session, item) = persistentFourSetSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        park(vm, session, item)
        for s in 1...3 { log(vm, ctx, set: s, load: nil) }
        vm.skipSet(exerciseID: vm.exercises[0].id, setIndex: 4, reason: .none, context: ctx)

        XCTAssertEqual(item.targetSets, 4, "Skip does not reduce the planned working set count")
        XCTAssertEqual(item.actualReps, [8, 8, 8, 0])
        XCTAssertEqual(item.restPausePatternsBySet[3], "SKIP")
        XCTAssertTrue(vm.exercises[0].isComplete, "a skipped set counts as done for completion")
        XCTAssertEqual(session.status, .completed)
        let r = CoachingEngine.recommend(for: item)
        XCTAssertEqual(r?.nextSuggestedLoad, 100)
        XCTAssertTrue(r?.message.contains("3 of 4 planned sets logged") ?? false, r?.message ?? "nil")
        // SURPRISING: the item is complete and carry-forward ran, yet the engine treats it as
        // incomplete (RULE 3) and withholds the bump the three primary sets earned.
    }
}
