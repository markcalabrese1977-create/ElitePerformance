import XCTest
import SwiftData
@testable import ElitePerformance

/// One invariant violation found by `invariantViolations`.
struct InvariantViolation: Equatable {
    let code: String
    let detail: String
}

/// Result of checking one target session's items against history.
struct InvariantResult {
    var violations: [InvariantViolation] = []
    /// Number of items for which a real "previous" was found and compared
    /// (CAP_2X / ZEROED). Zero here on a non-trivial journey means the checker
    /// silently compared nothing — the original vacuity defect this whole
    /// mechanism exists to catch.
    var comparisons: Int = 0
}

/// Pure core of the journey carry-forward invariant tripwire. No XCTAssert — only
/// computes and returns what it found, so canary tests (JourneyCanaryTests.swift)
/// can directly verify the checker catches each violation class, and so a green
/// scenario test can be told apart from a vacuous one (comparisons == 0).
///
/// "Previous" is found the same way PlanMemoryEngine.carryForwardPlans itself
/// finds its source/target pairing: matched by exerciseId only (never index), and
/// restricted to sessions with status == .completed || .inProgress — mirroring
/// carryForwardPlans' own top-of-function gate (`guard session.status == .inProgress
/// || .completed`). That status filter matters: in Scenario 2's deliberate skip, the
/// skipped session is never logged (stays .planned, holds stale seed values) but is
/// still chronologically between two real sessions of the same exercise. Without the
/// status filter, "most recent prior session by date" would incorrectly select the
/// skipped session — which never actually fed carry-forward — instead of the real
/// completed predecessor.
///
/// This searches BACKWARD from `target` (find target's real previous in `history`),
/// not forward from a source. Mathematically this identifies the same pairs the old
/// forward-search design did (carry-forward defines a unique source/target relation,
/// walkable from either end) — but only the backward direction lets this be expressed
/// as a pure function of a single target session, which is what makes it canary-testable.
func invariantViolations(forTarget target: Session, history: [Session]) -> InvariantResult {
    var result = InvariantResult()

    // ID_INTEGRITY — session-level, no previous needed.
    let targetIds = target.items.map { $0.exerciseId }
    if targetIds.count != Set(targetIds).count {
        result.violations.append(InvariantViolation(
            code: "ID_INTEGRITY",
            detail: "target session has duplicate exerciseIds"
        ))
    }

    // PHASE_DELOAD — session-level, structurally guaranteed in production source
    // (Session.isDeloadWeek derives directly from Session.mesoPhase in
    // Domain/Models/Session.swift), kept as a regression tripwire only. No canary
    // fabricates a mismatch for this code — it cannot disagree by construction.
    if target.isDeloadWeek != (target.mesoPhase == .deload) {
        result.violations.append(InvariantViolation(
            code: "PHASE_DELOAD",
            detail: "isDeloadWeek must agree with mesoPhase"
        ))
    }

    let priorSessions = history.filter {
        $0.date < target.date && ($0.status == .completed || $0.status == .inProgress)
    }

    for item in target.items {
        // PLAN_COUNT — intrinsic to the item, no previous needed.
        if item.plannedLoadsBySet.count != item.targetSets {
            result.violations.append(InvariantViolation(
                code: "PLAN_COUNT",
                detail: "\(item.exerciseId): plannedLoadsBySet.count (\(item.plannedLoadsBySet.count)) != targetSets (\(item.targetSets))"
            ))
        }

        // NONFINITE — intrinsic to the item, no previous needed.
        if !item.suggestedLoad.isFinite || item.suggestedLoad < 0 {
            result.violations.append(InvariantViolation(
                code: "NONFINITE",
                detail: "\(item.exerciseId): suggestedLoad \(item.suggestedLoad) not finite/non-negative"
            ))
        }

        // Real "previous" — most recent prior session (by date) containing the
        // SAME exerciseId, matched by exerciseId only, restricted to sessions that
        // could actually have fed carry-forward (see doc comment above).
        guard let previousSession = priorSessions
            .filter({ $0.items.contains(where: { $0.exerciseId == item.exerciseId }) })
            .max(by: { $0.date < $1.date }),
            let previousItem = previousSession.items.first(where: { $0.exerciseId == item.exerciseId })
        else { continue }

        result.comparisons += 1

        // CAP_2X
        if item.suggestedLoad > previousItem.suggestedLoad * 2.0 + 0.001 {
            result.violations.append(InvariantViolation(
                code: "CAP_2X",
                detail: "\(item.exerciseId): \(item.suggestedLoad) > 2x \(previousItem.suggestedLoad)"
            ))
        }

        // ZEROED — no zeroing after a baseline exists
        if previousItem.suggestedLoad > 0 && item.suggestedLoad == 0 {
            result.violations.append(InvariantViolation(
                code: "ZEROED",
                detail: "\(item.exerciseId): zeroed after a baseline (\(previousItem.suggestedLoad)) existed"
            ))
        }
    }

    return result
}

/// Thin XCTAssert wrapper over invariantViolations — the only place this becomes a
/// test assertion. Returns comparisons made so callers can accumulate a per-test
/// running total and assert it's > 0 (the vacuity tripwire itself).
@discardableResult
func assertJourneyInvariants(
    after target: Session,
    history: [Session],
    file: StaticString = #filePath,
    line: UInt = #line
) -> Int {
    let result = invariantViolations(forTarget: target, history: history)
    XCTAssertTrue(
        result.violations.isEmpty,
        result.violations.map { "\($0.code): \($0.detail)" }.joined(separator: "; "),
        file: file, line: line
    )
    return result.comparisons
}
