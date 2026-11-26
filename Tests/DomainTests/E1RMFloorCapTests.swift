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
            rec.message.contains("Next Week A: 185"),
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
        XCTAssertTrue(rec.message.contains("Next Week A: 55"), rec.message)
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
        XCTAssertTrue(rec.message.contains("Next Week A: 65"), rec.message)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
                let i = item("bench_press", load: 50, reps: [12, 12, 12])   // a compound: RIR only gates compounds. Target RIR 3
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

        out.append(("failure + rep crash", { let i = item("bench_press", load: 50, reps: [12, 10, 8]); i.actualRIRs = [0, 0, 0]; return i }()))   // RIR gates compounds only
        out.append(("intra-session load drop", { let i = base(); i.actualLoads = [50, 50, 40]; return i }()))

        out.append(("incomplete: set 1 hard", { let i = base([12]); i.targetSets = 3; i.actualRIRs = [0]; return i }()))
        out.append(("incomplete: set 1 short", { let i = base([8]); i.targetSets = 3; return i }()))
        out.append(("incomplete: 2 sets in", { let i = base([12, 12]); i.targetSets = 3; return i }()))

        out.append(("under range: hold", base([9, 9, 9])))
        out.append(("under range: reduce", base([6, 6, 6])))
        out.append(("flagged override at top", { let i = base()
            i.loadOverrideReasonRaw = LoadOverrideReason.generalFatigue.rawValue; return i }()))
        out.append(("in range, not top", base([11, 11, 11])))
        out.append(("off-target RIR", { let i = item("bench_press", load: 50, reps: [12, 12, 12]); i.actualRIRs = [0, 0, 0]; return i }()))   // RIR gates compounds only
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
            "In range at the target effort. Load is fixed on this exercise: keep it where it is, and change it yourself when you're ready.")
        XCTAssertEqual(rec.nextSuggestedLoad, 50, "behavior unchanged: still a hold")
    }

    /// Non-exempt wording is unchanged on every path whose exempt text was reworded, apart from
    /// the landing suffix a hold now carries when a target exists (these items are wave A).
    func test_nonExempt_reworkedPaths_textByteIdentical() throws {
        // The pinned wording is Simple's; the mode is a process-wide setting, so pin it here instead of inheriting whatever an earlier test left.
        EffortTracking.mode = .simple
        defer { EffortTracking.clearMirror() }
        func msg(_ i: SessionItem) throws -> String {
            try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists)).message
        }
        let byName = Dictionary(uniqueKeysWithValues: scenarios().map { ($0.name, $0.item) })
        XCTAssertEqual(try msg(byName["in range, not top"]!),
            "On target and in range — hold 50. Hit the top of your range (12) on all working sets to earn the increase; climb your reps next session. Next Week A: 50, same load, reps-first.")
        XCTAssertEqual(try msg(byName["off-target RIR"]!),
            "36 reps, counted as 27: sets 1–3 were All out, aim: Easy. Needed 35 — hold. Next Week A: 50, same load, reps-first.")
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

// MARK: - Per-exercise max load

final class MaxLoadTests: XCTestCase {

