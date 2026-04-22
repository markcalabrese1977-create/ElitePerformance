import Foundation

// LEGACY — FROZEN
// Simplified progression logic predating CoachingEngine and ProgressionEngine.
// No production call sites confirmed. Tests only.
// No new logic. No modifications. Scheduled for deletion after
// CoachingEngine test coverage absorbs its three cases.

enum Adjustment { case hold, increase(percent: Double), decrease(percent: Double) }

struct Progression {
    /// Simplified Three-to-Grow logic
    static func decideAdjustment(actualReps: [Int], targetUpper: Int, repDrop: Int) -> Adjustment {
        guard !actualReps.isEmpty else { return .hold }
        let allTop = actualReps.allSatisfy { $0 >= targetUpper }
        if allTop { return .increase(percent: 0.05) } // +5% next
        if repDrop >= 2 { return .decrease(percent: 0.05) } // -5% next
        return .hold
    }
}
