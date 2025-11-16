import Foundation

/// What the coach says and does for a single exercise:
/// - `message`: text shown in recap / coaching note
/// - `nextSuggestedLoad`: what to seed as the next-session planned load (if any)
struct CoachingRecommendation {
    let message: String
    let nextSuggestedLoad: Double?
}

/// Central decision-maker for how to progress or hold load on a single exercise
/// based on the most recent session's performance.
///
/// v2 rules:
/// - 0 RIR + big rep crash = DO NOT auto-increase
/// - Under target reps = fix reps first, no increase
/// - Over-target reps without failure = small load bump
/// - On-target = repeat once, then consider bump
struct CoachingEngine {

    static func recommend(for item: SessionItem) -> CoachingRecommendation? {
        let reps = item.actualReps
        let loads = item.actualLoads

        let count = min(reps.count, loads.count)
        guard count > 0 else { return nil }

        // Only treat sets with both reps and load as "working" sets.
        var workingIndices: [Int] = []
        for idx in 0..<count {
            if reps[idx] > 0 && loads[idx] > 0 {
                workingIndices.append(idx)
            }
        }
        guard !workingIndices.isEmpty else { return nil }

        // Base load anchor: last working set's load
        let baseLoad: Double = {
            if let lastIdx = workingIndices.last {
                return loads[lastIdx]
            }
            return 0
        }()

        // Planned targets
        let plannedTopReps = item.plannedRepsBySet.max() ?? item.targetReps
        let targetReps = item.targetReps
        let targetRIR = item.targetRIR

        // Actual performance metrics
        let firstIndex = workingIndices.first!
        let lastIndex  = workingIndices.last!
        let firstReps  = reps[firstIndex]
        let lastReps   = reps[lastIndex]
        let repDrop    = firstReps - lastReps
        let bestReps   = workingIndices.map { reps[$0] }.max() ?? 0

        // RIR metrics if your model has actualRIRs (optional but supported).
        var avgRIR: Double? = nil
        var minRIR: Int? = nil
        if let actualRIRs = getActualRIRs(from: item),
           actualRIRs.count == reps.count {

            let workingRIRs: [Int] = workingIndices.compactMap { idx in
                idx < actualRIRs.count ? actualRIRs[idx] : nil
            }

            if !workingRIRs.isEmpty {
                let sum = workingRIRs.reduce(0, +)
                avgRIR = Double(sum) / Double(workingRIRs.count)
                minRIR = workingRIRs.min()
            }
        }

        func nextLoad(from base: Double, step: Double) -> Double? {
            guard base > 0 else { return nil }
            return max(0, base + step)
        }

        // ---- RULESET ----
        // We check the strongest signals first.

        // 1) If you hit FAILURE (0 RIR) and reps crashed by ≥3 → DO NOT increase.
        if let minRIR = minRIR, minRIR <= 0, repDrop >= 3 {
            let msg = """
            You pushed at least one set to 0 RIR and reps dropped from \(firstReps) to \(lastReps). Hold this load next session and focus on more even performance before increasing.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 2) Under-repped relative to target → fix reps first, no load increase.
        if bestReps < targetReps {
            let msg = """
            Your best set was below the target of \(targetReps) reps. Keep this load the same next session and aim to hit at least \(targetReps) clean reps before increasing.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 3) You hit or beat reps, but sets were MUCH harder than planned (RIR too low)
        if let avgRIR = avgRIR, avgRIR < Double(targetRIR) - 0.5 {
            let msg = """
            You hit or nearly hit the rep target, but sets were harder than planned (average RIR below target). Repeat this load next session and focus on leaving a bit more in the tank.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 4) Clearly over-performing with room in the tank:
        //    best reps ≥ planned top + 2, and not taken to failure.
        if bestReps >= plannedTopReps + 2 {
            if let minRIR = minRIR, minRIR <= 0 {
                // Over-performed but also hit 0 RIR somewhere → be conservative.
                let msg = """
                You exceeded the rep target but also hit 0 RIR on at least one set. Keep this load and aim for more stable sets rather than increasing weight yet.
                """
                return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
            }

            // Conservative, plate-friendly jumps.
            let step: Double
            if baseLoad >= 200 {
                step = 5.0
            } else if baseLoad >= 100 {
                step = 2.5
            } else {
                step = 2.0
            }

            let suggested = nextLoad(from: baseLoad, step: step) ?? baseLoad
            let msg = """
            You exceeded the rep target of \(plannedTopReps) by a comfortable margin without going to failure. Increase the load by about \(step) next session and keep the same number of sets.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: suggested)
        }

        // 5) Hit target reps at roughly target difficulty → repeat once more.
        if bestReps >= plannedTopReps {
            let msg = """
            You hit the planned sets and reps at roughly the intended difficulty. Repeat this load once more; if it still feels solid next time, consider a small weight increase.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 6) Catch-all conservative guidance.
        let msg = """
        Solid work. Repeat this load next session and aim for slightly better rep quality or more even performance across sets before increasing.
        """
        return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
    }

    // MARK: - Helper to read RIR safely

    /// If your SessionItem model has `actualRIRs: [Int]`, this will return it.
    /// If not, we just return nil and the engine behaves as a reps-only coach.
    private static func getActualRIRs(from item: SessionItem) -> [Int]? {
        // If you have `actualRIRs` as a stored property, this line will compile:
        //    return item.actualRIRs
        //
        // If not, comment the line above out and leave `return nil`.
        #if compiler(>=5.9)
        // Adjust this if your property name is different.
        return item.actualRIRs
        #else
        return nil
        #endif
    }
}
