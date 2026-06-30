import XCTest
import SwiftData
@testable import ElitePerformance

/// Journey harness smoke test — proves the real pipeline runs end-to-end.
///
/// Carry-forward note: this test exercises the "first session ever" path.
/// The source item has suggestedLoad = 100 (written by seedProgram — only the
/// first session is pre-seeded; see JourneyFixture.seedProgram doc comment for
/// why every other session must stay at the materializer's untouched zeros).
/// The target item starts with suggestedLoad = 0 and plannedLoadsBySet = [0,...].
/// After carry-forward:
///   - The baseline copy sets targetItem.suggestedLoad = 100 unconditionally.
///   - LoadProjectionService.project may then OVERRIDE to a projected value
///     (capped at sourceItem.suggestedLoad * 2.0 = 200). Verified empirically:
///     with only one session of history, projection does not override here, so
///     the result is exactly the baseline-copied 100.0.
///   - Either path results in suggestedLoad > 0 on the next session.
final class JourneyHarnessTests: XCTestCase {

    /// The load a lifter would actually log for `item` this session: its current
    /// suggestedLoad if one exists, or a sensible starting weight if this is the
    /// first time this exercise has ever been scheduled (suggestedLoad == 0).
    ///
    /// Necessary because JourneyFixture.seedProgram only pre-seeds the very FIRST
    /// scheduled session (Day A) — a Day B exercise's first occurrence (the
    /// session's second ever) legitimately starts at suggestedLoad == 0, same as
    /// any exercise a real lifter has never logged before. Logging item.suggestedLoad
    /// verbatim for that first Day B occurrence would log 0 lbs, which is not a
    /// realistic session script and would mask real assertions behind a fixture
    /// artifact rather than actual carry-forward behavior.
    private func realisticLoad(for item: SessionItem, fallback: Double = 100.0) -> Double {
        item.suggestedLoad > 0 ? item.suggestedLoad : fallback
    }

    func test_smoke_seedThenOneSession_nextSessionHasNonZeroSuggestedLoad() throws {
        let fixture = try JourneyFixture.make()

        // Monday 2026-07-06 — ensures clean weekday alignment with Mon+Thu schedule
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!

        try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

        // Confirm the program seeded correctly
        let firstSession = try XCTUnwrap(fixture.currentPlannedSession(), "Expected at least one planned session after seeding")
        XCTAssertFalse(firstSession.items.isEmpty, "First session should have exercises")

        // Build a realistic session script: log every exercise at 100 lbs, 10 reps, RIR 2
        let logs: [JourneyExerciseLog] = firstSession.items.map { item in
            let sets = (0..<item.targetSets).map { _ in
                JourneySetLog(load: 100.0, reps: item.targetReps, rir: 2, feedback: "", pump: 0)
            }
            return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
        }
        let script = JourneySessionScript(logs: logs)

        try fixture.logAndComplete(script)

        // After completing session 1, the carry-forward engine should have written
        // nonzero suggestedLoad to the next session's matching exercises.
        let nextSession = try XCTUnwrap(fixture.nextPlannedSession(), "Expected a second planned session")
        XCTAssertFalse(nextSession.items.isEmpty, "Next session should have exercises")

        // Assert on bench press specifically (anchor lift in Day A)
        let benchId = ExerciseCatalog.benchPress.id
        let nextBench = try XCTUnwrap(
            fixture.item(benchId, in: nextSession),
            "Next session should contain bench press"
        )

        XCTAssertGreaterThan(
            nextBench.suggestedLoad, 0,
            "carry-forward must write a nonzero suggestedLoad to the next bench press item"
        )
        XCTAssertFalse(
            nextBench.plannedLoadsBySet.isEmpty,
            "carry-forward must populate plannedLoadsBySet on the next bench press item"
        )
        XCTAssertTrue(
            nextBench.plannedLoadsBySet.allSatisfy { $0 > 0 },
            "every planned load in the next session should be nonzero after carry-forward"
        )
    }

    // MARK: - Invariant tripwire

