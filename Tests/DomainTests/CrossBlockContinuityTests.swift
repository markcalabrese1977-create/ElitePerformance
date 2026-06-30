import XCTest
import SwiftData
@testable import ElitePerformance

/// Cross-block continuity: meso -> maintenance -> second meso.
///
/// Exercises the two real maintenance-seeding routes found in recon:
///   Path A — MaintenanceProgramSeeder.seed(from:)            clones the prior meso's roster,
///            anchors via ProgramGenerator.anchorLoadsForNewMeso
///   Path B — MaintenanceProgramSeeder.seedFromNewProgram(...) builds from a fresh template,
///            anchors via the file-private anchorLoadsFromFullHistory
///
/// FIXED (previously a recon finding): DUPProgramReplaceService.replacePlannedProgram —
/// confirmed via full call-chain trace (App/ContentView.swift and
/// Features/Home/HomeView.swift's handleOnboardingDismiss both route through
/// ProgramApplicationService.apply -> DUPProgramReplaceService.replacePlannedProgram ->
/// DUPProgramSeeder.seed) to be the real, single shared entry point for seeding any
/// regular meso — now calls ProgramGenerator.anchorLoadsForNewMeso itself as its final
/// step, mirroring MaintenanceProgramSeeder.seed's own placement (anchor immediately
/// after the new meso's sessions are saved). This file seeds the second meso via
/// JourneyFixture.seedFreshMeso, which wraps that real entry point — anchoring now
/// happens automatically, through production code, not via a manual call from this test.
final class CrossBlockContinuityTests: XCTestCase {

    // MARK: - Shared script driver

    /// Runs the same clean-climber pattern as JourneyHarnessTests.swift's
    /// test_scenario1_cleanClimber (full meso, working weeks logged at suggestedLoad/
    /// targetReps/rir 2, deload weeks logged at their own plannedLoadsBySet unchanged/
    /// rir 3) against `fixture`'s currently-seeded meso, to completion.
    ///
    /// Records each anchor-priority exercise's PEAK suggestedLoad across non-deload
    /// (working) weeks only, read off the model BEFORE that session is logged (i.e.
    /// what carry-forward actually delivered into it) — never the deload week's
    /// reduced value, never anything from maintenance. This is the number every
    /// assertion below compares against.
    @discardableResult
    private func runCleanClimberToCompletion(_ fixture: JourneyFixture) throws -> [String: Double] {
        var peakLoadByExercise: [String: Double] = [:]

        while let session = fixture.currentPlannedSession() {
            let isDeload = session.isDeloadWeek

            if !isDeload {
                for item in session.items where item.priorityRaw == ExercisePriority.anchor.rawValue {
                    let current = peakLoadByExercise[item.exerciseId] ?? 0
                    peakLoadByExercise[item.exerciseId] = max(current, item.suggestedLoad)
                }
            }

            let logs: [JourneyExerciseLog]
            if isDeload {
                logs = session.items.map { item in
                    let sets = item.plannedLoadsBySet.map { load in
                        JourneySetLog(load: load, reps: item.targetReps, rir: 3, feedback: "", pump: 0)
                    }
                    return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                }
            } else {
                logs = session.items.map { item in
                    let sets = (0..<item.targetSets).map { _ in
                        JourneySetLog(load: item.suggestedLoad, reps: item.targetReps, rir: 2, feedback: "", pump: 0)
                    }
                    return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                }
            }

            try fixture.logAndComplete(JourneySessionScript(logs: logs))
            assertJourneyInvariants(after: session, allSessions: fixture.allSessionsSorted())
        }

        return peakLoadByExercise
    }

    /// Logs `count` maintenance sessions in sequence using exactly the load/rep/RIR
    /// pattern the maintenance prescription seeded (read off makeMaintenanceItem's
    /// fields via the model — targetReps/targetRIR — not invented by this test).
    private func logMaintenanceSessions(_ fixture: JourneyFixture, count: Int) throws {
        for _ in 0..<count {
            guard let session = fixture.currentPlannedSession() else { break }
            let logs: [JourneyExerciseLog] = session.items.map { item in
                let sets = (0..<item.targetSets).map { _ in
                    JourneySetLog(load: item.suggestedLoad, reps: item.targetReps, rir: item.targetRIR, feedback: "", pump: 0)
                }
                return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
            }
            try fixture.logAndComplete(JourneySessionScript(logs: logs))
            assertJourneyInvariants(after: session, allSessions: fixture.allSessionsSorted())
        }
    }

