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
/// v4 rules:
/// - **Three to Grow, One to Know**:
///   - Progression uses only the first 3 working sets (the "growth" sets).
///   - A 4th set is diagnostic only and cannot veto an earned increase,
///     except in the special case of a major load downshift (re-baseline).
/// - Detect meaningful load *downshifts* within a session and re-baseline to the lighter load.
/// - 0 RIR + big rep crash (on growth sets) = DO NOT auto-increase.
/// - Under target reps (on growth sets) = fix reps first, no increase.
/// - Harder than planned (low RIR or lots of rest-pause on growth sets) = repeat load.
/// - Hit top reps on all 3 growth sets at planned difficulty = small load bump.
/// - Over-target reps without failure and with room in the tank = small load bump.
/// - On-target = repeat once, then consider bump.
struct CoachingEngine {

    static func recommend(for item: SessionItem) -> CoachingRecommendation? {
        let reps  = item.actualReps
        let loads = item.actualLoads

        let count = min(reps.count, loads.count)
        guard count > 0 else { return nil }

        // ----------------------------------------------------
        // Working sets = any set with both load and reps > 0
        // ----------------------------------------------------
        var workingIndices: [Int] = []
        for idx in 0..<count {
            if reps[idx] > 0 && loads[idx] > 0 {
                workingIndices.append(idx)
            }
        }
        guard !workingIndices.isEmpty else { return nil }

        // "Three to Grow": primary working sets are the first up to 3 sets.
        let primaryIndices = Array(workingIndices.prefix(3))
        guard !primaryIndices.isEmpty else { return nil }

        let primaryLoads = primaryIndices.map { loads[$0] }
        let primaryReps  = primaryIndices.map { reps[$0] }

        // Baseline load = load on the last growth set
        let baseLoad: Double = primaryLoads.last ?? 0

        // Planned targets
        let plannedTopReps = item.plannedRepsBySet.max() ?? item.targetReps
        let targetReps     = item.targetReps
        let targetRIR      = item.targetRIR

        // Actual performance metrics on *growth sets only*
        let firstReps = primaryReps.first ?? 0
        let lastReps  = primaryReps.last ?? 0
        let repDrop   = firstReps - lastReps
        let bestReps  = primaryReps.max() ?? 0

        // RIR metrics (growth sets only, if available)
        let actualRIRs = item.actualRIRs
        var primaryRIRs: [Int] = []
        if !actualRIRs.isEmpty {
            for idx in primaryIndices {
                if idx < actualRIRs.count {
                    primaryRIRs.append(actualRIRs[idx])
                }
            }
        }

        var avgRIR: Double? = nil
        var minRIR: Int? = nil
        if !primaryRIRs.isEmpty {
            let sum = primaryRIRs.reduce(0, +)
            avgRIR = Double(sum) / Double(primaryRIRs.count)
            minRIR = primaryRIRs.min()
        }

        // Rest-pause / myo-rep flags (growth sets only)
        let rpFlags = item.usedRestPauseFlags
        var primaryRP: [Bool] = []
        if !rpFlags.isEmpty {
            for idx in primaryIndices {
                if idx < rpFlags.count {
                    primaryRP.append(rpFlags[idx])
                }
            }
        }
        let restPauseCount = primaryRP.filter { $0 }.count

        func nextLoad(from base: Double, step: Double) -> Double? {
            guard base > 0 else { return nil }
            return max(0, base + step)
        }

        func loadStep(for base: Double) -> Double {
            if base >= 200 {
                return 5.0
            } else if base >= 100 {
                return 2.5
            } else {
                return 2.0
            }
        }

        // ----------------------------------------------------
        // 0) Downshift / Re-baseline detection (126 → 106 case)
        //     Uses *all* working sets (including 4th "know" set).
        // ----------------------------------------------------
        let workingLoads = workingIndices.map { loads[$0] }
        if let maxLoad = workingLoads.max(),
           let minLoad = workingLoads.min(),
           maxLoad > 0,
           minLoad > 0 {

            let drop        = maxLoad - minLoad
            let dropPercent = drop / maxLoad

            let firstLoad = loads[workingIndices.first!]
            let lastLoad  = loads[workingIndices.last!]

            // Heaviest set was early, lightest set was later, and drop is meaningful.
            if dropPercent >= 0.10,
               firstLoad == maxLoad,
               lastLoad == minLoad,
               minLoad < maxLoad {

                let msg = """
                You opened heavier (~\(Int(maxLoad))) but dropped to \(Int(minLoad)) on later sets to stay within your target. We’ll treat \(Int(minLoad)) as your new baseline for this movement so you can stabilize technique and joint comfort before building load back up.
                """
                return CoachingRecommendation(
                    message: msg,
                    nextSuggestedLoad: minLoad
                )
            }
        }

        // ----------------------------------------------------
        // 1) Failure + big rep crash on growth sets → hold
        // ----------------------------------------------------
        if let minRIR = minRIR,
           minRIR <= 0,
           repDrop >= 3 {

            let msg = """
            You pushed at least one of your primary sets to 0 RIR and reps dropped from \(firstReps) to \(lastReps). Hold this load next session and focus on more even performance across those first 3 sets before increasing.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // ----------------------------------------------------
        // 2) Under target reps (growth sets) → fix reps before load
        // ----------------------------------------------------
        if bestReps < targetReps {
            let msg = """
            Your best primary set was below the target of \(targetReps) reps. Keep this load the same next session and aim to hit at least \(targetReps) clean reps on those first 3 sets before increasing.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // ----------------------------------------------------
        // 3) Harder than planned (growth sets: low RIR or lots of RP)
        // ----------------------------------------------------
        let rirTooLow: Bool = {
            guard let avgRIR = avgRIR else { return false }
            // More than about 0.5 RIR below target → clearly harder than planned.
            return avgRIR < Double(targetRIR) - 0.5
        }()

        let lotsOfRestPause = restPauseCount >= 2

        if rirTooLow || lotsOfRestPause {
            var reasons: [String] = []
            if rirTooLow {
                reasons.append("RIR was lower than planned")
            }
            if lotsOfRestPause {
                reasons.append("multiple primary sets needed rest-pause to finish")
            }
            let reasonText = reasons.joined(separator: " and ")

            let msg = """
            You hit or nearly hit the rep target, but the first 3 sets were harder than planned (\(reasonText)). Repeat this load next session and focus on smoother, more controlled primary sets before increasing.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // ----------------------------------------------------
        // 3.5) Three to Grow: all 3 growth sets at top reps → bump
        // ----------------------------------------------------
        let allPrimaryAtTop = primaryReps.count >= 3 &&
            primaryReps.allSatisfy { $0 >= plannedTopReps }

        let rirOnTargetForIncrease: Bool = {
            guard let avgRIR = avgRIR else { return true } // if unknown, assume okay
            // Around the planned RIR range
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()

        if allPrimaryAtTop && rirOnTargetForIncrease && restPauseCount == 0 {
            let step = loadStep(for: baseLoad)
            let suggested = nextLoad(from: baseLoad, step: step) ?? baseLoad

            let msg = """
            You hit the top rep target on all three primary sets at roughly the intended difficulty, without needing rest-pause. Increase the load by about \(step) next session; the 4th set is diagnostic and doesn’t block this progression.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: suggested)
        }

        // ----------------------------------------------------
        // 4) Clearly over-performing with room in the tank
        //     (growth sets only)
        // ----------------------------------------------------
        let comfortablyOverReps = bestReps >= plannedTopReps + 2
        let notToFailure = (minRIR ?? targetRIR) > 0 && restPauseCount == 0

        if comfortablyOverReps && notToFailure {
            let step = loadStep(for: baseLoad)
            let suggested = nextLoad(from: baseLoad, step: step) ?? baseLoad

            let msg = """
            You exceeded the rep target of \(plannedTopReps) by a comfortable margin on your primary sets without needing rest-pause or going to failure. Increase the load by about \(step) next session and keep the same number of sets.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: suggested)
        }

        // ----------------------------------------------------
        // 5) On target reps at roughly target difficulty → repeat once
        // ----------------------------------------------------
        let hitRepTarget = bestReps >= plannedTopReps
        let nearTargetRIR: Bool = {
            guard let avgRIR = avgRIR else { return true } // if we don't know, assume fine
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()

        if hitRepTarget && nearTargetRIR {
            let msg = """
            You hit the planned sets and reps on your primary work at roughly the intended difficulty. Repeat this load once more; if it still feels solid next time, you’ll be in a good spot for a small weight increase.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // ----------------------------------------------------
        // 6) Catch-all conservative guidance
        // ----------------------------------------------------
        let msg = """
        Solid work. Repeat this load next session and aim for slightly better rep quality or more even performance across your first 3 sets before increasing.
        """
        return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
    }
}
