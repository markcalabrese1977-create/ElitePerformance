import XCTest
import SwiftData
@testable import ElitePerformance

/// Section N — cross-cutting invariants that must hold regardless of which
/// branch of CoachingEngine / LoadProjectionService / PlanMemoryEngine fires.
///
/// Recon note: several of these were specified before the real source was
/// read. Where the real, confirmed behavior differs from the literal wording
/// of the catalog entry, the test asserts the REAL behavior and says so in a
/// comment — a test that asserts a false invariant just to match a prompt is
/// worse than no test at all.
final class InvariantTests: XCTestCase {

    // MARK: - Shared helpers

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func item(
        exerciseId: String = "test_exercise",
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
        plannedTopReps: Int = 12,
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
        i.plannedRepsBySet = Array(repeating: plannedTopReps, count: reps.count)
        i.setFeedbackBySet = setFeedbackBySet ?? Array(repeating: "", count: reps.count)
        return i
    }

    // MARK: - T-N.1: No suggestion exceeds 2x previous suggestedLoad on any branch

    /// CoachingEngine's own sanity cap (`loadSanityCap = baseLoad * 2.0`).
    /// Force a huge minLoadIncrement so the *uncapped* suggestion would be
    /// far more than 2x, then confirm the cap clamps it back down.
    func test_N1_coachingEngineNeverExceeds2xBaseLoad() {
        let i = item(
            reps: [12, 12, 12], loads: [10, 10, 10], rirs: [2, 2, 2],
            targetReps: 10, targetRIR: 2, suggestedLoad: 10,
            repMin: 8, repMax: 12, plannedTopReps: 12
        )
        let result = CoachingEngine.recommend(for: i, minLoadIncrement: 1000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nextSuggestedLoad ?? -1, 20, accuracy: 0.001, "10 base load -> cap is 20, regardless of the 1000 increment")
    }

    /// PlanMemoryEngine's carry-forward cap (`min(projection.suggestedLoad, sourceItem.suggestedLoad * 2.0)`).
    /// Seed a huge e1RM baseline elsewhere in history so LoadProjectionService.project
    /// would want to suggest far more than 2x the *source* session's suggestedLoad,
    /// then confirm PlanMemoryEngine clamps the carried-forward value.
    func test_N1_planMemoryEngineCarryForwardNeverExceeds2xSource() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // Big historical e1RM baseline for "bench" from a much earlier, unrelated session.
        let bigHistoryItem = item(
            exerciseId: "bench", reps: [10, 10, 10], loads: [500, 500, 500], rirs: [2, 2, 2],
            targetReps: 10, targetRIR: 2, suggestedLoad: 500, repMin: 8, repMax: 12
        )
        let bigHistorySession = Session(date: twoDaysAgo, status: .completed, weekIndex: 1, items: [bigHistoryItem])

