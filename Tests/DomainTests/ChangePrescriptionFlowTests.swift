import XCTest
import SwiftData
@testable import ElitePerformance

final class ChangePrescriptionFlowTests: XCTestCase {

    private typealias Model = ChangePrescriptionModel
    private var container: ModelContainer!

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

    private func model(_ ctx: ModelContext, _ block: MesoBlock, scope: PrescriptionScope = .everyRemaining) throws -> Model {
        let session = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(session.items.sorted { $0.order < $1.order }.first {
            !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId)
        })
        return Model(session: session, item: item, context: ctx, scope: scope, now: Date(timeIntervalSince1970: 0))
    }

    // MARK: Steppers

    func test_theSetCountStepper_setsPlanEdited_likeTheRIRStepper() {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        XCTAssertFalse(i.planEdited)
        PlanStepperEdits.setSets(i, to: 4)
        XCTAssertEqual(i.targetSets, 4)
        XCTAssertTrue(i.planEdited, "a lifter-chosen set count is a hand-set target")
        i.planEdited = false
        PlanStepperEdits.setRIR(i, to: 1)
        XCTAssertEqual(i.targetRIR, 1)
        XCTAssertTrue(i.planEdited, "a hand-set RIR is the lifter's")
        i.planEdited = false

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
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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
        var plain = Model(session: sessions[0], item: sessions[0].items[0], context: nctx, scope: .weekType)
        XCTAssertFalse(plain.showsLetters)
        plain.letter = "a"
        plain.setDelta = 1
        XCTAssertEqual(try XCTUnwrap(plain.plan()).targets.count, 3, "the letter is ignored without waves")
    }

    // MARK: Preview == applied

    func test_previewCountEqualsAppliedCount_forEachScope() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .weekType)
        m.setDelta = 1
        m.letter = "a"

        let plan = try XCTUnwrap(m.plan())
        let rows = Model.rows(plan)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.count, plan.targets.count)
        XCTAssertTrue(rows.allSatisfy { $0.wave == "A" })
        XCTAssertEqual(Model.confirmTitle(count: rows.count), "Apply to \(rows.count)")
        XCTAssertEqual(m.title(for: .weekType), "This week type, rest of block (\(plan.targets.count))")
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

    // MARK: P3: labels match, and only a load edit freezes carry-forward

    private func bandItem(sets: Int, setMin: Int?, setMax: Int?) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: sets, targetRIR: 2, suggestedLoad: 100,
                            setMin: setMin, setMax: setMax)
        i.plannedLoadsBySet = Array(repeating: 100.0, count: sets)
        return i
    }

    func test_setsStepper_widensTheSetBand_neverNarrowsIt() {
        let i = bandItem(sets: 3, setMin: 3, setMax: 4)
        PlanStepperEdits.setSets(i, to: 4)
        XCTAssertEqual(i.setMin, 3); XCTAssertEqual(i.setMax, 4, "inside the band: unchanged")
        PlanStepperEdits.setSets(i, to: 5)
        XCTAssertEqual(i.setMin, 3); XCTAssertEqual(i.setMax, 5, "above the band: setMax follows")
        PlanStepperEdits.setSets(i, to: 2)
        XCTAssertEqual(i.setMin, 2, "below the band: setMin follows"); XCTAssertEqual(i.setMax, 5, "setMax never narrows")
        PlanStepperEdits.setSets(i, to: 4)
        XCTAssertEqual(i.setMin, 2); XCTAssertEqual(i.setMax, 5)

        let noBand = bandItem(sets: 3, setMin: nil, setMax: nil)
        PlanStepperEdits.setSets(noBand, to: 5)
        XCTAssertNil(noBand.setMin); XCTAssertNil(noBand.setMax, "no band stays no band")
    }

    func test_rirStepper_collapsesTheRangeToTheChosenNumber() {
        let i = bandItem(sets: 3, setMin: nil, setMax: nil)
        i.targetRIRMin = 2; i.targetRIRMax = 3; i.targetRIR = 3
        PlanStepperEdits.setRIR(i, to: 1)
        XCTAssertEqual(i.targetRIR, 1); XCTAssertEqual(i.targetRIRMin, 1); XCTAssertEqual(i.targetRIRMax, 1)
        XCTAssertTrue(i.planEdited)
    }

    func test_anyLifterEditToPlannedLoadsRepsOrRIR_setsPlanEdited() {
        func fresh() -> SessionItem {
            let i = bandItem(sets: 3, setMin: nil, setMax: nil)
            i.plannedRepsBySet = [8, 8, 8]; i.plannedRIRsBySet = [2, 2, 2]
            XCTAssertFalse(i.planEdited)
            return i
        }
        let reps = fresh()
        PlanStepperEdits.setPlannedReps(reps, at: 1, to: 10)
        XCTAssertEqual(reps.plannedRepsBySet, [8, 10, 8]); XCTAssertTrue(reps.planEdited, "a rep-only edit sets the flag")
        let rir = fresh()
        PlanStepperEdits.setPlannedRIR(rir, at: 2, to: 1)
        XCTAssertEqual(rir.plannedRIRsBySet, [2, 2, 1]); XCTAssertTrue(rir.planEdited, "an RIR-only edit sets the flag")
        let grown = fresh()
        PlanStepperEdits.setPlannedReps(grown, at: 4, to: 6)      // grows the array like the field does
        XCTAssertEqual(grown.plannedRepsBySet, [8, 8, 8, 0, 6]); XCTAssertTrue(grown.planEdited)
        let load = fresh()
        PlanStepperEdits.setPlannedLoad(load, at: 1, to: 105)
        XCTAssertEqual(load.plannedLoadsBySet, [100, 105, 100]); XCTAssertTrue(load.planEdited, "a hand-set load is protected")
    }
    // MARK: B5. Top set for remaining sessions

    private typealias SvcB5 = SessionItemEditService

    /// First lift of the first session, its day label and canonical id.
    private func liftB5(_ block: MesoBlock) throws -> (day: String, id: String, session: Session) {
        let first = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(first.items.sorted { $0.order < $1.order }.first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) })
        return (try XCTUnwrap(first.dayLabel), ExerciseCatalog.canonicalExerciseId(for: item.exerciseId), first)
    }

    private func liftItems(_ block: MesoBlock, day: String, id: String) -> [SessionItem] {
        block.sessions.filter { SessionDayLabelMatcher.matches($0.dayLabel, day) }.sorted { $0.date < $1.date }
            .compactMap { s in s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id } }
    }

    private let topSpecB5 = TopSetSpec(count: 1, repMin: 4, repMax: 6, rir: 2)

    func test_B5_addTopSet_forLettersBAndC_only() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let before = Dictionary(uniqueKeysWithValues: liftItems(block, day: lift.day, id: lift.id).map { ($0.id, $0.plannedLoadsBySet.count) })
        let plan = SvcB5.planChangePrescription(
            meso: block, dayLabel: lift.day, exerciseId: lift.id, letters: ["b", "c"], scope: .allRemaining,
            change: PrescriptionChange(topSet: .set(topSpecB5)), now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(plan.targets.isEmpty)
        for t in plan.targets {
            XCTAssertTrue(["b", "c"].contains(t.waveRaw?.lowercased() ?? ""))
            XCTAssertTrue(t.after.text.hasPrefix("1 x 4-6 @ 2 top + \(t.after.sets) x "), t.after.text)
            XCTAssertNil(t.before.top)
        }
        try SvcB5.applyChange(plan, in: ctx)

        for item in liftItems(block, day: lift.day, id: lift.id) {
            let wave = item.waveRaw?.lowercased() ?? ""
            if wave == "b" || wave == "c" {
                XCTAssertEqual(item.topCount, 1, wave)
                XCTAssertEqual(item.setRolesBySet, SessionItem.roles(backOffs: item.targetSets, tops: 1))
                XCTAssertEqual(item.plannedLoadsBySet.count, item.targetSets + 1)
                XCTAssertEqual(item.plannedRepsBySet.count, item.targetSets + 1)
                XCTAssertEqual(item.plannedRIRsBySet.count, item.targetSets + 1)
                XCTAssertEqual([item.topRepMin, item.topRepMax, item.topRIR], [4, 6, 2])
                XCTAssertEqual([item.plannedRepsBySet.last, item.plannedRIRsBySet.last], [4, 2])
                XCTAssertFalse(item.planEdited, "an automatic structural edit does not freeze carry-forward")
            } else {
                XCTAssertNil(item.setRolesBySet, "letter \(wave) is untouched")
                XCTAssertEqual(item.plannedLoadsBySet.count, before[item.id])
            }
        }
    }

    func test_B5_newTopLoad_isSeededFromHistoryAtTopRepsAndRIR() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let done = lift.session
        let doneItem = try XCTUnwrap(done.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == lift.id })
        doneItem.actualLoads = [200, 200, 200]; doneItem.actualReps = [8, 8, 8]; doneItem.actualRIRs = [2, 2, 2]
        done.status = .completed
        try ctx.save()
        let expected = try XCTUnwrap(HistorySeedLoad.load(
            for: lift.id, goalReps: 4, targetRIR: 2, in: block.sessions.map { $0 }, loadIncrement: 2.5, role: .top))
        let plan = SvcB5.planChangePrescription(
            meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
            change: PrescriptionChange(topSet: .set(topSpecB5)), now: Date(timeIntervalSince1970: 0))
        try SvcB5.applyChange(plan, in: ctx)
        let targets = plan.targets.map(\.item)
        XCTAssertFalse(targets.isEmpty)
        XCTAssertGreaterThan(expected, 200, "a 4-rep top at RIR 2 is heavier than 200 x 8")
        for item in targets {
            XCTAssertEqual(item.plannedLoadsBySet.last, expected)
            XCTAssertTrue(item.plannedLoadsBySet.dropLast().allSatisfy { $0 == 0 }, "back-off loads are not touched")
        }
        XCTAssertEqual(done.items.first { $0 === doneItem }?.setRolesBySet, nil, "the completed session is history and is left alone")
    }

    func test_B5_updateRemoveAndSetDelta_keepTheTopTail() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let now = Date(timeIntervalSince1970: 0)
        func run(_ change: PrescriptionChange) throws {
            let plan = SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                    change: change, now: now)
            try SvcB5.applyChange(plan, in: ctx)
        }
        try run(PrescriptionChange(topSet: .set(topSpecB5)))
        // Deload-wave items are never changed (no top set there); the rest carry it.
        let items = liftItems(block, day: lift.day, id: lift.id).filter { $0.hasTopSet }
        XCTAssertFalse(items.isEmpty)
        for i in items { i.plannedLoadsBySet[i.plannedLoadsBySet.count - 1] = 315 }     // a known top load
        let sets0 = items.map(\.targetSets)

        try run(PrescriptionChange(setDelta: 1))
        for (i, s0) in zip(items, sets0) where i.targetSets == s0 + 1 {
            XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets + 1)
            XCTAssertEqual(i.plannedLoadsBySet.last, 315, "the top load rides the tail through a sets change")
            XCTAssertEqual(i.setRolesBySet, SessionItem.roles(backOffs: i.targetSets, tops: 1))
        }

        try run(PrescriptionChange(topSet: .set(TopSetSpec(count: 1, repMin: 3, repMax: 5, rir: 1))))
        for i in items {
            XCTAssertEqual([i.topRepMin, i.topRepMax, i.topRIR], [3, 5, 1])
            XCTAssertEqual(i.plannedLoadsBySet.last, 315, "updating the spec keeps the existing top load")
            XCTAssertEqual([i.plannedRepsBySet.last, i.plannedRIRsBySet.last], [3, 1])
        }

        try run(PrescriptionChange(topSet: .remove))
        for i in items {
            XCTAssertNil(i.setRolesBySet); XCTAssertNil(i.topRepMin); XCTAssertNil(i.topRIR)
            XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets)
            XCTAssertEqual(i.plannedRepsBySet.count, i.targetSets)
            XCTAssertFalse(i.hasTopSet)
        }
    }

    func test_B5_rollback_restoresRolesAndSpec() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let plan = SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                change: PrescriptionChange(topSet: .set(topSpecB5)), now: Date(timeIntervalSince1970: 0))
        let items = liftItems(block, day: lift.day, id: lift.id)
        let snap = items.map { [$0.plannedLoadsBySet.count, $0.plannedRepsBySet.count, $0.topCount] }
        XCTAssertThrowsError(try SvcB5.applyChange(plan, in: ctx, hooks: .init(forceVerificationFailure: true)))
        XCTAssertEqual(items.map { [$0.plannedLoadsBySet.count, $0.plannedRepsBySet.count, $0.topCount] }, snap)
        XCTAssertTrue(items.allSatisfy { $0.setRolesBySet == nil && $0.topRepMin == nil })
        XCTAssertThrowsError(try SvcB5.applyChange(plan, in: ctx, hooks: .init(forceSaveFailure: true)))
        XCTAssertTrue(items.allSatisfy { $0.setRolesBySet == nil })
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_B5_invalidTopSpec_isNotAChange_andNoChangeIsRefused() throws {
        XCTAssertFalse(PrescriptionChange(topSet: .set(TopSetSpec(count: 1, repMin: 6, repMax: 4, rir: 2))).isValid)
        XCTAssertFalse(PrescriptionChange(topSet: .set(TopSetSpec(count: 0, repMin: 4, repMax: 6, rir: 2))).isValid)
        XCTAssertTrue(PrescriptionChange(topSet: .remove).isValid)
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        try SvcB5.applyChange(SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                           change: PrescriptionChange(topSet: .set(topSpecB5)), now: Date(timeIntervalSince1970: 0)), in: ctx)
        let again = SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                 change: PrescriptionChange(topSet: .set(topSpecB5)), now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(again.targets.isEmpty, "the same top set again is no change: " + again.targets.map { "\($0.waveRaw ?? "-") \($0.before.text) -> \($0.after.text)" }.joined(separator: "; "))
        XCTAssertTrue(again.refusals.allSatisfy { $0.reason == .noChange || $0.reason == .deload }, "\(again.refusals.map { $0.reason })")
        XCTAssertTrue(again.refusals.contains { $0.reason == .noChange })
    }

    func test_B5_replace_keepsTheTopSpec_withTheTopLoadRestartedAtZero() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let now = Date(timeIntervalSince1970: 0)
        try SvcB5.applyChange(SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                           change: PrescriptionChange(topSet: .set(topSpecB5)), now: now), in: ctx)
        for i in liftItems(block, day: lift.day, id: lift.id) { i.plannedLoadsBySet[i.plannedLoadsBySet.count - 1] = 315 }
        let used = Set(block.sessions.flatMap(\.items).map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        let y = try XCTUnwrap(ExerciseCatalog.all.first { !used.contains($0.id) && !ExerciseCatalog.isBodyweight(exerciseId: $0.id) }).id
        let plan = SvcB5.planReplace(meso: block, dayLabel: lift.day, from: lift.id, to: y, scope: .allRemaining, context: ctx, now: now)
        let touched = plan.targets.map(\.item).filter { $0.hasTopSet }
        XCTAssertFalse(touched.isEmpty)
        try SvcB5.apply(plan, in: ctx)
        for i in touched {
            XCTAssertEqual(ExerciseCatalog.canonicalExerciseId(for: i.exerciseId), y)
            XCTAssertEqual(i.setRolesBySet, SessionItem.roles(backOffs: i.targetSets, tops: 1), "the spec survives a replace")
            XCTAssertEqual([i.topRepMin, i.topRepMax, i.topRIR], [4, 6, 2])
            XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets + 1)
            XCTAssertEqual(i.plannedLoadsBySet.last, 0, "the new lift's top load restarts")
            XCTAssertEqual(i.actualLoads.count, i.targetSets + 1)
        }
    }


    func test_B7_changePrescriptionSets_movesPrescribedSets_withTargetSets() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let plan = SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                change: PrescriptionChange(setDelta: -1), now: Date(timeIntervalSince1970: 0))
        let items = plan.targets.map(\.item)
        let before = items.map(\.targetSets)
        XCTAssertFalse(items.isEmpty)
        try SvcB5.applyChange(plan, in: ctx)
        for (i, b) in zip(items, before) {
            XCTAssertEqual(i.targetSets, max(1, b - 1))
            XCTAssertEqual(i.prescribedSets, i.targetSets)
        }
    }

    func test_B5_modelBuildsTheTopSetChange() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block)
        XCTAssertNil(m.change.topSet)
        m.topMode = .set; m.topLow = 4; m.topHigh = 6; m.topRIR = 2
        XCTAssertEqual(m.change.topSet, .set(TopSetSpec(count: 1, repMin: 4, repMax: 6, rir: 2)))
        XCTAssertEqual(m.topSetTitle, "Add top set: 1 x 4-6 @ 2")
        m.topMode = .remove
        XCTAssertEqual(m.change.topSet, .remove)
        XCTAssertTrue(m.change.isValid)
    }

    // MARK: M1. Max load on seeds

    func test_M1_replaceSeed_isClampedToTheReplacementsMax() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let now = Date(timeIntervalSince1970: 0)
        let used = Set(block.sessions.flatMap(\.items).map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        let y = try XCTUnwrap(ExerciseCatalog.all.first { !used.contains($0.id) && !ExerciseCatalog.isBodyweight(exerciseId: $0.id) }).id
        let hist = SessionItem(order: 1, exerciseId: y, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        hist.actualLoads = [300, 300, 300]; hist.actualReps = [8, 8, 8]; hist.actualRIRs = [2, 2, 2]
        ctx.insert(Session(date: Date(timeIntervalSince1970: -86_400 * 30), status: .completed, weekIndex: 1, items: [hist]))
        try ctx.save()

        let free = SvcB5.planReplace(meso: block, dayLabel: lift.day, from: lift.id, to: y, scope: .allRemaining, context: ctx, now: now)
        let freeSeed = try XCTUnwrap(free.targets.first?.seedLoad)
        XCTAssertGreaterThan(freeSeed, 100)

        let profile = UserProfile(); profile.setMaxLoad(100, exerciseId: y); ctx.insert(profile)
        try ctx.save()
        let capped = SvcB5.planReplace(meso: block, dayLabel: lift.day, from: lift.id, to: y, scope: .allRemaining, context: ctx, now: now)
        XCTAssertFalse(capped.targets.isEmpty)
        XCTAssertTrue(capped.targets.allSatisfy { $0.seedLoad == 100 }, "\(capped.targets.map { $0.seedLoad as Any })")
        try SvcB5.apply(capped, in: ctx)
        XCTAssertTrue(capped.targets.allSatisfy { $0.item.suggestedLoad == 100 && $0.item.plannedLoadsBySet.allSatisfy { $0 <= 100 } })
    }

    func test_M1_newTopSetSeed_isClampedToTheMax() throws {
        let (ctx, block) = try makeBlock()
        let lift = try liftB5(block)
        let doneItem = try XCTUnwrap(lift.session.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == lift.id })
        doneItem.actualLoads = [200, 200, 200]; doneItem.actualReps = [8, 8, 8]; doneItem.actualRIRs = [2, 2, 2]
        lift.session.status = .completed
        try ctx.save()
        let uncapped = try XCTUnwrap(HistorySeedLoad.load(for: lift.id, goalReps: 4, targetRIR: 2, in: block.sessions.map { $0 },
                                                          loadIncrement: 2.5, role: .top))
        let cap = uncapped - 10
        let profile = UserProfile(); profile.setMaxLoad(cap, exerciseId: lift.id); ctx.insert(profile)
        let plan = SvcB5.planChangePrescription(meso: block, dayLabel: lift.day, exerciseId: lift.id, scope: .allRemaining,
                                                change: PrescriptionChange(topSet: .set(topSpecB5)), now: Date(timeIntervalSince1970: 0))
        try SvcB5.applyChange(plan, in: ctx)
        let targets = plan.targets.map(\.item)
        XCTAssertFalse(targets.isEmpty)
        for item in targets { XCTAssertEqual(item.plannedLoadsBySet.last, cap) }
    }
}

