// Domain/MechanicalLoadSharedStore.swift
import Foundation

/// Projects mechanical load totals to a shared App Group so HealthDashboard
/// can read them. NOT a source of truth — SessionHistory.mechanicalLoad is.
/// Key format: "mechanicalLoad.YYYY-MM-DD" → Double (whole-day total).
enum MechanicalLoadSharedStore {

    static let appGroupID = "group.com.markcalabrese.eliteperformance"
    static let keyPrefix = "mechanicalLoad."

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Assign the whole-day total for a date. Idempotent — replaces, never adds.
    /// Removes the key when total is 0 so stale days don't linger.
    static func set(total: Double, for date: Date) {
        guard let defaults = sharedDefaults else {
            print("⚠️ MechanicalLoadSharedStore: App Group unavailable")
            return
        }
        let key = keyPrefix + dateKey(for: date)
        if total > 0 {
            defaults.set(total, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func read(for date: Date) -> Double {
        guard let defaults = sharedDefaults else { return 0 }
        return defaults.double(forKey: keyPrefix + dateKey(for: date))
    }

    static func readRange(from start: Date, to end: Date) -> [Date: Double] {
        guard let defaults = sharedDefaults else { return [:] }
        var result: [Date: Double] = [:]
        let cal = Calendar.current
        var current = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        while current <= endDay {
            let value = defaults.double(forKey: keyPrefix + dateKey(for: current))
            if value > 0 { result[current] = value }
            current = cal.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(86400)
        }
        return result
    }

    /// Remove every mechanicalLoad.* key. Used before a full rebuild.
    static func clearAll() {
        guard let defaults = sharedDefaults else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
