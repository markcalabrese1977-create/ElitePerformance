import XCTest
import SwiftData
@testable import ElitePerformance

/// K2: with a kg profile, every load the app computes lands on a kg step. Loads are stored lb throughout; the fixtures
/// below type kg values and convert them the way LoadInput does. The lb path is covered by the existing suite, which
/// must not change.
final class KgRoundingMatrixTests: XCTestCase {

    private let ex = "leg_extension"
    private func lb(_ kg: Double) -> Double { LoadUnit.kg.toStoredLb(kg) }
    private func kg(_ lb: Double) -> Double { LoadUnit.kg.fromStoredLb(lb) }
    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }

    private func assertKg(_ storedLb: Double, _ expectedKg: Double, _ msg: String = "", line: UInt = #line) {
        XCTAssertEqual(kg(storedLb), expectedKg, accuracy: 1e-6, "\(msg) (\(kg(storedLb)) kg)", line: line)
    }
    private func assertOnStep(_ storedLb: Double, _ step: Double, _ msg: String = "", line: UInt = #line) {
        let steps = kg(storedLb) / step
        XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-6, "\(msg): \(kg(storedLb)) kg is not on \(step) kg steps", line: line)
    }

    private func makeContext(increment: Double = 2.5) throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let ctx = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        ctx.insert(UserProfile(minLoadIncrement: increment, unit: .kg))
        return ctx
    }

    private func source(wave: String? = "b", kgLoad: Double, reps: [Int], loads: [Double]? = nil) -> SessionItem {
        let load = lb(kgLoad)
        let i = SessionItem(order: 1, exerciseId: ex, targetReps: 12, targetSets: reps.count, targetRIR: 2,
                            suggestedLoad: load, waveRaw: wave, repMin: 10, repMax: 12)
        i.actualReps = reps
        i.actualLoads = loads ?? Array(repeating: load, count: reps.count)
        i.actualRIRs = Array(repeating: 2, count: reps.count)
        i.plannedLoadsBySet = Array(repeating: load, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    private func target(wave: String? = "b", kgSeed: Double) -> SessionItem {
        let seed = lb(kgSeed)
        let i = SessionItem(order: 1, exerciseId: ex, targetReps: 12, targetSets: 3, targetRIR: 2,
                            suggestedLoad: seed, waveRaw: wave, repMin: 10, repMax: 12)
        i.plannedLoadsBySet = Array(repeating: seed, count: 3)
        return i
    }

    @discardableResult
    private func carryForward(_ src: SessionItem, _ tgt: SessionItem, ctx: ModelContext) throws -> Session {
        let a = Session(date: day(-1), status: .completed, weekIndex: 2, dayLabel: "Legs A", items: [src])
        let b = Session(date: day(20), status: .planned, weekIndex: 5, dayLabel: "Legs A", items: [tgt])
        ctx.insert(a); ctx.insert(b)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: a)
        return a
    }

    // MARK: Carry-forward

    func test_earnedBump_isOneKgStep() throws {
        let tgt = target(kgSeed: 100)
        try carryForward(source(kgLoad: 100, reps: [12, 12, 12]), tgt, ctx: try makeContext())
        assertKg(tgt.suggestedLoad, 102.5, "one 2.5 kg step up from 100 kg")
        XCTAssertEqual(tgt.plannedLoadsBySet.count, 3)
        tgt.plannedLoadsBySet.forEach { assertKg($0, 102.5) }
    }

    func test_earnedBump_withA1_25Increment() throws {
        let tgt = target(kgSeed: 100)
        try carryForward(source(kgLoad: 100, reps: [12, 12, 12]), tgt, ctx: try makeContext(increment: 1.25))
        assertKg(tgt.suggestedLoad, 101.25)
    }

    func test_hold_keepsTheKgLoadExactly() throws {
        let tgt = target(kgSeed: 105)
        try carryForward(source(kgLoad: 100, reps: [12, 12, 10]), tgt, ctx: try makeContext())
        assertKg(tgt.suggestedLoad, 100, "hold: the target follows the evidence")
    }

    func test_reduce_landsOnAKgStep() throws {
        let tgt = target(kgSeed: 105)
        try carryForward(source(kgLoad: 102.5, reps: [6, 6, 6]), tgt, ctx: try makeContext())
        // 5% off 102.5 kg = 97.375 -> nearest 2.5 kg step.
        assertKg(tgt.suggestedLoad, 97.5)
    }

    func test_bump_neverPassesTheMaxLoad() throws {
        let ctx = try makeContext()
        let profile = try XCTUnwrap(try ctx.fetch(FetchDescriptor<UserProfile>()).first)
        profile.setMaxLoad(lb(100), exerciseId: ex)
        let tgt = target(kgSeed: 100)
        try carryForward(source(kgLoad: 100, reps: [12, 12, 12]), tgt, ctx: ctx)
        assertKg(tgt.suggestedLoad, 100, "a bump past the max holds at the max")
    }

    func test_deloadTarget_landsOnAKgStep() throws {
        let tgt = target(wave: "deload", kgSeed: 100)
        try carryForward(source(kgLoad: 102.5, reps: [12, 12, 12]), tgt, ctx: try makeContext())
        XCTAssertGreaterThan(tgt.suggestedLoad, 0)
        assertOnStep(tgt.suggestedLoad, 2.5, "deload")
        tgt.plannedLoadsBySet.forEach { assertOnStep($0, 2.5, "deload slot") }
    }

    // MARK: Engine

    func test_topSetBump_isOneKgStep() {
        let i = SessionItem(order: 1, exerciseId: ex, targetReps: 8, targetSets: 2, targetRIR: 2, suggestedLoad: lb(100),
                            waveRaw: "b", repMin: 6, repMax: 8)
        i.setRolesBySet = ["", "", SessionItem.topRole]
        i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 1
        i.actualReps = [8, 8, 6]
        i.actualLoads = [lb(100), lb(100), lb(120)]
        i.actualRIRs = [2, 2, 1]
        i.plannedLoadsBySet = [lb(100), lb(100), lb(120)]
        i.setFeedbackBySet = ["", "", ""]
        guard i.hasTopSet else { return XCTFail("fixture has no top set") }
        let rec = CoachingEngine.recommend(for: i, minLoadIncrement: 2.5, unit: .kg)
        XCTAssertNotNil(rec?.nextTopLoad)
        if let top = rec?.nextTopLoad { assertKg(top, 122.5, "top set +1 step") }
        if let back = rec?.nextSuggestedLoad { assertOnStep(back, 2.5, "back-off") }
    }

    func test_noIncrementOnFile_fallsBackToKgSteps() {
        let i = source(kgLoad: 100, reps: [12, 12, 12])
        let rec = CoachingEngine.recommend(for: i, minLoadIncrement: nil, unit: .kg)
        if let next = rec?.nextSuggestedLoad { assertOnStep(next, 1.25, "fallback bump") }
    }

    func test_steppedUp_snapsKgButLeavesLbUntouched() {
        XCTAssertEqual(CoachingEngine.steppedUp(102.3, step: 2.5, unit: .lb), 104.8)
        // 102.5 lb = 46.49 kg; +2.5 kg = 48.99 kg -> the nearest 2.5 kg step (50 kg).
        assertKg(CoachingEngine.steppedUp(102.5, step: 2.5, unit: .kg), 50)
    }

    // MARK: Seeds

    private func completed(kgLoad: Double, reps: Int = 10) -> Session {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: lb(kgLoad))
        item.actualReps = [reps]
        item.actualLoads = [lb(kgLoad)]
        item.actualRIRs = [0]
        return Session(date: Date(), status: .completed, weekIndex: 1, items: [item])
    }

    func test_historySeed_landsOnKgSteps() throws {
        let ctx = try makeContext()
        for kgLoad in [60.0, 82.5, 91.0, 100.0, 117.5] {
            let s = completed(kgLoad: kgLoad)
            ctx.insert(s)
            for inc in [1.25, 2.5] {
                let seed = try XCTUnwrap(HistorySeedLoad.load(for: "bench_press", goalReps: 8, targetRIR: 2, in: [s],
                                                              loadIncrement: inc, unit: .kg))
                assertOnStep(seed, inc, "seed from \(kgLoad) kg @ \(inc)")
            }
        }
    }

    func test_nextMesoSeed_peakAndHistory_landOnKgSteps() throws {
        let ctx = try makeContext()
        let s = completed(kgLoad: 100)
        ctx.insert(s)
        let r = HistorySeedLoad.nextMesoSeed(for: "bench_press", goalReps: 8, targetRIR: 2, previousMeso: [s], allSessions: [s],
                                             loadIncrement: 2.5, unit: .kg, isFixedLoad: false)
        XCTAssertGreaterThan(r.load, 0)
        assertOnStep(r.load, 2.5, "next-meso peak seed")
        let top = HistorySeedLoad.nextMesoSeed(for: "bench_press", goalReps: 8, targetRIR: 2, previousMeso: [s], allSessions: [s],
                                               loadIncrement: 1.25, unit: .kg, isFixedLoad: false, role: .top)
        assertOnStep(top.load, 1.25, "next-meso top seed")
    }

    func test_projection_sameWaveProgression_landsOnKgSteps() throws {
        let ctx = try makeContext()
        var sessions: [Session] = []
        for n in [-21, -14, -7] {
            let i = source(kgLoad: 100, reps: [12, 12, 12])
            let s = Session(date: day(n), status: .completed, weekIndex: 1, dayLabel: "Legs A", items: [i])
            ctx.insert(s); sessions.append(s)
        }
        let p = LoadProjectionService.project(
            exerciseId: ex, targetReps: 12, targetRIR: 2, repMin: 10, repMax: 12, currentWaveRaw: "b",
            allSessions: sessions, activeMesoSessionIDs: [], loadIncrement: 2.5, unit: .kg
        )
        let load = try XCTUnwrap(p?.suggestedLoad)
        assertOnStep(load, 2.5, "projection")
        if let floor = p?.e1rmFloorLoad, floor > 0 { assertOnStep(floor, 2.5, "e1RM floor") }
    }

    // MARK: Maintenance seeding

    /// A kg lifter's completed history on every item of `meso`, typed in kg (83.3 kg x 9: never on a step).
    private func logKgHistory(_ meso: MesoBlock, in fixture: JourneyFixture) {
        for session in meso.sessions {
            session.status = .completed
            for item in session.items {
                item.actualLoads = [lb(83.3), lb(83.3)]
                item.actualReps = [9, 9]
                item.actualRIRs = [2, 2]
            }
        }
        try? fixture.context.save()
    }

    private func maintenanceLoads(_ meso: MesoBlock) -> [Double] {
        meso.sessions.flatMap { $0.items.map(\.suggestedLoad) }.filter { $0 > 0 }
    }

    func test_maintenanceFromMeso_kgLoadsLandOnKgSteps() throws {
        let fixture = try JourneyFixture.make()
        fixture.context.insert(UserProfile(minLoadIncrement: 2.5, unit: .kg))
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let meso = try fixture.seedProgram(startDate: start, startingLoad: 100)
        logKgHistory(meso, in: fixture)
        let maintenance = try fixture.seedMaintenanceFromMeso(
            sourceMeso: meso, trainingWeekdays: [2, 5], totalWeeks: 2,
            startDate: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        )
        let loads = maintenanceLoads(maintenance)
        XCTAssertFalse(loads.isEmpty, "the maintenance block anchored no loads")
        loads.forEach { assertOnStep($0, 2.5, "Path A maintenance anchor") }
    }

    func test_maintenanceFromTemplate_kgLoadsLandOnKgSteps() throws {
        let fixture = try JourneyFixture.make()
        fixture.context.insert(UserProfile(minLoadIncrement: 2.5, unit: .kg))
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let meso = try fixture.seedProgram(startDate: start, startingLoad: 100)
        logKgHistory(meso, in: fixture)
        let maintenance = try fixture.seedMaintenanceFromTemplate(
            template: FullBody2DayTemplate.template, totalWeeks: 2,
            startDate: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        )
        let loads = maintenanceLoads(maintenance)
        XCTAssertFalse(loads.isEmpty, "the maintenance block anchored no loads")
        // The seeder rounds to the unit's fine default (1.25 kg), not the lifter's increment.
        loads.forEach { assertOnStep($0, 1.25, "Path B maintenance anchor") }
    }

    // MARK: Mechanical-load payload

    func test_mechanicalLoadPayload_carriesItsUnit() throws {
        let sandbox = DefaultsSandbox()
        defer { sandbox.restore() }
        guard let group = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else { throw XCTSkip("App Group unavailable") }
        group.removeObject(forKey: MechanicalLoadSharedStore.unitKey)
        MechanicalLoadSharedStore.set(total: 1234, for: Date())
        XCTAssertEqual(group.string(forKey: MechanicalLoadSharedStore.unitKey), "lb")
        XCTAssertEqual(MechanicalLoadSharedStore.read(for: Date()), 1234)
        XCTAssertTrue(MechanicalLoadSharedStore.readRange(from: day(-2), to: day(1)).values.allSatisfy { $0 > 0 }, "the unit key is not a day total")
    }
}