        // Source session being completed "today" with a much smaller suggestedLoad.
        let sourceItem = item(
            exerciseId: "bench", reps: [10, 10, 10], loads: [10, 10, 10], rirs: [2, 2, 2],
            targetReps: 10, targetRIR: 2, suggestedLoad: 10, repMin: 8, repMax: 12
        )
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        // Future planned session with an effectively-empty bench item.
        let futureItem = item(
            exerciseId: "bench", reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0],
            targetReps: 10, targetRIR: 2, suggestedLoad: 0, repMin: 8, repMax: 12
        )
        futureItem.plannedLoadsBySet = [0, 0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(bigHistorySession)
        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        // Without the cap this would be pulled toward the 500-load history's e1RM.
        // With the cap it must never exceed 2x the source's own suggestedLoad (10 -> 20).
        XCTAssertLessThanOrEqual(futureItem.suggestedLoad, 20.0001)
        XCTAssertGreaterThan(futureItem.suggestedLoad, 0, "should still have carried forward *something*, just capped")
    }

    // MARK: - T-N.2: Deload week -> CoachingEngine never progresses (real behavior, not literal "always nil")
    //
    // CONFIRMED VIA SOURCE (CoachingEngine.swift Guard 1): a deload item with a valid
    // suggestedLoad and any logged data returns a non-nil maintenance/hold message —
    // it does NOT return nil "always". nil is returned only when there's no usable
    // suggestedLoad or no actual data yet. The real, always-true invariant is: deload
    // NEVER returns an increase — nextSuggestedLoad is nil or <= item.suggestedLoad.

    func test_N2_deloadNeverReturnsNilWhenBaselineAndDataExist() {
        // Performance here would normally earn a big increase on a non-deload item.
        let i = item(
            reps: [15, 15, 15], loads: [100, 100, 100], rirs: [4, 4, 4],
            targetReps: 10, targetRIR: 3, suggestedLoad: 100,
            waveRaw: "deload", repMin: 8, repMax: 12
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result, "deload guard returns a hold message, not nil, when there's a baseline + data")
        XCTAssertEqual(result?.nextSuggestedLoad, 100, "deload holds the existing suggestedLoad — never increases")
    }

    func test_N2_deloadReturnsNilWithoutBaseline() {
        let i = item(
            reps: [10, 10, 10], loads: [100, 100, 100], rirs: [3, 3, 3],
            suggestedLoad: 0, waveRaw: "deload"
        )
        XCTAssertNil(CoachingEngine.recommend(for: i), "no suggestedLoad baseline -> deload guard itself returns nil")
    }

    // MARK: - T-N.3: First session / no baseline -> nil, always

    func test_N3_coachingEngineNoBaselineIsAlwaysNil() {
        let i = item(reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 0)
        XCTAssertNil(CoachingEngine.recommend(for: i))
    }

    func test_N3_loadProjectionNoHistoryIsAlwaysNil() {
        let projection = LoadProjectionService.project(
            exerciseId: "bench", targetReps: 10, targetRIR: 2, repMin: 8, repMax: 12,
            currentWaveRaw: nil, allSessions: [], activeMesoSessionIDs: []
        )
        XCTAssertNil(projection)
    }

    // MARK: - T-N.4: Pain flag -> never a progression (nextSuggestedLoad always nil)

    func test_N4_painFlagNeverProgresses() {
        let i = item(
            reps: [15, 15, 15], loads: [100, 100, 100], rirs: [4, 4, 4],
            targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 12,
            setFeedbackBySet: [SetFeedback.pain.rawValue, "", ""]
        )
        let result = CoachingEngine.recommend(for: i)
        XCTAssertNotNil(result, "pain still returns a message")
        XCTAssertNil(result?.nextSuggestedLoad, "pain flag must never carry a progression number")
    }

    // MARK: - T-N.5: nil projection -> target load unchanged, never zeroed

    func test_N5_nilProjectionLeavesCarriedForwardLoadUntouched() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // No actual data logged anywhere for this exercise -> project() will find
        // zero e1RM candidates and return nil. suggestedLoad alone still carries forward.
        let sourceItem = item(
            exerciseId: "overhead_press", reps: [0, 0], loads: [0, 0], rirs: [0, 0],
            suggestedLoad: 100, repMin: 8, repMax: 12
        )
        sourceItem.plannedLoadsBySet = [100, 100]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [sourceItem])

        let futureItem = item(
            exerciseId: "overhead_press", reps: [0, 0], loads: [0, 0], rirs: [0, 0],
            suggestedLoad: 0, repMin: 8, repMax: 12
        )
        futureItem.plannedLoadsBySet = [0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [futureItem])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.suggestedLoad, 100, "nil projection must not zero out the carried-forward load")
    }

    // MARK: - T-N.6: Exactly one load write per carry-forward (no double-write)

    func test_N6_carryForwardWritesEachMatchedItemExactlyOnce_andIsIdempotent() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let benchSource = item(exerciseId: "bench", reps: [0], loads: [0], rirs: [0], suggestedLoad: 100, repMin: 8, repMax: 12)
        benchSource.plannedLoadsBySet = [100]
        let squatSource = item(exerciseId: "squat", reps: [0], loads: [0], rirs: [0], suggestedLoad: 200, repMin: 8, repMax: 12)
        squatSource.plannedLoadsBySet = [200]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [benchSource, squatSource])

        let benchFuture = item(exerciseId: "bench", reps: [0], loads: [0], rirs: [0], suggestedLoad: 0, repMin: 8, repMax: 12)
        benchFuture.plannedLoadsBySet = [0]
        let squatFuture = item(exerciseId: "squat", reps: [0], loads: [0], rirs: [0], suggestedLoad: 0, repMin: 8, repMax: 12)
        squatFuture.plannedLoadsBySet = [0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [benchFuture, squatFuture])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        let engine = PlanMemoryEngine(context: context)
        engine.carryForwardPlans(from: sourceSession)

        XCTAssertEqual(benchFuture.suggestedLoad, 100)
        XCTAssertEqual(squatFuture.suggestedLoad, 200)

        // Second call must be a no-op: the future items are no longer "effectively
        // empty" (isPlanEffectivelyEmpty guard), so nothing should change again.
        engine.carryForwardPlans(from: sourceSession)
        XCTAssertEqual(benchFuture.suggestedLoad, 100, "second call must not double-apply")
        XCTAssertEqual(squatFuture.suggestedLoad, 200, "second call must not double-apply")
    }

    // MARK: - T-N.7: All load matching by exerciseId, never positional index

    func test_N7_matchingIsByExerciseIdNotArrayPosition() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        // Source order: [bench, squat]
        let benchSource = item(exerciseId: "bench", reps: [0], loads: [0], rirs: [0], suggestedLoad: 100, repMin: 8, repMax: 12)
        benchSource.plannedLoadsBySet = [100]
        let squatSource = item(exerciseId: "squat", reps: [0], loads: [0], rirs: [0], suggestedLoad: 200, repMin: 8, repMax: 12)
        squatSource.plannedLoadsBySet = [200]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 1, items: [benchSource, squatSource])

        // Future order is REVERSED: [squat, bench] — positional matching would swap the values.
        let squatFuture = item(exerciseId: "squat", reps: [0], loads: [0], rirs: [0], suggestedLoad: 0, repMin: 8, repMax: 12)
        squatFuture.plannedLoadsBySet = [0]
        let benchFuture = item(exerciseId: "bench", reps: [0], loads: [0], rirs: [0], suggestedLoad: 0, repMin: 8, repMax: 12)
        benchFuture.plannedLoadsBySet = [0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 2, items: [squatFuture, benchFuture])

        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(benchFuture.suggestedLoad, 100, "bench must get bench's load even though it's at a different array index")
        XCTAssertEqual(squatFuture.suggestedLoad, 200, "squat must get squat's load even though it's at a different array index")
    }

    // MARK: - T-N.8: suggestedLoad never negative, NaN, or Inf

    func test_N8_outputsAreAlwaysFiniteAndNonNegative() {
        // E1RMCalculator edge cases
        XCTAssertTrue(E1RMCalculator.e1RM(load: 0, reps: 0).isFinite)
        XCTAssertGreaterThanOrEqual(E1RMCalculator.e1RM(load: 0, reps: 0), 0)
        XCTAssertTrue(E1RMCalculator.load(for: 0, reps: 0, targetRIR: 0).isFinite)
        XCTAssertGreaterThanOrEqual(E1RMCalculator.load(for: 0, reps: 0, targetRIR: 0), 0)
        XCTAssertTrue(E1RMCalculator.rounded(123.456, increment: 0).isFinite, "increment <= 0 must not divide by zero")

        // CoachingEngine across a normal and an extreme branch
        let normal = item(reps: [10, 10, 9], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100)
        if let load = CoachingEngine.recommend(for: normal)?.nextSuggestedLoad {
            XCTAssertTrue(load.isFinite)
            XCTAssertGreaterThanOrEqual(load, 0)
        }

        // LoadProjectionService with no usable history
        let projection = LoadProjectionService.project(
            exerciseId: "bench", targetReps: 10, targetRIR: 2, repMin: 8, repMax: 12,
            currentWaveRaw: nil, allSessions: [], activeMesoSessionIDs: []
        )
        XCTAssertNil(projection)
    }

    // MARK: - T-N.9: mesoPhase == .deload <=> isDeloadWeek
    //
    // CONFIRMED VIA SOURCE this is only a one-directional implication, not an
    // iff. Session.isDeloadWeek is true only on the literal last week
    // (weekIndex == totalWeeks). Session.mesoPhase uses percentage bands and
    // flips to .deload at >=90% of the block. For an 11-week meso (the
    // documented default in ChestArmsLowBackMesoProfile.totalWeeks), week 10
    // is already >=90% (10/11 ≈ 0.909) so mesoPhase == .deload there, but
    // isDeloadWeek is false (week 10 != week 11). See OPEN Q6.

    func test_N9_isDeloadWeekImpliesMesoPhaseDeload() {
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), totalWeeks: 11)
        let session = Session(date: Date(), weekIndex: 11, items: [])
        session.meso = meso
        XCTAssertTrue(session.isDeloadWeek)
        XCTAssertEqual(session.mesoPhase, .deload, "the true, always-valid direction: last week implies deload phase")
    }

    func test_N9_KNOWN_GAP_mesoPhaseDeloadDoesNotImplyIsDeloadWeek() {
        let meso = MesoBlock(name: "Test Meso", startDate: Date(), totalWeeks: 11)
        let session = Session(date: Date(), weekIndex: 10, items: [])
        session.meso = meso
        XCTAssertEqual(session.mesoPhase, .deload, "10/11 ≈ 0.909 >= 0.90 band")
        XCTAssertFalse(session.isDeloadWeek, "week 10 != week 11 — confirmed asymmetry, see OPEN Q6 in TestOpenQuestions.swift")
    }

    // MARK: - T-N.10: Maintenance items (waveRaw == "deload") never progressed

    func test_N10_loadProjectionServiceNeverProgressesDeloadRegardlessOfHistory() {
        // Even with a textbook-perfect clean-progression history, the top-of-function
        // guard must return nil unconditionally for a deload wave.
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date())!

        let clean1 = item(exerciseId: "bench", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100, waveRaw: "deload", repMin: 8, repMax: 12)
        let s1 = Session(date: twoDaysAgo, status: .completed, weekIndex: 1, items: [clean1])
        let clean2 = item(exerciseId: "bench", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100, waveRaw: "deload", repMin: 8, repMax: 12)
        let s2 = Session(date: yesterday, status: .completed, weekIndex: 2, items: [clean2])

        let projection = LoadProjectionService.project(
            exerciseId: "bench", targetReps: 10, targetRIR: 2, repMin: 8, repMax: 12,
            currentWaveRaw: "deload", allSessions: [s1, s2], activeMesoSessionIDs: []
        )
        XCTAssertNil(projection)
    }

    func test_N10_planMemoryEngineNeverIncreasesDeloadTargetItem() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let clean1 = item(exerciseId: "bench", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100, waveRaw: "deload", repMin: 8, repMax: 12)
        let s1 = Session(date: twoDaysAgo, status: .completed, weekIndex: 1, items: [clean1])

        let sourceItem = item(exerciseId: "bench", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], suggestedLoad: 100, waveRaw: "deload", repMin: 8, repMax: 12)
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 2, items: [sourceItem])

        let futureItem = item(exerciseId: "bench", reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0], suggestedLoad: 0, waveRaw: "deload", repMin: 8, repMax: 12)
        futureItem.plannedLoadsBySet = [0, 0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 3, items: [futureItem])

        context.insert(s1)
        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        XCTAssertEqual(futureItem.suggestedLoad, 100, "deload target item must hold the carried-forward load, never progress past it")
    }

    // MARK: - T-N.11: Every seeding path moves MesoLifecycle.activeStartDate
    //
    // CONFIRMED VIA SOURCE this is FALSE as literally stated. Grepped all three
    // seeding entry points (DUPProgramSeeder.seed, MaintenanceProgramSeeder.seed,
    // MaintenanceProgramSeeder.seedFromNewProgram) — none of them call
    // MesoLifecycle.confirmStartNewMeso or AppStateBridge.setActiveMesoStartDate.
    // That call is made separately, by hand, at each UI call site (SettingsView,
    // MesoRolloverGuardSheet, MesoSummaryView, MaintenanceProgramPickerView) right
    // next to the seeder call. The real invariant lives at the call site, not the
    // seeder. See OPEN Q7.

    func test_N11_seederAloneDoesNotMoveActiveStartDate() throws {
        let originalEpoch = UserDefaults.standard.double(forKey: "meso.activeStartDateEpoch")
        defer {
            if originalEpoch > 0 {
                UserDefaults.standard.set(originalEpoch, forKey: "meso.activeStartDateEpoch")
            } else {
                UserDefaults.standard.removeObject(forKey: "meso.activeStartDateEpoch")
            }
        }

        let farPastAnchor = Date(timeIntervalSince1970: 1)
        MesoLifecycle.setActiveStartDate(farPastAnchor)
        let before = MesoLifecycle.activeStartDate

        let context = try makeContext()
        let sourceMeso = MesoBlock(name: "Source Meso", startDate: Date(), status: .active, totalWeeks: 8)
        let sourceDayItem = SessionItem(order: 1, exerciseId: "bench", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        let sourceDaySession = Session(date: Date(), status: .completed, weekIndex: 1, dayLabel: "Day 1", items: [sourceDayItem])
        sourceDaySession.meso = sourceMeso
        context.insert(sourceMeso)
        context.insert(sourceDaySession)
        try context.save()

        // Confirm the seeder actually does real work (not an early-bail with no sessions),
        // making the "activeStartDate untouched" finding meaningful rather than vacuous.
        try MaintenanceProgramSeeder.seed(from: sourceMeso, trainingWeekdays: [2, 4, 6], totalWeeks: 2, context: context)
        let allSessionsAfter = try context.fetch(FetchDescriptor<Session>())
        XCTAssertGreaterThan(allSessionsAfter.count, 1, "sanity check: seeding actually created new sessions")

        XCTAssertEqual(MesoLifecycle.activeStartDate, before, "confirmed: the seeder itself never touches MesoLifecycle.activeStartDate — that's done by the UI call site")
    }

    // MARK: - T-N.12: Restored history >= template defaults for seeding (post-restore seeding fidelity)
    // BUG T-B.6 UNVERIFIED
    //
    // CONFIRMED BROKEN VIA SOURCE, not just "unverified": ProgramGenerator.anchorLoadsForNewMeso
    // (the Path-A loader used by MaintenanceProgramSeeder.seed) anchors each item's
    // suggestedLoad by calling LoadProjectionService.project(currentWaveRaw: item.waveRaw).
    // Every maintenance item is seeded with waveRaw == "deload" (MaintenanceProgramSeeder
    // .makeMaintenanceItem). LoadProjectionService.project() now has a top-of-function
    // guard — added this session for a different bug (maintenance items getting
    // progressively overloaded) — that unconditionally returns nil whenever
    // currentWaveRaw == "deload". That guard also silently defeats
    // anchorLoadsForNewMeso for every maintenance item: the projection is always nil,
    // so suggestedLoad is left at its seeded 0, regardless of how much real history
    // exists. This test reproduces it directly against rich, unambiguous history.
    func test_N12_maintenanceSeedingAnchorsLoadFromHistory() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let lastMeso = MesoBlock(name: "Prior Meso", startDate: cal.date(byAdding: .day, value: -60, to: Date())!, status: .archived, totalWeeks: 8)
        context.insert(lastMeso)

        // Unambiguous prior history: Machine Hip Thrust at 410x10 multiple times.
        for daysAgo in [50, 43, 36] {
            let historyItem = SessionItem(
                order: 1, exerciseId: "machine_hip_thrust", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 410
            )
            historyItem.actualReps = [10, 10, 10]
            historyItem.actualLoads = [410, 410, 410]
            historyItem.actualRIRs = [2, 2, 2]
            let s = Session(date: cal.date(byAdding: .day, value: -daysAgo, to: Date())!, status: .completed, weekIndex: 1, items: [historyItem])
            s.meso = lastMeso
            context.insert(s)
        }
        try context.save()

        let newMaintenanceItem = MaintenanceProgramSeeder.makeMaintenanceItem(exerciseId: "machine_hip_thrust", name: "Machine Hip Thrust", order: 1)
        let maintenanceMeso = MesoBlock(name: "Maintenance Block", startDate: Date(), status: .active, totalWeeks: 4)
        let maintenanceSession = Session(date: Date(), status: .planned, weekIndex: 1, items: [newMaintenanceItem])
        maintenanceSession.meso = maintenanceMeso
        context.insert(maintenanceMeso)
        context.insert(maintenanceSession)
        try context.save()

        XCTAssertEqual(newMaintenanceItem.suggestedLoad, 0, "sanity check: seeded at 0 before anchoring")

        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: maintenanceMeso, context: context)

        // EXPECTED (per anchorLoadsForNewMeso's own doc comment "Anchor loads from
        // previous meso peak"): suggestedLoad should reflect the 410 history.
        // CONFIRMED CURRENTLY FAILING: the deload guard in LoadProjectionService.project()
        // makes this always nil for maintenance items, so suggestedLoad stays 0.
        XCTAssertGreaterThan(newMaintenanceItem.suggestedLoad, 0, "BUG T-B.6: maintenance load anchoring is silently defeated by the deload guard in LoadProjectionService.project()")
    }

    // MARK: - T-N.13: On completed session, next session's coached loads are correctly applied (DoD gate)

    func test_N13_twoConsecutiveCleanSessionsProduceCorrectlyAppliedIncrease() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let clean1 = item(exerciseId: "bench", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 12)
        let s1 = Session(date: twoDaysAgo, status: .completed, weekIndex: 1, items: [clean1])

        let sourceItem = item(exerciseId: "bench", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], targetReps: 10, targetRIR: 2, suggestedLoad: 100, repMin: 8, repMax: 12)
        sourceItem.plannedLoadsBySet = [100, 100, 100]
        let sourceSession = Session(date: yesterday, status: .completed, weekIndex: 2, items: [sourceItem])

        let futureItem = item(exerciseId: "bench", reps: [0, 0, 0], loads: [0, 0, 0], rirs: [0, 0, 0], targetReps: 10, targetRIR: 2, suggestedLoad: 0, repMin: 8, repMax: 12)
        futureItem.plannedLoadsBySet = [0, 0, 0]
        let futureSession = Session(date: tomorrow, status: .planned, weekIndex: 3, items: [futureItem])

        context.insert(s1)
        context.insert(sourceSession)
        context.insert(futureSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: sourceSession)

        // 2 consecutive clean sessions at 100 with 2.5 default increment -> 102.5.
        XCTAssertEqual(futureItem.suggestedLoad, 102.5, accuracy: 0.001)
        XCTAssertEqual(futureItem.plannedLoadsBySet, [102.5, 102.5, 102.5])
    }
}
