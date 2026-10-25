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
