import XCTest
import SwiftData
@testable import ElitePerformance

/// An EARNED bump steps off the load that was just lifted — never off a historical
/// e1RM.
///
/// `CoachingEngine.qualifyingBump` used to take `max(baseLoad + increment,
/// e1rmFloorLoad)`, and the floor is derived from all-time RIR-weighted e1RM
/// history (current-meso peak or cross-meso decay baseline, `LoadProjectionService`
/// :245-255). So a lifter who once handled ~225 and is now working at 180 got
/// "Next Week A: 220.0" off a clean 180 session — a 40 kg jump for hitting the top
/// of a 10–12 range. Conservative by default: the floor may raise a bump UP TO
/// baseLoad + one increment, never past it.
///
/// The second half covers the flagged-load rule: when the source session's load was
/// temporarily or deliberately reduced, a top-of-range performance at that reduced
/// load earns nothing at all and writes nothing.
final class E1RMFloorCapTests: XCTestCase {

    // MARK: - Helpers

    /// A complete, clean, top-of-range session — the RULE 5b "increase earned" path.
    private func topOfRangeItem(
        exerciseId: String,
        load: Double,
        reps: [Int],
        targetRIR: Int,
        repMin: Int,
        repMax: Int,
        overrideReason: LoadOverrideReason? = nil
    ) -> SessionItem {
        let item = SessionItem(
            order: 1,
            exerciseId: exerciseId,
            targetReps: repMax,
            targetSets: reps.count,
            targetRIR: targetRIR,
            suggestedLoad: load,
            waveRaw: "a",
            repMin: repMin,
            repMax: repMax,
            loadOverrideReasonRaw: overrideReason?.rawValue
        )
        item.actualReps  = reps
        item.actualLoads = Array(repeating: load, count: reps.count)
        item.actualRIRs  = Array(repeating: targetRIR, count: reps.count)
        item.plannedRepsBySet = Array(repeating: repMax, count: reps.count)
        item.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return item
    }

    private func recommend(
        _ item: SessionItem,
        increment: Double,
        e1rmFloorLoad: Double?
    ) throws -> CoachingRecommendation {
        try XCTUnwrap(
            CoachingEngine.recommend(
                for: item,
                minLoadIncrement: increment,
                e1rmFloorLoad: e1rmFloorLoad,
                carryForwardTarget: .exists
            ),
            "expected a recommendation for a complete, clean, top-of-range session"
        )
    }

    // MARK: - The reported bugs

    /// leg_extension 180 × 12,12 @2 (top of 10–12) with a ~225 e1RM floor.
    /// Shipped: "Next Week A: 220.0". Expected: 185.
    func test_legExtension_floorFarAboveLastLoad_capsAtOneIncrement() throws {
        let item = topOfRangeItem(
            exerciseId: "leg_extension",
            load: 180, reps: [12, 12], targetRIR: 2, repMin: 10, repMax: 12
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 225)

        XCTAssertEqual(
            try XCTUnwrap(rec.nextSuggestedLoad), 185.0, accuracy: 0.001,
            "a 180 session may earn one increment, not a jump to the 225 history"
        )
        XCTAssertTrue(
            rec.message.contains("Next Week A: 185.0"),
            "the message reads from the same number and must state the capped load: \(rec.message)"
        )
        XCTAssertFalse(
            rec.message.contains("220"),
            "the uncapped floor value must not survive anywhere in the message: \(rec.message)"
        )
    }