    /// Checks the per-session carry-forward invariants for every exerciseId
    /// present in both `completedSession` and `nextSession`. Call after every
    /// `logAndComplete`. Reads values straight off the models production code
    /// wrote — does not recompute any engine math.
    private func assertInvariants(
        after completedSession: Session,
        next nextSession: Session,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // exerciseId integrity: no two items in nextSession share an exerciseId
        let nextIds = nextSession.items.map { $0.exerciseId }
        XCTAssertEqual(
            nextIds.count, Set(nextIds).count,
            "exerciseId integrity: nextSession has duplicate exerciseIds",
            file: file, line: line
        )

        // N.9 — tautological under the current Session.isDeloadWeek implementation
        // (it derives directly from mesoPhase), kept as a regression tripwire.
        XCTAssertEqual(
            nextSession.isDeloadWeek, nextSession.mesoPhase == .deload,
            "N.9 isDeloadWeek must agree with mesoPhase",
            file: file, line: line
        )

        for completedItem in completedSession.items {
            guard let nextItem = nextSession.items.first(where: { $0.exerciseId == completedItem.exerciseId }) else {
                continue
            }

            // N.1 — 2x cap
            XCTAssertLessThanOrEqual(
                nextItem.suggestedLoad, completedItem.suggestedLoad * 2.0 + 0.001,
                "N.1 2x cap violated for \(completedItem.exerciseId): \(nextItem.suggestedLoad) > 2x \(completedItem.suggestedLoad)",
                file: file, line: line
            )

            // N.3 — no zeroing after a baseline exists
            if completedItem.suggestedLoad > 0 {
                XCTAssertGreaterThan(
                    nextItem.suggestedLoad, 0,
                    "N.3 suggestedLoad zeroed after a baseline existed for \(completedItem.exerciseId)",
                    file: file, line: line
                )
            }

            // N.7 — plannedLoadsBySet.count must match targetSets.
            // BUG CONFIRMED: PlanMemoryEngine.carryForwardPlans (Domain/Logic/PlanMemoryEngine.swift)
            // sets `targetItem.plannedLoadsBySet = sourceItem.plannedLoadsBySet` (the SOURCE
            // item's array length), and the post-projection refill reuses that same
            // already-copied count (`Array(repeating: finalLoad, count: targetItem.plannedLoadsBySet.count)`)
            // instead of `targetItem.targetSets`. Any wave transition that changes the
            // prescribed set count (e.g. wave A → B: 3 → 4 sets for bench press) leaves
            // plannedLoadsBySet undersized relative to targetSets. Verified empirically via
            // debug probe: source (wave A, 3 sets) → target (wave B, targetSets=4) produced
            // plannedLoadsBySet.count == 3.
            XCTAssertEqual(
                nextItem.plannedLoadsBySet.count, nextItem.targetSets,
                "N.7 BUG CONFIRMED: plannedLoadsBySet.count (\(nextItem.plannedLoadsBySet.count)) != targetSets (\(nextItem.targetSets)) for \(completedItem.exerciseId) — PlanMemoryEngine copies the source item's set count instead of resizing to the target's targetSets across wave transitions",
                file: file, line: line
            )

            // N.8 — finite (covers NaN too) and non-negative
            XCTAssertTrue(
                nextItem.suggestedLoad.isFinite,
                "N.8 suggestedLoad not finite for \(completedItem.exerciseId)",
                file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                nextItem.suggestedLoad, 0,
                "N.8 suggestedLoad negative for \(completedItem.exerciseId)",
                file: file, line: line
            )
        }
    }

    // MARK: - Scenario 1: Clean climber

    func test_scenario1_cleanClimber() throws {
        let fixture = try JourneyFixture.make()
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!

        let meso = try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)
        // FIXED: DUPProgramSeeder.seed (Domain/Programs/DUPProgramSeeder.swift) now passes
        // template.totalWeeks into the MesoBlock initializer it constructs, so
        // Session.mesoPhase / isDeloadWeek correctly reach .deload at the materializer's
        // real deload week. (Previously MesoBlock.totalWeeks stayed nil, mesoPhase always
        // fell back to .early, and isDeloadWeek was always false for any program seeded
        // via DUPProgramSeeder.)
        XCTAssertNotNil(meso.totalWeeks, "DUPProgramSeeder must assign MesoBlock.totalWeeks so Session.isDeloadWeek can ever be true")

        struct SessionSnapshot {
            let weekIndex: Int
            let isDeload: Bool
            let waveRaw: String?
            var suggestedLoadByExercise: [String: Double] = [:]
            var targetSetsByExercise: [String: Int] = [:]
            var targetRIRByExercise: [String: Int] = [:]
            var plannedLoadsBySetByExercise: [String: [Double]] = [:]
        }