    /// `daysAgo` days before the real wall-clock "now". Necessary because
    /// E1RMCalculator.decayWeightedE1RM's referenceDate defaults to the actual
    /// Date() at call time, not anything relative to the fixture's synthetic dates.
    /// A future-anchored start date (the pattern JourneyHarnessTests.swift uses) would
    /// make every session's daysSince clamp to 0, collapsing decay-weighting to flat
    /// equal-weighting and masking the recency bias this test specifically checks for.
    private func startDateSafelyInThePast(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    }

    /// Week-1 (earliest-dated session) suggestedLoad for `exerciseId` in `meso`.
    private func weekOneLoad(_ exerciseId: String, in meso: MesoBlock) -> Double? {
        meso.sessions
            .sorted { $0.date < $1.date }
            .first { $0.items.contains { $0.exerciseId == exerciseId } }?
            .items.first { $0.exerciseId == exerciseId }?
            .suggestedLoad
    }

    // MARK: - Path A: meso -> maintenance (clone source roster) -> second meso

    func test_crossBlock_pathA_mesoMaintenanceMeso() throws {
        let startDate = startDateSafelyInThePast(daysAgo: 150)

        // --- Fixture X: meso -> maintenance -> second meso ---
        let fixtureX = try JourneyFixture.make()
        let mesoX = try fixtureX.seedProgram(startDate: startDate, startingLoad: 100.0)
        let peakX = try runCleanClimberToCompletion(fixtureX)
        XCTAssertFalse(peakX.isEmpty, "expected at least one anchor exercise's peak to be recorded")

        let lastMesoDate = try XCTUnwrap(fixtureX.allSessionsSorted().last?.date, "expected the meso to have produced sessions")
        let maintenanceStart = Calendar.current.date(byAdding: .day, value: 1, to: lastMesoDate)!
        let maintenanceTotalWeeks = 2

        try fixtureX.seedMaintenanceFromMeso(
            sourceMeso: mesoX,
            trainingWeekdays: [2, 5],
            totalWeeks: maintenanceTotalWeeks,
            startDate: maintenanceStart
        )
        // Log 3 of the 4 seeded maintenance sessions (2 days/week * 2 weeks) — partial
        // completion, matching a realistic "did some maintenance, then started a new
        // meso" transition. The 1 unlogged session is dated before secondMesoStart and
        // gets cleaned up by DUPProgramReplaceService's own delete-on/after-startDate
        // step inside seedFreshMeso below is NOT guaranteed (it only deletes sessions
        // dated >= the new meso's startDate) — this is itself a minor real-world gap
        // (stale incomplete past sessions aren't swept on a new-meso transition), noted
        // but not asserted on here since it doesn't affect this test's relationship-based
        // reads (meso.sessions), only currentPlannedSession()-style lookups.
        try logMaintenanceSessions(fixtureX, count: 3)

        let secondMesoStart = Calendar.current.date(byAdding: .day, value: 7 * maintenanceTotalWeeks + 3, to: maintenanceStart)!
        // seedFreshMeso wraps DUPProgramReplaceService.replacePlannedProgram, which now
        // anchors automatically as its final step — no manual anchoring call here.
        let secondMesoX = try fixtureX.seedFreshMeso(startDate: secondMesoStart, trainingWeekdays: [2, 5])

        // --- Fixture Y (control): meso -> second meso, NO maintenance in between ---
        // Same script, same start date (deterministic — no randomness in the script),
        // second meso seeded at the SAME calendar date fixtureX's was. The only
        // difference between X's and Y's history at anchoring time is whether
        // maintenance-block sessions are present — isolates exactly the variable
        // assertion (a) is about.
        let fixtureY = try JourneyFixture.make()
        _ = try fixtureY.seedProgram(startDate: startDate, startingLoad: 100.0)
        let peakY = try runCleanClimberToCompletion(fixtureY)
        XCTAssertEqual(peakX, peakY, "sanity: identical deterministic script on a fresh fixture should reach the identical peak")

        let secondMesoY = try fixtureY.seedFreshMeso(startDate: secondMesoStart, trainingWeekdays: [2, 5])

        let anchorIds = Set(peakX.keys)

        // MARK: a. Maintenance-block loads must never feed the second meso's anchor.
        // FIXED: ProgramGenerator.anchorLoadsForNewMeso now excludes sessions whose
        // session.meso?.isMaintenance == true from the historical pool (MesoBlock.isMaintenance,
        // set by MaintenanceProgramSeeder.seed). Verified the with-maintenance and
        // without-maintenance (control) anchors now match exactly (82.5 == 82.5 for every
        // anchor exercise, both paths) — no residual maintenance-specific contamination.
        var contaminated: [String] = []
        for exerciseId in anchorIds {
            guard let withMaintenance = weekOneLoad(exerciseId, in: secondMesoX),
                  let withoutMaintenance = weekOneLoad(exerciseId, in: secondMesoY) else { continue }
            if withMaintenance < withoutMaintenance - 0.01 {
                contaminated.append("\(exerciseId): withMaintenance=\(withMaintenance) controlWithoutMaintenance=\(withoutMaintenance)")
            }
        }
        XCTAssertTrue(
            contaminated.isEmpty,
            "a. maintenance-block sessions must not measurably pull the second meso's anchor below the control (no-maintenance) anchor, but did for: \(contaminated.joined(separator: "; "))"
        )

        // MARK: b. MesoLifecycle.activeStartDate
        // STUB: MesoLifecycle.activeStartDate exists (App/MesoLifecycle.swift) but is
        // UserDefaults.standard-backed (process-global, not ModelContext-scoped) and is
        // never written by any of the seeding entry points this journey drives —
        // DUPProgramSeeder.seed, DUPProgramReplaceService.replacePlannedProgram,
        // MaintenanceProgramSeeder.seed, and MaintenanceProgramSeeder.seedFromNewProgram
        // never call MesoLifecycle.setActiveStartDate or .confirmStartNewMeso. The only
        // call site of confirmStartNewMeso is Features/Settings/MesoRolloverGuardSheet.swift
        // (a UI confirmation sheet), and confirmStartNewMeso itself touches no SwiftData
        // state at all (MesoLabel.startNewMeso + 2 UserDefaults writes). Exercising it
        // here would mean mutating real, unscoped UserDefaults.standard from an automated
        // in-memory test — a test-isolation hazard, not a meaningful read on seeder
        // behavior. Flag for product discussion: should the seeding functions themselves
        // call MesoLifecycle.setActiveStartDate, so the activeStartDate metrics cutoff
        // can't silently desync from the actual active block whenever a transition
        // happens through these Domain-layer paths directly (as opposed to the UI flow
        // that calls confirmStartNewMeso)?

        // MARK: c. Anchoring starts below the recorded peak, but greater than 0.
        // The residual gap here (e.g. anchored=82.5 vs peak=102.5, measured after the
        // maintenance-contamination fix above) is NOT a maintenance-specific issue —
        // confirmed by the now-exact convergence in assertion (a). It's the separately
        // deferred, larger architecture gap: anchorLoadsForNewMeso's historicalSessions
        // pool still includes the source meso's OWN deload week undifferentiated from
        // working weeks (no exclusion by Session.isDeloadWeek), diluting the
        // decay-weighted average below true peak. Out of scope for this task — see
        // recon report.
        for exerciseId in anchorIds {
            guard let peak = peakX[exerciseId],
                  let anchored = weekOneLoad(exerciseId, in: secondMesoX) else { continue }

            XCTAssertGreaterThan(
                anchored, 0,
                "c. second meso's anchored suggestedLoad must be greater than 0 for \(exerciseId) — this is the original v1.1 bug (new mesos starting from 0)"
            )
            XCTAssertLessThan(
                anchored, peak,
                "c. second meso's anchored suggestedLoad (\(anchored)) should start below the recorded pre-maintenance peak (\(peak)) for \(exerciseId) — T-E.9 performance-gated starting loads are deferred to v1.3, this reflects the current decay-weighted-average algorithm rather than a deliberate percentage gate"
            )
        }
    }

