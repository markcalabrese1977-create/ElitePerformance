import XCTest
import SwiftData
@testable import ElitePerformance

/// Per-session carry-forward invariant tripwire, shared across journey tests.
///
/// NOT the same check as JourneyHarnessTests.swift's private `assertInvariants(after:next:)`.
/// That version compares `completedSession` against literally the next chronological
/// session. On a 2-day-split template (Day A / Day B strictly alternating, disjoint
/// exercise rosters), the literally-next session NEVER shares an exerciseId with the
/// one that just completed — so its per-exercise N.1/N.3/N.7/N.8 checks have been
/// vacuously skipped for every transition in every existing scenario test. Verified by
/// tracing DUPProgramScheduler.buildSchedule's index math directly: dayNumber =
/// (zeroBased % trainingDaysPerWeek) + 1 strictly alternates 1,2,1,2,... for a 2-day
/// template, and FullBody2DayTemplate's Day A/Day B rosters are completely disjoint.
///
/// This version instead mirrors PlanMemoryEngine.carryForwardPlans' OWN search —
/// for each item in `completedSession`, find the real future session carry-forward
/// would have targeted (`futureSessions.first(where: { future in future.items.contains(...) })`)
/// — so the checks fire against the actual target, not an arbitrary chronological neighbor.
func assertJourneyInvariants(
    after completedSession: Session,
    allSessions: [Session],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let currentIndex = allSessions.firstIndex(where: {
        $0.persistentModelID == completedSession.persistentModelID
    }) else {
        XCTFail("assertJourneyInvariants: completedSession not found in allSessions", file: file, line: line)
        return
    }
    let futureSessions = Array(allSessions[(currentIndex + 1)...])

    var checkedTargetSessionIDs = Set<PersistentIdentifier>()

    for completedItem in completedSession.items {
        guard let targetSession = futureSessions.first(where: { future in
            future.items.contains(where: { $0.exerciseId == completedItem.exerciseId })
        }) else { continue }

        guard let nextItem = targetSession.items.first(where: {
            $0.exerciseId == completedItem.exerciseId
        }) else { continue }

        // Session-level checks (N.9, exerciseId integrity) — once per unique target session.
        if !checkedTargetSessionIDs.contains(targetSession.persistentModelID) {
            checkedTargetSessionIDs.insert(targetSession.persistentModelID)

            let targetIds = targetSession.items.map { $0.exerciseId }
            XCTAssertEqual(
                targetIds.count, Set(targetIds).count,
                "exerciseId integrity: target session has duplicate exerciseIds",
                file: file, line: line
            )

            // N.9 — tautological under the current Session.isDeloadWeek implementation
            // (it derives directly from mesoPhase), kept as a regression tripwire.
            XCTAssertEqual(
                targetSession.isDeloadWeek, targetSession.mesoPhase == .deload,
                "N.9 isDeloadWeek must agree with mesoPhase",
                file: file, line: line
            )
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
        // BUG CONFIRMED (open, not part of this task's scope — see PlanMemoryEngine.swift):
        // carryForwardPlans sets `targetItem.plannedLoadsBySet = sourceItem.plannedLoadsBySet`
        // (the SOURCE item's array length), and the post-projection refill reuses that same
        // already-copied count instead of `targetItem.targetSets`. Any wave transition that
        // changes the prescribed set count (e.g. wave A → B: 3 → 4 sets) leaves
        // plannedLoadsBySet undersized/oversized relative to targetSets. This check was
        // previously vacuous in JourneyHarnessTests.swift's assertInvariants (see file doc
        // comment above) — now that it's wired to the real target session, expect this to
        // surface for real across wave-count transitions.
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
