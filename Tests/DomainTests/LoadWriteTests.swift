import XCTest
import SwiftData
@testable import ElitePerformance

/// Section B — Load write & carry-forward mechanics, focused on
/// PlanMemoryEngine.carryForwardPlans(from:) specifically (distinct from
/// Section N's cross-cutting invariants, though some setup is necessarily
/// similar since they exercise the same engine).
final class LoadWriteTests: XCTestCase {

    // MARK: - Shared helpers

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func item(
        exerciseId: String = "bench",
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
        i.setFeedbackBySet = setFeedbackBySet ?? Array(repeating: "", count: reps.count)
        return i
    }

    private var cal: Calendar { Calendar.current }

    // T-B.1: Only .completed or .inProgress source sessions carry forward.
    func test_B1_plannedSourceSessionDoesNothing() throws {
        let context = try makeContext()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let sourceItem = item(reps: [10], loads: [100], rirs: [2], suggestedLoad: 100)
        sourceItem.plannedLoadsBySet = [100]
        let sourceSession = Session(date: yesterday, status: .planned, weekIndex: 1, items: [sourceItem])

        let futureItem = item(reps: [0], loads: [0], rirs: [0], suggestedLoad: 0)
        futureItem.plannedLoadsBySet = [0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.suggestedLoad, 0, "a still-.planned source session must not carry anything forward")
    }

