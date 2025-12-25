//
//  ProgressionEngine.swift
//  ElitePerformance
//
//  Global progression engine ("coach brain") + meso-specific profiles.
//  This file is intentionally pure logic with no SwiftUI/SwiftData dependencies.
//

import Foundation

// MARK: - Basic data structures

/// Snapshot of a single set used by the progression engine.
/// Callers can map from whatever Set model you use into this.
struct SetSnapshot {
    /// Working weight for the set (lbs or kg – be consistent across the app).
    let load: Double
    /// Completed reps.
    let reps: Int
    /// Logged RIR (Reps In Reserve). Optional so you can still run logic without it.
    let rir: Double?
}

/// Where you are within a mesocycle.
/// Your 8-week blocks can map week numbers to these phases.
enum MesoPhase {
    case early      // Weeks 1–3
    case mid        // Weeks 4–5
    case late       // Weeks 6–7 (1 RIR bias kicks in)
    case deload     // Week 8 or formal deload
}

/// High-level grouping for how we *treat* an exercise in progression logic.
enum ExerciseCluster {
    case primaryChestPress      // Bench, main incline, etc.
    case secondaryPressOrArms   // Secondary chest, triceps compounds
    case primaryLeg             // Hack / leg press
    case pumpIsolation          // Flys, curls, lateral raises, calf raises
    case lowBackStability       // Pull-throughs, back extensions, carries, core
}

/// Configuration knobs for how an exercise (or cluster) should progress.
struct ProgressionConfig {
    /// Target rep range for working sets (e.g. 6–8, 8–12, 10–15).
    let repRange: ClosedRange<Int>

    /// Base target RIR for the *early* meso phase.
    /// This will be adjusted automatically for mid/late based on global rules.
    let baseTargetRIR: Double

    /// Standard load increment when performance is clearly strong.
    /// Example: 5.0 for big compounds, 2.5 for DB work, 1.0 for isolation/cables.
    let primaryLoadIncrement: Double

    /// Optional smaller increment for more conservative bumps on good-but-not-perfect days.
    let secondaryLoadIncrement: Double

    /// Minimum and maximum working sets we want to live between for this movement.
    let minSets: Int
    let maxSets: Int

    /// Whether the engine is allowed to *increase* set count for this movement.
    let allowSetIncrease: Bool

    /// Whether the engine is allowed to *decrease* load (useful for low-back or sensitive movements).
    let allowLoadDecrease: Bool

    /// Flag for "tech / health first" exercises. For these, we bias strongly toward
    /// holding or even decreasing load rather than chasing progression.
    let isLowBackOrStability: Bool
}

/// Result from the progression engine for a single exercise.
struct ProgressionDecision {
    /// Suggested next working load.
    let nextLoad: Double
    /// Suggested working set count for the next session.
    let nextSets: Int
    /// High-level action label for UI display or logging.
    let action: ProgressionAction
    /// Human-readable notes you can show in the app ("Hold – mid-range reps at target RIR.", etc.).
    let notes: [String]
}

/// Coarse-grained label for what the engine is doing.
enum ProgressionAction: String {
    case increaseLoad = "Increase Load"
    case holdLoad = "Hold Load"
    case reduceLoad = "Reduce Load"
    case reduceSets = "Reduce Sets"
    case deload = "Deload"
}

// MARK: - Global engine (your overlay rules)

struct ProgressionEngine {

