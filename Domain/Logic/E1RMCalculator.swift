// Domain/Logic/E1RMCalculator.swift
import Foundation

/// Pure functions for estimated 1RM and RIR-adjusted load calculations.
/// Formula: Epley — e1RM = load × (1 + reps / 30)
struct E1RMCalculator {

    /// Estimated 1-rep max from a given load and rep count.
    static func e1RM(load: Double, reps: Int) -> Double {
        guard load > 0, reps > 0 else { return 0 }
        return load * (1.0 + Double(reps) / 30.0)
    }

    /// Target load for a given e1RM, rep count, and RIR target.
    /// Inverse Epley: load = e1RM / (1 + reps / 30), then adjusted for RIR.
    /// RIR adjustment: each RIR unit ≈ 2.5% reduction from theoretical max.
    static func load(for e1rm: Double, reps: Int, targetRIR: Int) -> Double {
        guard e1rm > 0, reps > 0 else { return 0 }
        let rirFactor = 1.0 - (Double(targetRIR) * 0.025)
        return (e1rm / (1.0 + Double(reps) / 30.0)) * rirFactor
    }

    /// Round a load to the nearest increment (e.g. 2.5, 5.0).
    static func rounded(_ load: Double, increment: Double) -> Double {
        guard increment > 0 else { return load }
        return (load / increment).rounded() * increment
    }

    /// Resolves the load to use for volume/e1RM math: the logged actual load if any,
    /// otherwise the user's bodyweight for known bodyweight exercises.
    static func effectiveLoad(actualLoad: Double, exerciseId: String, bodyWeight: Double?) -> Double {
        if actualLoad > 0 { return actualLoad }
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId), let bw = bodyWeight, bw > 0 { return bw }
        return 0
    }

    /// RIR-weighted e1RM from a single session's sets.
    ///
    /// Sets performed at or above the target RIR get full weight (1.0).
    /// Sets performed below target RIR (harder than intended) are downweighted,
    /// floored at 0.5 so they still contribute but don't dominate.
    ///
    /// This prevents a single pushed set at low RIR from inflating the e1RM
    /// estimate beyond what represents sustainable working capacity.
    ///
    /// - Parameters:
    ///   - sets: Array of (load, reps, actualRIR) tuples from a single session.
    ///   - targetRIR: The intended RIR for the session.
    /// - Returns: RIR-weighted average e1RM, or 0 if no valid sets.
    static func rirWeightedE1RM(
        from sets: [(load: Double, reps: Int, actualRIR: Int)],
        targetRIR: Int
    ) -> Double {
        let validSets = sets.filter { $0.load > 0 && $0.reps > 0 }
        guard !validSets.isEmpty else { return 0 }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for set in validSets {
            let setE1RM = e1RM(load: set.load, reps: set.reps)
            guard setE1RM > 0 else { continue }

            let weight: Double = {
                guard targetRIR > 0 else { return 1.0 }
                let ratio = Double(set.actualRIR) / Double(targetRIR)
                return max(0.5, min(1.0, ratio))
            }()

            weightedSum += setE1RM * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }

    /// Decay-weighted e1RM across multiple sessions.
    ///
    /// Recent sessions contribute more than older ones using exponential decay.
    /// Default half-life of 21 days means a session from 3 weeks ago counts
    /// at 50% weight, 6 weeks ago at 25%, and so on.
    ///
    /// - Parameters:
    ///   - candidates: Array of (e1rm, sessionDate) pairs.
    ///   - referenceDate: The date to measure recency from. Defaults to today.
    ///   - halfLifeDays: Days until a session's weight halves. Default 21 (3 weeks).
    /// - Returns: Weighted average e1RM, or 0 if no valid candidates.
    static func decayWeightedE1RM(
        from candidates: [(e1rm: Double, date: Date)],
        referenceDate: Date = Date(),
        halfLifeDays: Double = 21.0
    ) -> Double {
        guard !candidates.isEmpty, halfLifeDays > 0 else { return 0 }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for candidate in candidates {
            guard candidate.e1rm > 0 else { continue }
            let daysSince = referenceDate.timeIntervalSince(candidate.date) / 86400.0
            let clampedDays = max(0.0, daysSince)
            let weight = pow(0.5, clampedDays / halfLifeDays)
            weightedSum += candidate.e1rm * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }
}