    /// cable_tricep_rope_pushdown 50 × 12 ×3 @3 with a ~100 e1RM floor.
    /// Shipped: 95. Expected: 55.
    func test_ropePushdown_floorNearDoubleLastLoad_capsAtOneIncrement() throws {
        let item = topOfRangeItem(
            exerciseId: "cable_tricep_rope_pushdown",
            load: 50, reps: [12, 12, 12], targetRIR: 3, repMin: 10, repMax: 12
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 100)

        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 55.0, accuracy: 0.001)
        XCTAssertTrue(rec.message.contains("Next Week A: 55.0"), rec.message)
        XCTAssertFalse(rec.message.contains("95"), rec.message)
    }

    // MARK: - The cap must not break the no-floor and low-floor cases

    /// No history at all → baseLoad + one increment, exactly as before.
    func test_noFloor_bumpIsBaseLoadPlusOneIncrement() throws {
        let item = topOfRangeItem(
            exerciseId: "leg_extension",
            load: 180, reps: [12, 12], targetRIR: 2, repMin: 10, repMax: 12
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: nil)

        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 185.0, accuracy: 0.001)
    }

    /// A floor at or BELOW the last load must still never collapse the bump — the
    /// Farmer-Carry no-move bug the floor was introduced to fix stays fixed.
    func test_floorBelowLastLoad_stillBumpsOneIncrement() throws {
        let item = topOfRangeItem(
            exerciseId: "farmer_carry",
            load: 100, reps: [12, 12, 12], targetRIR: 2, repMin: 10, repMax: 12
        )
        let rec = try recommend(item, increment: 2.5, e1rmFloorLoad: 80)

        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 102.5, accuracy: 0.001)
    }

    /// RULE 5a (over-performed, every set ≥ repMax + 2) takes the same cap.
    func test_overPerformedPath_alsoCapped() throws {
        let item = topOfRangeItem(
            exerciseId: "leg_extension",
            load: 180, reps: [14, 14], targetRIR: 2, repMin: 10, repMax: 12
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 225)

        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 185.0, accuracy: 0.001)
    }

    // MARK: - Flagged load: no bump, no write

    /// leg_extension 180 × 12,12 @2 flagged generalFatigue. The 180 was already a
    /// reduction, so clearing the range there earns nothing: nil load (nothing is
    /// written, so a target plan of 217.5 keeps 217.5) and hold-flavoured copy.
    func test_generalFatigueOverride_earnsNothingAndWritesNothing() throws {
        let item = topOfRangeItem(
            exerciseId: "leg_extension",
            load: 180, reps: [12, 12], targetRIR: 2, repMin: 10, repMax: 12,
            overrideReason: .generalFatigue
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 225)

        XCTAssertNil(
            rec.nextSuggestedLoad,
            "a nil load is what leaves an already-planned 217.5 untouched at both write sites"
        )
        XCTAssertFalse(rec.message.contains("increase earned"), rec.message)
        XCTAssertTrue(
            rec.message.contains("general fatigue"),
            "the message must say the plan holds because today was flagged: \(rec.message)"
        )
        XCTAssertTrue(rec.message.contains("plan holds"), rec.message)
        for number in ["185", "217.5", "220", "225"] {
            XCTAssertFalse(
                rec.message.contains(number),
                "no number may appear above (or beside) the existing plan: found '\(number)' in \(rec.message)"
            )
        }
    }

    /// The same suppression for the other two temporary/deliberate reductions.
    func test_jointTendernessAndDeliberateDeload_alsoSuppressTheBump() throws {
        for reason in [LoadOverrideReason.jointTenderness, .deliberateDeload] {
            let item = topOfRangeItem(
                exerciseId: "leg_extension",
                load: 180, reps: [12, 12], targetRIR: 2, repMin: 10, repMax: 12,
                overrideReason: reason
            )
            let rec = try recommend(item, increment: 5, e1rmFloorLoad: 225)
            XCTAssertNil(rec.nextSuggestedLoad, "\(reason) is a reduced load: \(rec.message)")
            XCTAssertFalse(rec.message.contains("increase earned"), "\(reason): \(rec.message)")
        }
    }

    /// equipmentConstraint is NOT a statement about the lifter — the rack rung
    /// dictated the number. It still earns a (capped) bump.
    func test_equipmentConstraintOverride_stillEarnsTheCappedBump() throws {
        let item = topOfRangeItem(
            exerciseId: "cable_tricep_rope_pushdown",
            load: 60, reps: [12, 12, 12], targetRIR: 3, repMin: 10, repMax: 12,
            overrideReason: .equipmentConstraint
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 100)

        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 65.0, accuracy: 0.001)
    }

    /// The addendum's second case: pushdown 60 × 12 ×3 @3, no override, floor ~100 → 65.
    func test_ropePushdown_noOverride_floorNear100_bumpsTo65() throws {
        let item = topOfRangeItem(
            exerciseId: "cable_tricep_rope_pushdown",
            load: 60, reps: [12, 12, 12], targetRIR: 3, repMin: 10, repMax: 12
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 100)

        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 65.0, accuracy: 0.001)
        XCTAssertTrue(rec.message.contains("Next Week A: 65.0"), rec.message)
    }

    /// A flagged source that UNDER-performs is untouched by RULE 4b — the normal
    /// hold/reduce paths still run ahead of it.
    func test_flaggedSourceUnderPerforming_stillHoldsNormally() throws {
        let item = topOfRangeItem(
            exerciseId: "leg_extension",
            load: 180, reps: [8, 8], targetRIR: 2, repMin: 10, repMax: 12,
            overrideReason: .generalFatigue
        )
        let rec = try recommend(item, increment: 5, e1rmFloorLoad: 225)

        XCTAssertNotNil(
            rec.nextSuggestedLoad,
            "RULE 4 runs before 4b — a missed session still gets its hold/reduce call"
        )
    }

    // MARK: - Enum classification is pinned

    func test_overrideReasonClassification() {
        XCTAssertTrue(LoadOverrideReason.jointTenderness.suppressesEarnedProgression)
        XCTAssertTrue(LoadOverrideReason.generalFatigue.suppressesEarnedProgression)
        XCTAssertTrue(LoadOverrideReason.deliberateDeload.suppressesEarnedProgression)
        XCTAssertFalse(LoadOverrideReason.equipmentConstraint.suppressesEarnedProgression)
        XCTAssertEqual(
            LoadOverrideReason.allCases.count, 4,
            "a new case needs a temporary-vs-not classification here"
        )
    }

    // MARK: - PlanMemoryEngine write sites
    //
    // Two distinct paths, and the cap has to hold on both:
    //  - EMPTY target  → the seed path in carryForwardPlans (projection write).
    //  - NON-EMPTY target → propagateEarnedBumpToMaterializedItem (the `continue`
    //    branch at the top of the loop). A target that already carries a plan can
    //    never reach the seed path.

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private var cal: Calendar { Calendar.current }

    private func engineItem(
        reps: [Int], loads: [Double], rirs: [Int], suggestedLoad: Double,
        feedback: [String]? = nil, overrideReason: LoadOverrideReason? = nil,
        plannedLoads: [Double]? = nil
    ) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: "leg_extension",
            targetReps: 12, targetSets: reps.count, targetRIR: 2,
            suggestedLoad: suggestedLoad, waveRaw: nil, repMin: 10, repMax: 12,
            loadOverrideReasonRaw: overrideReason?.rawValue
        )
        i.actualReps = reps
        i.actualLoads = loads
        i.actualRIRs = rirs
        i.plannedLoadsBySet = plannedLoads ?? Array(repeating: suggestedLoad, count: reps.count)
        i.setFeedbackBySet = feedback ?? Array(repeating: "", count: reps.count)
        return i
    }

    /// SEED PATH. An ORDINARY, unflagged session whose `recommend()` returns no
    /// load (pain was flagged) leaves the projection as the only writer — and
    /// project() hands back the raw all-time e1RM floor as its suggestedLoad. Before
    /// the cap that seeded a ~250-derived load onto a target off a 180 session.
    func test_seedPath_ordinarySession_floorCannotSeedAboveLastLoadPlusIncrement() throws {
        let context = try makeContext()
        let d = { (n: Int) in self.cal.date(byAdding: .day, value: n, to: Date())! }

        // Heavy history — drives e1rmFloorLoad far above anything recent.
        let hist = engineItem(reps: [12, 12], loads: [250, 250], rirs: [2, 2], suggestedLoad: 250)
        let histSession = Session(date: d(-14), status: .completed, weekIndex: 1, items: [hist])

        // Recent ordinary session at 180, NO loadOverrideReason. Pain flagged, so
        // CoachingEngine returns a recommendation carrying a nil load.
        let src = engineItem(reps: [12, 12], loads: [180, 180], rirs: [2, 2], suggestedLoad: 180,
                             feedback: [SetFeedback.pain.rawValue, ""])
        let srcSession = Session(date: d(-1), status: .completed, weekIndex: 2, items: [src])

        // Empty target → the seed path.
        let tgt = engineItem(reps: [0, 0], loads: [0, 0], rirs: [0, 0], suggestedLoad: 0,
                             plannedLoads: [0, 0])
        let tgtSession = Session(date: d(1), status: .planned, weekIndex: 3, items: [tgt])

        context.insert(histSession); context.insert(srcSession); context.insert(tgtSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)

        XCTAssertLessThanOrEqual(
            tgt.suggestedLoad, 185.0,
            "the seed must not exceed the last working load (180) + one increment (5); "
            + "got \(tgt.suggestedLoad), which means the uncapped all-time floor landed"
        )
        XCTAssertGreaterThan(tgt.suggestedLoad, 0, "the empty target must still be seeded")
        for load in tgt.plannedLoadsBySet {
            XCTAssertLessThanOrEqual(load, 185.0, "plannedLoadsBySet must carry the capped value too")
        }
    }

    /// MATERIALIZED PATH — the addendum's case. Source flagged generalFatigue, the
    /// target already carries a 217.5 plan: nothing is written, 217.5 stands.
    func test_materializedPath_flaggedSource_leavesExistingPlanExactlyAsItStands() throws {
        let context = try makeContext()
        let d = { (n: Int) in self.cal.date(byAdding: .day, value: n, to: Date())! }

        let hist = engineItem(reps: [12, 12], loads: [225, 225], rirs: [2, 2], suggestedLoad: 225)
        let histSession = Session(date: d(-14), status: .completed, weekIndex: 1, items: [hist])

        // 180 × 12,12 @2 — a qualifying performance, but the load was flagged.
        let src = engineItem(reps: [12, 12], loads: [180, 180], rirs: [2, 2], suggestedLoad: 180,
                             overrideReason: .generalFatigue)
        let srcSession = Session(date: d(-1), status: .completed, weekIndex: 2, items: [src])

        // Target already planned at 217.5 → the materialized write-back path.
        let tgt = engineItem(reps: [0, 0], loads: [0, 0], rirs: [0, 0], suggestedLoad: 217.5,
                             plannedLoads: [217.5, 217.5])
        let tgtSession = Session(date: d(1), status: .planned, weekIndex: 3, items: [tgt])

        context.insert(histSession); context.insert(srcSession); context.insert(tgtSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)

        XCTAssertEqual(tgt.suggestedLoad, 217.5, accuracy: 0.001,
                       "a flagged source must not write anything onto an existing plan")
        XCTAssertEqual(tgt.plannedLoadsBySet, [217.5, 217.5])
    }

    /// MATERIALIZED PATH, unflagged. The write-back still fires for a genuine
    /// earned bump — and lands the CAPPED value, not the 225-derived floor.
    func test_materializedPath_unflaggedSource_writesBackTheCappedBumpOnly() throws {
        let context = try makeContext()
        let d = { (n: Int) in self.cal.date(byAdding: .day, value: n, to: Date())! }

        let hist = engineItem(reps: [12, 12], loads: [250, 250], rirs: [2, 2], suggestedLoad: 250)
        let histSession = Session(date: d(-14), status: .completed, weekIndex: 1, items: [hist])

        let src = engineItem(reps: [12, 12], loads: [180, 180], rirs: [2, 2], suggestedLoad: 180)
        let srcSession = Session(date: d(-1), status: .completed, weekIndex: 2, items: [src])

        // Existing plan BELOW the earned bump, so a write-back is allowed to fire.
        let tgt = engineItem(reps: [0, 0], loads: [0, 0], rirs: [0, 0], suggestedLoad: 180,
                             plannedLoads: [180, 180])
        let tgtSession = Session(date: d(1), status: .planned, weekIndex: 3, items: [tgt])

        context.insert(histSession); context.insert(srcSession); context.insert(tgtSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)

        XCTAssertEqual(tgt.suggestedLoad, 182.5, accuracy: 0.001,
                       "one increment off 180 at the default 2.5 increment — never the 250 floor")
    }

}

