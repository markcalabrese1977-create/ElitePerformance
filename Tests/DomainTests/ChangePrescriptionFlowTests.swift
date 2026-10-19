import XCTest
import SwiftData
@testable import ElitePerformance

final class ChangePrescriptionFlowTests: XCTestCase {

    private typealias Model = ChangePrescriptionModel
    private var container: ModelContainer!

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let cal = Calendar(identifier: .gregorian)
        try DUPProgramSeeder.seed(
            startDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!,
            trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal, mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        try ctx.save()
        return (ctx, try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first))
    }

    private func model(_ ctx: ModelContext, _ block: MesoBlock, scope: ReplaceScopeChoice = .allRemaining) throws -> Model {
        let session = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(session.items.sorted { $0.order < $1.order }.first {
            !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId)
        })
        return Model(session: session, item: item, context: ctx, scope: scope, now: Date(timeIntervalSince1970: 0))
    }

    // MARK: Steppers

    func test_setsAndRIRSteppers_doNotSetPlanEdited() {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        XCTAssertFalse(i.planEdited)
        PlanStepperEdits.setSets(i, to: 4)
        PlanStepperEdits.setRIR(i, to: 1)
        XCTAssertEqual(i.targetSets, 4)
        XCTAssertEqual(i.targetRIR, 1)
        XCTAssertFalse(i.planEdited, "a sets/RIR stepper tap must not freeze carry-forward")

        i.planEdited = true            // set by editing a load
        PlanStepperEdits.setSets(i, to: 3)
        XCTAssertTrue(i.planEdited, "the steppers never clear it either")
    }

    // MARK: Letters

    func test_lettersAreOfferedOnWaveBlocksOnly() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        XCTAssertTrue(m.showsLetters)
        XCTAssertEqual(Set(m.availableLetters), ["a", "b", "c"], "deload is not offered")

        // A block with no wave letters: nothing to pick, and a stale letter is ignored.
        let c = try ModelContainer(for: Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                                                UserProfile.self, User.self, CustomExercise.self]),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let nctx = ModelContext(c)
        let meso = MesoBlock(name: "Mine", startDate: Date(), status: .active, totalWeeks: 4)
        nctx.insert(meso)
        var sessions: [Session] = []
        for w in 1...3 {
            let it = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0,
                                 plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [0, 0, 0], plannedRIRsBySet: [2, 2, 2])
            let s = Session(date: Date().addingTimeInterval(Double(w) * 7 * 86400), status: .planned, weekIndex: w, dayLabel: "Day A", items: [it])
            s.meso = meso; nctx.insert(s); sessions.append(s)
        }
        try nctx.save()
        var plain = Model(session: sessions[0], item: sessions[0].items[0], context: nctx, scope: .allRemaining)
        XCTAssertFalse(plain.showsLetters)
        plain.letter = "a"
        plain.setDelta = 1
        XCTAssertEqual(try XCTUnwrap(plain.plan()).targets.count, 3, "the letter is ignored without waves")
    }

    // MARK: Preview == applied

    func test_previewCountEqualsAppliedCount_forEachScope() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block)
        m.setDelta = 1
        m.letter = "a"

        let plan = try XCTUnwrap(m.plan())
        let rows = Model.rows(plan)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.count, plan.targets.count)
        XCTAssertTrue(rows.allSatisfy { $0.wave == "A" })
        XCTAssertEqual(Model.confirmTitle(count: rows.count), "Apply to \(rows.count)")
        XCTAssertEqual(m.title(for: .allRemaining), "All remaining \(m.dayLabel ?? "") sessions (\(plan.targets.count))")
        XCTAssertEqual(m.title(for: .thisSession), "This session only")

        guard case .success(let applied) = m.apply(plan) else { return XCTFail("apply failed") }
        XCTAssertEqual(applied.sessionsChanged, rows.count, "preview count == applied count")
        for t in plan.targets { XCTAssertEqual(t.item.targetSets, t.before.sets + 1) }

        var single = try model(ctx, block, scope: .thisSession)
        single.changeRIR = true; single.rirLow = 1; single.rirHigh = 2
        let onePlan = try XCTUnwrap(single.plan())
        XCTAssertEqual(onePlan.targets.count, 1, "reps-entry scope: this session only")
        guard case .success(let one) = single.apply(onePlan) else { return XCTFail("apply failed") }
        XCTAssertEqual(one.sessionsChanged, 1)
    }

    func test_invalidOrEmptyChange_hasNothingToApply() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        XCTAssertFalse(m.change.isValid)
        XCTAssertTrue(try XCTUnwrap(m.plan()).targets.isEmpty)
    }

    func test_failures_showAMessage_andWriteNothing() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block)
        m.setDelta = 1
        let plan = try XCTUnwrap(m.plan())
        let other = try XCTUnwrap(block.sessions.first { s in !plan.targets.contains { $0.session === s } })
        other.status = .inProgress

        guard case .failure(let failure) = m.apply(plan) else { return XCTFail("should refuse") }
        XCTAssertEqual(failure.error, .sessionInProgress)
        XCTAssertTrue(failure.message.contains("Nothing was changed"))
        XCTAssertTrue(plan.targets.allSatisfy { $0.item.targetSets == $0.before.sets })
    }
}