// MARK: - Change the note under an exercise for the remaining sessions

final class NoteChangeTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private var container: ModelContainer!

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

    private let longAgo = Date(timeIntervalSince1970: 0)

    /// The first non-bodyweight exercise of the first session, its day label, and every item of it in the block.
    private func target(_ block: MesoBlock) throws -> (day: String, exercise: String, items: [SessionItem]) {
        let first = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(first.items.sorted { $0.order < $1.order }.first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) })
        let day = try XCTUnwrap(first.dayLabel)
        let canon = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let items = block.sessions.filter { SessionDayLabelMatcher.matches($0.dayLabel, day) }
            .flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canon }
        return (day, canon, items)
    }

    private func plan(_ block: MesoBlock, _ t: (day: String, exercise: String, items: [SessionItem]),
                      letters: Set<String>? = nil, scope: Service.ReplaceScope = .allRemaining, note: String?) -> Service.ChangePlan {
        Service.planChangePrescription(meso: block, dayLabel: t.day, exerciseId: t.exercise, letters: letters, scope: scope,
                                       change: PrescriptionChange(note: note), now: longAgo)
    }

    private func fields(_ i: SessionItem) -> [String] { [i.intensifierNotes ?? "-", i.prescriptionNotes ?? "-"] }

    func test_noteOnlyChange_isValid_andANilNoteIsNotAChange() {
        XCTAssertTrue(PrescriptionChange(note: "x").isValid)
        XCTAssertTrue(PrescriptionChange(note: "").isValid, "clearing is a change")
        XCTAssertFalse(PrescriptionChange(note: nil).isValid)
    }

    func test_aOnlyNote_changesTheALetter_andLeavesBAndC() throws {
        let (ctx, block) = try makeBlock()
        let t = try target(block)
        let before = Dictionary(uniqueKeysWithValues: t.items.map { (ObjectIdentifier($0), fields($0)) })
        let loads = t.items.map { $0.plannedLoadsBySet }
        let edited = t.items.map(\.planEdited)

        let p = plan(block, t, letters: ["a"], note: "Pause every rep.")
        XCTAssertFalse(p.targets.isEmpty)
        XCTAssertTrue(p.targets.allSatisfy { $0.waveRaw?.lowercased() == "a" })
        try Service.applyChange(p, in: ctx)

        for i in t.items {
            if i.waveRaw?.lowercased() == "a" {
                XCTAssertEqual(i.executionNoteText, "Pause every rep.")
                XCTAssertEqual(NoteFields(i).prescription == nil || NoteFields(i).intensifier == nil, true, "only the shown field holds text")
            } else {
                XCTAssertEqual(fields(i), before[ObjectIdentifier(i)], "B, C and deload notes are untouched")
            }
        }
        XCTAssertEqual(t.items.map { $0.plannedLoadsBySet }, loads, "loads untouched")
        XCTAssertEqual(t.items.map(\.planEdited), edited, "planEdited untouched")
    }

    func test_clearNote_emptiesBothFields_andTheLineDisappears() throws {
        let (ctx, block) = try makeBlock()
        let t = try target(block)
        let p = plan(block, t, note: "")
        try Service.applyChange(p, in: ctx)
        for tgt in p.targets {
            XCTAssertNil(tgt.item.intensifierNotes); XCTAssertNil(tgt.item.prescriptionNotes)
            XCTAssertNil(tgt.item.executionNoteText)
        }
        // Whitespace-only counts as clear.
        let again = plan(block, t, note: "   ")
        XCTAssertTrue(again.targets.isEmpty, "already clear: nothing to change")
        XCTAssertTrue(again.refusals.contains { $0.reason == .noChange })
    }

    func test_newNoteIsWrittenToTheDisplayedField_andTheOtherIsCleared_soNothingFallsBack() throws {
        let (ctx, block) = try makeBlock()
        let t = try target(block)
        let sessions = block.sessions.sorted { $0.date < $1.date }
        let aItems = t.items.filter { $0.waveRaw?.lowercased() == "a" }
        let showsIntensifier = try XCTUnwrap(aItems.first)
        let showsPrescription = try XCTUnwrap(aItems.dropFirst().first)
        showsIntensifier.intensifierNotes = "OLD INTENSIFIER"; showsIntensifier.prescriptionNotes = "OLD RX"
        showsPrescription.intensifierNotes = "   "; showsPrescription.prescriptionNotes = "OLD RX 2"
        XCTAssertEqual(showsIntensifier.executionNoteText, "OLD INTENSIFIER")
        XCTAssertEqual(showsPrescription.executionNoteText, "OLD RX 2", "a blank intensifier note does not display")
        _ = sessions

        let p = plan(block, t, letters: ["a"], note: "  New text  ")
        try Service.applyChange(p, in: ctx)

        XCTAssertEqual(showsIntensifier.intensifierNotes, "New text")
        XCTAssertNil(showsIntensifier.prescriptionNotes, "the older note can never show again")
        XCTAssertEqual(showsPrescription.prescriptionNotes, "New text")
        XCTAssertNil(showsPrescription.intensifierNotes)
        for i in [showsIntensifier, showsPrescription] { XCTAssertEqual(i.executionNoteText, "New text") }

        // And clearing afterwards leaves nothing behind to fall back to.
        try Service.applyChange(plan(block, t, letters: ["a"], note: ""), in: ctx)
        XCTAssertNil(showsIntensifier.executionNoteText); XCTAssertNil(showsPrescription.executionNoteText)
    }

    func test_thisSessionScope_changesOnlyThatSession() throws {
        let (ctx, block) = try makeBlock()
        let t = try target(block)
        let one = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let others = t.items.filter { !one.items.contains($0) }.map(fields)
        let p = plan(block, t, scope: .thisSession(one), note: "Only today")
        XCTAssertEqual(p.targets.count, 1)
        try Service.applyChange(p, in: ctx)
        XCTAssertEqual(p.targets[0].item.executionNoteText, "Only today")
        XCTAssertEqual(t.items.filter { !one.items.contains($0) }.map(fields), others)
    }

    func test_previewShowsOldToNewTruncated() throws {
        let (ctx, block) = try makeBlock()
        let t = try target(block)
        let long = String(repeating: "abcdefghij", count: 6)
        let p = plan(block, t, letters: ["a"], note: long)
        let rows = ChangePrescriptionModel.rows(p)
        XCTAssertEqual(rows.count, p.targets.count)
        let note = try XCTUnwrap(rows[0].note)
        XCTAssertTrue(note.hasPrefix("Note: "), note)
        XCTAssertTrue(note.contains("…\""), "long notes are shortened: \(note)")
        XCTAssertTrue(note.contains(" -> "))
        XCTAssertEqual(ChangePrescriptionModel.shortNote(nil), "none")
        XCTAssertEqual(ChangePrescriptionModel.shortNote("hi"), "\"hi\"")
        _ = ctx
    }

    func test_rollback_restoresBothNoteFields() throws {
        let (ctx, block) = try makeBlock()
        let t = try target(block)
        for (n, i) in t.items.enumerated() where i.waveRaw?.lowercased() == "a" {
            i.intensifierNotes = n % 2 == 0 ? "INT \(n)" : nil
            i.prescriptionNotes = "RX \(n)"
        }
        try ctx.save()
        let before = t.items.map(fields)

        let p = plan(block, t, letters: ["a"], note: "Changed")
        XCTAssertThrowsError(try Service.applyChange(p, in: ctx, hooks: .init(forceVerificationFailure: true)))
        XCTAssertEqual(t.items.map(fields), before)
        XCTAssertThrowsError(try Service.applyChange(p, in: ctx, hooks: .init(forceSaveFailure: true)))
        XCTAssertEqual(t.items.map(fields), before)
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_sessionScreenUsesTheSameDisplayRule() {
        XCTAssertEqual(NoteFields(intensifier: " I ", prescription: "R").displayed, "I")
        XCTAssertEqual(NoteFields(intensifier: "  ", prescription: " R ").displayed, "R")
        XCTAssertNil(NoteFields(intensifier: nil, prescription: "  ").displayed)
    }

    func test_modelBuildsTheNoteChange() throws {
        let (ctx, block) = try makeBlock()
        let first = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(first.items.first)
        var model = ChangePrescriptionModel(session: first, item: item, context: ctx, scope: .everyRemaining, now: longAgo)
        XCTAssertNil(model.change.note)
        model.noteText = "Hello"
        XCTAssertEqual(model.change.note, "Hello")
        model.clearNote = true
        XCTAssertEqual(model.change.note, "", "Clear note wins over the text")
    }

}