// MARK: - Fixed-load exercises (per-exercise exemption from auto-progression)

/// A fixed-load exercise (e.g. the rehab-track cable_tricep_rope_pushdown) never gets an
/// AUTOMATIC load increase from any path; only the lifter moves it. Upward paths only —
/// pain/fatigue/under-target behavior and all non-exempt behavior are unchanged.
final class FixedLoadExemptTests: XCTestCase {

    private let pushdown = "cable_tricep_rope_pushdown"
    private let fixedText = "Fixed-load exercise: load doesn't auto-progress. Change it yourself when you're ready."

    private func item(
        _ exerciseId: String, load: Double, reps: [Int], rir: Int = 3,
        feedback: [String]? = nil, repMin: Int = 10, repMax: Int = 12
    ) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: exerciseId, targetReps: repMax, targetSets: reps.count,
            targetRIR: rir, suggestedLoad: load, waveRaw: "a", repMin: repMin, repMax: repMax
        )
        i.actualReps = reps
        i.actualLoads = Array(repeating: load, count: reps.count)
        i.actualRIRs = Array(repeating: rir, count: reps.count)
        i.plannedRepsBySet = Array(repeating: repMax, count: reps.count)
        i.setFeedbackBySet = feedback ?? Array(repeating: "", count: reps.count)
        return i
    }

    // MARK: Engine

    func test_exempt_allSetsAtTop_noIncrease_noNumber_fixedText() throws {
        for reps in [[12, 12, 12], [14, 14, 14]] {   // top-of-range AND over-performed
            let i = item(pushdown, load: 50, reps: reps)
            let rec = try XCTUnwrap(CoachingEngine.recommend(
                for: i, minLoadIncrement: 5, e1rmFloorLoad: 100,
                carryForwardTarget: .exists, isProgressionExempt: true))
            XCTAssertNil(rec.nextSuggestedLoad, "no load may be promised for a fixed-load exercise")
            XCTAssertEqual(rec.message, fixedText)
            XCTAssertFalse(rec.message.contains("increase earned"))
            XCTAssertFalse(rec.message.contains(where: \.isNumber), "no number in the fixed-load text")
        }
    }

    func test_exempt_60x12x3_atRIR3_noBumpSuggestion() throws {
        let i = item(pushdown, load: 60, reps: [12, 12, 12])
        let rec = try XCTUnwrap(CoachingEngine.recommend(
            for: i, minLoadIncrement: 2.5, carryForwardTarget: .exists, isProgressionExempt: true))
        XCTAssertNil(rec.nextSuggestedLoad)
    }

    func test_nonExempt_sameSession_unchanged_stillEarnsIncrease() throws {
        let i = item(pushdown, load: 50, reps: [12, 12, 12])
        let byDefault = try XCTUnwrap(CoachingEngine.recommend(
            for: i, minLoadIncrement: 5, carryForwardTarget: .exists))
        let explicitFalse = try XCTUnwrap(CoachingEngine.recommend(
            for: i, minLoadIncrement: 5, carryForwardTarget: .exists, isProgressionExempt: false))
        XCTAssertEqual(byDefault.message, explicitFalse.message)
        XCTAssertEqual(byDefault.nextSuggestedLoad, explicitFalse.nextSuggestedLoad)
        XCTAssertEqual(try XCTUnwrap(byDefault.nextSuggestedLoad), 55.0, accuracy: 0.001)
        XCTAssertTrue(byDefault.message.contains("increase earned"))
    }

    func test_exempt_painUnderTargetFatigue_behaviorIdenticalToNonExempt() throws {
        let scenarios: [(String, SessionItem)] = [
            ("pain", item(pushdown, load: 50, reps: [12, 12, 12],
                          feedback: [SetFeedback.pain.rawValue, "", ""])),
            ("soreness", item(pushdown, load: 50, reps: [12, 12, 12],
                              feedback: [SetFeedback.soreness.rawValue, "", ""])),
            ("under-target hold", item(pushdown, load: 50, reps: [8, 8, 8])),
            ("under-target reduce", item(pushdown, load: 50, reps: [6, 6, 6])),
            ("in range, not top", item(pushdown, load: 50, reps: [11, 11, 11])),
            ("off-target RIR", {
                let i = item(pushdown, load: 50, reps: [12, 12, 12])   // target RIR 3
                i.actualRIRs = [0, 0, 0]                               // lifted at RIR 0
                return i
            }()),
        ]
        for (name, i) in scenarios {
            let a = CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists)
            let b = CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                             isProgressionExempt: true)
            // Behavior (the load) is always unchanged. The wording is unchanged too, except on
            // the paths whose exempt text drops progression language on purpose.
            let rewordedForExempt: Set<String> = ["soreness", "in range, not top", "off-target RIR", "under-target hold", "under-target reduce"]  // both [8,8,8] and [6,6,6] land on the reduce path
            if !rewordedForExempt.contains(name) {
                XCTAssertEqual(a?.message, b?.message, "\(name): message must be unchanged")
            }
            XCTAssertEqual(a?.nextSuggestedLoad, b?.nextSuggestedLoad, "\(name): load must be unchanged")
        }
    }

    func test_pullUp_bodyweight_allSetsAtTop_proposesNoAddedLoad() {
        // Recon (d): BW work logs load 0 and plans suggestedLoad 0 → the engine's
        // no-baseline / no-working-set guards return nil. No added-load proposal, so
        // pull_up is NOT a default-exempt candidate.
        let i = item("pull_up", load: 0, reps: [10, 10, 10], rir: 2, repMin: 8, repMax: 10)
        XCTAssertNil(CoachingEngine.recommend(for: i, minLoadIncrement: 2.5, carryForwardTarget: .exists))
    }

    // MARK: Membership / profile

    func test_freshProfile_hasNoExemptExercises_andAliasAndCaseResolve() {
        let p = UserProfile()
        XCTAssertNil(p.exemptExerciseIdsStored)
        XCTAssertEqual(p.exemptExerciseIds, [], "nothing is fixed-load by default")
        XCTAssertFalse(p.isProgressionExempt(exerciseId: pushdown))
        p.setProgressionExempt(true, exerciseId: pushdown)
        XCTAssertEqual(p.exemptExerciseIdsStored, [pushdown])
        XCTAssertTrue(p.isProgressionExempt(exerciseId: pushdown))
        XCTAssertTrue(p.isProgressionExempt(exerciseId: "CABLE_TRICEP_ROPE_PUSHDOWN"))
        XCTAssertFalse(p.isProgressionExempt(exerciseId: "leg_extension"))
        XCTAssertFalse(p.isProgressionExempt(exerciseId: "pull_up"))

        // Legacy alias id resolves to its canonical exercise.
        p.setProgressionExempt(true, exerciseId: "arnold_press")
        XCTAssertTrue(p.isProgressionExempt(exerciseId: "31c44a80-6c56-4e9d-aca1-ee754cd157b6"))
        p.setProgressionExempt(false, exerciseId: "31c44a80-6c56-4e9d-aca1-ee754cd157b6")
        XCTAssertFalse(p.isProgressionExempt(exerciseId: "arnold_press"))

        // Turning everything off leaves an explicit [].
        p.setProgressionExempt(false, exerciseId: pushdown)
        XCTAssertEqual(p.exemptExerciseIdsStored, [])
        XCTAssertFalse(p.isProgressionExempt(exerciseId: pushdown))

        // No profile at all → nothing exempt.
        XCTAssertFalse(UserProfile.isProgressionExempt(exerciseId: pushdown, profile: nil))
        XCTAssertEqual(UserProfile.defaultExemptExerciseIds, [])

        // An explicit stored list is read back unchanged.
        let stored = UserProfile()
        stored.exemptExerciseIds = [pushdown, "hammer_curl"]
        XCTAssertEqual(stored.exemptExerciseIds, [pushdown, "hammer_curl"])
        XCTAssertTrue(UserProfile.isProgressionExempt(exerciseId: "hammer_curl", profile: stored))
    }

    // MARK: PlanMemoryEngine

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private var cal: Calendar { Calendar.current }

    private func planItem(_ exerciseId: String, reps: [Int], load: Double, suggested: Double, planned: [Double]) -> SessionItem {
        let i = SessionItem(
            order: 1, exerciseId: exerciseId, targetReps: 12, targetSets: reps.count, targetRIR: 3,
            suggestedLoad: suggested, waveRaw: nil, repMin: 10, repMax: 12
        )
        i.actualReps = reps
        i.actualLoads = Array(repeating: load, count: reps.count)
        i.actualRIRs = Array(repeating: 3, count: reps.count)
        i.plannedLoadsBySet = planned
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    /// EXEMPT + MATERIALIZED target: a top-of-range source writes nothing; target unchanged.
    func test_exempt_materializedTarget_unchanged_nonExemptControlStillWrites() throws {
        for (exerciseId, exempt) in [(pushdown, true), ("leg_extension", false)] {
            let context = try makeContext()
            let profile = UserProfile()
            profile.setProgressionExempt(true, exerciseId: pushdown)   // nothing is exempt by default
            context.insert(profile)
            let d = { (n: Int) in self.cal.date(byAdding: .day, value: n, to: Date())! }
            let src = planItem(exerciseId, reps: [12, 12, 12], load: 60, suggested: 60, planned: [60, 60, 60])
            let srcSession = Session(date: d(-1), status: .completed, weekIndex: 2, items: [src])
            let tgt = planItem(exerciseId, reps: [0, 0, 0], load: 0, suggested: 60, planned: [60, 60, 60])
            let tgtSession = Session(date: d(1), status: .planned, weekIndex: 3, items: [tgt])
            context.insert(srcSession); context.insert(tgtSession)
            try context.save()

            PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)

            if exempt {
                XCTAssertEqual(tgt.suggestedLoad, 60, accuracy: 0.001)
                XCTAssertEqual(tgt.plannedLoadsBySet, [60, 60, 60])
            } else {
                XCTAssertGreaterThan(tgt.suggestedLoad, 60, "non-exempt control: the earned bump still propagates")
            }
        }
    }

    /// EXEMPT + EMPTY target: seeded at exactly the last lifted load, never +increment,
    /// even with a far-higher history driving the e1RM floor. Non-exempt control is capped
    /// at +increment (unchanged behavior).
    func test_exempt_emptyTarget_seededAtExactlyLastLoad() throws {
        for (exerciseId, exempt) in [(pushdown, true), ("leg_extension", false)] {
            let context = try makeContext()
            let profile = UserProfile()
            profile.setProgressionExempt(true, exerciseId: pushdown)   // nothing is exempt by default
            context.insert(profile)
            let d = { (n: Int) in self.cal.date(byAdding: .day, value: n, to: Date())! }
            let hist = planItem(exerciseId, reps: [12, 12, 12], load: 100, suggested: 100, planned: [100, 100, 100])
            let histSession = Session(date: d(-14), status: .completed, weekIndex: 1, items: [hist])
            let src = planItem(exerciseId, reps: [12, 12, 12], load: 60, suggested: 60, planned: [60, 60, 60])
            let srcSession = Session(date: d(-1), status: .completed, weekIndex: 2, items: [src])
            let tgt = planItem(exerciseId, reps: [0, 0, 0], load: 0, suggested: 0, planned: [0, 0, 0])
            let tgtSession = Session(date: d(1), status: .planned, weekIndex: 3, items: [tgt])
            context.insert(histSession); context.insert(srcSession); context.insert(tgtSession)
            try context.save()

            PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)

            if exempt {
                XCTAssertEqual(tgt.suggestedLoad, 60, accuracy: 0.001, "exactly the last lifted load")
                XCTAssertEqual(tgt.plannedLoadsBySet, [60, 60, 60])
            } else {
                XCTAssertGreaterThan(tgt.suggestedLoad, 0)
                XCTAssertLessThanOrEqual(tgt.suggestedLoad, 62.5, "non-exempt stays capped at last + one increment")
            }
        }
    }

    /// Turning the exemption off in the profile restores normal progression.
    func test_exemptOffInProfile_progressesNormally() throws {
        let context = try makeContext()
        let profile = UserProfile()
        profile.setProgressionExempt(true, exerciseId: pushdown)
        profile.setProgressionExempt(false, exerciseId: pushdown)
        context.insert(profile)
        let d = { (n: Int) in self.cal.date(byAdding: .day, value: n, to: Date())! }
        let src = planItem(pushdown, reps: [12, 12, 12], load: 60, suggested: 60, planned: [60, 60, 60])
        let srcSession = Session(date: d(-1), status: .completed, weekIndex: 2, items: [src])
        let tgt = planItem(pushdown, reps: [0, 0, 0], load: 0, suggested: 60, planned: [60, 60, 60])
        let tgtSession = Session(date: d(1), status: .planned, weekIndex: 3, items: [tgt])
        context.insert(srcSession); context.insert(tgtSession)
        try context.save()

        PlanMemoryEngine(context: context).carryForwardPlans(from: srcSession)
        XCTAssertGreaterThan(tgt.suggestedLoad, 60)
    }

    // MARK: Backup

    private func makeBackupContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func exportImport(_ configure: (UserProfile) -> Void) throws -> UserProfile {
        let src = try makeBackupContainer()
        let sctx = ModelContext(src)
        let p = UserProfile()
        configure(p)
        sctx.insert(p)
        try sctx.save()
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: sctx)
        defer { try? FileManager.default.removeItem(at: result.url) }

        let dst = try makeBackupContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: result.url, modelContainer: dst)
        return try XCTUnwrap(try ModelContext(dst).fetch(FetchDescriptor<UserProfile>()).first)
    }

    func test_backup_roundTrip_customList_andExplicitEmpty() throws {
        let custom = try exportImport { $0.exemptExerciseIds = ["cable_tricep_rope_pushdown", "hammer_curl"] }
        XCTAssertEqual(custom.exemptExerciseIds, ["cable_tricep_rope_pushdown", "hammer_curl"])

        let empty = try exportImport { $0.exemptExerciseIds = [] }
        XCTAssertEqual(empty.exemptExerciseIds, [], "an explicit empty list must survive, not revert to the default")

        let untouched = try exportImport { _ in }
        XCTAssertEqual(untouched.exemptExerciseIds, [])
    }

    func test_backup_oldBackupWithoutField_restoresToEmpty() throws {
        let json = """
        {"version":1,"exportedAt":"2026-01-01T00:00:00Z","mesoBlocks":[],"sessions":[],
         "sessionHistory":[],"exerciseNotes":[],"customExercises":[],
         "userProfile":{"profileId":"11111111-1111-1111-1111-111111111111","daysPerWeek":5}}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try makeBackupContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container)
        let profile = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(profile.daysPerWeek, 5)
        XCTAssertEqual(profile.exemptExerciseIds, [], "a backup without the field restores to empty")
    }

    // MARK: Coach text: exempt variants drop progression language

    private func scenarios() -> [(name: String, item: SessionItem)] {
        func base(_ reps: [Int] = [12, 12, 12]) -> SessionItem { item(pushdown, load: 50, reps: reps) }
        var out: [(String, SessionItem)] = []

        let deload = base(); deload.waveRaw = "deload"
        out.append(("deload", deload))

        out.append(("pain", { let i = base(); i.setFeedbackBySet = [SetFeedback.pain.rawValue, "", ""]; return i }()))
        out.append(("soreness", { let i = base(); i.setFeedbackBySet = [SetFeedback.soreness.rawValue, "", ""]; return i }()))
        out.append(("disruption", { let i = base(); i.setFeedbackBySet = [SetFeedback.disruption.rawValue, "", ""]; return i }()))
        out.append(("soreness+disruption", { let i = base()
            i.setFeedbackBySet = [SetFeedback.soreness.rawValue, SetFeedback.disruption.rawValue, ""]; return i }()))

        out.append(("failure + rep crash", { let i = base([12, 10, 8]); i.actualRIRs = [0, 0, 0]; return i }()))
        out.append(("intra-session load drop", { let i = base(); i.actualLoads = [50, 50, 40]; return i }()))

        out.append(("incomplete: set 1 hard", { let i = base([12]); i.targetSets = 3; i.actualRIRs = [0]; return i }()))
        out.append(("incomplete: set 1 short", { let i = base([8]); i.targetSets = 3; return i }()))
        out.append(("incomplete: 2 sets in", { let i = base([12, 12]); i.targetSets = 3; return i }()))

        out.append(("under range: hold", base([9, 9, 9])))
        out.append(("under range: reduce", base([6, 6, 6])))
        out.append(("flagged override at top", { let i = base()
            i.loadOverrideReasonRaw = LoadOverrideReason.generalFatigue.rawValue; return i }()))
        out.append(("in range, not top", base([11, 11, 11])))
        out.append(("off-target RIR", { let i = base(); i.actualRIRs = [0, 0, 0]; return i }()))
        out.append(("top of range (4c)", base()))
        out.append(("over-performed (4c)", base([14, 14, 14])))
        return out
    }

    /// For an exempt item NO coach string on ANY path promises progression or states a
    /// next-load number (the reduce path included — see the dedicated test below).
    func test_exempt_noCoachStringOnAnyPathPromisesProgression() throws {
        let banned = ["earn", "increase", "moving up", "move up", "next week", "next time", "starts at"]
        var checked = 0
        for (name, i) in scenarios() {
            guard let rec = CoachingEngine.recommend(
                for: i, minLoadIncrement: 5, e1rmFloorLoad: 100, carryForwardTarget: .exists,
                isProgressionExempt: true) else { continue }   // nil = no string at all
            checked += 1
            let lower = rec.message.lowercased()
            for word in banned {
                XCTAssertFalse(lower.contains(word), "\(name): exempt text contains \"\(word)\": \(rec.message)")
            }
            if let next = rec.nextSuggestedLoad {
                let lifted = i.actualLoads.max() ?? 0
                XCTAssertLessThanOrEqual(next, lifted, "\(name): exempt item must never be told an upward load")
                // No allowance for a next-load number on any path (incl. reduce): the written
                // load never appears in the text, as "47.5" or as a bare integer.
                // (A load that equals one actually lifted may be restated as an OBSERVED fact,
                // e.g. "Load dropped from 50 to 40"; only a newly computed load is a next-load
                // number.)
                if !i.actualLoads.contains(next) {
                    XCTAssertFalse(rec.message.contains(String(format: "%.1f", next)),
                                   "\(name): exempt text states the next load: \(rec.message)")
                    XCTAssertFalse(rec.message.contains(String(Int(next))),
                                   "\(name): exempt text states the next load: \(rec.message)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 14, "the sweep must actually exercise the paths")
    }

    func test_exempt_inRangeNotTop_usesTheSpecifiedText() throws {
        let rec = try XCTUnwrap(CoachingEngine.recommend(
            for: item(pushdown, load: 50, reps: [11, 11, 11]), minLoadIncrement: 5,
            carryForwardTarget: .exists, isProgressionExempt: true))
        XCTAssertEqual(rec.message,
            "In range at the target effort. Load is fixed on this exercise: keep it where it is, and change it yourself when your elbow reads clean.")
        XCTAssertEqual(rec.nextSuggestedLoad, 50, "behavior unchanged: still a hold")
    }

    /// Non-exempt wording is unchanged on every path whose exempt text was reworded, apart from
    /// the landing suffix a hold now carries when a target exists (these items are wave A).
    func test_nonExempt_reworkedPaths_textByteIdentical() throws {
        func msg(_ i: SessionItem) throws -> String {
            try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists)).message
        }
        let byName = Dictionary(uniqueKeysWithValues: scenarios().map { ($0.name, $0.item) })
        XCTAssertEqual(try msg(byName["in range, not top"]!),
            "On target and in range — hold 50.0. Hit the top of your range (12) on all working sets to earn the increase; climb your reps next session. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["off-target RIR"]!),
            "Performance didn't clearly support an increase. Hold this load and look for more consistent output next session before moving up. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["soreness+disruption"]!),
            "Soreness and disruption were flagged this session. Hold this load and focus on quality before considering an increase. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["soreness"]!),
            "Soreness was flagged this session. Hold this load — muscle soreness mid-session is a signal to avoid pushing progression. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["failure + rep crash"]!),
            "You hit failure and reps fell from 12 to 8 — the load exceeded your repeatable capacity. Hold here. Focus on keeping reps consistent set to set before considering an increase. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["under range: hold"]!),
            "Your best first 3 working sets came in below the planned range (10–12 reps). Hold this load and focus on hitting the bottom of the range before considering an increase. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["flagged override at top"]!),
            "This session was flagged as general fatigue, so the load you lifted was already reduced. Hitting the top of the range there doesn't move the plan — your existing plan holds. Log an unflagged session at the planned load to earn an increase.")
        XCTAssertTrue(try msg(byName["intra-session load drop"]!).contains("Next Week A starts at 40. Build from there."))
    }

    /// Exempt + reduce path: no load number in the text for ANY target state, and never a claim
    /// of a lowering or a landing — carry-forward does not write an exempt exercise's plan.
    /// Behavior (the lowered load is still returned) is unchanged.
    func test_exempt_reducePath_noLoadNumber_claimsOnlyWhatLands() throws {
        let banned = ["earn", "increase", "moving up", "move up", "next week", "next time", "starts at", "next session"]
        for target in [CoachingEngine.CarryForwardTarget.exists, .existsEdited, .endOfChain, .unresolved] {
            let i = item(pushdown, load: 50, reps: [6, 6, 6])
            let rec = try XCTUnwrap(CoachingEngine.recommend(
                for: i, minLoadIncrement: 2.5, carryForwardTarget: target, isProgressionExempt: true))
            let lowered = try XCTUnwrap(rec.nextSuggestedLoad, "behavior unchanged: the lowered load is still returned")
            XCTAssertLessThan(lowered, 50)
            XCTAssertFalse(rec.message.contains(where: \.isNumber), "\(target): no number at all: \(rec.message)")
            for word in banned {
                XCTAssertFalse(rec.message.lowercased().contains(word), "\(target): contains \"\(word)\": \(rec.message)")
            }
            XCTAssertFalse(rec.message.lowercased().contains("lowered"), "\(target): must not claim a lowering: \(rec.message)")
            XCTAssertEqual(rec.message,
                "Reps came in well under the bottom of the range across multiple sets. Load is fixed on this exercise; change it yourself if you want to rebuild in range.")
        }
    }

    func test_nonExempt_reduceMessage_landsInTheNamedSession() throws {
        let i = item(pushdown, load: 50, reps: [6, 6, 6])
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 2.5, carryForwardTarget: .exists))
        XCTAssertEqual(rec.message,
            "Reps came in well under the bottom of the range across multiple sets. Backing the load down to rebuild in range. Next Week A: 47.5.")
        XCTAssertEqual(try XCTUnwrap(rec.nextSuggestedLoad), 47.5, accuracy: 0.001)
        // Recap callers pass no target: the original wording is kept for them.
        let recap = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 2.5))
        XCTAssertEqual(recap.message,
            "Reps came in well under the bottom of the range across multiple sets. Backing the load down to 47.5 next session to rebuild in range.")
    }
}
