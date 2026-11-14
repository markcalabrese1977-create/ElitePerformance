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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        defer { withExtendedLifetime(container) {} }

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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        defer { withExtendedLifetime(container) {} }

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

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
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

        XCTAssertEqual(vm.exercises[0].sets[3].plannedRIR, 2, "padded 0 RIR is unset: show the base RIR, not '@ 0 RIR'")
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        log(vm, ctx, set: 4, load: "315", reps: "5")
        XCTAssertEqual(item.actualLoads[3], 315)

        let reopened = SessionScreenViewModel(session: session)
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


    // MARK: B2. Role-aware coaching (top set + back-offs)

    /// 3 back-off rows (6-8 @ 2, bench cluster step 5) and 1 top row at the tail (4-6 @ 2).
    private func topSetItem(reps: [Int], loads: [Double], rirs: [Int]? = nil) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
            repMin: 6, repMax: 8
        )
        i.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 2
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = rirs ?? Array(repeating: 2, count: reps.count)
        i.plannedRepsBySet = [7, 7, 7, 5]
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    /// Device repro: the top set is logged FIRST (tail row), then the back-offs one by one.
    func test_B2_deviceRepro_topLoggedFirst_thenBackOffs() {
        let a = CoachingEngine.recommend(for: topSetItem(reps: [0, 0, 0, 5], loads: [0, 0, 0, 315]))
        XCTAssertEqual(a?.message, "Top set: 315 x 5, on target — hold.")
        XCTAssertEqual(a?.nextTopLoad, 315)
        XCTAssertNil(a?.nextSuggestedLoad, "no back-off logged: nothing to say about the back-off load")

        let b = CoachingEngine.recommend(for: topSetItem(reps: [7, 0, 0, 5], loads: [290, 0, 0, 315]))
        XCTAssertEqual(b?.message, "Top set: 315 x 5, on target — hold.", "one on-target back-off: nothing to add yet")

        let c = CoachingEngine.recommend(for: topSetItem(reps: [7, 7, 0, 5], loads: [290, 290, 0, 315]))
        XCTAssertEqual(c?.message, "Top set: 315 x 5, on target — hold. Back-offs: 2 of 3 logged.")
        XCTAssertEqual(c?.nextSuggestedLoad, 290, "the back-off base is a back-off, never the 315 top set")
        XCTAssertEqual(c?.nextTopLoad, 315)

        let d = CoachingEngine.recommend(for: topSetItem(reps: [8, 8, 8, 5], loads: [290, 290, 290, 315]))
        XCTAssertTrue(d?.message.hasPrefix("Top set: 315 x 5, on target — hold.") ?? false, d?.message ?? "nil")
        XCTAssertTrue(d?.message.contains("increase earned") ?? false, d?.message ?? "nil")
        XCTAssertEqual(d?.nextSuggestedLoad, 295, "back-off bump is one step off 290")
        XCTAssertEqual(d?.nextTopLoad, 315, "top set at 5 of 4-6 holds")
    }

    func test_B2_topAtTopOfRange_earnsOneStep_underRange_holds() {
        let up = CoachingEngine.recommend(for: topSetItem(reps: [7, 7, 7, 6], loads: [290, 290, 290, 315]))
        XCTAssertEqual(up?.nextTopLoad, 320)
        XCTAssertTrue(up?.message.contains("Top set: 315 x 6, top of the range — increase earned. Next top set: 320.") ?? false, up?.message ?? "nil")
        let low = CoachingEngine.recommend(for: topSetItem(reps: [7, 7, 7, 3], loads: [290, 290, 290, 315]))
        XCTAssertEqual(low?.nextTopLoad, 315)
        XCTAssertTrue(low?.message.contains("under the range (4–6)") ?? false, low?.message ?? "nil")
        let hard = CoachingEngine.recommend(for: topSetItem(reps: [7, 7, 7, 6], loads: [290, 290, 290, 315], rirs: [2, 2, 2, 0]))
        XCTAssertEqual(hard?.nextTopLoad, 315, "harder than the target RIR holds even at the top of the range")
    }

    /// A skipped back-off with the top logged: back-off evidence is insufficient and the top load never
    /// becomes the back-off base.
    func test_B2_skippedBackOff_topLogged_noBackOffWrite_topNeverBase() {
        let i = topSetItem(reps: [7, 7, 0, 5], loads: [290, 290, 0, 315])
        XCTAssertFalse(CoachingEngine.hasSufficientPrimaryEvidence(i))
        XCTAssertTrue(CoachingEngine.hasTopEvidence(i))
        XCTAssertEqual(CoachingEngine.plannedWorkingSetIndices(for: i), [0, 1])
        XCTAssertEqual(CoachingEngine.workingSetIndices(for: i), [0, 1], "top rows are not back-off working sets")
        let r = CoachingEngine.recommend(for: i)
        XCTAssertEqual(r?.nextSuggestedLoad, 290)
        XCTAssertTrue(r?.message.contains("Back-offs: 2 of 3 logged.") ?? false, r?.message ?? "nil")
    }

    /// Top at 315, back-offs 12.7% lighter: the heaviest set is not "an opener above the baseline".
    func test_B2_backOffsTwelvePercentLighter_noRule1dRebaseline() {
        let r = CoachingEngine.recommend(for: topSetItem(reps: [8, 8, 8, 5], loads: [275, 275, 275, 315]))
        XCTAssertFalse(r?.message.contains("Load dropped") ?? true, r?.message ?? "nil")
        XCTAssertEqual(r?.nextSuggestedLoad, 280, "bump off the back-off base 275, not off 315")
        // Control: without roles the same rows ARE a dropped-load pattern when the heavy set leads.
        let legacy = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 6, targetSets: 4, targetRIR: 2,
                                 suggestedLoad: 290, repMin: 6, repMax: 8)
        legacy.actualReps = [5, 8, 8, 8]; legacy.actualLoads = [315, 275, 275, 275]
        legacy.actualRIRs = [2, 2, 2, 2]; legacy.setFeedbackBySet = ["", "", "", ""]
        XCTAssertTrue(CoachingEngine.recommend(for: legacy)?.message.contains("Load dropped") ?? false)
    }

    func test_B2_painOnTopSet_stopsEverything_noTopLoad() {
        let i = topSetItem(reps: [8, 8, 8, 5], loads: [290, 290, 290, 315])
        i.setFeedbackBySet = ["", "", "", SetFeedback.pain.rawValue]
        let r = CoachingEngine.recommend(for: i)
        XCTAssertTrue(r?.message.hasPrefix("Pain was flagged") ?? false, r?.message ?? "nil")
        XCTAssertNil(r?.nextTopLoad)
        XCTAssertNil(r?.nextSuggestedLoad)
    }

    func test_B2_itemWithoutTopSet_hasNoTopLoad() {
        let r = CoachingEngine.recommend(for: coachItem(targetSets: 3, reps: [8, 8, 8], loads: [100, 100, 100]))
        XCTAssertNil(r?.nextTopLoad)
        XCTAssertEqual(r?.nextSuggestedLoad, 105)
    }


    // MARK: B3. Role-aware carry-forward and seeds

    /// Turns `item` into back-offs + one top row at the tail (planned arrays sized to match).
    private func addTop(_ item: SessionItem, topLoad: Double) {
        let n = item.targetSets
        item.setRolesBySet = SessionItem.roles(backOffs: n, tops: 1)
        item.topRepMin = 4; item.topRepMax = 6; item.topRIR = 2
        item.plannedRepsBySet = Array(repeating: item.targetReps, count: n) + [5]
        item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: n) + [2]
        item.plannedLoadsBySet = Array(item.plannedLoadsBySet.prefix(n)) + [topLoad]
    }

    /// Seeds the program, gives week-1 and week-4 Day-A bench a top row, logs the week-1 session
    /// (back-offs at the top of the range, top row as given) and returns (source, target).
    private func topJourney(backOffsLogged: Int? = nil, topLoad: Double = 200, topReps: Int = 6,
                            targetPlan: (SessionItem) -> Void = { _ in }) throws -> (SessionItem, SessionItem) {
        let fixture = try JourneyFixture.make()
        var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = 6
        try fixture.seedProgram(startDate: Calendar.current.date(from: comps)!, startingLoad: 100.0)
        let first = try XCTUnwrap(fixture.currentPlannedSession())
        let sessions = fixture.allSessionsSorted()
        let benchId = ExerciseCatalog.benchPress.id
        let source = try XCTUnwrap(fixture.item(benchId, in: first))
        let target = try XCTUnwrap(fixture.item(benchId, in: sessions[6]))
        let n = source.targetSets
        addTop(source, topLoad: topLoad)
        addTop(target, topLoad: 0)
        targetPlan(target)
        let backReps = (source.repMax ?? source.targetReps) + 2
        let logs = first.items.map { it -> JourneyExerciseLog in
            if it === source {
                let backs = (0..<(backOffsLogged ?? n)).map { _ in
                    JourneySetLog(load: 100, reps: backReps, rir: it.targetRIR, feedback: "", pump: 0)
                }
                let pad = (0..<(n - backs.count)).map { _ in JourneySetLog(load: 0, reps: 0, rir: 0, feedback: "", pump: 0) }
                return JourneyExerciseLog(exerciseId: it.exerciseId,
                                          sets: backs + pad + [JourneySetLog(load: topLoad, reps: topReps, rir: 2, feedback: "", pump: 0)])
            }
            return JourneyExerciseLog(exerciseId: it.exerciseId, sets: (0..<it.targetSets).map { _ in
                JourneySetLog(load: 100, reps: backReps, rir: it.targetRIR, feedback: "", pump: 0)
            })
        }
        try fixture.logAndComplete(JourneySessionScript(logs: logs))
        return (source, target)
    }

    /// Materialized, unedited target plan [95 x n] + top 300: the write is per role.
    func test_B3_propagate_writesBackOffSlotsAndTopSlotSeparately() throws {
        let (_, target) = try topJourney(targetPlan: { t in
            t.suggestedLoad = 95
            t.plannedLoadsBySet = Array(repeating: 95, count: t.targetSets) + [300]
        })
        let n = target.targetSets
        XCTAssertGreaterThan(target.suggestedLoad, 95, "back-off bump written")
        XCTAssertLessThan(target.suggestedLoad, 120, "back-off bump is off the 100 back-offs, never off the 200 top set")
        XCTAssertEqual(Array(target.plannedLoadsBySet.prefix(n)), Array(repeating: target.suggestedLoad, count: n))
        XCTAssertEqual(target.plannedLoadsBySet.count, n + 1, "the tail is preserved")
        XCTAssertEqual(target.plannedLoadsBySet[n], 202.5, "top: one increment off the 200 top set (6 of 4-6 at RIR 2)")
        XCTAssertEqual(target.setRolesBySet, SessionItem.roles(backOffs: n, tops: 1))
    }

    /// A skipped back-off: no back-off write (insufficient evidence), the logged top still writes its own slot.
    func test_B3_skippedBackOff_noBackOffWrite_topStillWrites() throws {
        let (source, target) = try topJourney(backOffsLogged: 2, targetPlan: { t in
            t.suggestedLoad = 95
            t.plannedLoadsBySet = Array(repeating: 95, count: t.targetSets) + [300]
        })
        let n = target.targetSets
        XCTAssertGreaterThanOrEqual(n, 3)
        XCTAssertFalse(CoachingEngine.hasSufficientPrimaryEvidence(source), "2 of \(n) back-offs logged is incomplete evidence")
        XCTAssertTrue(CoachingEngine.hasTopEvidence(source))
        XCTAssertEqual(target.suggestedLoad, 95, "back-off load untouched")
        XCTAssertEqual(Array(target.plannedLoadsBySet.prefix(n)), Array(repeating: 95, count: n))
        XCTAssertEqual(target.plannedLoadsBySet[n], 202.5, "the top set has its own evidence")
    }

    /// Empty target: back-off loads resized to the target's back-off count, the top slot from the source's top.
    func test_B3_emptyTargetSeed_keepsTailAndRoles() throws {
        let (_, target) = try topJourney(topLoad: 200, topReps: 5, targetPlan: { t in
            t.suggestedLoad = 0
            t.plannedLoadsBySet = Array(repeating: 0, count: t.targetSets + 1)
        })
        let n = target.targetSets
        XCTAssertEqual(target.plannedLoadsBySet.count, n + 1)
        XCTAssertTrue(target.plannedLoadsBySet.prefix(n).allSatisfy { $0 > 0 && $0 < 150 }, "\(target.plannedLoadsBySet)")
        XCTAssertEqual(target.plannedLoadsBySet[n], 200, "top in range holds at the logged top load")
    }

    func test_B3_propagatedPlan_isRoleAware_andPaddingStaysZero() {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        item.plannedLoadsBySet = [90, 90, 90, 300, 0]    // 5th = padding
        XCTAssertEqual(PlanMemoryEngine.propagatedPlan(100, top: 320, for: item), [100, 100, 100, 320, 0])
        XCTAssertEqual(PlanMemoryEngine.propagatedPlan(100, for: item), [100, 100, 100, 300, 0], "nil top keeps the top slot")
        XCTAssertEqual(PlanMemoryEngine.propagatedPlan(nil, top: 320, for: item), [90, 90, 90, 320, 0], "nil back-off keeps the back-off slots")
    }

    func test_B3_resizeBackOffs_keepsTopTailAndRoles() {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
                               plannedRepsBySet: [7, 7, 7, 5], plannedLoadsBySet: [290, 290, 290, 315], plannedRIRsBySet: [2, 2, 2, 2])
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        item.resizeBackOffs(to: 4, backOffLoad: 300)
        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual(item.plannedLoadsBySet, [300, 300, 300, 300, 315])
        XCTAssertEqual(item.plannedRepsBySet, [7, 7, 7, 7, 5])
        XCTAssertEqual(item.setRolesBySet, ["", "", "", "", "top"])
        item.resizeBackOffs(to: 2)
        XCTAssertEqual(item.plannedLoadsBySet, [300, 300, 315])
        XCTAssertEqual(item.setRolesBySet, ["", "", "top"])
        // No top set: only loads, exactly as carry-forward always did.
        let plain = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
                                plannedRepsBySet: [7, 7, 7], plannedLoadsBySet: [290, 290, 290], plannedRIRsBySet: [2, 2, 2])
        plain.resizeBackOffs(to: 4, backOffLoad: 300)
        XCTAssertEqual(plain.plannedLoadsBySet, [300, 300, 300, 300])
        XCTAssertNil(plain.setRolesBySet)
    }

    private func completedSession(daysAgo: Int, rows: [(Double, Int)], top: Bool, in ctx: ModelContext) -> Session {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: top ? rows.count - 1 : rows.count,
                               targetRIR: 2, suggestedLoad: rows[0].0, repMin: 6, repMax: 8)
        item.actualLoads = rows.map(\.0); item.actualReps = rows.map(\.1)
        item.actualRIRs = Array(repeating: 2, count: rows.count)
        item.plannedLoadsBySet = rows.map(\.0)
        if top { item.setRolesBySet = SessionItem.roles(backOffs: rows.count - 1, tops: 1); item.topRepMin = 4; item.topRepMax = 6; item.topRIR = 2 }
        let s = Session(date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [item])
        ctx.insert(s)
        return s
    }

    func test_B3_historySeed_backOffFromBackOffRows_topFromTopRows_peakCountsAll() throws {
        let ctx = try makeContext()
        let withTop = completedSession(daysAgo: 7, rows: [(275, 8), (275, 8), (275, 8), (315, 5)], top: true, in: ctx)
        let backOnly = completedSession(daysAgo: 7, rows: [(275, 8), (275, 8), (275, 8)], top: false, in: ctx)
        let a = HistorySeedLoad.load(for: "bench_press", goalReps: 8, targetRIR: 2, in: [withTop], loadIncrement: 5)
        let b = HistorySeedLoad.load(for: "bench_press", goalReps: 8, targetRIR: 2, in: [backOnly], loadIncrement: 5)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "the back-off seed ignores the heavier top row")
        let top = HistorySeedLoad.load(for: "bench_press", goalReps: 5, targetRIR: 2, in: [withTop], loadIncrement: 5, role: .top)
        let legacyTop = HistorySeedLoad.load(for: "bench_press", goalReps: 5, targetRIR: 2, in: [backOnly], loadIncrement: 5, role: .top)
        XCTAssertNotNil(top); XCTAssertNotNil(legacyTop)
        XCTAssertGreaterThan(top ?? 0, legacyTop ?? 0, "top seed reads the 315 x 5 row; a session with no top row falls back to all its rows")
        let peakAll = try XCTUnwrap(HistorySeedLoad.peakE1RM(for: "bench_press", in: [withTop]))
        let peakBack = try XCTUnwrap(HistorySeedLoad.peakE1RM(for: "bench_press", in: [withTop], role: .backOff))
        XCTAssertGreaterThan(peakAll, peakBack, "peak e1RM still counts every row")
    }

    func test_B3_isCleanSession_judgesBackOffRowsOnly() {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
                            repMin: 6, repMax: 8)
        i.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        i.actualReps = [7, 7, 7, 3]; i.actualLoads = [290, 290, 290, 315]; i.actualRIRs = [2, 2, 2, 0]
        XCTAssertTrue(LoadProjectionService.isCleanSession(i, prescribedMin: 6), "a hard 3-rep top set does not fail the back-offs")
        i.actualReps = [5, 5, 5, 12]
        XCTAssertFalse(LoadProjectionService.isCleanSession(i, prescribedMin: 6), "a 12-rep top row does not satisfy the back-off minimum")
    }

    func test_B3_lastKnownLoad_isTheLastBackOff_notTheTopSet() throws {
        let ctx = try makeContext()
        _ = completedSession(daysAgo: 3, rows: [(290, 8), (290, 8), (290, 8), (315, 5)], top: true, in: ctx)
        let current = Session(date: Date(), weekIndex: 1, items: [])
        ctx.insert(current)
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: current, context: ctx), 290)
    }


    // MARK: B4. Top set in the logger

    private func topSession(in ctx: ModelContext) -> (Session, SessionItem) {
        let session = Session(date: Date(), weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1, exerciseId: "bench_press",
            targetReps: 7, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
            repMin: 6, repMax: 8,
            plannedRepsBySet: [7, 7, 7, 5], plannedLoadsBySet: [290, 290, 290, 315], plannedRIRsBySet: [2, 2, 2, 2]
        )
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        item.topRepMin = 4; item.topRepMax = 6; item.topRIR = 2
        session.items = [item]
        ctx.insert(session)
        return (session, item)
    }

    func test_B4_topRowIsBuiltFirstInDisplay_withItsOwnPlan() throws {
        let ctx = try makeContext()
        let (session, item) = topSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        let ex = vm.exercises[0]
        XCTAssertEqual(ex.sets.map(\.index), [1, 2, 3, 4], "storage order keeps the top at the tail")
        XCTAssertEqual(ex.displaySets.map(\.index), [4, 1, 2, 3], "display shows the top first")
        let top = ex.sets[3]
        XCTAssertTrue(top.isTop)
        XCTAssertEqual([top.plannedLoad, Double(top.plannedReps), Double(top.plannedRIR ?? -1)], [315, 5, 2])
        XCTAssertEqual([ex.topRepMin, ex.topRepMax], [4, 6])
        XCTAssertFalse(ex.sets[0].isTop)
        XCTAssertEqual(ex.topCount, 1)
    }

    /// Device repro through the real logger: top first, then the back-offs; completion needs every planned row incl. the top.
    func test_B4_topLoggedFirst_roleFromRow_coachingAndCompletion() throws {
        let ctx = try makeContext()
        let (session, item) = topSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        log(vm, ctx, set: 4, load: "315", reps: "5")
        XCTAssertEqual(vm.exercises[0].coachMessage, "Top set: 315 x 5, on target — hold.")
        XCTAssertEqual(item.actualLoads, [0, 0, 0, 315])
        XCTAssertEqual(item.setRolesBySet, ["", "", "", "top"], "role persisted from the row")
        log(vm, ctx, set: 1, load: "290", reps: "7")
        log(vm, ctx, set: 2, load: "290", reps: "7")
        XCTAssertEqual(vm.exercises[0].coachMessage, "Top set: 315 x 5, on target — hold. Back-offs: 2 of 3 logged.")
        XCTAssertFalse(vm.exercises[0].isComplete)
        log(vm, ctx, set: 3, load: "290", reps: "7")
        XCTAssertTrue(vm.exercises[0].isComplete)
        XCTAssertEqual(item.targetSets, 3)
    }

    func test_B4_topNotLogged_keepsTheExerciseIncomplete() throws {
        let ctx = try makeContext()
        let (session, item) = topSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        for set in 1...3 { log(vm, ctx, set: set, load: "290", reps: "7") }
        XCTAssertFalse(vm.exercises[0].isComplete, "the planned top row is part of the session")
        log(vm, ctx, set: 4, load: "315", reps: "5")
        XCTAssertTrue(vm.exercises[0].isComplete)
    }

    /// Add Set inserts the new back-off BEFORE the top tail; the top keeps its role and its logged data.
    func test_B4_addSet_insertsBackOffBeforeTheTopTail() throws {
        let ctx = try makeContext()
        let (session, item) = topSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        log(vm, ctx, set: 4, load: "315", reps: "5")
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        let ex = vm.exercises[0]
        XCTAssertEqual(ex.targetSets, 4)
        XCTAssertEqual(ex.sets.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(ex.sets.map(\.isTop), [false, false, false, false, true])
        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual(item.setRolesBySet?.prefix(5).map { $0 }, ["", "", "", "", "top"])
        XCTAssertEqual(item.actualLoads[4], 315, "the logged top set moved with its row")
        XCTAssertEqual(item.actualReps[4], 5)
        XCTAssertEqual(item.actualLoads[3], 0, "the new back-off row is unlogged")
        XCTAssertTrue(CoachingEngine.hasTopEvidence(item))
        XCTAssertEqual(ex.sets[3].plannedLoad, 290, "the new back-off is seeded from the last back-off, not the top")
    }

    func test_B4_programTabSetStepper_keepsTheTopTail() {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 7, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
                               setMin: 3, setMax: 3,
                               plannedRepsBySet: [7, 7, 7, 5], plannedLoadsBySet: [290, 290, 290, 315], plannedRIRsBySet: [2, 2, 2, 2])
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        PlanStepperEdits.setSets(item, to: 4)
        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual(item.plannedLoadsBySet, [290, 290, 290, 290, 315])
        XCTAssertEqual(item.setRolesBySet, ["", "", "", "", "top"])
        XCTAssertEqual(item.setMax, 4)
        PlanStepperEdits.setSets(item, to: 2)
        XCTAssertEqual(item.plannedLoadsBySet, [290, 290, 315])
        XCTAssertEqual(item.topRowIndices, [2])
    }


    func test_B5_csvExport_labelsTopRows() throws {
        let ctx = try makeContext()
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [])
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
            plannedRepsBySet: [8, 8, 8, 5], plannedLoadsBySet: [290, 290, 290, 315], plannedRIRsBySet: [2, 2, 2, 2],
            actualReps: [8, 7, 6, 5], actualLoads: [290, 290, 290, 315], actualRIRs: [2, 2, 2, 2]
        )
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        session.items = [item]
        ctx.insert(session)
        try ctx.save()
        let result = try SetsV1CSVExporter.exportCompletedSessionsCSV(modelContext: ctx, fileName: "b5_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: result.url) }
        let lines = try String(contentsOf: result.url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix(",coach_note,set_role,load_unit"), lines[0])
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[4].hasSuffix(",top,lb"), lines[4])
        XCTAssertTrue(lines[1].hasSuffix(",,lb"), "back-off rows have an empty role: \(lines[1])")
    }


    // MARK: B7. Prescribed set count

    func test_B7_inSessionAddSet_changesTargetSetsOnly() throws {
        let ctx = try makeContext()
        let (session, item) = threeSetSession(in: ctx)
        let vm = SessionScreenViewModel(session: session)
        XCTAssertEqual(item.prescribedSets, 3, "born prescribed")
        for s in 1...3 { log(vm, ctx, set: s, load: "100") }
        vm.addSet(toExerciseID: vm.exercises[0].id, context: ctx)
        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual(item.prescribedSets, 3, "Add Set is not a prescription change")
        XCTAssertEqual(item.effectivePrescribedSets, 3)
    }

    func test_B7_prescriptionEditsMovePrescribedSets() {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        PlanStepperEdits.setSets(i, to: 4)
        XCTAssertEqual([i.targetSets, i.prescribedSets], [4, 4])
        i.setRolesBySet = SessionItem.roles(backOffs: 4, tops: 1)
        i.plannedLoadsBySet = [100, 100, 100, 100, 150]; i.plannedRepsBySet = [8, 8, 8, 8, 5]; i.plannedRIRsBySet = [2, 2, 2, 2, 2]
        PlanStepperEdits.setSets(i, to: 3)
        XCTAssertEqual([i.targetSets, i.prescribedSets], [3, 3])
        let old = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        old.prescribedSets = nil
        XCTAssertEqual(old.effectivePrescribedSets, 3)
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