// MARK: - Multi-session safety: default scope, letter scope, confirmation, backup, undo

@MainActor
final class MultiSessionSafetyTests: XCTestCase {

    private typealias Model = ChangePrescriptionModel
    private var container: ModelContainer!

    private func makeBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

    private func model(_ ctx: ModelContext, _ block: MesoBlock, scope: PrescriptionScope? = nil) throws -> Model {
        let session = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(session.items.sorted { $0.order < $1.order }.first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) })
        let now = Date(timeIntervalSince1970: 0)
        if let scope { return Model(session: session, item: item, context: ctx, scope: scope, now: now) }
        return Model(session: session, item: item, context: ctx, now: now)
    }

    /// Everything a prescription change can write, plus the fields it must leave alone, for every item in the block.
    private func snapshot(_ block: MesoBlock) -> [String] {
        block.sessions.sorted { $0.date < $1.date }.flatMap { s in
            s.items.sorted { $0.order < $1.order }.map { i in
                [ "\(s.weekIndex)", i.exerciseId, i.waveRaw ?? "-", "\(i.targetSets)", "\(i.targetReps)", "\(i.targetRIR)",
                  "\(String(describing: i.setMin))", "\(String(describing: i.setMax))", "\(String(describing: i.repMin))",
                  "\(String(describing: i.repMax))", "\(String(describing: i.targetRIRMin))", "\(String(describing: i.targetRIRMax))",
                  "\(i.plannedLoadsBySet)", "\(i.plannedRepsBySet)", "\(i.plannedRIRsBySet)", "\(String(describing: i.setRolesBySet))",
                  "\(String(describing: i.topRepMin))", "\(String(describing: i.topRepMax))", "\(String(describing: i.topRIR))",
                  "\(String(describing: i.prescribedSets))", "\(String(describing: i.intensifierNotes))",
                  "\(String(describing: i.prescriptionNotes))", "\(i.planEdited)", "\(i.suggestedLoad)" ].joined(separator: "|")
            }
        }
    }

    private func lift(_ block: MesoBlock) throws -> (day: String, id: String) {
        let first = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(first.items.sorted { $0.order < $1.order }.first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) })
        return (try XCTUnwrap(first.dayLabel), ExerciseCatalog.canonicalExerciseId(for: item.exerciseId))
    }

    // MARK: Scope

    func test_defaultScopeIsThisSessionOnly_andItIsTheFirstOption() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block)
        XCTAssertEqual(m.scope, .thisSession)
        XCTAssertEqual(m.availableScopes.first, .thisSession)
        XCTAssertEqual(m.availableScopes, [.thisSession, .weekType, .everyRemaining], "waved block: all three")
        XCTAssertEqual(PrescriptionScope.thisSession.title, "This session only")
        XCTAssertEqual(PrescriptionScope.weekType.title, "This week type, rest of block")
        XCTAssertEqual(PrescriptionScope.everyRemaining.title, "Every remaining session")
        var edit = m
        edit.changeReps = true; edit.repLow = 12; edit.repHigh = 15
        XCTAssertEqual(try XCTUnwrap(edit.plan()).targets.count, 1, "untouched defaults change one session")
    }

    func test_weekTypeStartsOnTheSessionsOwnLetter_andThereIsNoAll() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block, scope: .weekType)
        let own = try XCTUnwrap(m.session.items.first { $0 === m.item }?.waveRaw?.lowercased())
        XCTAssertEqual(m.letter, own)
        var none = m
        none.letter = nil
        let plan = try XCTUnwrap({ var n = none; n.changeReps = true; n.repLow = 12; n.repHigh = 15; return n.plan() }())
        XCTAssertTrue(plan.targets.isEmpty, "no letter chosen changes nothing; there is no 'All'")
    }

    func test_nonWavedBlock_hasNoWeekTypeScope() throws {
        let (ctx, block) = try makeBlock()
        let session = try XCTUnwrap(block.sessions.first)
        for s in block.sessions { for i in s.items { i.waveRaw = nil } }
        let m = Model(session: session, item: try XCTUnwrap(session.items.first), context: ctx)
        XCTAssertFalse(m.showsLetters)
        XCTAssertEqual(m.availableScopes, [.thisSession, .everyRemaining])
    }

    func test_letterScopeNeverTouchesOtherLetters() throws {
        let (ctx, block) = try makeBlock()
        let (day, id) = try lift(block)
        var m = try model(ctx, block, scope: .weekType)
        m.letter = "c"
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let before = Dictionary(uniqueKeysWithValues: block.sessions.flatMap(\.items).map { ($0.persistentModelID, snapshot(of: $0)) })
        let plan = try XCTUnwrap(m.plan())
        XCTAssertFalse(plan.targets.isEmpty)
        XCTAssertTrue(plan.targets.allSatisfy { $0.waveRaw?.lowercased() == "c" })
        guard case .success = m.apply(plan) else { return XCTFail("apply failed") }
        let changed = Set(plan.targets.map { $0.item.persistentModelID })
        for s in block.sessions { for i in s.items where !changed.contains(i.persistentModelID) {
            XCTAssertEqual(snapshot(of: i), before[i.persistentModelID], "\(s.dayLabel ?? "") wk\(s.weekIndex) \(i.waveRaw ?? "-") untouched")
        } }
        // Other letters of the same lift on the same day are among the untouched ones.
        let sameLift = block.sessions.filter { SessionDayLabelMatcher.matches($0.dayLabel, day) }
            .flatMap { $0.items.filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id } }
        XCTAssertTrue(sameLift.contains { $0.waveRaw?.lowercased() != "c" })
    }

    private func snapshot(of i: SessionItem) -> String {
        "\(i.targetSets)|\(i.targetReps)|\(i.repMin ?? -1)|\(i.repMax ?? -1)|\(i.plannedRepsBySet)|\(i.plannedLoadsBySet)|\(i.planEdited)"
    }

    // MARK: Entry point and scope counts

    func test_scopeRowsCountTheSessionsInScope_beforeAnyValueChanges() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .thisSession)
        XCTAssertFalse(m.change.isValid)
        let every = m.sessionsInScope(.everyRemaining), type = m.sessionsInScope(.weekType)
        XCTAssertGreaterThan(every, 1)
        XCTAssertGreaterThan(type, 1)
        XCTAssertLessThan(type, every, "one letter is a subset of every letter")
        XCTAssertEqual(m.title(for: .everyRemaining), "Every remaining session (\(every))")
        XCTAssertEqual(m.title(for: .weekType), "This week type, rest of block (\(type))")
        XCTAssertEqual(try XCTUnwrap(m.plan(scope: .everyRemaining)).targets.count, 0, "nothing to change yet")

        // A change that touches only some of those sessions: the row keeps the scope's size, the alert counts the changed ones.
        m.scope = .everyRemaining
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let plan = try XCTUnwrap(m.plan())
        XCTAssertEqual(m.sessionsInScope(.everyRemaining), every, "the row does not move with the value")
        XCTAssertTrue(Model.confirmationMessage(plan).contains("in \(plan.targets.count) sessions"))
    }

    func test_planEditedSessionsAreNotInTheEveryRemainingCount() throws {
        let (ctx, block) = try makeBlock()
        let m = try model(ctx, block, scope: .everyRemaining)
        let before = m.sessionsInScope(.everyRemaining)
        let (day, id) = try lift(block)
        let items = block.sessions.sorted { $0.date < $1.date }.filter { SessionDayLabelMatcher.matches($0.dayLabel, day) }
            .compactMap { s in s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id } }
        items.first { $0.waveRaw?.lowercased() != "deload" }?.planEdited = true
        XCTAssertEqual(m.sessionsInScope(.everyRemaining), before - 1)
    }

    func test_theEntryPointIsCalledChangePrescription() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let day = try String(contentsOf: dir.appendingPathComponent("Features/Home/ProgramDayDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(day.contains("Change prescription…"))
        XCTAssertFalse(day.contains("Change for remaining sessions"))
        let guide = try String(contentsOf: dir.appendingPathComponent("ElitePerformance/Resources/Guide/Guide.html"), encoding: .utf8)
        XCTAssertTrue(guide.contains("Change prescription…"))
        XCTAssertFalse(guide.contains("Change for remaining sessions"))
    }

    // MARK: Confirmation text

    func test_scopeSummary_wordsLettersAndWeeks() {
        XCTAssertEqual(MultiSessionCopy.scopeSummary(waves: ["c", "c"], weeks: [9, 12]), "C weeks, weeks 9 and 12")
        XCTAssertEqual(MultiSessionCopy.scopeSummary(waves: ["a", "c", "a"], weeks: [1, 3, 4]), "A and C weeks, weeks 1, 3 and 4")
        XCTAssertEqual(MultiSessionCopy.scopeSummary(waves: ["a", "b", "c"], weeks: [4, 5, 6, 7]), "A, B and C weeks, weeks 4–7")
        XCTAssertEqual(MultiSessionCopy.scopeSummary(waves: [nil, nil], weeks: [2, 3]), "weeks 2 and 3", "no waves: weeks only")
        XCTAssertEqual(MultiSessionCopy.weeksText([5]), "week 5")
    }

    func test_confirmationText_hasTheNameTheValuesTheCountTheLettersAndTheWeeks() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .weekType)
        m.letter = "c"
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let plan = try XCTUnwrap(m.plan())
        let n = plan.targets.count
        XCTAssertGreaterThan(n, 1)
        let weeks = Array(Set(plan.targets.map(\.weekIndex))).sorted()
        let before = plan.targets[0].before
        let old = MultiSessionCopy.range(before.repMin, before.repMax)
        let text = Model.confirmationMessage(plan)
        XCTAssertEqual(text, "\(ExerciseCatalog.displayName(for: plan.exerciseId)): \(old) → 12–15 in \(n) sessions "
                       + "(C weeks, \(MultiSessionCopy.weeksText(weeks))). Change?")
        XCTAssertTrue(Model.isMultiSession(plan))
        var one = m
        one.scope = .thisSession
        XCTAssertFalse(Model.isMultiSession(try XCTUnwrap(one.plan())), "one session needs no confirmation")
    }

    func test_confirmationText_namesEveryPart_whenSeveralThingsChange() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .everyRemaining)
        m.setDelta = 1
        m.changeRIR = true; m.rirLow = 1; m.rirHigh = 2
        let text = Model.confirmationMessage(try XCTUnwrap(m.plan()))
        XCTAssertTrue(text.contains("sets +1"), text)
        XCTAssertTrue(text.contains("RIR "), text)
        XCTAssertTrue(text.contains("→ 1–2"), text)
    }

    // MARK: Backup first

    func test_aFailedBackup_appliesNothing_andASuccessfulOneAppliesAfterIt() async throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .everyRemaining)
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let plan = try XCTUnwrap(m.plan())
        let before = snapshot(block)

        let failing = SeedBackupGuard(backup: { _ in .failure(AutoBackupError.emptyStore) })
        var applied = 0
        failing.run(container: container) { if case .success = m.apply(plan) { applied += 1 } }
        try await wait { failing.failure != nil }
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(snapshot(block), before, "nothing was written")

        var order: [String] = []
        let ok = SeedBackupGuard(backup: { _ in order.append("backup"); return .success(nil) })
        ok.run(container: container) { order.append("apply"); _ = m.apply(plan) }
        try await wait { order.count == 2 }
        XCTAssertEqual(order, ["backup", "apply"])
        XCTAssertNotEqual(snapshot(block), before)
    }

    func test_theFormTakesTheBackupBeforeApplyingMoreThanOneSession() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let change = try String(contentsOf: dir.appendingPathComponent("Features/Home/ChangePrescriptionFlow.swift"), encoding: .utf8)
        XCTAssertTrue(change.contains("seedGuard.run(container: modelContext.container)"))
        XCTAssertTrue(change.contains("pendingConfirm = plan"), "multi-session goes through the alert first")
        let replace = try String(contentsOf: dir.appendingPathComponent("Features/Home/ReplaceExerciseFlow.swift"), encoding: .utf8)
        XCTAssertTrue(replace.contains("seedGuard.run(container: modelContext.container)"))
        XCTAssertTrue(replace.contains("ReplaceExerciseModel.isMultiSession(plan)"))
    }

    func test_replaceConfirmation_hasTheCountAndTheScope() throws {
        let (ctx, block) = try makeBlock()
        let session = try XCTUnwrap(block.sessions.sorted { $0.date < $1.date }.first)
        let item = try XCTUnwrap(session.items.sorted { $0.order < $1.order }.first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) })
        let used = Set(block.sessions.flatMap(\.items).map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        let y = try XCTUnwrap(ExerciseCatalog.all.first { !used.contains($0.id) && !ExerciseCatalog.isBodyweight(exerciseId: $0.id) })
        let rm = ReplaceExerciseModel(session: session, item: item, replacementId: y.id, context: ctx, now: Date(timeIntervalSince1970: 0))
        let all = try XCTUnwrap(rm.plan(for: .allRemaining))
        XCTAssertTrue(ReplaceExerciseModel.isMultiSession(all))
        let text = ReplaceExerciseModel.confirmationMessage(all)
        XCTAssertTrue(text.contains("in \(all.targets.count) sessions ("), text)
        XCTAssertTrue(text.hasSuffix("Replace?"), text)
        XCTAssertFalse(ReplaceExerciseModel.isMultiSession(try XCTUnwrap(rm.plan(for: .thisSession))))
    }

    // MARK: Undo

    func test_undoPutsEveryChangedFieldBackExactly() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .everyRemaining)
        m.setDelta = 1
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        m.changeRIR = true; m.rirLow = 1; m.rirHigh = 2
        m.noteText = "Controlled tempo"
        m.topMode = .set; m.topLow = 4; m.topHigh = 6; m.topRIR = 2
        let before = snapshot(block)
        let plan = try XCTUnwrap(m.plan())
        XCTAssertGreaterThan(plan.targets.count, 1)
        let undo = m.captureUndo(plan)
        XCTAssertEqual(undo.sessionCount, plan.targets.count)
        guard case .success = m.apply(plan) else { return XCTFail("apply failed") }
        XCTAssertNotEqual(snapshot(block), before, "the apply changed something")
        guard case .success(let restored) = m.undo(undo) else { return XCTFail("undo failed") }
        XCTAssertEqual(restored, plan.targets.count)
        XCTAssertEqual(snapshot(block), before, "every field of every item is as it was, planEdited included")
    }

    func test_undoRestoresOnlyTheFieldsTheChangeWrote_notAnythingTheLifterDidSince() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .everyRemaining)
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let plan = try XCTUnwrap(m.plan())
        let undo = m.captureUndo(plan)
        guard case .success = m.apply(plan) else { return XCTFail("apply failed") }
        let target = try XCTUnwrap(plan.targets.last)
        target.item.suggestedLoad = 123.5               // not a prescription field
        target.item.planEdited = true
        guard case .success = m.undo(undo) else { return XCTFail("undo failed") }
        XCTAssertEqual(target.item.suggestedLoad, 123.5, "undo is not a backup restore")
        XCTAssertTrue(target.item.planEdited)
        XCTAssertEqual(target.item.repMin, target.before.repMin)
        XCTAssertEqual(target.item.repMax, target.before.repMax)
    }

    func test_undoSkipsASessionThatHasStartedSince() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .everyRemaining)
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let plan = try XCTUnwrap(m.plan())
        let undo = m.captureUndo(plan)
        guard case .success = m.apply(plan) else { return XCTFail("apply failed") }
        let started = try XCTUnwrap(plan.targets.first)
        started.session.status = .inProgress
        guard case .success(let restored) = m.undo(undo) else { return XCTFail("undo failed") }
        XCTAssertEqual(restored, plan.targets.count - 1)
        XCTAssertEqual(started.item.repMin, 12, "the started session keeps what it has")
    }

    // MARK: Hand-edited plans

    func test_everyRemaining_stillRefusesPlanEditedItems() throws {
        let (ctx, block) = try makeBlock()
        var m = try model(ctx, block, scope: .everyRemaining)
        m.changeReps = true; m.repLow = 12; m.repHigh = 15
        let all = try XCTUnwrap(m.plan())
        let edited = try XCTUnwrap(all.targets.dropFirst(2).first)
        edited.item.planEdited = true
        let again = try XCTUnwrap(m.plan())
        XCTAssertEqual(again.targets.count, all.targets.count - 1)
        XCTAssertFalse(again.targets.contains { $0.item === edited.item })
        XCTAssertEqual(again.editedSkipped, 1)
        guard case .success = m.apply(again) else { return XCTFail("apply failed") }
        XCTAssertEqual(edited.item.repMin, edited.before.repMin, "the hand-edited item is left as it is")
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - Wave labels (one path for every screen)
final class WaveLabelsTests: XCTestCase {

    private typealias S = WaveLabels.Sample
    private func anchors(_ a: Int, _ b: Int, _ c: Int) -> [S] {
        [S(letter: "a", repMax: a, isAnchor: true), S(letter: "b", repMax: b, isAnchor: true), S(letter: "c", repMax: c, isAnchor: true)]
    }

    // MARK: Ordering

    func test_threeLetters_areOrderedByRepMax_lowestHeaviest() {
        XCTAssertEqual(WaveLabels.labels(samples: anchors(6, 8, 10), mesoName: "X"), ["a": "Heavy", "b": "Moderate", "c": "Light"])
        // Not tied to the alphabet: the letters follow the numbers.
        XCTAssertEqual(WaveLabels.labels(samples: anchors(10, 6, 8), mesoName: "X"), ["a": "Light", "b": "Heavy", "c": "Moderate"])
        XCTAssertEqual(WaveLabels.labels(samples: anchors(8, 10, 6), mesoName: "X"), ["a": "Moderate", "b": "Light", "c": "Heavy"])
    }

    func test_twoLetters_areHeavyAndLight() {
        let two = [S(letter: "a", repMax: 5, isAnchor: true), S(letter: "c", repMax: 12, isAnchor: true)]
        XCTAssertEqual(WaveLabels.labels(samples: two, mesoName: "X"), ["a": "Heavy", "c": "Light"])
    }

    func test_theMeanOfAnchorsDecides_notAccessories() {
        var s = anchors(6, 8, 10)
        // Accessories say the opposite; they are ignored while every letter has an anchor.
        s += [S(letter: "a", repMax: 30, isAnchor: false), S(letter: "c", repMax: 3, isAnchor: false)]
        XCTAssertEqual(WaveLabels.labels(samples: s, mesoName: "X")["a"], "Heavy")
        // Means, not single values: a=(6+10)/2=8, b=(6+6)/2=6 -> b is the heavier.
        let mixed = [S(letter: "a", repMax: 6, isAnchor: true), S(letter: "a", repMax: 10, isAnchor: true),
                     S(letter: "b", repMax: 6, isAnchor: true), S(letter: "b", repMax: 6, isAnchor: true)]
        XCTAssertEqual(WaveLabels.labels(samples: mixed, mesoName: "X"), ["b": "Heavy", "a": "Light"])
    }

    func test_withNoAnchorsEveryPrescriptionCounts() {
        let s = [S(letter: "a", repMax: 6, isAnchor: false), S(letter: "b", repMax: 12, isAnchor: false)]
        XCTAssertEqual(WaveLabels.labels(samples: s, mesoName: "X"), ["a": "Heavy", "b": "Light"])
    }

    // MARK: Fallback

    func test_lettersInTheSameRepZone_fallBackToTheExistingNames() {
        let same = anchors(8, 8, 9)           // span 1 -> the same zone
        XCTAssertEqual(WaveLabels.labels(samples: same, mesoName: "12-Week DUP Meso"),
                       ["a": "Strength", "b": "Hypertrophy", "c": "Intensification"])
        XCTAssertEqual(WaveLabels.labels(samples: same, mesoName: "4-Day Upper / Lower"),
                       ["a": "Baseline", "b": "Volume", "c": "Intensity"])
        XCTAssertEqual(WaveLabels.labels(samples: same, mesoName: "3-Day Push / Pull / Legs"),
                       ["a": "Accumulation", "b": "Development", "c": "Intensification"])
        // Two reps apart is a difference.
        XCTAssertEqual(WaveLabels.labels(samples: anchors(8, 8, 10), mesoName: "X")["c"], "Light")
    }

    func test_aSingleLetter_usesTheExistingName() {
        XCTAssertEqual(WaveLabels.labels(samples: [S(letter: "a", repMax: 8, isAnchor: true)], mesoName: "12-Week DUP Meso"), ["a": "Strength"])
    }

    // MARK: Deload, maintenance, no waves

    func test_deloadAndMaintenanceKeepTheirLabels_andCarryNoLetter() {
        let labels = WaveLabels.labels(samples: anchors(6, 8, 10), mesoName: "12-Week DUP Meso")
        XCTAssertNil(labels["deload"], "deload is not ranked")
        XCTAssertEqual(WaveLabels.display(forRaw: "deload", labels: labels, mesoName: "12-Week DUP Meso"), "Deload")
        XCTAssertEqual(WaveLabels.display(forRaw: "deload", labels: labels, mesoName: "Maintenance Block"), "Maintenance")
        // A deload prescription never moves the means.
        let withDeload = anchors(6, 8, 10) + [S(letter: "deload", repMax: 20, isAnchor: true)]
        XCTAssertEqual(WaveLabels.labels(samples: withDeload, mesoName: "X"), WaveLabels.labels(samples: anchors(6, 8, 10), mesoName: "X"))
    }

    func test_noWaves_showsNothing() {
        XCTAssertTrue(WaveLabels.labels(samples: [], mesoName: "X").isEmpty)
        XCTAssertTrue(WaveLabels.labels(sessions: [], mesoName: "X").isEmpty)
        XCTAssertNil(WaveLabels.display(forRaw: nil, labels: [:], mesoName: "X"))
        XCTAssertNil(WaveLabels.display(forRaw: "  ", labels: [:], mesoName: "X"))
    }

    func test_displayReadsNameThenLetter() {
        let labels = WaveLabels.labels(samples: anchors(6, 8, 10), mesoName: "X")
        XCTAssertEqual(WaveLabels.display(forRaw: "b", labels: labels, mesoName: "X"), "Moderate (B)")
        XCTAssertEqual(WaveLabels.display(forRaw: "A", labels: labels, mesoName: "X"), "Heavy (A)")
    }

    // MARK: A renamed block still gets labels

    private func block(name: String, reps: [String: Int]) throws -> MesoBlock {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        keep.append(c)
        let ctx = ModelContext(c)
        let meso = MesoBlock(name: name, startDate: Date(), status: .active, totalWeeks: 3)
        ctx.insert(meso)
        for (i, letter) in reps.keys.sorted().enumerated() {
            let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: reps[letter]!, targetSets: 3, targetRIR: 2, suggestedLoad: 0,
                                   waveRaw: letter, priorityRaw: "anchor", repMin: reps[letter]! - 2, repMax: reps[letter]!)
            let s = Session(date: Date().addingTimeInterval(Double(i) * 86400), status: .planned, weekIndex: i + 1, dayLabel: "D", items: [item])
            s.meso = meso; ctx.insert(s)
        }
        try ctx.save()
        return meso
    }
    private var keep: [ModelContainer] = []

    func test_aRenamedBlock_stillGetsLabels() throws {
        let original = try block(name: "12-Week DUP Meso", reps: ["a": 6, "b": 8, "c": 10])
        let renamed = try block(name: "My summer block", reps: ["a": 6, "b": 8, "c": 10])
        XCTAssertEqual(WaveLabels.labels(meso: original), ["a": "Heavy", "b": "Moderate", "c": "Light"])
        XCTAssertEqual(WaveLabels.labels(meso: renamed), WaveLabels.labels(meso: original))
        XCTAssertEqual(WaveLabels.display(forRaw: "b", meso: renamed), "Moderate (B)")
        // Same zone + renamed: the generic fallback names, never nothing.
        let flat = try block(name: "My summer block", reps: ["a": 8, "b": 8, "c": 8])
        XCTAssertEqual(WaveLabels.labels(meso: flat), ["a": "Baseline", "b": "Volume", "c": "Intensity"])
    }

    // MARK: Every built-in template (the report)

    func test_everyBuiltInTemplate_labels() {
        let templates: [ProgramTemplate] = [DUP10WeekTemplate.template, PPL3WeekTemplate.template, UpperLower4DayTemplate.template,
                                            Hybrid5DayTemplate.template, FullBody2DayTemplate.template, PPL6DayTemplate.template]
        for t in templates {
            let labels = WaveLabels.labels(template: t)
            print("WAVELABELS \(t.name): \(labels.sorted { $0.key < $1.key }.map { "\($0.key.uppercased())=\($0.value)" }.joined(separator: " "))")
            XCTAssertFalse(labels.isEmpty, t.name)
        }
        XCTAssertEqual(WaveLabels.labels(template: DUP10WeekTemplate.template), ["a": "Heavy", "b": "Moderate", "c": "Light"])
    }
}