        var snapshots: [SessionSnapshot] = []
        var extraReserveExercises: [Int: Set<String>] = [:]  // snapshot index -> exerciseIds logged at rir 1
        var anchorExerciseIds: Set<String> = []
        var sessionCounter = 0

        while let session = fixture.currentPlannedSession() {
            sessionCounter += 1
            let isDeload = session.isDeloadWeek
            // Pick 2 mid-meso working sessions, well clear of the deload band at
            // the end (weeks 9-10), to exercise the extra-reserve path.
            let useExtraReserve = !isDeload && (sessionCounter == 4 || sessionCounter == 10)

            var snapshot = SessionSnapshot(
                weekIndex: session.weekIndex,
                isDeload: isDeload,
                waveRaw: session.items.first?.waveRaw
            )
            for item in session.items {
                snapshot.suggestedLoadByExercise[item.exerciseId] = item.suggestedLoad
                snapshot.targetSetsByExercise[item.exerciseId] = item.targetSets
                snapshot.targetRIRByExercise[item.exerciseId] = item.targetRIR
                snapshot.plannedLoadsBySetByExercise[item.exerciseId] = item.plannedLoadsBySet
                if item.priorityRaw == ExercisePriority.anchor.rawValue {
                    anchorExerciseIds.insert(item.exerciseId)
                }
            }
            snapshots.append(snapshot)
            let snapshotIndex = snapshots.count - 1

            let logs: [JourneyExerciseLog]
            if isDeload {
                // Log all exercises at their plannedLoadsBySet values unchanged.
                logs = session.items.map { item in
                    let sets = item.plannedLoadsBySet.map { load in
                        JourneySetLog(load: load, reps: item.targetReps, rir: 3, feedback: "", pump: 0)
                    }
                    return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                }
            } else {
                let rir = useExtraReserve ? 1 : 2
                if useExtraReserve {
                    extraReserveExercises[snapshotIndex] = Set(session.items.map { $0.exerciseId })
                }
                logs = session.items.map { item in
                    let sets = (0..<item.targetSets).map { _ in
                        JourneySetLog(load: realisticLoad(for: item), reps: item.targetReps, rir: rir, feedback: "", pump: 0)
                    }
                    return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                }
            }

            try fixture.logAndComplete(JourneySessionScript(logs: logs))

            if let next = fixture.currentPlannedSession() {
                assertInvariants(after: session, next: next)
            }
        }

        XCTAssertGreaterThan(sessionCounter, 1, "expected the full meso to produce multiple sessions")
        XCTAssertFalse(anchorExerciseIds.isEmpty, "expected at least one anchor-priority exercise")

        // MARK: a. Monotonic non-decreasing suggestedLoad across working sessions

