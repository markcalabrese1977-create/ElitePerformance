import Foundation

/// Shared safety rules for edits that rewrite a planned session's items in place
/// (exercise replacement, one-off cleanup migrations).
enum SessionEditSafety {

    /// True when the session is still `.planned` and nothing on it has been logged.
    static func isSafeToModify(_ session: Session) -> Bool {
        guard session.status == .planned else { return false }
        return !hasLoggedData(session)
    }

    /// True when any item on the session carries evidence the lifter has started it.
    static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains(where: hasLoggedData)
    }

    /// Item-level logged-data check. Broader than "has actual loads/reps": a skipped set, a pump
    /// or feedback rating, or a SetLog row is also something the lifter did, and a rewrite that
    /// resets those arrays would erase it.
    static func hasLoggedData(_ item: SessionItem) -> Bool {
        item.isCompleted
            || item.actualLoads.contains { $0 > 0 }
            || item.actualReps.contains { $0 > 0 }
            || !item.logs.isEmpty
            || item.setFeedbackBySet.contains { !$0.isEmpty }
            || item.pumpRatingsBySet.contains { $0 != 0 }
            || item.restPausePatternsBySet.contains(Self.skipMarker)
    }

    /// `persist` encodes a skipped set as this pattern in `restPausePatternsBySet`.
    static let skipMarker = "SKIP"
}

/// Day-type identity used to line up sessions of the same slot across a block.
///
/// Exact equality, no trimming: this is precisely the rule `PlanMemoryEngine.nextTargetItem`
/// has always applied, so anything that must agree with carry-forward chaining uses it too.
enum SessionDayLabelMatcher {
    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        lhs == rhs
    }

    static func matches(_ lhs: Session, _ rhs: Session) -> Bool {
        matches(lhs.dayLabel, rhs.dayLabel)
    }
}
