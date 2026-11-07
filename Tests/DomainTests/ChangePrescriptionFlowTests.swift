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
        XCTAssertFalse(i.planEdited)
    }

    func test_onlyALoadEditSetsPlanEdited_perSetRepsAndRIRDoNot() {
        let i = bandItem(sets: 3, setMin: nil, setMax: nil)
        i.plannedRepsBySet = [8, 8, 8]; i.plannedRIRsBySet = [2, 2, 2]
        PlanStepperEdits.setPlannedReps(i, at: 1, to: 10)
        PlanStepperEdits.setPlannedRIR(i, at: 2, to: 1)
        PlanStepperEdits.setPlannedReps(i, at: 4, to: 6)      // grows the array like the field does
        XCTAssertEqual(i.plannedRepsBySet, [8, 10, 8, 0, 6]); XCTAssertEqual(i.plannedRIRsBySet, [2, 2, 1])
        XCTAssertFalse(i.planEdited, "per-set reps and RIR edits leave carry-forward free to write loads")

        PlanStepperEdits.setPlannedLoad(i, at: 1, to: 105)
        XCTAssertEqual(i.plannedLoadsBySet, [100, 105, 100])
        XCTAssertTrue(i.planEdited, "a hand-set load is protected")
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
        var model = ChangePrescriptionModel(session: first, item: item, context: ctx, scope: .allRemaining, now: longAgo)
        XCTAssertNil(model.change.note)
        model.noteText = "Hello"
        XCTAssertEqual(model.change.note, "Hello")
        model.clearNote = true
        XCTAssertEqual(model.change.note, "", "Clear note wins over the text")
    }

}
