// Domain/MechanicalLoadSharedStore.swift
import Foundation

/// Writes mechanical load scores to a shared App Group UserDefaults container
/// so HealthDashboard can read them without HealthKit restrictions.
///
/// Key format: "mechanicalLoad.YYYY-MM-DD" → Double
/// HealthDashboard reads from the same App Group using the same key format.
enum MechanicalLoadSharedStore {

    static let appGroupID = "group.com.markcalabrese.eliteperformance"
    static let keyPrefix = "mechanicalLoad."

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Write a mechanical load score for a given date.
    /// Uses the date as the key so multiple sessions on the same day accumulate.
    static func write(score: Double, for date: Date) {
        guard let defaults = sharedDefaults else {
            print("⚠️ MechanicalLoadSharedStore: App Group unavailable")
            return
        }
        let key = keyPrefix + dateKey(for: date)
        let existing = defaults.double(forKey: key)
        defaults.set(existing + score, forKey: key)
        print("✅ MechanicalLoadSharedStore: wrote \(String(format: "%.0f", score)) for \(dateKey(for: date)) (total: \(String(format: "%.0f", existing + score)))")
    }

    /// Read the mechanical load score for a given date.
    static func read(for date: Date) -> Double {
        guard let defaults = sharedDefaults else { return 0 }
        return defaults.double(forKey: keyPrefix + dateKey(for: date))
    }

    /// Read scores for a date range, returns [Date: Double].
    static func readRange(from start: Date, to end: Date) -> [Date: Double] {
        guard let defaults = sharedDefaults else { return [:] }
        var result: [Date: Double] = [:]
        let cal = Calendar.current
        var current = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        while current <= endDay {
            let key = keyPrefix + dateKey(for: current)
            let value = defaults.double(forKey: key)
            if value > 0 { result[current] = value }
            current = cal.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(86400)
        }
        return result
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