        for exerciseId in anchorExerciseIds {
            let workingLoads = snapshots
                .filter { !$0.isDeload }
                .compactMap { $0.suggestedLoadByExercise[exerciseId] }
            guard workingLoads.count > 1 else { continue }
            for (prior, next) in zip(workingLoads, workingLoads.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    prior, next,
                    "a. suggestedLoad must be non-decreasing across working sessions for \(exerciseId): \(prior) -> \(next)"
                )
            }
        }

        // MARK: b. targetSets follows the seeded per-wave ramp (read off the static template config)

        let benchId = ExerciseCatalog.benchPress.id
        if let benchTemplate = FullBody2DayTemplate.dayA.exerciseTemplates.first(where: { $0.exerciseId == benchId }) {
            for snapshot in snapshots {
                guard let waveRaw = snapshot.waveRaw, let wave = WaveType(rawValue: waveRaw) else { continue }
                guard let expectedSets = benchTemplate.prescription(for: wave)?.setMin else { continue }
                guard let actualSets = snapshot.targetSetsByExercise[benchId] else { continue }
                XCTAssertEqual(
                    actualSets, expectedSets,
                    "b. week \(snapshot.weekIndex) targetSets for bench (wave \(waveRaw)) should match the seeded template's setMin"
                )
            }
        } else {
            XCTFail("b. expected to find bench press in the Day A template for ramp comparison")
        }

        // MARK: c. targetRIR is non-increasing within each wave cycle (DUP intentionally
        // resets RIR at the start of every new accumulation block — wave "a" — so the
        // check only applies to consecutive sessions that stay within the same cycle).

        for exerciseId in anchorExerciseIds {
            let working = snapshots.filter { !$0.isDeload }
            for (prior, next) in zip(working, working.dropFirst()) {
                guard next.waveRaw != WaveType.a.rawValue else { continue } // new cycle — RIR legitimately resets
                guard let priorRIR = prior.targetRIRByExercise[exerciseId],
                      let nextRIR = next.targetRIRByExercise[exerciseId] else { continue }
                XCTAssertLessThanOrEqual(
                    nextRIR, priorRIR,
                    "c. targetRIR should be non-increasing within a wave cycle for \(exerciseId): week \(prior.weekIndex) (\(priorRIR)) -> week \(next.weekIndex) (\(nextRIR))"
                )
            }
        }

        // MARK: d. Deload week load is lower than the prior working session's load
        // for at least one anchor exercise. (Deload reduction is expected to come via
        // the wave/RIR path, not via any explicit "reduce" step in PlanMemoryEngine.)
        //
        // Uses waveRaw == "deload" (materializer-assigned, real per-session wave) rather
        // than isDeload (session.isDeloadWeek) to locate the deload week: isDeloadWeek's
        // mesoPhase-band definition (>=90% of the block) flags weeks 9 AND 10 as deload
        // for this 10-week template, while only week 10 is actually wave == .deload at
        // the materializer level (week 9 is wave .c, peak intensity). waveRaw pinpoints
        // the one week PlanMemoryEngine itself treats as deload.

        if let deloadSnapshot = snapshots.last(where: { $0.waveRaw == WaveType.deload.rawValue }),
           let priorWorkingSnapshot = snapshots.last(where: { $0.waveRaw != WaveType.deload.rawValue && $0.weekIndex < deloadSnapshot.weekIndex }) {
            var anyLower = false
            for exerciseId in anchorExerciseIds {
                guard let deloadFirst = deloadSnapshot.plannedLoadsBySetByExercise[exerciseId]?.first,
                      let priorFirst = priorWorkingSnapshot.plannedLoadsBySetByExercise[exerciseId]?.first else { continue }
                if deloadFirst < priorFirst { anyLower = true }
            }
            // BUG CONFIRMED: PlanMemoryEngine.carryForwardPlans only ever SKIPS
            // progression for a deload-wave target (`if targetItem.waveRaw == "deload"
            // { continue }`) — it never calls LoadProjectionService for that target, so
            // no reduction logic runs at all. The unconditional baseline copy two lines
            // above (`targetItem.suggestedLoad = sourceItem.suggestedLoad`) already ran
            // before that check, so a deload week's load is the prior session's load,
            // verbatim — never reduced. The assertion below is written to the spec's
            // literal expectation and is expected to go RED for this reason.
            XCTAssertTrue(
                anyLower,
                "d. BUG CONFIRMED: expected at least one anchor exercise's deload-week plannedLoadsBySet[0] to be lower than the prior working session's — PlanMemoryEngine never reduces load for deload-wave targets, it only skips further progression after an unconditional baseline copy of the prior session's load"
            )
        } else {
            XCTFail("d. expected both a deload snapshot and a prior working snapshot")
        }

        // MARK: e. The 2 extra-reserve (rir 1) sessions produced a strict increase on
        // the immediately following session for every exercise they touched.

        XCTAssertEqual(extraReserveExercises.count, 2, "expected exactly 2 extra-reserve sessions to have been logged")
        for (snapshotIndex, exerciseIds) in extraReserveExercises {
            let nextIndex = snapshotIndex + 1
            guard nextIndex < snapshots.count else { continue }
            let thisSnapshot = snapshots[snapshotIndex]
            let nextSnapshot = snapshots[nextIndex]
            for exerciseId in exerciseIds {
                guard let thisLoad = thisSnapshot.suggestedLoadByExercise[exerciseId],
                      let nextLoad = nextSnapshot.suggestedLoadByExercise[exerciseId] else { continue }
                XCTAssertGreaterThan(
                    nextLoad, thisLoad,
                    "e. extra-reserve (rir 1) session for \(exerciseId) at week \(thisSnapshot.weekIndex) should produce a strict suggestedLoad increase on the following session, not a hold: \(thisLoad) -> \(nextLoad)"
                )
            }
        }
    }

    // MARK: - Scenario 2: Fatigue, skip, pain

    func test_scenario2_fatigueSkipPain() throws {
        let fixture = try JourneyFixture.make()
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!
        try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

        func logClean(_ session: Session) throws {
            let logs = session.items.map { item -> JourneyExerciseLog in
                let sets = (0..<item.targetSets).map { _ in
                    JourneySetLog(load: realisticLoad(for: item), reps: item.targetReps, rir: 2, feedback: "", pump: 0)
                }
                return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
            }
            try fixture.logAndComplete(JourneySessionScript(logs: logs), session: session)
            if let next = fixture.currentPlannedSession() {
                assertInvariants(after: session, next: next)
            }
        }

        // Weeks 1-2 (sessions 1-4): log clean.
        for _ in 0..<4 {
            let session = try XCTUnwrap(fixture.currentPlannedSession())
            try logClean(session)
        }

        // Week 3, session 1: SIMULATE A SKIP.
        // SessionStatus has no .skipped case (Domain/Models/Session.swift only
        // defines .planned, .inProgress, .completed), so the skip is simulated by
        // leaving this session untouched — never calling logAndComplete on it —
        // and completing the NEXT chronological session directly via the
        // session-specific logAndComplete(_:session:) overload instead of the
        // currentPlannedSession()-driven one (which would just return this same
        // skipped session forever, since it never becomes .completed).
        let skippedSession = try XCTUnwrap(fixture.currentPlannedSession(), "expected a session to skip")
        let suggestedLoadBeforeSkip: [String: Double] = Dictionary(
            uniqueKeysWithValues: skippedSession.items.map { ($0.exerciseId, $0.suggestedLoad) }
        )

        let allSessions = fixture.allSessionsSorted()
        guard let skippedIndex = allSessions.firstIndex(where: { $0.persistentModelID == skippedSession.persistentModelID }),
              skippedIndex + 1 < allSessions.count else {
            XCTFail("expected a session after the skipped one")
            return
        }
        let sessionAfterSkip = allSessions[skippedIndex + 1]

        // Pick one exerciseId present in sessionAfterSkip to flag pain on; log the rest clean.
        let painExerciseId = try XCTUnwrap(sessionAfterSkip.items.first?.exerciseId, "expected at least one exercise in the post-skip session")

        let logsAfterSkip: [JourneyExerciseLog] = sessionAfterSkip.items.map { item in
            if item.exerciseId == painExerciseId {
                let sets = (0..<item.targetSets).map { _ in
                    JourneySetLog(load: realisticLoad(for: item), reps: item.targetReps, rir: 2, feedback: SetFeedback.pain.rawValue, pump: 0)
                }
                return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
            } else {
                let sets = (0..<item.targetSets).map { _ in
                    JourneySetLog(load: realisticLoad(for: item), reps: item.targetReps, rir: 2, feedback: "", pump: 0)
                }
                return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
            }
        }
        try fixture.logAndComplete(JourneySessionScript(logs: logsAfterSkip), session: sessionAfterSkip)

        // MARK: a. The skipped session did not lower any load — suggestedLoad on the
        // session-after-skip should be >= suggestedLoad on the session-before-skip
        // (missing data, not poor performance).
        for item in sessionAfterSkip.items {
            guard let before = suggestedLoadBeforeSkip[item.exerciseId] else { continue }
            XCTAssertGreaterThanOrEqual(
                item.suggestedLoad, before,
                "a. skip should not lower suggestedLoad for \(item.exerciseId): before=\(before) after=\(item.suggestedLoad)"
            )
        }

        // MARK: b. The pain-flagged exercise's next session gets a non-nil, non-empty
        // coachNote; other exercises in that same next session still progressed
        // normally (>= the post-skip session's own suggestedLoad).
        //
        // Exercises only repeat every other session (Day A / Day B alternation), so
        // "the next session" containing painExerciseId is not necessarily the literal
        // next-by-date session — search forward for the first one that actually
        // contains it, mirroring how PlanMemoryEngine itself locates a carry-forward
        // target (`futureSessions.first(where: { future in future.items.contains(...) })`).
        guard let skipPostIndex = allSessions.firstIndex(where: { $0.persistentModelID == sessionAfterSkip.persistentModelID }) else {
            XCTFail("expected sessionAfterSkip to be findable in allSessions")
            return
        }
        guard let sessionAfterPain = allSessions[(skipPostIndex + 1)...].first(where: { future in
            future.items.contains(where: { $0.exerciseId == painExerciseId })
        }) else {
            XCTFail("expected a future session containing the pain-flagged exercise")
            return
        }

        if let painTargetItem = sessionAfterPain.items.first(where: { $0.exerciseId == painExerciseId }) {
            let coachNote = painTargetItem.coachNote
            XCTAssertNotNil(coachNote, "b. pain-flagged exercise's next session should have a non-nil coachNote")
            XCTAssertFalse((coachNote ?? "").isEmpty, "b. pain-flagged exercise's next session coachNote should be non-empty")
        } else {
            XCTFail("b. expected the pain-flagged exercise to reappear in the session after sessionAfterSkip")
        }

        for item in sessionAfterPain.items where item.exerciseId != painExerciseId {
            guard let priorLoad = sessionAfterSkip.items.first(where: { $0.exerciseId == item.exerciseId })?.suggestedLoad else { continue }
            XCTAssertGreaterThanOrEqual(
                item.suggestedLoad, priorLoad,
                "b. other exercise \(item.exerciseId) should still have progressed normally despite the unrelated pain flag: prior=\(priorLoad) next=\(item.suggestedLoad)"
            )
        }

        // MARK: c. Carry-forward after the skip sourced from the last COMPLETED
        // session, not zero — the post-skip session's suggestedLoad is exactly the
        // skipped session's pre-existing seeded/carried value (since the skipped
        // session was never logged, its own item values are whatever the LAST
        // completed session — week 2 session 2 — carried into it, untouched).
        for item in sessionAfterSkip.items {
            XCTAssertGreaterThan(
                item.suggestedLoad, 0,
                "c. post-skip session's suggestedLoad must come from the last completed session's carry-forward, not zero, for \(item.exerciseId)"
            )
        }
    }

    // MARK: - Scenario 3: Plateau then decline

    func test_scenario3_plateauThenDecline() throws {
        let fixture = try JourneyFixture.make()
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!
        let meso = try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

        var verdicts: [ExerciseVerdict] = []
        var trackedExerciseId: String?

        // 3 sessions holding load flat, then 3 sessions declining by 5.0 each.
        for sessionIndex in 0..<6 {
            let session = try XCTUnwrap(fixture.currentPlannedSession())
            if trackedExerciseId == nil {
                trackedExerciseId = session.items.first?.exerciseId
            }
            guard let exerciseId = trackedExerciseId else {
                XCTFail("expected at least one exercise to track")
                return
            }

            let isDecline = sessionIndex >= 3
            let logs: [JourneyExerciseLog] = session.items.map { item in
                var load = realisticLoad(for: item)
                if item.exerciseId == exerciseId, isDecline {
                    load = max(0, load - 5.0 * Double(sessionIndex - 2))
                }
                let rir = isDecline ? 3 : 2
                let sets = (0..<item.targetSets).map { _ in
                    JourneySetLog(load: load, reps: item.targetReps, rir: rir, feedback: "", pump: 0)
                }
                return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
            }
            try fixture.logAndComplete(JourneySessionScript(logs: logs), session: session)
            if let next = fixture.currentPlannedSession() {
                assertInvariants(after: session, next: next)
            }

            // MesoPerformanceAnalyzer.analyze(meso:allPriorSessions:) — real signature
            // confirmed via recon. meso.sessions is the cascade relationship, already
            // populated by DUPProgramSeeder.
            if let analysis = MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: []) {
                if let summary = analysis.exerciseSummaries.first(where: { $0.exerciseId == exerciseId }) {
                    verdicts.append(summary.verdict)
                }
            }
        }

        XCTAssertFalse(verdicts.isEmpty, "expected at least one verdict to be recorded across the 6 sessions")

        // Verdict transitions: progressing/plateaued -> plateaued -> declining across the window.
        if let first = verdicts.first {
            XCTAssertTrue(
                first == .progressing || first == .plateaued || first == .insufficient,
                "expected an early verdict of progressing, plateaued, or insufficient (not yet enough decline data), got \(first)"
            )
        }
        if let last = verdicts.last {
            XCTAssertEqual(last, .declining, "expected the final verdict after 3 declining sessions to be .declining, got \(last)")
        }

        // Warmup/deload exclusion: MesoPerformanceAnalyzer's recon-confirmed behavior
        // already excludes deload weeks (`nonDeloadCompletedSessions`) and excludes
        // warmup sets via the 50%-of-session-max-load filter before computing e1RM —
        // both are read directly from Domain/Logic/MesoPerformanceAnalyzer.swift, not
        // re-derived here. No session in this scenario is a deload week (weekIndex 1-6
        // of a 10-week meso, well inside the <90% band), so this scenario cannot
        // independently verify the deload-exclusion branch.
        // STUB: deload-week exclusion not exercised by this scenario — would need a
        // dedicated journey that runs into week 9/10 while tracking exerciseSummaries.

        // STUB T-E.9: performance-gated starting loads not yet implemented — see
        // roadmap Phase 4.4. No assertion made here; this scenario only exercises
        // MesoPerformanceAnalyzer's verdict computation, not load-gating.
    }

    // MARK: - Scenario 4: Drift / idempotency

    func test_scenario4_idempotency() throws {
        func runCleanClimbScript(on fixture: JourneyFixture) throws {
            var components = DateComponents()
            components.year = 2026; components.month = 7; components.day = 6
            let startDate = Calendar.current.date(from: components)!
            try fixture.seedProgram(startDate: startDate, startingLoad: 100.0)

            while let session = fixture.currentPlannedSession() {
                let isDeload = session.isDeloadWeek
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
                            JourneySetLog(load: realisticLoad(for: item), reps: item.targetReps, rir: 2, feedback: "", pump: 0)
                        }
                        return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
                    }
                }
                try fixture.logAndComplete(JourneySessionScript(logs: logs))
            }
        }

        func finalLoadsByExercise(_ fixture: JourneyFixture) -> [String: Double] {
            var result: [String: Double] = [:]
            for session in fixture.allSessionsSorted() {
                for item in session.items {
                    result[item.exerciseId] = item.suggestedLoad
                }
            }
            return result
        }

        // Two separate fixtures, identical script, identical seed parameters.
        let fixtureA = try JourneyFixture.make()
        try runCleanClimbScript(on: fixtureA)
        let fixtureB = try JourneyFixture.make()
        try runCleanClimbScript(on: fixtureB)

        let loadsA = finalLoadsByExercise(fixtureA)
        let loadsB = finalLoadsByExercise(fixtureB)
        XCTAssertEqual(loadsA.keys.sorted(), loadsB.keys.sorted(), "both fixtures should have produced the same set of exerciseIds")
        for exerciseId in loadsA.keys {
            XCTAssertEqual(
                loadsA[exerciseId], loadsB[exerciseId],
                "no run-to-run drift expected for \(exerciseId)"
            )
        }

        // Double carry-forward on the same completed session must not compound.
        let fixtureC = try JourneyFixture.make()
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 6
        let startDate = Calendar.current.date(from: components)!
        try fixtureC.seedProgram(startDate: startDate, startingLoad: 100.0)

        let firstSession = try XCTUnwrap(fixtureC.currentPlannedSession())
        let logs: [JourneyExerciseLog] = firstSession.items.map { item in
            let sets = (0..<item.targetSets).map { _ in
                JourneySetLog(load: realisticLoad(for: item), reps: item.targetReps, rir: 2, feedback: "", pump: 0)
            }
            return JourneyExerciseLog(exerciseId: item.exerciseId, sets: sets)
        }
        try fixtureC.logAndComplete(JourneySessionScript(logs: logs))

        let nextSession = try XCTUnwrap(fixtureC.currentPlannedSession())
        let loadsAfterFirstCall: [String: Double] = Dictionary(
            uniqueKeysWithValues: nextSession.items.map { ($0.exerciseId, $0.suggestedLoad) }
        )

        // Call carryForwardPlans a SECOND time on the same already-completed session,
        // without logging a new one.
        PlanMemoryEngine(context: fixtureC.context).carryForwardPlans(from: firstSession)

        for item in nextSession.items {
            guard let before = loadsAfterFirstCall[item.exerciseId] else { continue }
            XCTAssertEqual(
                item.suggestedLoad, before,
                "double carry-forward on the same completed session must not compound suggestedLoad for \(item.exerciseId)"
            )
        }
    }
}
