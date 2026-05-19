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

    static func recommend(for item: SessionItem, minLoadIncrement: Double? = nil, mesoPhase: MesoPhase = .early, consecutiveCleanCount: Int = 0) -> CoachingRecommendation? {
        let reps = item.actualReps
        let loads = item.actualLoads

        let count = min(reps.count, loads.count)
        guard count > 0 else { return nil }

        // Guard 1 — Deload week: never make progression calls on deload sessions
        if item.waveRaw?.lowercased() == "deload" {
            return nil
        }

        // Guard 2 — No baseline: if suggestedLoad is 0 there's nothing to progress from
        if item.suggestedLoad <= 0 {
            return nil
        }

        // Guard 3 — First session baseline: if no actual data has been logged yet, return nil
        let hasAnyActualData = (0..<count).contains { reps[$0] > 0 || loads[$0] > 0 }
        guard hasAnyActualData else { return nil }

        // Guard 4 — Pain flag: immediate stop, no progression call
        let hasPainFlag = (0..<min(count, item.setFeedbackBySet.count)).contains {
            item.setFeedbackBySet[$0] == SetFeedback.pain.rawValue
        }
        if hasPainFlag {
            return CoachingRecommendation(
                message: "Pain was flagged on at least one set. No progression call will be made. Reassess before your next session.",
                nextSuggestedLoad: nil
            )
        }

        // Guard 5 — Soreness/disruption flag: captured here, applied as override below
        let hasFatigueFlag = (0..<min(count, item.setFeedbackBySet.count)).contains {
            let fb = item.setFeedbackBySet[$0]
            return fb == SetFeedback.soreness.rawValue || fb == SetFeedback.disruption.rawValue
        }

        // Working sets = any set with both load and reps > 0
        var workingIndices: [Int] = []
        for idx in 0..<count {
            if reps[idx] > 0 && loads[idx] > 0 {
                workingIndices.append(idx)
            }
        }

        // Warmup pollution guard: exclude sets below 50% of session max load
        if let maxLoad = workingIndices.map({ loads[$0] }).max(), maxLoad > 0 {
            workingIndices = workingIndices.filter { loads[$0] >= maxLoad * 0.5 }
        }
        guard !workingIndices.isEmpty else { return nil }

        let plannedWorkingSetCount = max(1, item.targetSets)
        let growthSetTarget = min(plannedWorkingSetCount, 3)

        // Progression evaluates only the first up to 3 working sets
        let primaryIndices = Array(workingIndices.prefix(growthSetTarget))
        guard !primaryIndices.isEmpty else { return nil }

        let primaryLoads = primaryIndices.map { loads[$0] }
        let primaryReps = primaryIndices.map { reps[$0] }

        let baseLoad: Double = primaryLoads.last ?? 0

        // Guard 6 — Sanity cap: never suggest more than 2x the previous load
        let loadSanityCap = baseLoad * 2.0

        // 2.4 — ProgressionEngine decision for cluster-aware progression
        let progressionDecision: ProgressionDecision? = {
            guard let cluster = ExerciseCatalog.cluster(for: item.exerciseId) else { return nil }
            let config = ChestArmsLowBackMesoProfile.config(for: cluster)
            let snapshots = item.toSetSnapshots()
            guard !snapshots.isEmpty else { return nil }
            return ProgressionEngine.suggestNext(
                history: snapshots,
                currentSets: item.targetSets,
                config: config,
                phase: mesoPhase
            )
        }()

        let plannedTopReps = item.repMax ?? item.plannedRepsBySet.max() ?? item.targetReps
        let plannedBottomReps = item.repMin ?? item.plannedRepsBySet.min() ?? item.targetReps
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

        // Drop set detection
        let lastPrimaryIdx = primaryIndices.last ?? 0
        let dropPatternForLastSet: String = {
            if lastPrimaryIdx < item.dropSetPatternsBySet.count {
                return item.dropSetPatternsBySet[lastPrimaryIdx]
            }
            return ""
        }()
        let lastSetHadGoodDropSet: Bool = {
            guard !dropPatternForLastSet.isEmpty else { return false }
            let firstDrop = dropPatternForLastSet.split(separator: ",").first.map(String.init) ?? ""
            let parts = firstDrop.split(separator: "x")
            if parts.count == 2, let dropReps = Int(parts[1]) {
                return dropReps >= max(1, targetReps / 2)
            }
            return !firstDrop.isEmpty
        }()

        // Pump awareness — average pump rating across primary sets
        let avgPump: PumpRating = {
            let ratings = primaryIndices.compactMap { idx -> PumpRating? in
                guard idx < item.pumpRatingsBySet.count else { return nil }
                let r = PumpRating(rawValue: item.pumpRatingsBySet[idx]) ?? .none
                return r == .none ? nil : r
            }
            guard !ratings.isEmpty else { return .none }
            let avg = ratings.map { $0.rawValue }.reduce(0, +) / ratings.count
            return PumpRating(rawValue: avg) ?? .none
        }()

        func nextLoad(from base: Double, step: Double) -> Double? {
            guard base > 0 else { return nil }
            return max(0, base + step)
        }

        func loadStep(for base: Double) -> Double {
            if let increment = minLoadIncrement, increment > 0 {
                return increment
            }
            if let cluster = ExerciseCatalog.cluster(for: item.exerciseId) {
                let config = ChestArmsLowBackMesoProfile.config(for: cluster)
                return config.primaryLoadIncrement
            }
            if base >= 200 { return 5.0 }
            if base >= 100 { return 2.5 }
            return 2.0
        }

        let primaryWorkPhrase: String = {
            switch growthSetTarget {
            case 1: return "working set"
            case 2: return "first 2 working sets"
            default: return "first 3 working sets"
            }
        }()

        // MARK: - Decision Pipeline

        // 0) Downshift / Re-baseline detection
        // If load dropped ≥10% from first to last working set (no drop set), reset baseline.
        let lastWorkingIdx = workingIndices.last ?? 0
        let lastSetHadDropSet = lastWorkingIdx < item.dropSetPatternsBySet.count &&
            !item.dropSetPatternsBySet[lastWorkingIdx].isEmpty

        let workingLoads = workingIndices.map { loads[$0] }
        if !lastSetHadDropSet,
           workingIndices.count >= 2,
           let maxLoad = workingLoads.max(),
           let minLoad = workingLoads.min(),
           maxLoad > 0,
           minLoad > 0 {

            let dropPercent = (maxLoad - minLoad) / maxLoad
            let firstLoad = loads[workingIndices.first!]
            let lastLoad = loads[workingIndices.last!]

            if dropPercent >= 0.10,
               firstLoad == maxLoad,
               lastLoad == minLoad,
               minLoad < maxLoad {

                let msg = "Load dropped from \(Int(maxLoad)) to \(Int(minLoad)) across your working sets — you opened above your repeatable baseline. Next session starts at \(Int(minLoad)). Build from there."
                return CoachingRecommendation(message: msg, nextSuggestedLoad: minLoad)
            }
        }

        // Stage-aware gating — session must have all planned sets logged before a real call
        let completedGrowthSetCount = primaryIndices.count
        let completedWorkingSetCount = workingIndices.count

        if completedGrowthSetCount < growthSetTarget || completedWorkingSetCount < plannedWorkingSetCount {
            let remaining = plannedWorkingSetCount - completedWorkingSetCount

            if completedGrowthSetCount == 1 {
                let currentLoadText = String(format: "%.1f", baseLoad)
                let currentReps = primaryReps[0]

                if let avgRIR, avgRIR < Double(targetRIR) - 0.5 {
                    let msg = "Set 1 at \(currentLoadText) × \(currentReps) is already harder than the target RIR. Keep this load and monitor the remaining \(remaining == 1 ? "set" : "sets") — if it stays hard, this is a hold day."
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }

                if currentReps < plannedBottomReps {
                    let msg = "Set 1 came in short of the rep target. Stay at this load — if reps stay low across sets, the load needs to come down next session."
                    return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
                }

                // On target after 1 set — nothing useful to say yet
                return nil
            }

            // 2+ sets logged but session incomplete — terse, no decision
            let msg = "\(completedWorkingSetCount) sets in. Finish the session."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // From here on, all planned sets are logged — real recommendation territory

        // 1) Failure + big rep crash → hold
        if let minRIR = minRIR,
           minRIR <= 0,
           repDrop >= 3 {
            let msg = "You hit failure and reps fell from \(firstReps) to \(lastReps) — the load exceeded your repeatable capacity. Hold here. Focus on keeping reps consistent set to set before considering an increase."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 2) Under target reps → fix reps first
        if bestReps < plannedBottomReps {
            if lastSetHadGoodDropSet {
                let msg = "Working sets came in below the planned reps. The drop set kept volume in, but the working sets need to hit the target range before adding load. Hold here."
                return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
            }
            let msg = "Your best \(primaryWorkPhrase) came in below the planned range (\(plannedBottomReps)–\(plannedTopReps) reps). Hold this load and focus on hitting the bottom of the range before considering an increase."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 3) Harder than planned (RIR or rest-pause)
        let rirTooLow: Bool = {
            guard let avgRIR = avgRIR else { return false }
            return avgRIR < Double(targetRIR) - 0.5
        }()

        let lotsOfRestPause = restPauseCount >= 2

        if rirTooLow || lotsOfRestPause {
            var reasons: [String] = []
            if rirTooLow { reasons.append("RIR below target") }
            if lotsOfRestPause { reasons.append("rest-pause required to finish sets") }
            let reasonText = reasons.joined(separator: ", ")
            let msg = "This was harder than the target — \(reasonText). Hold this load. Execution needs to be cleaner before adding weight."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 4) Clearly over-performing — evaluated BEFORE 3.5
        // Absurd reps must not misfire the "clean execution" path.
        // Fatigue flag overrides even over-performance — a compromised session isn't reliable.
        let comfortablyOverReps = bestReps >= plannedTopReps + 2
        let notToFailure = (minRIR ?? targetRIR) > 0 && restPauseCount == 0

        if comfortablyOverReps && notToFailure {
            if hasFatigueFlag {
                let msg = "Reps exceeded the target range, but fatigue was flagged this session. This isn't a reliable indicator — hold this load and reassess next session."
                return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
            }
            let suggested: Double = {
                if let decision = progressionDecision, decision.action == .increaseLoad {
                    return min(decision.nextLoad, loadSanityCap)
                }
                let step = loadStep(for: baseLoad)
                return nextLoad(from: baseLoad, step: step) ?? baseLoad
            }()
            let nextLoad = min(suggested, loadSanityCap)
            let pumpNote: String = {
                switch avgPump {
                case .good: return " Pump was good — this lift is responding well."
                case .excellent: return " Pump was excellent — strong stimulus confirmed."
                case .poor: return " Pump was poor — consider whether load, technique, or fatigue affected stimulus."
                default: return ""
                }
            }()
            let msg = "Reps came in well above the target range with room to spare. Next session: \(String(format: "%.1f", nextLoad)).\(pumpNote)"
            return CoachingRecommendation(message: msg, nextSuggestedLoad: nextLoad)
        }

        // Fatigue flag override — soreness/disruption holds load regardless of rep performance
        if hasFatigueFlag {
            let msg: String = {
                let flags = (0..<min(count, item.setFeedbackBySet.count))
                    .map { item.setFeedbackBySet[$0] }
                let hasSoreness = flags.contains(SetFeedback.soreness.rawValue)
                let hasDisruption = flags.contains(SetFeedback.disruption.rawValue)
                if hasSoreness && hasDisruption {
                    return "Soreness and disruption were flagged this session. Hold this load and focus on quality before considering an increase."
                } else if hasSoreness {
                    return "Soreness was flagged this session. Hold this load — muscle soreness mid-session is a signal to avoid pushing progression."
                } else {
                    return "Disruption was flagged this session. This wasn't a reliable performance indicator — hold this load and reassess next session."
                }
            }()
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // Shared conditions for 3.5 and 3.6
        let allPrimaryAtTop =
            primaryReps.count >= growthSetTarget &&
            primaryReps.allSatisfy { $0 >= plannedBottomReps } &&
            bestReps >= plannedTopReps

        let rirOnTargetForIncrease: Bool = {
            guard let avgRIR = avgRIR else { return true }
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()

        // 3.5) Hit planned reps cleanly, no rest-pause → increase candidate
        if allPrimaryAtTop && rirOnTargetForIncrease && restPauseCount == 0 {
            let suggested: Double = {
                if let decision = progressionDecision, decision.action == .increaseLoad {
                    return min(decision.nextLoad, loadSanityCap)
                }
                let step = loadStep(for: baseLoad)
                return nextLoad(from: baseLoad, step: step) ?? baseLoad
            }()

            let pumpNote: String = {
                switch avgPump {
                case .good: return " Pump was good — this lift is responding well."
                case .excellent: return " Pump was excellent — strong stimulus confirmed."
                case .poor: return " Pump was poor — consider whether load, technique, or fatigue affected stimulus."
                default: return ""
                }
            }()

            let nextLoad = min(suggested, loadSanityCap)
            let msg: String
            if plannedWorkingSetCount >= 4 {
                msg = "Clean execution across the working sets at the target difficulty. Next session: \(String(format: "%.1f", nextLoad)). Volume beyond the primary sets is supplemental — don't let it drive the progression call.\(pumpNote)"
            } else {
                msg = "Clean execution across the working sets at the target difficulty. Next session: \(String(format: "%.1f", nextLoad)).\(pumpNote)"
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: nextLoad)
        }

        // 3.6) Hit planned reps + drop set finisher → increase
        if allPrimaryAtTop && rirOnTargetForIncrease && lastSetHadGoodDropSet {
            let suggested: Double = {
                if let decision = progressionDecision, decision.action == .increaseLoad {
                    return min(decision.nextLoad, loadSanityCap)
                }
                let step = loadStep(for: baseLoad)
                return nextLoad(from: baseLoad, step: step) ?? baseLoad
            }()
            let nextLoad = min(suggested, loadSanityCap)
            let msg = "Working sets hit the rep target and you extended with a drop set. Next session: \(String(format: "%.1f", nextLoad))."
            return CoachingRecommendation(message: msg, nextSuggestedLoad: nextLoad)
        }

        // 5) On target reps at roughly target difficulty → repeat
        let hitRepTarget = bestReps >= plannedBottomReps
        let nearTargetRIR: Bool = {
            guard let avgRIR = avgRIR else { return true }
            return abs(avgRIR - Double(targetRIR)) <= 0.5
        }()

        if hitRepTarget && nearTargetRIR {
            let msg: String
            if consecutiveCleanCount >= 1 {
                let nextLoad = String(format: "%.1f", (baseLoad + (minLoadIncrement ?? 2.5)))
                msg = "On target again — two clean sessions confirmed. Load steps up to \(nextLoad) next session."
            } else {
                msg = "On target at the planned difficulty. \(String(format: "%.1f", baseLoad)) again next session — one more clean session earns the increase."
            }
            return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
        }

        // 6) Catch-all
        let msg = "Performance didn't clearly support an increase. Hold this load and look for more consistent output next session before moving up."
        return CoachingRecommendation(message: msg, nextSuggestedLoad: baseLoad)
    }

    private static func formatLoad(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.1f", value)
    }
}
