import Foundation
import SwiftData

/// Simple coaching output for a single exercise in a session.
struct CoachingRecommendation {
    /// Human-readable guidance for the *next* time you do this lift.
    let message: String
    /// Next suggested working-set load. If `nil`, keep the current plan.
    let nextSuggestedLoad: Double?
}

/// Engine that compares planned vs actual performance and suggests what to do next time.
///
/// v1.1 focuses on:
/// - 3 working sets ("3 to grow")
/// - An optional 4th diagnostic set ("1 to know")
/// - Load progression / hold / repeat decisions
/// - Using RIR to scale how big a jump you take when you overperform
enum CoachingEngine {

    static func recommend(for item: SessionItem) -> CoachingRecommendation? {
        let loggedSets = item.loggedSetsCount
        let plannedSets = item.plannedSetCount
        let plannedTopReps = item.plannedTopReps

        // If literally nothing meaningful was logged, don't change future plans.
        guard loggedSets > 0 else {
            return CoachingRecommendation(
                message: "No meaningful work logged on this lift. Repeat this prescription next time before progressing.",
                nextSuggestedLoad: nil
            )
        }

        // Determine "working" vs "diagnostic" sets based on your 3-to-grow-1-to-know rule.
        let workingSetIndices = workingSetsIndices(loggedSets: loggedSets)
        let diagnosticIndex = diagnosticSetIndex(loggedSets: loggedSets)

        // Pull reps for working sets.
        let workingReps: [Int] = workingSetIndices.compactMap { idx in
            idx < item.actualReps.count ? item.actualReps[idx] : nil
        }

        let bestWorkingReps = workingReps.max() ?? 0
        let firstWorkingReps = workingReps.first ?? 0
        let lastWorkingReps = workingReps.last ?? 0

        // Baseline load = what you actually used on working sets, or fallbacks.
        guard let baselineLoad = baselineLoad(for: item) else {
            // If we can't infer a load, this is basically a calibration session.
            return CoachingRecommendation(
                message: "Calibration-only data for this lift. Establish a stable working weight across 3 sets before progressing.",
                nextSuggestedLoad: nil
            )
        }

        // Detect major fatigue crash across working sets.
        let fatigueCrash = detectFatigueCrash(
            firstReps: firstWorkingReps,
            lastReps: lastWorkingReps,
            plannedTopReps: plannedTopReps
        )

        // If you didn't complete the planned number of working sets, fix that first.
        if workingSetIndices.count < min(plannedSets, 3) {
            let msg = """
            You logged fewer working sets than planned (\(workingSetIndices.count)/\(min(plannedSets, 3))). \
            Keep the load around \(formatLoad(baselineLoad)) and focus on hitting all 3 quality working sets before increasing weight.
            """
            return CoachingRecommendation(
                message: msg,
                nextSuggestedLoad: baselineLoad
            )
        }

        // At this point, you've done at least 3 working sets.
        // Evaluate performance vs target reps.
        if fatigueCrash {
            let msg = """
            Strong first set but reps dropped off hard across working sets. \
            Hold the load at \(formatLoad(baselineLoad)) and aim for more even reps across your 3 sets before progressing.
            """
            return CoachingRecommendation(
                message: msg,
                nextSuggestedLoad: baselineLoad
            )
        }

        // Use the optional 4th set ("1 to know") as diagnostic for volume tolerance.
        let diagnosticMessage = diagnosticSetMessage(
            item: item,
            diagnosticIndex: diagnosticIndex,
            plannedTopReps: plannedTopReps
        )

        // Strong overperformance: clearly above rep target on working sets.
        if bestWorkingReps >= plannedTopReps + 2 {
            let baseIncrement = loadIncrement(for: baselineLoad)
            let (multiplier, rirNote) = overperformanceMultiplierAndNote(
                item: item,
                workingIndices: workingSetIndices
            )

            let adjustedIncrement = baseIncrement * multiplier
            let nextLoad = baselineLoad + adjustedIncrement

            var msg = """
            You exceeded the rep target on this load across your working sets. \
            Increase weight next session to about \(formatLoad(nextLoad)) and keep 3 quality working sets.
            """

            if let rirNote {
                msg += " " + rirNote
            }
            if let diagMsg = diagnosticMessage {
                msg += " " + diagMsg
            }

            return CoachingRecommendation(
                message: msg,
                nextSuggestedLoad: nextLoad
            )
        }

        // On target: you hit the reps without big crash, but not massively over.
        if bestWorkingReps >= plannedTopReps {
            var msg = """
            You hit the planned sets and reps at \(formatLoad(baselineLoad)). \
            Repeat this load once more to consolidate, then consider a small increase if it continues to feel strong.
            """

            if let diagMsg = diagnosticMessage {
                msg += " " + diagMsg
            }

            return CoachingRecommendation(
                message: msg,
                nextSuggestedLoad: baselineLoad
            )
        }

        // Under target reps but not a total collapse.
        var msg = """
        Reps came in below the target range on your working sets. \
        Keep the load at \(formatLoad(baselineLoad)) and focus on hitting the full rep target before progressing.
        """
        if let diagMsg = diagnosticMessage {
            msg += " " + diagMsg
        }

        return CoachingRecommendation(
            message: msg,
            nextSuggestedLoad: baselineLoad
        )
    }

