// Domain/MechanicalLoadHealthKitService.swift
import Foundation

/// Calculates mechanical load from a completed session.
///
/// Formula: Σ (load × reps × relative_intensity) per set
/// where relative_intensity = actualLoad / e1RM
/// This weights sets closer to failure more heavily than pure volume load.
///
/// The result is projected to the App Group via MechanicalLoadProjector;
/// HealthDashboard reads it from shared UserDefaults, not HealthKit.
enum MechanicalLoadHealthKitService {

    static func calculateMechanicalLoad(from session: Session) -> Double {
        var total = 0.0

        for item in session.items {
            let setCount = min(item.actualLoads.count, item.actualReps.count)
            guard setCount > 0 else { continue }

            for idx in 0..<setCount {
                let load = item.actualLoads[idx]
                let reps = item.actualReps[idx]
                guard load > 0, reps > 0 else { continue }

                let e1rm = E1RMCalculator.e1RM(load: load, reps: reps)
                guard e1rm > 0 else { continue }

                let relativeIntensity = load / e1rm
                total += load * Double(reps) * relativeIntensity
            }
        }

        return total.rounded()
    }
}
