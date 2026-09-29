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
