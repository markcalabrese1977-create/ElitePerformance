// Domain/MechanicalLoadHealthKitService.swift
import Foundation
import HealthKit
import SwiftData

/// Calculates mechanical load from a completed session and writes it to HealthKit
/// as a custom quantity type. HealthDashboard reads this value without needing
/// access to ElitePerformance's internal data model.
///
/// Formula: Σ (load × reps × relative_intensity) per set
/// where relative_intensity = actualLoad / e1RM
/// This weights sets closer to failure more heavily than pure volume load.
enum MechanicalLoadHealthKitService {

    static let quantityTypeIdentifier = "com.calabrese.eliteperformance.mechanicalLoad"
    private static let store = HKHealthStore()

    // MARK: - Public API

    @MainActor
    static func writeAfterSession(_ session: Session) async {
        let score = calculateMechanicalLoad(from: session)
        guard score > 0 else {
            print("ℹ️ MechanicalLoad: score is 0, skipping write")
            return
        }

        // Write to shared App Group so HealthDashboard can read it.
        // Custom HKQuantityType identifiers are not supported for third-party
        // apps without special entitlements, so we use shared UserDefaults instead.
        let date = session.completedAt ?? session.date
        MechanicalLoadSharedStore.write(score: score, for: date)
    }

    // MARK: - Calculation

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

    // MARK: - HealthKit Write

    private static func requestWriteAuthorizationIfNeeded() async throws {
        guard let quantityType = HKObjectType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: quantityTypeIdentifier)
        ) else {
            throw MechanicalLoadError.unsupportedQuantityType
        }
        try await store.requestAuthorization(toShare: [quantityType], read: [])
    }

    private static func writeSample(score: Double, date: Date) async throws {
        guard let quantityType = HKQuantityType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: quantityTypeIdentifier)
        ) else {
            throw MechanicalLoadError.unsupportedQuantityType
        }

        let quantity = HKQuantity(unit: .count(), doubleValue: score)
        let sample = HKQuantitySample(
            type: quantityType,
            quantity: quantity,
            start: date,
            end: date
        )

        try await store.save(sample)
    }
}

// MARK: - Errors

enum MechanicalLoadError: Error {
    case unsupportedQuantityType
}
