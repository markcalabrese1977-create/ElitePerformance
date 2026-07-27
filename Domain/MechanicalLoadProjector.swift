// Domain/MechanicalLoadProjector.swift
import Foundation
import SwiftData

/// Projects SessionHistory.mechanicalLoad into the App Group. SessionHistory
/// is the source of truth; this just mirrors day-totals out for HealthDashboard.
enum MechanicalLoadProjector {

    /// Recompute and assign one day's total from all SessionHistory rows on that day.
    static func projectDay(_ date: Date, in context: ModelContext) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }

        let descriptor = FetchDescriptor<SessionHistory>(
            predicate: #Predicate<SessionHistory> { $0.date >= start && $0.date < end }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        let total = rows.reduce(0.0) { $0 + ($1.mechanicalLoad ?? 0) }
        MechanicalLoadSharedStore.set(total: total, for: start)
    }

    /// Full rebuild: clear the App Group, then re-project every day present in history.
    static func projectAll(in context: ModelContext) {
        MechanicalLoadSharedStore.clearAll()
        let rows = (try? context.fetch(FetchDescriptor<SessionHistory>())) ?? []
        let cal = Calendar.current
        var totalsByDay: [Date: Double] = [:]
        for row in rows {
            let day = cal.startOfDay(for: row.date)
            totalsByDay[day, default: 0] += (row.mechanicalLoad ?? 0)
        }
        for (day, total) in totalsByDay {
            MechanicalLoadSharedStore.set(total: total, for: day)
        }
    }
}
