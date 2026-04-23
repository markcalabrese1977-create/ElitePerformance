import Foundation

// COACHING AUTHORITY — TRUTH PASS v1
// Canonical target: CoachingEngine (message path)
// Current user-visible authority: SessionScreenViewModel.coachMessage() — LEGACY
// Status: CoachingEngine confirmed dead in production as of truth pass (April 2026)
// Phase 1 scope: wire CoachingEngine.message into exercise.coachMessage only
// nextSuggestedLoad: NOT wired in Phase 1 — load authority is a separate truth pass
// Frozen: Progression.swift, coachMessage()
// Deletion target: coachV5Line dead branch, coachMessage() after Phase 1 tests pass

/// What the coach says and does for a single exercise:
/// - `message`: text shown in recap / coaching note
/// - `nextSuggestedLoad`: what to seed as the next-session planned load (if any)
struct CoachingRecommendation {
    let message: String
    let nextSuggestedLoad: Double?
}

struct CoachingEngine {

    static func recommend(for item: SessionItem) -> CoachingRecommendation? {
        let reps = item.actualReps
        let loads = item.actualLoads

        let count = min(reps.count, loads.count)
        guard count > 0 else { return nil }

        // Working sets = any set with both load and reps > 0
        var workingIndices: [Int] = []
        for idx in 0..<count {
            if reps[idx] > 0 && loads[idx] > 0 {
                workingIndices.append(idx)
            }
        }
        guard !workingIndices.isEmpty else { return nil }

        let plannedWorkingSetCount = max(1, item.targetSets)
        let growthSetTarget = min(plannedWorkingSetCount, 3)

        // Progression still evaluates only the first up to 3 working sets
        let primaryIndices = Array(workingIndices.prefix(growthSetTarget))
        guard !primaryIndices.isEmpty else { return nil }

        let primaryLoads = primaryIndices.map { loads[$0] }
        let primaryReps = primaryIndices.map { reps[$0] }

        let baseLoad: Double = primaryLoads.last ?? 0

        let plannedTopReps = item.plannedRepsBySet.max() ?? item.targetReps
        let targetReps = item.targetReps
        let targetRIR = item.targetRIR

        let firstReps = primaryReps.first ?? 0
        let lastReps = primaryReps.last ?? 0
        let repDrop = firstReps - lastReps
        let bestReps = primaryReps.max() ?? 0

        let actualRIRs = item.actualRIRs
        var primaryRIRs: [Int] = []
        if !actualRIRs.isEmpty {
            for idx in primaryIndices where idx < actualRIRs.count {
                primaryRIRs.append(actualRIRs[idx])
            }
        }

        var avgRIR: Double? = nil
        var minRIR: Int? = nil
        if !primaryRIRs.isEmpty {
            let sum = primaryRIRs.reduce(0, +)
            avgRIR = Double(sum) / Double(primaryRIRs.count)
            minRIR = primaryRIRs.min()
        }

        let rpFlags = item.usedRestPauseFlags
        var primaryRP: [Bool] = []
        if !rpFlags.isEmpty {
            for idx in primaryIndices where idx < rpFlags.count {
                primaryRP.append(rpFlags[idx])
            }
        }
        let restPauseCount = primaryRP.filter { $0 }.count

        func nextLoad(from base: Double, step: Double) -> Double? {
            guard base > 0 else { return nil }
            return max(0, base + step)
        }

        func loadStep(for base: Double) -> Double {
            if base >= 200 { return 5.0 }
            if base >= 100 { return 2.5 }
            return 2.0
        }

        func formatLoad(_ value: Double) -> String {
            if value == 0 { return "0" }
            return String(format: "%.1f", value)
        }

        let primaryWorkPhrase: String = {
            switch growthSetTarget {
            case 1: return "working set"
            case 2: return "first 2 working sets"
            default: return "first 3 working sets"
            }
        }()

        // 0) Downshift / Re-baseline detection
        let workingLoads = workingIndices.map { loads[$0] }
        if workingIndices.count >= 2,
           let maxLoad = workingLoads.max(),
           let minLoad = workingLoads.min(),
           maxLoad > 0,
           minLoad > 0 {

            let drop = maxLoad - minLoad
            let dropPercent = drop / maxLoad

            let firstLoad = loads[workingIndices.first!]
            let lastLoad = loads[workingIndices.last!]

            if dropPercent >= 0.10,
               firstLoad == maxLoad,
               lastLoad == minLoad,
               minLoad < maxLoad {

                let msg = """
                You opened heavier (~\(Int(maxLoad))) but had to drop to \(Int(minLoad)) on later sets to stay within target. This likely needs a lighter baseline next time so you can stabilize performance and rebuild from a more repeatable starting point.
                """
                return CoachingRecommendation(
                    message: msg,
                    nextSuggestedLoad: minLoad
                )
            }
        }

        let completedGrowthSetCount = primaryIndices.count

        // Stage-aware gating based on PLANNED working sets, not a fixed 3
        if completedGrowthSetCount < growthSetTarget {
            let remaining = growthSetTarget - completedGrowthSetCount

            if completedGrowthSetCount == 1 {
                let currentLoadText = formatLoad(baseLoad)
                let currentReps = primaryReps[0]

                if let avgRIR, avgRIR < Double(targetRIR) - 0.5 {
                    let msg = """
                    Set 1 is logged at \(currentLoadText) × \(currentReps), and it already looks a bit harder than planned. Hold this load for now and see how the remaining planned set\(remaining == 1 ? "" : "s") go before making a progression call.
                    """
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }

                if currentReps < targetReps {
                    let msg = """
                    Set 1 came in below the target rep goal. Stay here for now and see how the remaining planned set\(remaining == 1 ? "" : "s") go before deciding whether this is a hold or needs adjustment.
                    """
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }

                let msg = """
                Set 1 is in. Hold this load and see how the remaining planned set\(remaining == 1 ? "" : "s") look before deciding whether this supports a repeat or a small increase.
                """
                return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
            }

            let msg = """
            \(completedGrowthSetCount) working set\(completedGrowthSetCount == 1 ? "" : "s") are logged. Hold this load, finish the remaining planned set\(remaining == 1 ? "" : "s"), and then decide whether the full picture supports a repeat, a small increase, or a reset.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // From here on, we have enough planned work completed to issue a real recommendation

        // 1) Failure + big rep crash → hold
        if let minRIR = minRIR,
           minRIR <= 0,
           repDrop >= 3 {

            let msg = """
            You pushed at least one of your \(primaryWorkPhrase) to 0 RIR and reps dropped from \(firstReps) to \(lastReps). This looks like a repeat-load day. Aim for more even performance before trying to increase load.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 2) Under target reps → fix reps first
        if bestReps < targetReps {
            let msg = """
            Your best \(primaryWorkPhrase) was below the planned reps. This looks like a repeat-load day. Bring reps up before trying to increase load.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 3) Harder than planned
        let rirTooLow: Bool = {
            guard let avgRIR = avgRIR else { return false }
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
            Across the \(primaryWorkPhrase), this was harder than planned (\(reasonText)). This turned into a repeat-load day. Focus on smoother, more controlled work before increasing.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 3.5) Hit top reps on all evaluated growth sets → bump
        let allPrimaryAtTop =
            primaryReps.count >= growthSetTarget &&
            primaryReps.allSatisfy { $0 >= plannedTopReps }

        let rirOnTargetForIncrease: Bool = {
            guard let avgRIR = avgRIR else { return true }
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()

        if allPrimaryAtTop && rirOnTargetForIncrease && restPauseCount == 0 {
            let step = loadStep(for: baseLoad)
            let suggested = nextLoad(from: baseLoad, step: step) ?? baseLoad

            let msg: String
            if plannedWorkingSetCount >= 4 {
                msg = """
                You completed the planned reps across the primary working sets at roughly the intended difficulty, without needing rest-pause. This supports either a repeat-load day or a small increase next session, depending on how this lift is progressed. Any extra set here is supportive, not decisive.
                """
            } else {
                msg = """
                You completed the planned reps across the planned working sets at roughly the intended difficulty, without needing rest-pause. This supports either a repeat-load day or a small increase next session, depending on how this lift is progressed.
                """
            }

            return CoachingRecommendation(message: msg, nextSuggestedLoad: suggested)
        }

        // 4) Clearly over-performing with room in the tank
        let comfortablyOverReps = bestReps >= plannedTopReps + 2
        let notToFailure = (minRIR ?? targetRIR) > 0 && restPauseCount == 0

        if comfortablyOverReps && notToFailure {
            let step = loadStep(for: baseLoad)
            let suggested = nextLoad(from: baseLoad, step: step) ?? baseLoad

            let msg = """
            You exceeded the planned reps by a comfortable margin across your \(primaryWorkPhrase) without needing rest-pause or going to failure. This supports a small increase next session if this lift is being load-progressed.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: suggested)
        }

        // 5) On target reps at roughly target difficulty → repeat once
        let hitRepTarget = bestReps >= plannedTopReps
        let nearTargetRIR: Bool = {
            guard let avgRIR = avgRIR else { return true }
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()

        if hitRepTarget && nearTargetRIR {
            let msg = """
            You completed the planned work at roughly the intended difficulty. This looks like a solid repeat-load day, with room for a small increase next time if performance stays this clean.
            """
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 6) Catch-all
        let msg = """
        Solid work. This looks closer to a repeat-load day than an increase day. Aim for slightly better rep quality or more even performance before moving load up.
        """
        return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
    }

    private static func formatLoad(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.1f", value)
    }
}