    /// Main entry point.
    ///
    /// - Parameters:
    ///   - history: The sets from the most recent session for this exercise.
    ///   - currentSets: How many working sets you just did (3 for "3 to grow", etc.).
    ///   - config: ProgressionConfig describing how this exercise *should* behave.
    ///   - phase: Where we are in the meso (early / mid / late / deload).
    ///
    /// - Returns: A ProgressionDecision with nextLoad, nextSets, action, and notes.
    static func suggestNext(
        history: [SetSnapshot],
        currentSets: Int,
        config: ProgressionConfig,
        phase: MesoPhase
    ) -> ProgressionDecision {

        guard let lastSet = history.last else {
            // No history (new exercise) → conservative suggestion:
            // keep load and sets as-is; let user pick a starting point.
            return ProgressionDecision(
                nextLoad: 0,
                nextSets: max(config.minSets, currentSets),
                action: .holdLoad,
                notes: ["No prior data – pick a confident starting load and stay within \(config.repRange.lowerBound)–\(config.repRange.upperBound) reps."]
            )
        }

        let effectiveTargetRIR = adjustedTargetRIR(for: phase, base: config.baseTargetRIR)
        let repRange = config.repRange

        let avgRIR = averageRIR(from: history)
        let bestSet = bestPerformanceSet(from: history)

        let lastLoad = lastSet.load
        let currentLoad = lastLoad

        // Early exit for deload phase.
        if case .deload = phase {
            let lighterLoad = max(0, currentLoad - config.secondaryLoadIncrement)
            let reducedSets = max(config.minSets, currentSets - 1)
            return ProgressionDecision(
                nextLoad: lighterLoad,
                nextSets: reducedSets,
                action: .deload,
                notes: ["Deload phase – reduce load and/or sets regardless of performance."]
            )
        }

        // Low-back / stability movements: quality over progression.
        if config.isLowBackOrStability {
            // If RIR slipped too low or reps dropped below range, bias toward *less* load.
            if let avgRIR, avgRIR < effectiveTargetRIR - 0.5 || bestSet.reps < repRange.lowerBound {
                let lighter = config.allowLoadDecrease ? max(0, currentLoad - config.secondaryLoadIncrement) : currentLoad
                return ProgressionDecision(
                    nextLoad: lighter,
                    nextSets: min(currentSets, config.maxSets),
                    action: config.allowLoadDecrease ? .reduceLoad : .holdLoad,
                    notes: ["Low-back / stability day – prioritize control. Slight regression or load reduction is fine."]
                )
            } else {
                return ProgressionDecision(
                    nextLoad: currentLoad,
                    nextSets: min(currentSets, config.maxSets),
                    action: .holdLoad,
                    notes: ["Low-back / stability day – hold load, keep reps in \(repRange.lowerBound)–\(repRange.upperBound) with \(String(format: "%.1f", effectiveTargetRIR)) RIR."]
                )
            }
        }

        // General hypertrophy progression
        let repsAtTop = bestSet.reps >= repRange.upperBound
        let repsBelowBottom = bestSet.reps < repRange.lowerBound

        // Use average RIR when available, otherwise treat as neutral.
        let rir = avgRIR ?? effectiveTargetRIR

        // 1) Strong performance: near/at top of range AND RIR above target → increase load.
        if repsAtTop && rir >= effectiveTargetRIR + 0.3 {
            let increment = config.primaryLoadIncrement
            let newLoad = currentLoad + increment

            // Optional: consider adding a set if we're not at maxSets and performance is consistently strong.
            let newSets: Int
            if config.allowSetIncrease && currentSets < config.maxSets && rir >= effectiveTargetRIR + 0.7 {
                newSets = currentSets + 1
            } else {
                newSets = currentSets
            }

            return ProgressionDecision(
                nextLoad: newLoad,
                nextSets: newSets,
                action: .increaseLoad,
                notes: [
                    "Strong performance: top of rep range with RIR ~\(String(format: "%.1f", rir)) (target \(String(format: "%.1f", effectiveTargetRIR))).",
                    "Increase load by \(increment).",
                    newSets > currentSets ? "Add one set (3-to-grow-1-to-know push set unlocked)." : "Keep set count the same."
                ]
            )
        }

        // 2) Mid-range performance: within rep range, RIR around target → hold load.
        if repRange.contains(bestSet.reps) && abs(rir - effectiveTargetRIR) <= 0.5 {
            return ProgressionDecision(
                nextLoad: currentLoad,
                nextSets: currentSets,
                action: .holdLoad,
                notes: ["Solid session: reps in range and RIR close to target. Hold load and repeat for more data."]
            )
        }

        // 3) Slightly underperforming: reps in range but RIR a bit too low (harder than target).
        if repRange.contains(bestSet.reps) && rir < effectiveTargetRIR - 0.5 {
            let maybeReduceSets = currentSets > config.minSets
            return ProgressionDecision(
                nextLoad: currentLoad,
                nextSets: maybeReduceSets ? (currentSets - 1) : currentSets,
                action: maybeReduceSets ? .reduceSets : .holdLoad,
                notes: [
                    "Session was harder than planned (RIR ~\(String(format: "%.1f", rir)) vs target \(String(format: "%.1f", effectiveTargetRIR))).",
                    maybeReduceSets ? "Reduce one set next time to manage fatigue." : "Keep sets the same but watch fatigue."
                ]
            )
        }

        // 4) Clearly under range or very low RIR → consider load reduction if allowed.
        if repsBelowBottom || rir < effectiveTargetRIR - 1.0 {
            if config.allowLoadDecrease {
                let newLoad = max(0, currentLoad - config.secondaryLoadIncrement)
                return ProgressionDecision(
                    nextLoad: newLoad,
                    nextSets: max(config.minSets, currentSets - 1),
                    action: .reduceLoad,
                    notes: [
                        "Performance dropped (reps < \(repRange.lowerBound) or RIR well below target).",
                        "Reduce load slightly and consider one fewer set."
                    ]
                )
            } else {
                let newSets = max(config.minSets, currentSets - 1)
                return ProgressionDecision(
                    nextLoad: currentLoad,
                    nextSets: newSets,
                    action: .reduceSets,
                    notes: [
                        "Performance dropped but load reduction disabled for this movement.",
                        "Reduce set count to manage fatigue."
                    ]
                )
            }
        }

        // Default: conservative hold.
        return ProgressionDecision(
            nextLoad: currentLoad,
            nextSets: currentSets,
            action: .holdLoad,
            notes: ["Mixed signals – hold load and sets, gather more data next session."]
        )
    }