    private static var parked: [AnyObject] = []
    private let lift = "leg_extension"
    private var cal: Calendar { Calendar.current }
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: Date())! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Self.parked.append(c)
        return ModelContext(c)
    }

    private func profile(max: Double? = nil, exempt: Bool = false, id: String? = nil) -> UserProfile {
        let p = UserProfile()
        if let max { p.setMaxLoad(max, exerciseId: id ?? lift) }
        if exempt { p.setProgressionExempt(true, exerciseId: id ?? lift) }
        return p
    }

    /// 3 sets of `reps` at `load`, RIR 3, rep range 10-12.
    private func item(_ id: String? = nil, wave: String? = nil, reps: [Int], load: Double, suggested: Double? = nil,
                      planned: [Double]? = nil) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id ?? lift, targetReps: 12, targetSets: reps.count, targetRIR: 3,
                            suggestedLoad: suggested ?? load, waveRaw: wave, repMin: 10, repMax: 12)
        i.actualReps = reps
        i.actualLoads = reps.map { $0 > 0 ? load : 0 }
        i.actualRIRs = Array(repeating: 3, count: reps.count)
        i.plannedLoadsBySet = planned ?? Array(repeating: suggested ?? load, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    // MARK: Profile

    func test_profile_setClearAndCanonicalLookup() {
        let p = UserProfile()
        XCTAssertNil(p.maxLoadByExerciseStored)
        XCTAssertNil(p.maxLoad(for: lift))
        p.setMaxLoad(300, exerciseId: lift)
        XCTAssertEqual(p.maxLoad(for: lift), 300)
        XCTAssertEqual(UserProfile.maxLoad(for: lift, profile: p), 300)
        XCTAssertNil(UserProfile.maxLoad(for: lift, profile: nil))
        p.setMaxLoad(250, exerciseId: lift)
        XCTAssertEqual(p.maxLoadByExercise.count, 1, "setting again replaces, never duplicates")
        p.setMaxLoad(nil, exerciseId: lift)
        XCTAssertNil(p.maxLoad(for: lift))
        p.setMaxLoad(0, exerciseId: lift)
        XCTAssertNil(p.maxLoad(for: lift), "a non-positive value is no cap")
    }

    func test_clamp_noCap_belowCap_atCap_aboveCap() {
        let p = profile(max: 100)
        XCTAssertEqual(UserProfile.clampedLoad(90, exerciseId: lift, profile: p), 90)
        XCTAssertEqual(UserProfile.clampedLoad(100, exerciseId: lift, profile: p), 100)
        XCTAssertEqual(UserProfile.clampedLoad(120, exerciseId: lift, profile: p), 100)
        XCTAssertEqual(UserProfile.clampedLoad(120, exerciseId: "hammer_curl", profile: p), 120, "other exercises are uncapped")
        XCTAssertEqual(UserProfile.clampedLoad(120, exerciseId: lift, profile: nil), 120)
    }

    func test_clamp_fixedLoadWins_andBodyweightIsUnaffected() throws {
        let fixed = profile(max: 50, exempt: true)
        XCTAssertNil(UserProfile.effectiveMaxLoad(for: lift, profile: fixed))
        XCTAssertEqual(UserProfile.clampedLoad(60, exerciseId: lift, profile: fixed), 60, "a fixed load is never changed, up or down")
        let bw = try XCTUnwrap(ExerciseCatalog.all.first { ExerciseCatalog.isBodyweight(exerciseId: $0.id) }).id
        let p = profile(max: 5, id: bw)
        XCTAssertNil(UserProfile.effectiveMaxLoad(for: bw, profile: p))
        XCTAssertEqual(UserProfile.clampedLoad(0, exerciseId: bw, profile: p), 0)
    }

    // MARK: Coaching

    func test_coach_belowMax_progressionUnchanged() throws {
        let i = item(reps: [12, 12, 12], load: 100)
        let free = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists))
        let capped = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                            loadCap: .init(max: 200)))
        XCTAssertEqual(capped.message, free.message)
        XCTAssertEqual(try XCTUnwrap(capped.nextSuggestedLoad), 105, accuracy: 0.001)
    }

    func test_coach_earnedLoadPastMax_holdsAtMax_withTheMessage() throws {
        let i = item(reps: [12, 12, 12], load: 100)
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                         loadCap: .init(max: 100)))
        XCTAssertEqual(rec.nextSuggestedLoad, 100)
        XCTAssertEqual(rec.message, "At your max load (100). Progress with reps or tempo.")
        // A partial step to a max that is not on the increment.
        let part = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                          loadCap: .init(max: 102.5)))
        XCTAssertEqual(part.nextSuggestedLoad, 102.5)
        XCTAssertEqual(part.message, "At your max load (102.5). Progress with reps or tempo.")
        // Over-performed path too.
        let over = item(reps: [14, 14, 14], load: 100)
        let r2 = try XCTUnwrap(CoachingEngine.recommend(for: over, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                        loadCap: .init(max: 100)))
        XCTAssertEqual(r2.nextSuggestedLoad, 100)
        XCTAssertTrue(r2.message.hasPrefix("At your max load (100)."))
    }

    func test_coach_secondConsecutiveSessionAtMax_addsTheRepRangeHint() throws {
        let i = item(reps: [12, 12, 12], load: 100)
        let first = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                           loadCap: .init(max: 100, priorToppedStreak: 0)))
        XCTAssertFalse(first.message.contains("Consider"))
        let second = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                            loadCap: .init(max: 100, priorToppedStreak: 1)))
        XCTAssertEqual(second.message, "At your max load (100). Progress with reps or tempo. Consider a higher rep range or a different exercise.")
        XCTAssertEqual(second.nextSuggestedLoad, 100, "no automatic change: the load simply holds")
    }

    func test_coach_loadAboveTheMax_isClampedEvenWhenHolding() throws {
        // The max was lowered below what was lifted: a hold becomes the max.
        let i = item(reps: [10, 10, 10], load: 120)   // in range, not at the top: a hold
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, carryForwardTarget: .exists,
                                                         loadCap: .init(max: 100)))
        XCTAssertEqual(rec.nextSuggestedLoad, 100)
    }

    func test_coach_topSetRole_isCappedToo() throws {
        let i = SessionItem(order: 1, exerciseId: lift, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
                            repMin: 6, repMax: 8)
        i.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 2
        i.actualReps = [7, 7, 7, 6]; i.actualLoads = [100, 100, 100, 200]; i.actualRIRs = [2, 2, 2, 2]
        i.setFeedbackBySet = ["", "", "", ""]
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, loadCap: .init(max: 200)))
        XCTAssertEqual(rec.nextTopLoad, 200, "the earned 205 stops at the max")
        XCTAssertTrue(rec.message.contains("At your max load (200). Progress with reps or tempo."), rec.message)
        XCTAssertLessThan(try XCTUnwrap(rec.nextSuggestedLoad), 200, "the back-offs below the max are not affected")
        // Below the max the top still earns its step.
        let free = try XCTUnwrap(CoachingEngine.recommend(for: i, minLoadIncrement: 5, loadCap: .init(max: 300)))
        XCTAssertEqual(free.nextTopLoad, 205)
    }

    // MARK: Resolving the cap

    func test_resolve_nilForNoMax_fixedLoad_bodyweight_andCountsTheStreak() throws {
        let i = item(wave: "b", reps: [12, 12, 12], load: 100)
        XCTAssertNil(CoachingEngine.LoadCap.resolve(for: i, in: nil, allSessions: [], profile: nil))
        XCTAssertNil(CoachingEngine.LoadCap.resolve(for: i, in: nil, allSessions: [], profile: profile(max: 100, exempt: true)))
        XCTAssertEqual(CoachingEngine.LoadCap.resolve(for: i, in: nil, allSessions: [], profile: profile(max: 100)),
                       CoachingEngine.LoadCap(max: 100, priorToppedStreak: 0))

        let ctx = try makeContext()
        // Oldest -> newest: a miss, then two sessions that topped the range at 100, then today's.
        let miss = Session(date: day(-30), status: .completed, weekIndex: 1, dayLabel: "Day A", items: [item(wave: "b", reps: [10, 10, 10], load: 100)])
        let t1 = Session(date: day(-20), status: .completed, weekIndex: 2, dayLabel: "Day A", items: [item(wave: "b", reps: [12, 12, 12], load: 100)])
        let t2 = Session(date: day(-10), status: .completed, weekIndex: 3, dayLabel: "Day A", items: [item(wave: "b", reps: [12, 12, 12], load: 100)])
        let otherLetter = Session(date: day(-5), status: .completed, weekIndex: 4, dayLabel: "Day A", items: [item(wave: "a", reps: [8, 8, 8], load: 50)])
        let today = Session(date: day(0), status: .inProgress, weekIndex: 5, dayLabel: "Day A", items: [i])
        [miss, t1, t2, otherLetter, today].forEach(ctx.insert)
        try ctx.save()
        let cap = try XCTUnwrap(CoachingEngine.LoadCap.resolve(for: i, in: today, allSessions: [miss, t1, t2, otherLetter, today],
                                                               profile: profile(max: 100)))
        XCTAssertEqual(cap.priorToppedStreak, 2, "two consecutive same-letter sessions topped the range at the max; the miss and the other letter do not count")
    }

    // MARK: Carry-forward write sites

    private func carryForward(exempt: Bool = false, max: Double?, srcLoad: Double = 60, tgtPlanned: Double? = nil,
                              wave: String? = nil) throws -> SessionItem {
        let ctx = try makeContext()
        ctx.insert(profile(max: max, exempt: exempt))
        let hist = item(wave: wave, reps: [12, 12, 12], load: srcLoad, suggested: srcLoad)
        let histSession = Session(date: day(-14), status: .completed, weekIndex: 1, dayLabel: "Day A", items: [hist])
        let src = item(wave: wave, reps: [12, 12, 12], load: srcLoad, suggested: srcLoad)
        let srcSession = Session(date: day(-1), status: .completed, weekIndex: 2, dayLabel: "Day A", items: [src])
        let tgtLoad = tgtPlanned ?? 0
        let tgt = item(wave: wave, reps: [0, 0, 0], load: 0, suggested: tgtLoad, planned: [tgtLoad, tgtLoad, tgtLoad])
        let tgtSession = Session(date: day(1), status: .planned, weekIndex: 3, dayLabel: "Day A", items: [tgt])
        [histSession, srcSession, tgtSession].forEach(ctx.insert)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: srcSession)
        return tgt
    }

    func test_carryForward_emptyTargetSeed_isClamped_belowMaxUnchanged() throws {
        let capped = try carryForward(max: 60)
        XCTAssertEqual(capped.suggestedLoad, 60, accuracy: 0.001)
        XCTAssertTrue(capped.plannedLoadsBySet.allSatisfy { $0 <= 60 }, "\(capped.plannedLoadsBySet)")
        let free = try carryForward(max: 100)
        XCTAssertEqual(free.suggestedLoad, 62.5, accuracy: 0.001, "below the max the earned step is unchanged")
        let none = try carryForward(max: nil)
        XCTAssertEqual(none.suggestedLoad, free.suggestedLoad, accuracy: 0.001)
    }

    func test_carryForward_materializedTargetWrite_isClamped() throws {
        let capped = try carryForward(max: 60, tgtPlanned: 55)
        XCTAssertEqual(capped.suggestedLoad, 60, accuracy: 0.001)
        XCTAssertEqual(capped.plannedLoadsBySet, [60, 60, 60])
        let free = try carryForward(max: 100, tgtPlanned: 55)
        XCTAssertEqual(free.suggestedLoad, 62.5, accuracy: 0.001)
    }

    func test_carryForward_fixedLoadWinsOverMax() throws {
        let tgt = try carryForward(exempt: true, max: 50)
        XCTAssertEqual(tgt.suggestedLoad, 60, accuracy: 0.001, "a fixed-load exercise keeps exactly the last lifted load, over the max")
    }

    /// The same exercise in two letters: A sits at the max and holds, B (lighter) keeps progressing.
    func test_carryForward_perLetter_BAndCKeepProgressingWhileAIsCapped() throws {
        let ctx = try makeContext()
        ctx.insert(profile(max: 100))
        let srcA = Session(date: day(-10), status: .completed, weekIndex: 1, dayLabel: "Day A",
                           items: [item(wave: "a", reps: [12, 12, 12], load: 100)])
        let srcB = Session(date: day(-9), status: .completed, weekIndex: 2, dayLabel: "Day A",
                           items: [item(wave: "b", reps: [12, 12, 12], load: 80)])
        let tgtA = item(wave: "a", reps: [0, 0, 0], load: 0, suggested: 0, planned: [0, 0, 0])
        let tgtB = item(wave: "b", reps: [0, 0, 0], load: 0, suggested: 0, planned: [0, 0, 0])
        let sA = Session(date: day(5), status: .planned, weekIndex: 4, dayLabel: "Day A", items: [tgtA])
        let sB = Session(date: day(6), status: .planned, weekIndex: 5, dayLabel: "Day A", items: [tgtB])
        [srcA, srcB, sA, sB].forEach(ctx.insert)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: srcA)
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: srcB)
        XCTAssertEqual(tgtA.suggestedLoad, 100, accuracy: 0.001, "A holds at the max")
        XCTAssertEqual(tgtB.suggestedLoad, 82.5, accuracy: 0.001, "B is below the max and earns its step")
    }

    func test_carryForward_topSetRole_isCapped() throws {
        let ctx = try makeContext()
        ctx.insert(profile(max: 100))
        func roleItem(logged: Bool) -> SessionItem {
            let i = SessionItem(order: 1, exerciseId: lift, targetReps: 12, targetSets: 3, targetRIR: 3, suggestedLoad: 55,
                                waveRaw: "a", repMin: 10, repMax: 12)
            i.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
            i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 2
            i.plannedLoadsBySet = [55, 55, 55, 95]
            i.plannedRepsBySet = [12, 12, 12, 4]; i.plannedRIRsBySet = [3, 3, 3, 2]
            i.setFeedbackBySet = ["", "", "", ""]
            if logged {
                i.actualReps = [12, 12, 12, 6]; i.actualLoads = [60, 60, 60, 100]; i.actualRIRs = [3, 3, 3, 2]
            }
            return i
        }
        let srcItem = roleItem(logged: true)
        let tgtItem = roleItem(logged: false)
        let src = Session(date: day(-1), status: .completed, weekIndex: 2, dayLabel: "Day A", items: [srcItem])
        let tgt = Session(date: day(1), status: .planned, weekIndex: 3, dayLabel: "Day A", items: [tgtItem])
        ctx.insert(src); ctx.insert(tgt)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: src)
        XCTAssertEqual(tgtItem.plannedLoadsBySet.last, 100, "the top's earned 102.5 stops at the max")
        XCTAssertEqual(tgtItem.plannedLoadsBySet.first, 62.5, "the back-offs below the max progress")
    }

    func test_enforceMax_isANoOpForFixedLoadAndNoMax() {
        let i = item(reps: [12, 12, 12], load: 120)
        PlanMemoryEngine.enforceMax(on: i, profile: profile(max: 100, exempt: true), customExercises: [])
        XCTAssertEqual(i.suggestedLoad, 120)
        PlanMemoryEngine.enforceMax(on: i, profile: nil, customExercises: [])
        XCTAssertEqual(i.suggestedLoad, 120)
        PlanMemoryEngine.enforceMax(on: i, profile: profile(max: 100), customExercises: [])
        XCTAssertEqual(i.suggestedLoad, 100)
        XCTAssertTrue(i.plannedLoadsBySet.allSatisfy { $0 == 100 })
    }

    // MARK: Seeds

    func test_anchorLoadsForNewMeso_isClamped() throws {
        let ctx = try makeContext()
        ctx.insert(profile(max: 150))
        let hist = item(reps: [8, 8, 8], load: 200, suggested: 200)
        let past = Session(date: day(-30), status: .completed, weekIndex: 1, dayLabel: "Day A", items: [hist])
        let block = MesoBlock(name: "New", startDate: day(1), status: .active, totalWeeks: 4)
        let fresh = item(reps: [0, 0, 0], load: 0, suggested: 0, planned: [0, 0, 0])
        let next = Session(date: day(2), status: .planned, weekIndex: 1, dayLabel: "Day A", items: [fresh])
        ctx.insert(past); ctx.insert(block); ctx.insert(next)
        next.meso = block
        try ctx.save()
        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: block, context: ctx)
        XCTAssertEqual(fresh.suggestedLoad, 150, "the anchor from a 200 x 8 history stops at the 150 max")
        XCTAssertTrue(fresh.plannedLoadsBySet.allSatisfy { $0 <= 150 })
    }

    // MARK: Backup

    private func backupContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Self.parked.append(c)
        return c
    }

    func test_backup_roundTrip_withAndWithoutMaxLoads() throws {
        func roundTrip(_ configure: (UserProfile) -> Void) throws -> UserProfile {
            let src = try backupContainer()
            let sctx = ModelContext(src)
            let p = UserProfile(); configure(p); sctx.insert(p)
            try sctx.save()
            let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: sctx)
            defer { try? FileManager.default.removeItem(at: result.url) }
            let dst = try backupContainer()
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: result.url, modelContainer: dst)
            return try XCTUnwrap(try ModelContext(dst).fetch(FetchDescriptor<UserProfile>()).first)
        }
        let with = try roundTrip { $0.setMaxLoad(405, exerciseId: "back_squat"); $0.setMaxLoad(132.5, exerciseId: "hammer_curl") }
        XCTAssertEqual(with.maxLoad(for: "back_squat"), 405)
        XCTAssertEqual(with.maxLoad(for: "hammer_curl"), 132.5)
        let without = try roundTrip { _ in }
        XCTAssertNil(without.maxLoadByExerciseStored, "no caps stays nil, not an empty map")
        XCTAssertNil(without.maxLoad(for: "back_squat"))
    }

    func test_backup_oldBackupWithoutTheKey_restoresWithNoCaps() throws {
        let json = """
        {"version":1,"exportedAt":"2026-01-01T00:00:00Z","mesoBlocks":[],"sessions":[],
         "sessionHistory":[],"exerciseNotes":[],"customExercises":[],
         "userProfile":{"profileId":"11111111-1111-1111-1111-111111111111","daysPerWeek":5}}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = try backupContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: c)
        let p = try XCTUnwrap(try ModelContext(c).fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertNil(p.maxLoadByExerciseStored)
    }

    // MARK: M2. Lowering a max rewrites remaining planned loads above it

    private typealias Service = SessionItemEditService

    /// An active meso with one session per entry (planned, future) holding `lift` with the given loads.
    private func mesoWith(_ ctx: ModelContext, _ entries: [(wave: String, suggested: Double, loads: [Double], top: Bool)],
                          status: SessionStatus = .planned) throws -> (MesoBlock, [SessionItem], [Session]) {
        let block = MesoBlock(name: "Block", startDate: day(0), status: .active, totalWeeks: 12)
        ctx.insert(block)
        var items: [SessionItem] = [], sessions: [Session] = []
        for (n, e) in entries.enumerated() {
            let i = SessionItem(order: 1, exerciseId: lift, targetReps: 10, targetSets: e.top ? e.loads.count - 1 : e.loads.count,
                                targetRIR: 2, suggestedLoad: e.suggested, waveRaw: e.wave, repMin: 8, repMax: 12)
            i.plannedLoadsBySet = e.loads
            i.plannedRepsBySet = Array(repeating: 10, count: e.loads.count)
            i.plannedRIRsBySet = Array(repeating: 2, count: e.loads.count)
            if e.top { i.setRolesBySet = SessionItem.roles(backOffs: e.loads.count - 1, tops: 1); i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 2 }
            let s = Session(date: day(7 * (n + 1)), status: status, weekIndex: n + 1, dayLabel: "Day A", items: [i])
            s.meso = block
            ctx.insert(s)
            items.append(i); sessions.append(s)
        }
        try ctx.save()
        return (block, items, sessions)
    }

    func test_M2_loweringAMax_clampsOnlyAboveMaxPlannedSlots_andLeavesTheRest() throws {
        let ctx = try makeContext()
        let (block, items, _) = try mesoWith(ctx, [
            ("a", 120, [120, 120, 120], false),    // above: every slot
            ("b", 90, [90, 90, 90], false),        // below: untouched
            ("c", 110, [110, 100, 95], false),     // mixed: only the 110s
        ])
        let plan = Service.planClampToMax(meso: block, exerciseId: lift, max: 100)
        XCTAssertEqual(plan.targets.count, 2, "the letter below the max is not in the plan")
        XCTAssertEqual(Service.clampPreviewText(count: plan.targets.count, max: 100), "2 planned sessions above 100 will be set to 100")
        try Service.applyClampToMax(plan, in: ctx)
        XCTAssertEqual(items[0].suggestedLoad, 100); XCTAssertEqual(items[0].plannedLoadsBySet, [100, 100, 100])
        XCTAssertEqual(items[1].suggestedLoad, 90); XCTAssertEqual(items[1].plannedLoadsBySet, [90, 90, 90], "per-letter loads below the max are untouched")
        XCTAssertEqual(items[2].suggestedLoad, 100); XCTAssertEqual(items[2].plannedLoadsBySet, [100, 100, 95])
        XCTAssertTrue(items.allSatisfy { !$0.planEdited }, "an automatic cap is not a hand edit")
    }

    func test_M2_topSlotIsClamped_backOffsBelowTheMaxUntouched() throws {
        let ctx = try makeContext()
        let (block, items, _) = try mesoWith(ctx, [("b", 90, [90, 90, 90, 130], true)])
        let plan = Service.planClampToMax(meso: block, exerciseId: lift, max: 110)
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertTrue(plan.targets[0].detail(max: 110).contains("top 130 -> 110"), plan.targets[0].detail(max: 110))
        try Service.applyClampToMax(plan, in: ctx)
        XCTAssertEqual(items[0].plannedLoadsBySet, [90, 90, 90, 110])
        XCTAssertEqual(items[0].suggestedLoad, 90)
        XCTAssertEqual(items[0].setRolesBySet, SessionItem.roles(backOffs: 3, tops: 1))
    }

    func test_M2_neverTouches_completed_inProgress_orStartedItems_butLowersHandEditedPlans() throws {
        let ctx = try makeContext()
        let (block, items, sessions) = try mesoWith(ctx, [
            ("a", 120, [120, 120, 120], false),   // 0 planned and clean: a target
            ("a", 120, [120, 120, 120], false),   // 1 completed
            ("a", 120, [120, 120, 120], false),   // 2 in progress
            ("a", 120, [120, 120, 120], false),   // 3 planned but started (a logged set)
            ("a", 120, [120, 120, 120], false),   // 4 planned, hand-edited plan: a target too (M3)
        ])
        sessions[1].status = .completed
        sessions[2].status = .inProgress
        items[3].actualReps = [8, 0, 0]; items[3].actualLoads = [120, 0, 0]
        items[4].planEdited = true
        try ctx.save()
        let plan = Service.planClampToMax(meso: block, exerciseId: lift, max: 100)
        XCTAssertEqual(plan.targets.map { $0.weekIndex }, [1, 5])
        XCTAssertEqual(plan.targets.map { $0.edited }, [false, true])
        XCTAssertFalse(plan.targets[0].detail(max: 100).contains("(edited by you)"))
        XCTAssertTrue(plan.targets[1].detail(max: 100).hasSuffix("(edited by you)"), plan.targets[1].detail(max: 100))
        try Service.applyClampToMax(plan, in: ctx)
        XCTAssertEqual(items[0].suggestedLoad, 100)
        XCTAssertFalse(items[0].planEdited)
        XCTAssertEqual(items[4].suggestedLoad, 100); XCTAssertEqual(items[4].plannedLoadsBySet, [100, 100, 100])
        XCTAssertTrue(items[4].planEdited, "lowering to the max leaves planEdited as it was")
        for i in 1...3 {
            XCTAssertEqual(items[i].suggestedLoad, 120); XCTAssertEqual(items[i].plannedLoadsBySet, [120, 120, 120], "item \(i)")
        }
    }

    func test_M2_cancel_writesNothing_andAFailedApplyRestoresEverything() throws {
        let ctx = try makeContext()
        let (block, items, _) = try mesoWith(ctx, [("a", 120, [120, 120, 120], false), ("b", 110, [110, 100, 100], false)])
        let before = items.map { [$0.suggestedLoad] + $0.plannedLoadsBySet }
        // Cancel = the plan is only read: planning (and rendering the preview) writes nothing.
        let plan = Service.planClampToMax(meso: block, exerciseId: lift, max: 100)
        XCTAssertTrue(plan.isApplicable)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(items.map { [$0.suggestedLoad] + $0.plannedLoadsBySet }, before)
        // Forced failures restore every field.
        XCTAssertThrowsError(try Service.applyClampToMax(plan, in: ctx, hooks: .init(forceVerificationFailure: true)))
        XCTAssertEqual(items.map { [$0.suggestedLoad] + $0.plannedLoadsBySet }, before)
        XCTAssertThrowsError(try Service.applyClampToMax(plan, in: ctx, hooks: .init(forceSaveFailure: true)))
        XCTAssertEqual(items.map { [$0.suggestedLoad] + $0.plannedLoadsBySet }, before)
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_M2_planGoesStale_whenTheStateMovedUnderIt() throws {
        let ctx = try makeContext()
        let (block, items, _) = try mesoWith(ctx, [("a", 120, [120, 120, 120], false)])
        let plan = Service.planClampToMax(meso: block, exerciseId: lift, max: 100)
        items[0].suggestedLoad = 90; items[0].plannedLoadsBySet = [90, 90, 90]   // moved under the preview: no longer above the max
        XCTAssertThrowsError(try Service.applyClampToMax(plan, in: ctx)) {
            guard case Service.ReplaceError.planStale = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(items[0].suggestedLoad, 90, "a stale plan writes nothing")
    }

    func test_M2_noAboveMaxLoads_meansNoPlan_andPreviewWording() throws {
        let ctx = try makeContext()
        let (block, _, _) = try mesoWith(ctx, [("a", 90, [90, 90, 90], false)])
        XCTAssertFalse(Service.planClampToMax(meso: block, exerciseId: lift, max: 100).isApplicable)
        XCTAssertFalse(Service.planClampToMax(meso: nil, exerciseId: lift, max: 100).isApplicable)
        XCTAssertEqual(Service.clampPreviewText(count: 1, max: 317.5), "1 planned session above 317.5 will be set to 317.5")
    }
}