    // MARK: - Helpers

    /// Indices for the 3 "growth" working sets, capped by actual logged sets.
    private static func workingSetsIndices(loggedSets: Int) -> [Int] {
        let count = min(loggedSets, 3)
        return Array(0..<count)
    }

    /// Index for the optional 4th diagnostic set, if it exists.
    private static func diagnosticSetIndex(loggedSets: Int) -> Int? {
        return loggedSets >= 4 ? 3 : nil
    }

    /// Determine a baseline working load for this item:
    /// - Prefer actual working-set loads (non-zero)
    /// - Then fall back to planned loads
    /// - Finally to suggestedLoad if necessary
    private static func baselineLoad(for item: SessionItem) -> Double? {
        let nonZeroActuals = item.actualLoads.filter { abs($0) > 0.1 }
        if let first = nonZeroActuals.first {
            return first
        }

        let nonZeroPlanned = item.plannedLoadsBySet.filter { abs($0) > 0.1 }
        if let first = nonZeroPlanned.first {
            return first
        }

        return item.suggestedLoad > 0 ? item.suggestedLoad : nil
    }

    /// Decide if there's a clear fatigue crash pattern (first set at/above target,
    /// last working set 3+ reps below target).
    private static func detectFatigueCrash(firstReps: Int, lastReps: Int, plannedTopReps: Int) -> Bool {
        guard firstReps > 0 else { return false }
        guard lastReps >= 0 else { return false }

        // Example: target 10, first set 10–12, last set 6–7 → crash.
        if firstReps >= plannedTopReps && lastReps <= plannedTopReps - 3 {
            return true
        }

        return false
    }

    /// Use the 4th set as a diagnostic for volume tolerance.
    private static func diagnosticSetMessage(
        item: SessionItem,
        diagnosticIndex: Int?,
        plannedTopReps: Int
    ) -> String? {
        guard let idx = diagnosticIndex,
              idx < item.actualReps.count else {
            return nil
        }

        let diagReps = item.actualReps[idx]

        if diagReps >= plannedTopReps {
            return "Your 4th (diagnostic) set stayed strong, so you likely tolerate this volume well. If recovery and joints feel good, you can keep a 4th set in the mix for this lift."
        } else if diagReps <= plannedTopReps - 3 {
            return "The 4th (diagnostic) set dropped off, so treat it as an occasional test rather than a permanent 4th set. Keep your base volume at 3 solid working sets."
        } else {
            return "Your 4th (diagnostic) set was okay but not dominant. Keep 3 working sets as your baseline and only add the 4th when recovery is excellent."
        }
    }

    /// Very simple load increment rule for now.
    private static func loadIncrement(for current: Double) -> Double {
        // Could later branch on exercise type (compound vs isolation).
        if current < 50 {
            return 2.5
        } else if current < 200 {
            return 2.5
        } else {
            return 5.0
        }
    }

    /// Use RIR to scale how big a jump we take when you overperform.
    ///
    /// - If we don't have RIR logged → multiplier 1.0, no extra note.
    /// - If avg RIR >= plannedRIR + 2 → 2x jump (very easy).
    /// - If avg RIR >= plannedRIR + 1 → 1.5x jump (easy).
    private static func overperformanceMultiplierAndNote(
        item: SessionItem,
        workingIndices: [Int]
    ) -> (multiplier: Double, note: String?) {
        let plannedRIR = item.targetRIR

        let workingRIRs: [Int] = workingIndices.compactMap { idx in
            idx < item.actualRIRs.count ? item.actualRIRs[idx] : nil
        }

        guard !workingRIRs.isEmpty else {
            return (1.0, nil)
        }

        let total = workingRIRs.reduce(0, +)
        let avg = Double(total) / Double(workingRIRs.count)

        // If there's no real planned RIR, don't overcomplicate it.
        if plannedRIR <= 0 {
            return (1.0, nil)
        }

        if avg >= Double(plannedRIR + 2) {
            return (
                2.0,
                "You also reported RIR around \(Int(round(avg))) on your working sets, so we're taking a larger jump than usual."
            )
        } else if avg >= Double(plannedRIR + 1) {
            return (
                1.5,
                "You reported RIR higher than planned on your working sets, so we're taking a slightly larger jump than usual."
            )
        } else {
            return (1.0, nil)
        }
    }

    private static func formatLoad(_ load: Double) -> String {
        String(format: "%.1f lb", load)
    }
}
