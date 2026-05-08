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
}