    // MARK: - Helpers

    private static func adjustedTargetRIR(for phase: MesoPhase, base: Double) -> Double {
        switch phase {
        case .early:
            return base       // e.g. 2–3 RIR
        case .mid:
            return max(1.5, base - 0.3)  // drift slightly lower
        case .late:
            // Late-meso 1 RIR bias from your global rules.
            return max(1.0, base - 1.0)
        case .deload:
            return base + 1.0 // Not really used, but conceptually higher RIR.
        }
    }

    private static func averageRIR(from sets: [SetSnapshot]) -> Double? {
        let values = sets.compactMap { $0.rir }
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0.0, +)
        return sum / Double(values.count)
    }

    /// "Best" set as the one with the heaviest load, then most reps.
    private static func bestPerformanceSet(from sets: [SetSnapshot]) -> SetSnapshot {
        return sets.max(by: { lhs, rhs in
            if lhs.load == rhs.load {
                return lhs.reps < rhs.reps
            } else {
                return lhs.load < rhs.load
            }
        }) ?? sets[sets.startIndex]
    }
}

// MARK: - Meso-specific profile for 8-week Chest/Bis/Tris + Low-Back block

/// Profiles for your current 8-week meso.
/// These are *data only* – the engine logic above stays global.
struct ChestArmsLowBackMesoProfile {

    /// Map absolute week index (1-based) to a meso phase.
    /// This meso is 11 weeks total: 10 working + 1 deload.
    ///
    /// - Weeks 1–3: Early accumulation (higher reps, 2–3 RIR).
    /// - Weeks 4–6: Mid meso (steady progression, 1–2 RIR).
    /// - Weeks 7–10: Late / peak (heavier, 0–1 RIR slots).
    /// - Week 11+: Deload / reset.
    static func phase(forWeek week: Int) -> MesoPhase {
        switch week {
        case 1...3:
            return .early        // accumulation block
        case 4...6:
            return .mid          // building block
        case 7...10:
            return .late         // peak / overreach block
        default:
            return .deload       // week 11 and anything beyond
        }
    }
    
    /// Total planned length for this meso (weeks).
    static let totalWeeks: Int = 11

    /// Primary chest presses (bench, main incline).
    static let primaryChest = ProgressionConfig(
        repRange: 6...10,
        baseTargetRIR: 2.5,             // Early meso: 2–3 RIR
        primaryLoadIncrement: 5.0,      // 5 lb jumps (BB), or equivalent
        secondaryLoadIncrement: 2.5,    // more conservative option
        minSets: 3,
        maxSets: 4,
        allowSetIncrease: true,
        allowLoadDecrease: true,
        isLowBackOrStability: false
    )