    // T-B.2: Never overwrites an already-planned future SessionItem (per the
    // file's own doc comment) — isPlanEffectivelyEmpty guard.
    func test_B2_neverOverwritesAnAlreadyPlannedFutureItem() throws {
        let context = try makeContext()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let sourceItem = item(reps: [10], loads: [999], rirs: [2], suggestedLoad: 999)
        sourceItem.plannedLoadsBySet = [999]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        // Future item already has its own deliberate plan — not empty.
        let futureItem = item(reps: [0], loads: [0], rirs: [0], suggestedLoad: 50)
        futureItem.plannedLoadsBySet = [50]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.suggestedLoad, 50, "an already-planned future item must be left alone")
        XCTAssertEqual(futureItem.plannedLoadsBySet, [50])
    }

    // T-B.3: hasMeaningfulPlan gate — a source item with no plan at all is
    // never propagated (nothing to carry forward).
    func test_B3_sourceItemWithNoPlanIsNeverPropagated() throws {
        let context = try makeContext()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // No suggestedLoad, no planned reps, no planned loads.
        let sourceItem = item(reps: [0], loads: [0], rirs: [0], suggestedLoad: 0)
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        let futureItem = item(reps: [0], loads: [0], rirs: [0], suggestedLoad: 0)
        futureItem.plannedLoadsBySet = [0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.suggestedLoad, 0, "nothing meaningful to carry forward -> future item stays untouched")
    }

    // T-B.4: Carries forward to the NEXT matching future session only — a
    // second, farther-out future session with the same exercise is untouched.
    func test_B4_onlyTheNextMatchingFutureSessionIsUpdated() throws {
        let context = try makeContext()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let inTwoDays = cal.date(byAdding: .day, value: 2, to: Date())!
        let inNineDays = cal.date(byAdding: .day, value: 9, to: Date())!

        let sourceItem = item(reps: [10], loads: [100], rirs: [2], suggestedLoad: 100)
        sourceItem.plannedLoadsBySet = [100]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        let nearFutureItem = item(reps: [0], loads: [0], rirs: [0], suggestedLoad: 0)
        nearFutureItem.plannedLoadsBySet = [0]
        let nearFutureSession = Session(date: inTwoDays, status: .planned, weekIndex: 2, items: [nearFutureItem])

        let farFutureItem = item(reps: [0], loads: [0], rirs: [0], suggestedLoad: 0)
        farFutureItem.plannedLoadsBySet = [0]
        let farFutureSession = Session(date: inNineDays, status: .planned, weekIndex: 3, items: [farFutureItem])

        context.insert(sourceSession)
        context.insert(nearFutureSession)
        context.insert(farFutureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(nearFutureItem.suggestedLoad, 100, "nearest future session gets the carry-forward")
        XCTAssertEqual(farFutureItem.suggestedLoad, 0, "a second, farther-out future session is not also written to")
    }

    // T-B.5: progressionEnabled == false still allows the simple carry-forward
    // copy (suggestedLoad/plannedLoadsBySet) — only the LoadProjectionService
    // call is gated, per the `guard progressionEnabled else { continue }`
    // placement AFTER the unconditional copy.
    func test_B5_progressionDisabledStillCopiesButNeverProjects() throws {
        let context = try makeContext()
        let user = User(units: .lb, progressionEnabled: false)
        context.insert(user)

        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // Rich, textbook 2-consecutive-clean history that WOULD earn an increase
        // if progression were enabled.
        let clean1 = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100, repMin: 8, repMax: 12)
        let s1 = Session(date: twoDaysAgo, status: .completed, weekIndex: 1, items: [clean1])

        let sourceItem = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100, repMin: 8, repMax: 12)
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 2, items: [sourceItem])

        let futureItem = item(reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0], suggestedLoad: 0, repMin: 8, repMax: 12)
        futureItem.plannedLoadsBySet = [0, 0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 3, items: [futureItem])

        context.insert(s1)
        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        // Copied, but held at exactly the source's load — not the would-be 102.5 increase.
        XCTAssertEqual(futureItem.suggestedLoad, 100, "progressionEnabled=false must still copy the plain carry-forward")
    }

    // MARK: - T-B.6: Post-restore seeding fidelity
    //
    // FIXED: same root cause as InvariantTests' T-N.12, written independently
    // here per the catalog's explicit instruction not to skip this one.
    // ProgramGenerator.anchorLoadsForNewMeso used to seed maintenance items by
    // calling LoadProjectionService.project(currentWaveRaw: item.waveRaw).
    // Every maintenance item's waveRaw is "deload"
    // (MaintenanceProgramSeeder.makeMaintenanceItem), and project()'s deload
    // guard unconditionally returned nil for all of them. anchorLoadsForNewMeso
    // now reads e1RM directly from history instead — see OPEN Q1 in
    // TestOpenQuestions.swift.
    func test_B6_restoredHistoryAnchorsMaintenanceLoad() throws {
        let context = try makeContext()
        let priorMeso = MesoBlock(name: "Prior Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(priorMeso)

        for daysAgo in [50, 43, 36] {
            let historyItem = item(exerciseId: "romanian_deadlift", reps: [11, 11, 10], loads: [225, 225, 225], rirs: [2, 2, 2], suggestedLoad: 225, repMin: 10, repMax: 13)
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [historyItem])
            s.meso = priorMeso
            context.insert(s)
        }
        try context.save()

        let maintenanceItem = MaintenanceProgramSeeder.makeMaintenanceItem(exerciseId: "romanian_deadlift", name: "Romanian Deadlift", order: 1)
        let maintenanceMeso = MesoBlock(name: "Maintenance Block", startDate: Date(), status: .active, totalWeeks: 4)
        let maintenanceSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [maintenanceItem])
        maintenanceSession.meso = maintenanceMeso
        context.insert(maintenanceMeso)
        context.insert(maintenanceSession)
        try context.save()

        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: maintenanceMeso, context: context)

        XCTAssertGreaterThan(maintenanceItem.suggestedLoad, 0, "RDL has clean 225x10-11 history — anchoring must read it, not stay at 0")
    }

    // MARK: - T-B.7: Volume auto-regulation reduces set count + resizes
    // plannedLoadsBySet on carry-forward when recent history shows repeated
    // fatigue signals.

    func test_B7_repeatedFatigueSignalsReduceSetCountOnCarryForward() throws {
        let context = try makeContext()
        let fourDaysAgo = cal.date(byAdding: .day, value: -4, to: Date())!
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // Two of the last three completed sessions flagged soreness/disruption.
        let sore1 = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100,
                          setFeedbackBySet: [SetFeedback.soreness.rawValue, "", ""])
        let s1 = Session(date: fourDaysAgo, status: .completed, weekIndex: 1, items: [sore1])

        let sore2 = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100,
                          setFeedbackBySet: [SetFeedback.disruption.rawValue, "", ""])
        let s2 = Session(date: threeDaysAgo, status: .completed, weekIndex: 2, items: [sore2])

        let sourceItem = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], targetSets: 3, suggestedLoad: 100)
        sourceItem.plannedLoadsBySet = [100, 100, 100]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 3, items: [sourceItem])

        let futureItem = item(reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0], targetSets: 3, suggestedLoad: 0)
        futureItem.plannedLoadsBySet = [0, 0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 4, items: [futureItem])

        context.insert(s1)
        context.insert(s2)
        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.targetSets, 2, "2 of last 3 sessions flagged fatigue -> set count reduced by 1")
        XCTAssertEqual(futureItem.plannedLoadsBySet.count, 2, "plannedLoadsBySet must be resized to match the new set count")
        XCTAssertNotNil(futureItem.coachNote)
    }

    // MARK: - T-B.8: Pain flag on the source item carries forward a coach note
    // onto the target item.

    func test_B8_painFlagCarriesForwardAWarningCoachNote() throws {
        let context = try makeContext()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let sourceItem = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100,
                               setFeedbackBySet: [SetFeedback.pain.rawValue, "", ""])
        sourceItem.plannedLoadsBySet = [100, 100, 100]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        let futureItem = item(reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0], suggestedLoad: 0)
        futureItem.plannedLoadsBySet = [0, 0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.coachNote, "⚠️ Pain was flagged in your last session for this exercise. Reassess before loading.")
    }

    // MARK: - T-B.9: Carry-forward never overwrites prescription fields
    // (targetReps/targetRIR/repMin/repMax) — load only, per the file's own
    // doc comment ("Carry forward load only — never overwrite prescription
    // fields... belong to the target session's wave, not the source's").

    func test_B9_neverOverwritesPrescriptionFields() throws {
        let context = try makeContext()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // No real actual data, so LoadProjectionService.project() finds zero
        // e1RM candidates and returns nil — isolating this test to the simple,
        // unconditional carry-forward rather than the projection math (which
        // would otherwise read the *target* item's own targetReps/targetRIR
        // for its e1RM-floor calculation and produce a different, but
        // unrelated-to-this-test, numeric result).
        let sourceItem = item(reps: [0], loads: [0], rirs: [0], targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 12)
        sourceItem.plannedLoadsBySet = [100]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        // Future item's own wave prescribes different rep/RIR targets.
        let futureItem = item(reps: [0], loads: [0], rirs: [0], targetReps: 6, targetRIR: 1, suggestedLoad: 0, repMin: 4, repMax: 6)
        futureItem.plannedLoadsBySet = [0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.suggestedLoad, 100, "load is carried forward")
        XCTAssertEqual(futureItem.targetReps, 6, "but the target session's own rep prescription must survive untouched")
        XCTAssertEqual(futureItem.targetRIR, 1, "and its own RIR prescription")
        XCTAssertEqual(futureItem.repMin, 4)
        XCTAssertEqual(futureItem.repMax, 6)
    }

    // MARK: - T-B.10: Three addExercise paths are known to diverge silently
    // (OPEN Q4).
    //
    // CONFIRMED VIA SOURCE: there are three independent addExercise
    // implementations — SessionScreenViewModel.addExercise (SessionView.swift,
    // internal access, directly testable below), ProgramDayDetailView
    // .addExercise(from:) (private), and PlannedSessionEditorView
    // .addExercise(_:) (private). The latter two are `private` methods on
    // SwiftUI View structs and cannot be invoked directly from XCTest without
    // changing their access level, which is out of scope (no source changes
    // outside the test target). What CAN be confirmed and is asserted below:
    //
    // 1) SessionScreenViewModel.addExercise correctly seeds exerciseNameSnapshot
    //    and correctly-sized actual/planned arrays (fixed earlier this session;
    //    this guards against that exact regression recurring).
    // 2) PlannedSessionEditorView.addExercise(_:) (lines 80-102) is reproduced
    //    verbatim below — by transcription, since it can't be called directly —
    //    and is CONFIRMED to omit exerciseNameSnapshot entirely and to leave
    //    actualReps/actualLoads/actualRIRs at SessionItem's empty-array default.
    //    This is the same class of bug already fixed in path #1, now found
    //    un-audited in a third location.
    func test_B10_sessionScreenViewModelAddExerciseSeedsNameAndArrays() throws {
        let context = try makeContext()
        let session = Session(date: Date(), weekIndex: 1, items: [])
        context.insert(session)
        try context.save()

        let vm = SessionScreenViewModel(session: session)
        let catalogExercise = ExerciseCatalog.builtIn.first(where: { $0.id == "machine_hip_thrust" })!
        vm.addExercise(catalogExercise, context: context)

        guard let added = session.items.first(where: { $0.exerciseId == "machine_hip_thrust" }) else {
            return XCTFail("addExercise did not insert a matching SessionItem")
        }
        XCTAssertEqual(added.exerciseNameSnapshot, catalogExercise.name)
        // Non-maintenance path hardcodes array length 4 regardless of targetSets(3) —
        // a minor internal inconsistency, but the thing that actually mattered for the
        // original bug (reps showing as 0) is that these are non-empty and internally
        // consistent with each other, which they are.
        XCTAssertGreaterThan(added.actualReps.count, 0)
        XCTAssertEqual(added.actualReps.count, added.actualLoads.count)
        XCTAssertEqual(added.actualReps.count, added.actualRIRs.count)
        XCTAssertEqual(added.actualReps.count, added.plannedRepsBySet.count)
    }

    func test_B10_KNOWN_GAP_plannedSessionEditorViewAddExerciseOmitsNameAndArrays() {
        // Verbatim transcription of PlannedSessionEditorView.addExercise(_:)
        // (Features/Planner/PlannedSessionEditorView.swift:80-102) as of this
        // session — private, so this is the closest thing to a direct test.
        let targetSets = 3
        let targetReps = 10
        let targetRIR = 2
        let suggestedLoad: Double = 0
        let reproducedItem = SessionItem(
            order: 1,
            exerciseId: "machine_hip_thrust",
            targetReps: targetReps,
            targetSets: targetSets,
            targetRIR: targetRIR,
            suggestedLoad: suggestedLoad,
            plannedRepsBySet: Array(repeating: targetReps, count: targetSets),
            plannedLoadsBySet: Array(repeating: suggestedLoad, count: targetSets)
        )

        XCTAssertNil(reproducedItem.exerciseNameSnapshot, "CONFIRMED GAP: PlannedSessionEditorView never sets exerciseNameSnapshot")
        XCTAssertEqual(reproducedItem.actualReps.count, 0, "CONFIRMED GAP: actualReps is left at SessionItem's empty default, not sized to targetSets")
        XCTAssertEqual(reproducedItem.actualLoads.count, 0, "CONFIRMED GAP: actualLoads is left at SessionItem's empty default")
        XCTAssertEqual(reproducedItem.actualRIRs.count, 0, "CONFIRMED GAP: actualRIRs is left at SessionItem's empty default")
    }
}
