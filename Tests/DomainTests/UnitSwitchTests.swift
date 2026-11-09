import XCTest
import SwiftData
@testable import ElitePerformance

/// K4: switching units never rewrites stored loads; the re-round is a separate, confirmed, verified edit.
final class UnitSwitchTests: XCTestCase {

    private func lb(_ kg: Double) -> Double { LoadUnit.kg.toStoredLb(kg) }
    private func kg(_ lb: Double) -> Double { LoadUnit.kg.fromStoredLb(lb) }
    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }

    private struct World {
        let ctx: ModelContext
        let profile: UserProfile
        let meso: MesoBlock
        let planned: [SessionItem]      // three planned items
        let completed: SessionItem
        let inProgress: SessionItem
    }

    private func item(_ id: String, order: Int = 1, load: Double, edited: Bool = false) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: id, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: load, waveRaw: "a")
        i.plannedLoadsBySet = [load, load, load]
        i.plannedRepsBySet = [8, 8, 8]
        i.planEdited = edited
        return i
    }

    private func makeWorld(unit: LoadUnit = .lb) throws -> World {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let ctx = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let profile = UserProfile(minLoadIncrement: 2.5, unit: unit)
        ctx.insert(profile)
        let meso = MesoBlock(name: "Block", startDate: day(-14), status: .active, totalWeeks: 8)
        ctx.insert(meso)
        let a = item("bench_press", load: 102.5)                         // 46.49 kg
        let b = item("barbell_row", order: 2, load: 227.5, edited: true)  // 103.19 kg, hand-edited
        let c = item("leg_extension", order: 3, load: 0)                  // unset
        let planned = Session(date: day(3), status: .planned, weekIndex: 3, dayLabel: "Push", items: [a, b, c])
        planned.meso = meso
        let done = item("overhead_press", load: 95.3)
        done.actualLoads = [95.3, 95.3, 95.3]; done.actualReps = [8, 8, 8]; done.actualRIRs = [2, 2, 2]
        let completed = Session(date: day(-2), status: .completed, weekIndex: 2, dayLabel: "Push", items: [done])
        completed.meso = meso
        let live = item("incline_dumbbell_press", load: 61.1)
        live.actualLoads = [61.1]; live.actualReps = [8]; live.actualRIRs = [2]
        let inProgress = Session(date: day(1), status: .inProgress, weekIndex: 2, dayLabel: "Pull", items: [live])
        inProgress.meso = meso
        [planned, completed, inProgress].forEach(ctx.insert)
        try ctx.save()
        return World(ctx: ctx, profile: profile, meso: meso, planned: [a, b, c], completed: done, inProgress: live)
    }

    private func snapshot(_ w: World) -> [[Double]] {
        (w.planned + [w.completed, w.inProgress]).map { [$0.suggestedLoad] + $0.plannedLoadsBySet + $0.actualLoads }
    }

    private func onStep(_ storedLb: Double, _ step: Double, unit: LoadUnit, _ msg: String = "", line: UInt = #line) {
        let n = unit.fromStoredLb(storedLb) / step
        XCTAssertEqual(n, n.rounded(), accuracy: 1e-6, "\(msg) \(unit.fromStoredLb(storedLb)) \(unit.label)", line: line)
    }

    // MARK: Switching alone writes no load

    func test_switchRoundTrip_leavesStoredLoadsBitIdentical() throws {
        let w = try makeWorld()
        let before = snapshot(w)
        w.profile.loadUnit = .kg
        w.profile.minLoadIncrement = UnitAwareRounding.defaultIncrement(unit: .kg)
        try w.ctx.save()
        XCTAssertEqual(snapshot(w), before, "lb -> kg: stored loads untouched")
        XCTAssertEqual(LoadFormatter(unit: .kg).number(w.planned[0].suggestedLoad), "46.49", "display follows the unit")
        w.profile.loadUnit = .lb
        w.profile.minLoadIncrement = UnitAwareRounding.defaultIncrement(unit: .lb)
        try w.ctx.save()
        XCTAssertEqual(snapshot(w), before, "kg -> lb: still the same stored loads")
        XCTAssertEqual(w.profile.minLoadIncrement, 2.5)
        XCTAssertNil(w.profile.unitRaw)
    }

    func test_planningTheRound_writesNothing_cancelIsFree() throws {
        let w = try makeWorld(unit: .kg)
        let before = snapshot(w)
        let plan = SessionItemEditService.planRoundToUnit(meso: w.meso, unit: .kg, increment: 2.5, profile: w.profile)
        XCTAssertTrue(plan.isApplicable)
        XCTAssertFalse(w.ctx.hasChanges, "a plan is a preview")
        XCTAssertEqual(snapshot(w), before, "cancelling after the preview leaves everything as it was")
    }

    // MARK: The confirmed re-round

    func test_reRoundToKg_landsOnKgSteps_andTouchesNothingElse() throws {
        let w = try makeWorld(unit: .kg)
        let before = snapshot(w)
        let plan = SessionItemEditService.planRoundToUnit(meso: w.meso, unit: .kg, increment: 2.5, profile: w.profile)
        XCTAssertEqual(plan.targets.count, 2, "bench and row move; the unset leg extension and logged items do not")
        XCTAssertEqual(plan.loadCount, 8, "2 items x (suggested + 3 slots)")
        XCTAssertEqual(plan.sessionCount, 1)
        XCTAssertEqual(SessionItemEditService.roundPreviewTitle(plan), "Round 8 planned loads to kg steps — across 1 upcoming session.")
        XCTAssertEqual(SessionItemEditService.roundPreviewDetail(plan), "To the nearest 2.5 kg. Completed and started sessions are not touched.")
        let result = try SessionItemEditService.applyRoundToUnit(plan, profile: w.profile, in: w.ctx)
        XCTAssertEqual(result.sessionsChanged, 2)

        for i in [w.planned[0], w.planned[1]] {
            onStep(i.suggestedLoad, 2.5, unit: .kg, "suggested")
            i.plannedLoadsBySet.forEach { onStep($0, 2.5, unit: .kg, "slot") }
        }
        XCTAssertEqual(kg(w.planned[0].suggestedLoad), 47.5, accuracy: 1e-9, "46.49 kg -> the nearest 2.5 kg step")
        XCTAssertEqual(kg(w.planned[1].suggestedLoad), 102.5, accuracy: 1e-9, "103.19 kg -> 102.5")
        XCTAssertEqual(w.planned[2].suggestedLoad, 0)
        XCTAssertEqual(w.planned[2].plannedLoadsBySet, [0, 0, 0])
        // planEdited unchanged, in both directions.
        XCTAssertFalse(w.planned[0].planEdited)
        XCTAssertTrue(w.planned[1].planEdited)
        // Completed and in-progress sessions: byte-identical.
        let after = snapshot(w)
        XCTAssertEqual(Array(after[3...]), Array(before[3...]))
        XCTAssertEqual(after[2], before[2])
        XCTAssertEqual(w.completed.actualLoads, [95.3, 95.3, 95.3])
        XCTAssertEqual(w.inProgress.actualLoads, [61.1])
    }

    func test_reRoundToLb_fromKgTypedLoads() throws {
        let w = try makeWorld()
        w.planned[0].suggestedLoad = lb(100); w.planned[0].plannedLoadsBySet = [lb(100), lb(100), lb(100)]   // 220.46 lb
        w.planned[1].suggestedLoad = 0; w.planned[1].plannedLoadsBySet = [0, 0, 0]
        let plan = SessionItemEditService.planRoundToUnit(meso: w.meso, unit: .lb, increment: 2.5, profile: w.profile)
        XCTAssertEqual(plan.targets.count, 1)
        try SessionItemEditService.applyRoundToUnit(plan, profile: w.profile, in: w.ctx)
        XCTAssertEqual(w.planned[0].suggestedLoad, 220, "220.46 lb -> the nearest 2.5 lb step")
        XCTAssertEqual(w.planned[0].plannedLoadsBySet, [220, 220, 220])
    }

    func test_reRound_respectsMaxLoad_andSkipsFixedLoad() throws {
        let w = try makeWorld(unit: .kg)
        w.profile.setMaxLoad(lb(45), exerciseId: "bench_press")     // 46.49 kg would round to 45 anyway: cap at 45
        w.profile.setProgressionExempt(true, exerciseId: "barbell_row")
        let plan = SessionItemEditService.planRoundToUnit(meso: w.meso, unit: .kg, increment: 2.5, profile: w.profile)
        XCTAssertEqual(plan.targets.map { $0.item.exerciseId }, ["bench_press"], "the fixed-load row keeps its load")
        try SessionItemEditService.applyRoundToUnit(plan, profile: w.profile, in: w.ctx)
        XCTAssertLessThanOrEqual(w.planned[0].suggestedLoad, lb(45) + 1e-9)
        XCTAssertEqual(w.planned[1].suggestedLoad, 227.5, "fixed-load: untouched")
    }

    func test_reRound_failureRestoresEverything() throws {
        for hooks in [SessionItemEditService.ApplyHooks(forceVerificationFailure: true),
                      SessionItemEditService.ApplyHooks(forceSaveFailure: true)] {
            let w = try makeWorld(unit: .kg)
            let before = snapshot(w)
            let plan = SessionItemEditService.planRoundToUnit(meso: w.meso, unit: .kg, increment: 2.5, profile: w.profile)
            XCTAssertThrowsError(try SessionItemEditService.applyRoundToUnit(plan, profile: w.profile, in: w.ctx, hooks: hooks))
            XCTAssertEqual(snapshot(w), before, "a failed apply restores every load")
            XCTAssertTrue(w.planned[1].planEdited)
        }
    }

    func test_nothingToRound_whenLoadsAlreadyOnSteps() throws {
        let w = try makeWorld(unit: .kg)
        w.planned[0].suggestedLoad = lb(45); w.planned[0].plannedLoadsBySet = [lb(45), lb(45), lb(45)]
        w.planned[1].suggestedLoad = lb(102.5); w.planned[1].plannedLoadsBySet = [lb(102.5), lb(102.5), lb(102.5)]
        let plan = SessionItemEditService.planRoundToUnit(meso: w.meso, unit: .kg, increment: 2.5, profile: w.profile)
        XCTAssertFalse(plan.isApplicable)
        XCTAssertThrowsError(try SessionItemEditService.applyRoundToUnit(plan, profile: w.profile, in: w.ctx))
    }

    // MARK: Increment memory

    func test_incrementIsRememberedPerUnit() throws {
        let w = try makeWorld()
        w.profile.minLoadIncrement = 5                                  // a lb lifter on 5 lb
        w.profile.switchLoadUnit(to: .kg)
        XCTAssertEqual(w.profile.minLoadIncrement, 1.25, "first visit to kg: its default")
        XCTAssertEqual(w.profile.savedIncrementLb, 5)
        w.profile.switchLoadUnit(to: .lb)
        XCTAssertEqual(w.profile.minLoadIncrement, 5, "lb 5 -> kg -> lb restores 5")
        XCTAssertEqual(w.profile.savedIncrementKg, 1.25)
        w.profile.switchLoadUnit(to: .kg)
        w.profile.minLoadIncrement = 2.5                                // the lifter picks 2.5 kg
        w.profile.switchLoadUnit(to: .lb)
        XCTAssertEqual(w.profile.minLoadIncrement, 5)
        w.profile.switchLoadUnit(to: .kg)
        XCTAssertEqual(w.profile.minLoadIncrement, 2.5, "kg restores its own last value")
        let before = w.profile.minLoadIncrement
        w.profile.switchLoadUnit(to: .kg)
        XCTAssertEqual(w.profile.minLoadIncrement, before, "switching to the current unit is a no-op")
    }

    func test_firstSwitchUsesTheUnitDefault_dumbbellsOnlyIsCoarser() throws {
        let w = try makeWorld()
        w.profile.equipmentProfile = .dumbbellsOnly
        w.profile.minLoadIncrement = 5
        w.profile.switchLoadUnit(to: .kg)
        XCTAssertEqual(w.profile.minLoadIncrement, 2.5)
        let fresh = UserProfile()
        fresh.switchLoadUnit(to: .kg)
        XCTAssertEqual(fresh.minLoadIncrement, 1.25)
        XCTAssertNil(UserProfile().savedIncrementKg)
    }

    func test_reOnboardingInAnotherUnit_remembersTheOldIncrement() throws {
        let w = try makeWorld()
        w.profile.minLoadIncrement = 5
        var draft = OnboardingDraft()
        draft.unit = .kg; draft.loadIncrement = 1.25
        ProgramApplicationService.writeUserProfile(from: draft.result(startDate: Date()), context: w.ctx)
        XCTAssertEqual(w.profile.loadUnit, .kg)
        XCTAssertEqual(w.profile.savedIncrementLb, 5)
        w.profile.switchLoadUnit(to: .lb)
        XCTAssertEqual(w.profile.minLoadIncrement, 5)
    }

    // MARK: The round offer persists until answered

    func test_offerIsOpenFromTheSwitchUntilAnswered() throws {
        let w = try makeWorld()
        XCTAssertNil(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx),
                     "a lifter who never switched is never prompted, even with off-step loads")
        w.profile.switchLoadUnit(to: .kg)
        XCTAssertEqual(w.profile.roundOfferPending, true)
        let first = try XCTUnwrap(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
        XCTAssertEqual(first.unit, .kg)
        // Settings closed and reopened without answering: offered again.
        let again = try XCTUnwrap(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
        XCTAssertEqual(again.loadCount, first.loadCount)
        // Keep as is: closed.
        SessionItemEditService.dismissRoundOffer(profile: w.profile, in: w.ctx)
        XCTAssertNil(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
        // The next switch raises it again, per switch.
        w.profile.switchLoadUnit(to: .lb)
        XCTAssertEqual(w.profile.roundOfferPending, true)
        w.profile.switchLoadUnit(to: .kg)
        XCTAssertNotNil(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
    }

    func test_offerClosesAfterRound_andWhenNothingIsOffStep() throws {
        let w = try makeWorld()
        w.profile.switchLoadUnit(to: .kg)
        let plan = try XCTUnwrap(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
        try SessionItemEditService.applyRoundToUnit(plan, profile: w.profile, in: w.ctx)
        SessionItemEditService.dismissRoundOffer(profile: w.profile, in: w.ctx)
        XCTAssertNil(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
        // An open offer with nothing off-step closes itself.
        w.profile.roundOfferPending = true
        XCTAssertNil(SessionItemEditService.pendingRoundOffer(profile: w.profile, in: w.ctx))
        XCTAssertNil(w.profile.roundOfferPending)
    }

    func test_backup_carriesTheMemoryAndTheOpenOffer() throws {
        let w = try makeWorld()
        w.profile.minLoadIncrement = 5
        w.profile.switchLoadUnit(to: .kg)
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: w.ctx)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        let dto = try XCTUnwrap(json["userProfile"] as? [String: Any])
        XCTAssertEqual(dto["savedIncrementLb"] as? Double, 5)
        XCTAssertEqual(dto["roundOfferPending"] as? Bool, true)
        // An old backup (keys absent) restores with no memory and no open offer.
        let decoded = try JSONDecoder().decode(UserProfileBackupDTO.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.savedIncrementLb); XCTAssertNil(decoded.savedIncrementKg); XCTAssertNil(decoded.roundOfferPending)
    }

    // MARK: Analytics volume

    func test_analyticsVolume_convertedAndLabelled() {
        let lb = LoadFormatter(unit: .lb), kg = LoadFormatter(unit: .kg)
        XCTAssertEqual(lb.volumeK(24_000), 24)
        XCTAssertEqual(lb.volumeKText(lb.volumeK(24_000)), "24k lb", "lb gains only the unit label")
        XCTAssertEqual(kg.volumeK(24_000), 11, "24,000 lb·reps = 10,886 kg·reps")
        XCTAssertEqual(kg.volumeKText(kg.volumeK(24_000)), "11k kg")
        XCTAssertEqual(lb.volumeK(499), 0)
    }

    // MARK: Onboarding

    func test_onboardingDraft_carriesTheUnit() throws {
        var draft = OnboardingDraft()
        XCTAssertEqual(draft.result(startDate: Date()).unit, .lb, "a fresh install defaults to lb")
        draft.unit = .kg
        draft.loadIncrement = 1.25
        let result = draft.result(startDate: Date())
        XCTAssertEqual(result.unit, .kg)
        XCTAssertEqual(result.minLoadIncrement, 1.25)
        let decoded = try JSONDecoder().decode(OnboardingResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.unit, .kg)
        // A result encoded before kg support has no unit key: lb.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        json.removeValue(forKey: "unit")
        let old = try JSONDecoder().decode(OnboardingResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.unit, .lb)
    }

    func test_applyingOnboarding_writesTheUnitToTheProfile() throws {
        for unit in LoadUnit.allCases {
            let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
            let ctx = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            var draft = OnboardingDraft()
            draft.unit = unit
            draft.loadIncrement = UnitAwareRounding.defaultIncrement(unit: unit)
            ProgramApplicationService.writeUserProfile(from: draft.result(startDate: Date()), context: ctx)
            let profile = try XCTUnwrap(try ctx.fetch(FetchDescriptor<UserProfile>()).first)
            XCTAssertEqual(profile.loadUnit, unit)
            XCTAssertEqual(profile.unitRaw, unit == .lb ? nil : "kg")
            XCTAssertEqual(profile.minLoadIncrement, unit == .lb ? 2.5 : 1.25)
            // Re-onboarding with the other unit updates the existing profile.
            draft.unit = unit == .lb ? .kg : .lb
            ProgramApplicationService.writeUserProfile(from: draft.result(startDate: Date()), context: ctx)
            XCTAssertEqual(profile.loadUnit, draft.unit)
        }
    }

    func test_incrementChoicesAndDefaults() {
        XCTAssertEqual(UnitAwareRounding.incrementChoices(unit: .lb), [1.25, 2.5, 5])
        XCTAssertEqual(UnitAwareRounding.incrementChoices(unit: .kg), [1.25, 2.5, 5])
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .lb), 2.5)
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .lb, coarse: true), 5)
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .kg), 1.25)
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .kg, coarse: true), 2.5)
        XCTAssertEqual(LoadFormatter(unit: .lb).textInUnit(1.25), "1.25 lb")
        XCTAssertEqual(LoadFormatter(unit: .lb).textInUnit(5), "5 lb")
        XCTAssertEqual(LoadFormatter(unit: .kg).textInUnit(2.5), "2.5 kg")
    }
}
