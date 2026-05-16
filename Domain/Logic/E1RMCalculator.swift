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

    /// Decay-weighted e1RM across multiple sessions.
    ///
    /// Recent sessions contribute more than older ones using exponential decay.
    /// Default half-life of 21 days means a session from 3 weeks ago counts
    /// at 50% weight, 6 weeks ago at 25%, and so on.
    ///
    /// - Parameters:
    ///   - candidates: Array of (e1rm, sessionDate) pairs. Empty arrays return 0.
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
            // Clamp to non-negative — future dates treated as today
            let clampedDays = max(0.0, daysSince)
            let weight = pow(0.5, clampedDays / halfLifeDays)
            weightedSum += candidate.e1rm * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }
}