    // MARK: - Path B: meso -> maintenance (fresh template) -> second meso

    func test_crossBlock_pathB_mesoMaintenanceMeso() throws {
        let startDate = startDateSafelyInThePast(daysAgo: 150)

        // --- Fixture X: meso -> maintenance (Path B, fresh template) -> second meso ---
        let fixtureX = try JourneyFixture.make()
        _ = try fixtureX.seedProgram(startDate: startDate, startingLoad: 100.0)
        let peakX = try runCleanClimberToCompletion(fixtureX)
        XCTAssertFalse(peakX.isEmpty, "expected at least one anchor exercise's peak to be recorded")

        let lastMesoDate = try XCTUnwrap(fixtureX.allSessionsSorted().last?.date, "expected the meso to have produced sessions")
        let maintenanceStart = Calendar.current.date(byAdding: .day, value: 1, to: lastMesoDate)!
        let maintenanceTotalWeeks = 2

        // Path B intentionally does NOT reuse the source meso's roster — it builds from
        // a fresh ProgramTemplate. Same FullBody2DayTemplate keeps exerciseIds
        // comparable across this test's assertions without changing what's being tested
        // (the anchoring function differs between Path A and Path B regardless of
        // whether the roster itself also changes).
        try fixtureX.seedMaintenanceFromTemplate(
            template: FullBody2DayTemplate.template,
            totalWeeks: maintenanceTotalWeeks,
            startDate: maintenanceStart
        )
        try logMaintenanceSessions(fixtureX, count: 3)

        let secondMesoStart = Calendar.current.date(byAdding: .day, value: 7 * maintenanceTotalWeeks + 3, to: maintenanceStart)!
        // seedFreshMeso wraps DUPProgramReplaceService.replacePlannedProgram, which now
        // anchors automatically as its final step — no manual anchoring call here.
        let secondMesoX = try fixtureX.seedFreshMeso(startDate: secondMesoStart, trainingWeekdays: [2, 5])

        // --- Fixture Y (control): meso -> second meso, NO maintenance in between ---
        let fixtureY = try JourneyFixture.make()
        _ = try fixtureY.seedProgram(startDate: startDate, startingLoad: 100.0)
        let peakY = try runCleanClimberToCompletion(fixtureY)
        XCTAssertEqual(peakX, peakY, "sanity: identical deterministic script on a fresh fixture should reach the identical peak")

        let secondMesoY = try fixtureY.seedFreshMeso(startDate: secondMesoStart, trainingWeekdays: [2, 5])

        let anchorIds = Set(peakX.keys)

        // MARK: a. Maintenance-block loads must never feed the second meso's anchor.
        // NOTE: Path B's maintenance block anchors itself via anchorLoadsFromFullHistory
        // (not anchorLoadsForNewMeso) — but the SECOND meso after maintenance is still
        // anchored via anchorLoadsForNewMeso, called automatically by
        // DUPProgramReplaceService.replacePlannedProgram (inside seedFreshMeso), same as
        // Path A. The contamination question is about whether THAT call picks up
        // maintenance sessions from history, which is identical regardless of which
        // function anchored the maintenance block itself.
        // FIXED: both anchorLoadsForNewMeso and anchorLoadsFromFullHistory now exclude
        // session.meso?.isMaintenance == true sessions from their historical pool.
        // Verified with-maintenance and control anchors match exactly (82.5 == 82.5 for
        // every anchor exercise).
        var contaminated: [String] = []
        for exerciseId in anchorIds {
            guard let withMaintenance = weekOneLoad(exerciseId, in: secondMesoX),
                  let withoutMaintenance = weekOneLoad(exerciseId, in: secondMesoY) else { continue }
            if withMaintenance < withoutMaintenance - 0.01 {
                contaminated.append("\(exerciseId): withMaintenance=\(withMaintenance) controlWithoutMaintenance=\(withoutMaintenance)")
            }
        }
        XCTAssertTrue(
            contaminated.isEmpty,
            "a. maintenance-block sessions (seeded via Path B, MaintenanceProgramSeeder.seedFromNewProgram) must not measurably pull the second meso's anchor below the control (no-maintenance) anchor, but did for: \(contaminated.joined(separator: "; "))"
        )

        // MARK: b. MesoLifecycle.activeStartDate — same stub as Path A's test; see that
        // test's comment for the full finding. Not re-asserted here to avoid duplicate
        // noise for the same already-documented gap.

        // MARK: c. Anchoring starts below the recorded peak, but greater than 0.
        for exerciseId in anchorIds {
            guard let peak = peakX[exerciseId],
                  let anchored = weekOneLoad(exerciseId, in: secondMesoX) else { continue }

            XCTAssertGreaterThan(
                anchored, 0,
                "c. second meso's anchored suggestedLoad must be greater than 0 for \(exerciseId) — this is the original v1.1 bug (new mesos starting from 0)"
            )
            XCTAssertLessThan(
                anchored, peak,
                "c. second meso's anchored suggestedLoad (\(anchored)) should start below the recorded pre-maintenance peak (\(peak)) for \(exerciseId)"
            )
        }
    }
}