    /// Secondary presses and bigger tricep compounds (machine press, Smith dips).
    static let secondaryPressOrArms = ProgressionConfig(
        repRange: 8...12,
        baseTargetRIR: 2.5,
        primaryLoadIncrement: 5.0,
        secondaryLoadIncrement: 2.5,
        minSets: 2,
        maxSets: 4,
        allowSetIncrease: true,
        allowLoadDecrease: true,
        isLowBackOrStability: false
    )

    /// Primary leg movements (hack squat, leg press).
    static let primaryLeg = ProgressionConfig(
        repRange: 8...12,
        baseTargetRIR: 2.5,
        primaryLoadIncrement: 10.0,     // Larger jumps, but used less often
        secondaryLoadIncrement: 5.0,
        minSets: 3,
        maxSets: 4,
        allowSetIncrease: false,        // Volume is already high – no auto set add
        allowLoadDecrease: true,
        isLowBackOrStability: false
    )

    /// Pump/isolation (flys, curls, lateral raises, calf raises).
    static let pumpIsolation = ProgressionConfig(
        repRange: 10...15,
        baseTargetRIR: 2.5,
        primaryLoadIncrement: 2.5,
        secondaryLoadIncrement: 1.0,
        minSets: 2,
        maxSets: 4,
        allowSetIncrease: true,
        allowLoadDecrease: true,
        isLowBackOrStability: false
    )

    /// Low-back functional day (pull-throughs, bench back extensions, Pallof, carries).
    /// This is intentionally non-progressive: quality > load.
    static let lowBackStability = ProgressionConfig(
        repRange: 8...15,
        baseTargetRIR: 3.0,             // Even more conservative
        primaryLoadIncrement: 0.0,      // We effectively never "chase" heavier here
        secondaryLoadIncrement: 2.5,
        minSets: 2,
        maxSets: 3,
        allowSetIncrease: false,
        allowLoadDecrease: true,
        isLowBackOrStability: true
    )

    /// Convenience accessor by cluster.
    static func config(for cluster: ExerciseCluster) -> ProgressionConfig {
        switch cluster {
        case .primaryChestPress:
            return primaryChest
        case .secondaryPressOrArms:
            return secondaryPressOrArms
        case .primaryLeg:
            return primaryLeg
        case .pumpIsolation:
            return pumpIsolation
        case .lowBackStability:
            return lowBackStability
        }
    }
}
// MARK: - Adapters from SessionItem → ProgressionEngine

extension SessionItem {
    /// Convert the logged data for this exercise into the snapshots
    /// expected by ProgressionEngine.
    ///
    /// Uses only sets where both load and reps > 0, so half-logged sets
    /// don't pollute the decision.
    func toSetSnapshots() -> [SetSnapshot] {
        let repCount = actualReps.count
        let loadCount = actualLoads.count
        let rirCount = actualRIRs.count

        let count = min(repCount, min(loadCount, rirCount))
        guard count > 0 else { return [] }

        var result: [SetSnapshot] = []
        result.reserveCapacity(count)

        for idx in 0..<count {
            let reps = actualReps[idx]
            let load = actualLoads[idx]
            let rirInt = actualRIRs[idx]

            // Treat as a working set only if we have real data.
            if reps > 0 && load > 0 {
                result.append(
                    SetSnapshot(
                        load: load,
                        reps: reps,
                        rir: Double(rirInt)
                    )
                )
            }
        }

        return result
    }

    /// Convenience to run the engine for this exercise in the
    /// Chest/Bis/Tris + Low-Back meso.
    ///
    /// - weekIndex: 1–8 within the meso.
    /// - cluster: how we want to *treat* this exercise (primary chest,
    ///            leg compound, low-back stability, etc.).
    func progressionDecisionForChestArmsMeso(
        weekIndex: Int,
        cluster: ExerciseCluster
    ) -> ProgressionDecision? {
        let snapshots = toSetSnapshots()
        guard !snapshots.isEmpty else {
            return nil
        }

        let phase = ChestArmsLowBackMesoProfile.phase(forWeek: weekIndex)
        let config = ChestArmsLowBackMesoProfile.config(for: cluster)

        return ProgressionEngine.suggestNext(
            history: snapshots,
            currentSets: targetSets,
            config: config,
            phase: phase
        )
    }
}
