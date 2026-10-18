import XCTest
import SwiftData
@testable import ElitePerformance

/// Carry-forward writes the source's recommendation — bump, HOLD or REDUCE — into an unedited,
/// already-planned, same-letter target. Before this, only a bump over the stored load was
/// written, so a stale higher seed (hack squat 300 x 12,12,10 -> "hold 300" vs a 317.5 target)
/// survived every hold and reduction. Edited plans, exempt exercises, suppressing override
/// reasons, deload / bodyweight targets, the end of a chain and incomplete evidence still never
/// write.
final class CarryForwardWritesHoldsTests: XCTestCase {

    private let ex = "leg_extension"

    // MARK: - Fixture

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }

    /// A logged source item. `loads` defaults to `load` on every logged set.
    private func source(
        _ id: String? = nil, wave: String? = "b", load: Double = 300, reps: [Int], loads: [Double]? = nil,
        rir: Int = 2, targetSets: Int? = nil, override: LoadOverrideReason? = nil
    ) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: id ?? ex, targetReps: 12, targetSets: targetSets ?? reps.count,
            targetRIR: 2, suggestedLoad: load, waveRaw: wave, repMin: 10, repMax: 12,
            loadOverrideReasonRaw: override?.rawValue
        )
        i.actualReps = reps
        i.actualLoads = loads ?? Array(repeating: load, count: reps.count)
        i.actualRIRs = Array(repeating: rir, count: reps.count)
        i.plannedLoadsBySet = Array(repeating: load, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    /// A planned, unlogged target carrying a seed load.
    private func target(
        _ id: String? = nil, wave: String? = "b", seed: Double = 317.5, sets: Int = 3, edited: Bool = false
    ) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: id ?? ex, targetReps: 12, targetSets: sets, targetRIR: 2,
            suggestedLoad: seed, waveRaw: wave, repMin: 10, repMax: 12
        )
        i.plannedLoadsBySet = Array(repeating: seed, count: sets)
        i.planEdited = edited
        return i
    }

    /// source in `day(-1)`, one target in `day(1)`. Returns the sessions' items for assertions.
    @discardableResult
    /// A context whose profile lists `exerciseId` as fixed-load (nothing is exempt by default).
    private func fixedLoadContext(_ exerciseId: String) throws -> ModelContext {
        let context = try makeContext()
        let profile = UserProfile()
        profile.setProgressionExempt(true, exerciseId: exerciseId)
        context.insert(profile)
        return context
    }

    private func run(
        _ src: SessionItem, _ tgt: SessionItem, context: ModelContext? = nil
    ) throws -> (ctx: ModelContext, srcSession: Session, tgtSession: Session) {
        let context = try context ?? makeContext()
        let srcSession = Session(date: day(-1), status: .completed, weekIndex: 2, dayLabel: "Legs A", items: [src])
        let tgtSession = Session(date: day(20), status: .planned, weekIndex: 5, dayLabel: "Legs A", items: [tgt])
        context.insert(srcSession); context.insert(tgtSession)
        try context.save()
        PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)
        return (context, srcSession, tgtSession)
    }

    // MARK: - Hold / reduce / bump are written to an unedited target

    /// The evidence case: hack squat 300 x 12,12,10 @2 -> hold 300; the Oct 24 target held 317.5.
    func test_holdBelowTheSeed_isWritten() throws {
        let tgt = target()
        try run(source(reps: [12, 12, 10]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
        XCTAssertEqual(tgt.plannedLoadsBySet, [300, 300, 300])
        XCTAssertFalse(tgt.planEdited, "an automatic write never marks the plan edited")
    }

    func test_holdEqualToTheTarget_isANoOp() throws {
        let tgt = target(seed: 300)
        try run(source(reps: [12, 12, 10]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
        XCTAssertEqual(tgt.plannedLoadsBySet, [300, 300, 300])
    }

    func test_holdAboveTheSeed_isWrittenToo() throws {
        let tgt = target(seed: 290)
        try run(source(reps: [12, 12, 10]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001, "the target follows the evidence in both directions")
    }

    func test_reduceOnARepCrash_isWritten() throws {
        let tgt = target()
        try run(source(reps: [6, 6, 6]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 285, accuracy: 0.001, "5% off 300")
        XCTAssertEqual(tgt.plannedLoadsBySet, [285, 285, 285])
    }

    func test_intraSessionDropOff_writesTheMinimumWorkingLoad() throws {
        let tgt = target()
        try run(source(reps: [12, 12, 12], loads: [300, 300, 250]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 250, accuracy: 0.001)
    }

    func test_bump_stillWritten() throws {
        let tgt = target(seed: 300)
        try run(source(reps: [12, 12, 12]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 302.5, accuracy: 0.001)
    }

    func test_waveNilLegacyPath_writesAHold() throws {
        let tgt = target(wave: nil)
        try run(source(wave: nil, reps: [12, 12, 10]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    func test_secondCall_isIdempotent() throws {
        let tgt = target()
        let r = try run(source(reps: [6, 6, 6]), tgt)
        PlanMemoryEngine(context: r.ctx).carryForwardPlans(from: r.srcSession)
        XCTAssertEqual(tgt.suggestedLoad, 285, accuracy: 0.001, "the value derives from the source, not the target")
    }

    // MARK: - Never written

    func test_editedPlan_isNeverWritten_holdBumpOrReduce() throws {
        for (reps, label) in [([12, 12, 10], "hold"), ([12, 12, 12], "bump"), ([6, 6, 6], "reduce")] {
            let tgt = target(edited: true)
            try run(source(reps: reps), tgt)
            XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001, "\(label): an edited plan stays as set")
            XCTAssertEqual(tgt.plannedLoadsBySet, [317.5, 317.5, 317.5], label)
            XCTAssertTrue(tgt.planEdited, label)
        }
    }

    func test_suppressingOverrideReason_writesNothing_atTheTopAndOnAHold() throws {
        for reps in [[12, 12, 12], [12, 12, 10]] {
            let tgt = target()
            try run(source(reps: reps, override: .generalFatigue), tgt)
            XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001, "\(reps)")
        }
    }

    func test_equipmentConstraint_isNotSuppressing() throws {
        let tgt = target()
        try run(source(reps: [12, 12, 10], override: .equipmentConstraint), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    func test_exemptExercise_writesNothing() throws {
        let pushdown = "cable_tricep_rope_pushdown"
        for reps in [[12, 12, 10], [6, 6, 6]] {
            let tgt = target(pushdown, seed: 70)
            try run(source(pushdown, load: 60, reps: reps), tgt, context: try fixedLoadContext(pushdown))
            XCTAssertEqual(tgt.suggestedLoad, 70, accuracy: 0.001, "\(reps)")
        }
    }

    func test_deloadTarget_writesNothing() throws {
        let tgt = target(wave: "deload", seed: 180)
        try run(source(wave: nil, reps: [12, 12, 10]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 180, accuracy: 0.001)
    }

    func test_bodyweightTarget_writesNothing() throws {
        let tgt = target("pull_up", wave: nil, seed: 5)
        try run(source("pull_up", wave: nil, load: 10, reps: [8, 8, 8]), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 5, accuracy: 0.001)
    }

    func test_endOfChain_writesNothingAnywhere() throws {
        // The only later session is a different letter: no same-letter target exists.
        let ctx = try makeContext()
        let src = source(reps: [12, 12, 10])
        let other = target(wave: "c", seed: 317.5)
        let srcSession = Session(date: day(-1), status: .completed, weekIndex: 2, dayLabel: "Legs A", items: [src])
        let otherSession = Session(date: day(7), status: .planned, weekIndex: 3, dayLabel: "Legs A", items: [other])
        ctx.insert(srcSession); ctx.insert(otherSession)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: srcSession)
        XCTAssertEqual(other.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_progressionDisabled_writesNothing() throws {
        let ctx = try makeContext()
        ctx.insert(User(units: .lb, progressionEnabled: false))
        let tgt = target()
        try run(source(reps: [12, 12, 10]), tgt, context: ctx)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_painFlag_writesNothing() throws {
        let tgt = target()
        let src = source(reps: [12, 12, 10])
        src.setFeedbackBySet = [SetFeedback.pain.rawValue, "", ""]
        try run(src, tgt)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001, "no recommendation load on a pain flag")
    }

    // MARK: - Cross-letter isolation

    func test_lowerHold_writesOnlyTheSameLetterSession() throws {
        let ctx = try makeContext()
        let w2 = target(wave: "b", seed: 317.5)   // wrong letter
        let w3 = target(wave: "c", seed: 317.5)   // wrong letter
        let w4 = target(wave: "a", seed: 317.5)
        let srcWeek1 = source(wave: "a", reps: [12, 12, 10])
        let s1 = Session(date: day(-1), status: .completed, weekIndex: 1, dayLabel: "Legs A", items: [srcWeek1])
        let s2 = Session(date: day(6), status: .planned, weekIndex: 2, dayLabel: "Legs A", items: [w2])
        let s3 = Session(date: day(13), status: .planned, weekIndex: 3, dayLabel: "Legs A", items: [w3])
        let s4 = Session(date: day(20), status: .planned, weekIndex: 4, dayLabel: "Legs A", items: [w4])
        for s in [s1, s2, s3, s4] { ctx.insert(s) }
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: s1)
        XCTAssertEqual(w2.suggestedLoad, 317.5, accuracy: 0.001)
        XCTAssertEqual(w3.suggestedLoad, 317.5, accuracy: 0.001)
        XCTAssertEqual(w4.suggestedLoad, 300, accuracy: 0.001, "only the same-letter anchor takes the lower hold")
    }

    // MARK: - Incomplete evidence

    func test_oneOfThreeSetsLogged_writesNothing() throws {
        let tgt = target()
        try run(source(reps: [12], targetSets: 3), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_twoOfThreeSetsLogged_writesNothing() throws {
        let tgt = target()
        try run(source(reps: [12, 12], targetSets: 3), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_fourSetItem_withThreePrimarySetsLogged_stillWrites() throws {
        let tgt = target(sets: 4)
        try run(source(reps: [12, 12, 10], targetSets: 4), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    func test_threeOfThreeSets_writes() throws {
        let tgt = target()
        try run(source(reps: [12, 12, 10], targetSets: 3), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    func test_singleSetItem_oneLoggedSet_writes() throws {
        let tgt = target(sets: 1)
        try run(source(reps: [10], targetSets: 1), tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    // MARK: - Ramped sets

    /// A light warm-up (< 50% of the session max) is not a working set: 100, then 3 x 300.
    func test_warmupIsNotCounted_threeWorkingSetsAfterIt_writes() throws {
        let tgt = target()
        let src = source(reps: [10, 12, 12, 10], loads: [100, 300, 300, 300], targetSets: 3)
        try run(src, tgt)
        XCTAssertEqual(tgt.suggestedLoad, 300, accuracy: 0.001)
    }

    func test_warmupPlusOneWorkingSet_isIncompleteEvidence() throws {
        let tgt = target()
        let src = source(reps: [10, 12], loads: [100, 300], targetSets: 3)
        try run(src, tgt)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001, "1 working set of 3 is not enough")
    }

    /// A true ramp (250, 275, 300 — all >= 50% of the max) is three working sets; the
    /// recommendation steps off the last, heaviest one.
    func test_rampedWorkingSets_stepOffTheLastSet() throws {
        let tgt = target(seed: 280)
        let src = source(reps: [12, 12, 12], loads: [250, 275, 300], targetSets: 3)
        try run(src, tgt)
        XCTAssertEqual(tgt.suggestedLoad, 302.5, accuracy: 0.001)
    }

    // MARK: - The helper the guard and the engine share

    func test_primaryEvidenceHelper_matchesTheRule() {
        XCTAssertEqual(CoachingEngine.requiredPrimarySets(for: source(reps: [1], targetSets: 1)), 1)
        XCTAssertEqual(CoachingEngine.requiredPrimarySets(for: source(reps: [1], targetSets: 3)), 3)
        XCTAssertEqual(CoachingEngine.requiredPrimarySets(for: source(reps: [1], targetSets: 5)), 3)
        XCTAssertFalse(CoachingEngine.hasSufficientPrimaryEvidence(source(reps: [12, 12], targetSets: 3)))
        XCTAssertTrue(CoachingEngine.hasSufficientPrimaryEvidence(source(reps: [12, 12, 12], targetSets: 5)))
    }

    // MARK: - Message == stored value

    /// Mirrors SessionView's resolution of the target state.
    private func target(for srcSession: Session, _ src: SessionItem, in ctx: ModelContext) throws -> CoachingEngine.CarryForwardTarget {
        let all = try ctx.fetch(FetchDescriptor<Session>())
        guard let t = PlanMemoryEngine.nextTargetItem(for: src, after: srcSession, in: all) else { return .endOfChain }
        let hasPlan = t.suggestedLoad != 0 || t.plannedLoadsBySet.contains { $0 != 0 }
        return t.planEdited && hasPlan ? .existsEdited : .exists
    }

    private func message(_ src: SessionItem, _ state: CoachingEngine.CarryForwardTarget,
                         profile: UserProfile? = nil) throws -> String {
        try XCTUnwrap(CoachingEngine.recommend(
            for: src, minLoadIncrement: 2.5, carryForwardTarget: state,
            isProgressionExempt: UserProfile.isProgressionExempt(exerciseId: src.exerciseId, profile: profile)
        )).message
    }

    /// The load a "Next Week B: <n>" promise names.
    private func promisedLoad(_ message: String) -> Double? {
        guard let r = message.range(of: #"Next Week B: ([0-9]+(\.[0-9]+)?)"#, options: .regularExpression) else { return nil }
        return Double(message[r].dropFirst("Next Week B: ".count))
    }

    func test_message_hold_namesTheStoredLoad() throws {
        let tgt = target()
        let r = try run(source(reps: [12, 12, 10]), tgt)
        let src = r.srcSession.items[0]
        let msg = try message(src, try target(for: r.srcSession, src, in: r.ctx))
        XCTAssertTrue(msg.hasSuffix("Next Week B: 300, same load, reps-first."), msg)
        XCTAssertEqual(try XCTUnwrap(promisedLoad(msg)), tgt.suggestedLoad, accuracy: 0.001)
    }

    func test_message_bump_namesTheStoredLoad() throws {
        let tgt = target(seed: 300)
        let r = try run(source(reps: [12, 12, 12]), tgt)
        let src = r.srcSession.items[0]
        let msg = try message(src, try target(for: r.srcSession, src, in: r.ctx))
        XCTAssertEqual(try XCTUnwrap(promisedLoad(msg)), tgt.suggestedLoad, accuracy: 0.001, msg)
    }

    func test_message_reduce_namesTheStoredLoad() throws {
        let tgt = target()
        let r = try run(source(reps: [6, 6, 6]), tgt)
        let src = r.srcSession.items[0]
        let msg = try message(src, try target(for: r.srcSession, src, in: r.ctx))
        XCTAssertTrue(msg.contains("Next Week B: 285."), msg)
        XCTAssertEqual(try XCTUnwrap(promisedLoad(msg)), tgt.suggestedLoad, accuracy: 0.001)
        XCTAssertFalse(msg.contains("next session"), msg)
    }

    func test_message_editedTarget_makesNoNumericPromise_andTheStoredLoadIsUntouched() throws {
        for reps in [[12, 12, 10], [12, 12, 12], [6, 6, 6]] {
            let tgt = target(edited: true)
            let r = try run(source(reps: reps), tgt)
            let src = r.srcSession.items[0]
            let state = try target(for: r.srcSession, src, in: r.ctx)
            guard case .existsEdited = state else { return XCTFail("expected .existsEdited, got \(state)") }
            let msg = try message(src, state)
            XCTAssertTrue(msg.contains("Your edited plan for Next Week B stays as set."), "\(reps): \(msg)")
            XCTAssertNil(promisedLoad(msg), "\(reps): \(msg)")
            XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
        }
    }

    func test_message_endOfChain_makesNoPromise_andNothingIsWritten() throws {
        let ctx = try makeContext()
        let src = source(reps: [12, 12, 10])
        let other = target(wave: "c", seed: 317.5)
        let srcSession = Session(date: day(-1), status: .completed, weekIndex: 2, dayLabel: "Legs A", items: [src])
        let otherSession = Session(date: day(7), status: .planned, weekIndex: 3, dayLabel: "Legs A", items: [other])
        ctx.insert(srcSession); ctx.insert(otherSession)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: srcSession)
        let state = try target(for: srcSession, src, in: ctx)
        guard case .endOfChain = state else { return XCTFail("expected .endOfChain, got \(state)") }
        for reps in [[12, 12, 10], [12, 12, 12], [6, 6, 6]] {
            let msg = try message(source(reps: reps), .endOfChain)
            XCTAssertFalse(msg.contains("Next Week"), "\(reps): \(msg)")
            XCTAssertFalse(msg.contains("same load, reps-first"), "\(reps): \(msg)")
        }
        XCTAssertEqual(other.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_message_exempt_neverClaimsALoweringOrALanding() throws {
        let pushdown = "cable_tricep_rope_pushdown"
        for reps in [[12, 12, 10], [6, 6, 6]] {
            let tgt = target(pushdown, seed: 70)
            let r = try run(source(pushdown, load: 60, reps: reps), tgt, context: try fixedLoadContext(pushdown))
            let src = r.srcSession.items[0]
            let profile = try r.ctx.fetch(FetchDescriptor<UserProfile>()).first
            let msg = try message(src, try target(for: r.srcSession, src, in: r.ctx), profile: profile)
            let lower = msg.lowercased()
            for banned in ["next week", "next session", "lowered", "same load", "stays as set"] {
                XCTAssertFalse(lower.contains(banned), "\(reps): \(msg)")
            }
            XCTAssertEqual(tgt.suggestedLoad, 70, accuracy: 0.001, "and nothing was written")
        }
    }

    /// The incomplete-evidence guard blocks the write, so the message must not promise one.
    func test_message_incompleteEvidence_makesNoLandingClaim() throws {
        let tgt = target()
        let r = try run(source(reps: [12, 12], loads: [300, 250], targetSets: 3), tgt)
        let src = r.srcSession.items[0]
        let msg = try message(src, try target(for: r.srcSession, src, in: r.ctx))
        XCTAssertFalse(msg.contains("starts at"), msg)
        XCTAssertFalse(msg.contains("Next Week"), msg)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_message_flaggedSourceHold_makesNoLandingClaim() throws {
        let tgt = target()
        let r = try run(source(reps: [12, 12, 10], override: .generalFatigue), tgt)
        let src = r.srcSession.items[0]
        let msg = try message(src, try target(for: r.srcSession, src, in: r.ctx))
        XCTAssertFalse(msg.contains("Next Week"), msg)
        XCTAssertEqual(tgt.suggestedLoad, 317.5, accuracy: 0.001)
    }

    func test_message_holdSuffix_waveless_readsNextSession() throws {
        let msg = try message(source(wave: nil, reps: [12, 12, 10]), .exists)
        XCTAssertTrue(msg.hasSuffix("Next session: 300, same load, reps-first."), msg)
    }

    func test_message_unresolved_holdMakesNoClaim() throws {
        let msg = try message(source(reps: [12, 12, 10]), .unresolved)
        XCTAssertFalse(msg.contains("same load, reps-first"), msg)
    }
}
