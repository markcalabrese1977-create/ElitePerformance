import Foundation
import SwiftData

enum Apr21SessionHistoryRepairMigration {
    private static let completionKey = "apr21SessionHistoryRepairMigration.v3.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Apr 21 SessionHistory repair not needed.")
            return
        }

        let cal = Calendar.current
        guard let targetDate = cal.date(from: DateComponents(year: 2026, month: 4, day: 21)) else {
            print("⚠️ Apr 21 SessionHistory repair: could not construct target date.")
            return
        }
        let startOfDay = cal.startOfDay(for: targetDate)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

        // --- Restore session items from backup ground truth ---
        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { s in
                s.date >= startOfDay && s.date < endOfDay
            }
        )

        if let sessions = try? context.fetch(sessionDescriptor),
           let session = sessions.first(where: {
               $0.items.contains(where: { $0.exerciseId == "machine_hip_thrust" })
           }) {
            let restoreMap: [Int: (id: String, snapshot: String)] = [
                1: ("machine_hip_thrust",                         "Machine Hip Thrust"),
                2: ("custom_8e2ea611-f2e1-4338-9d64-8a269e7acc68", "Smith Machine Romanian Deadlift"),
                3: ("seated_leg_curl",                            "Seated Leg Curl"),
                4: ("cable_pull_through",                         "Cable Pull-Through"),
                5: ("cable_rope_crunch",                          "Cable Rope Crunch"),
                6: ("hanging_knee_raise",                         "Hanging Knee Raise")
            ]
            for item in session.items {
                if let correct = restoreMap[item.order] {
                    item.exerciseId = correct.id
                    item.exerciseNameSnapshot = correct.snapshot
                }
            }
        }

        // --- Restore SessionHistory from backup ground truth ---
        let histDescriptor = FetchDescriptor<SessionHistory>(
            predicate: #Predicate<SessionHistory> { h in
                h.date >= startOfDay && h.date < endOfDay
            }
        )

        if let histories = try? context.fetch(histDescriptor),
           let history = histories.first {

            let correct: [(name: String, muscle: String?, sets: Int, reps: Int, volume: Double)] = [
                ("Machine Hip Thrust",              "Glutes",     4, 32, 11200),
                ("Smith Machine Romanian Deadlift", "Hamstrings", 3, 24, 4944),
                ("Seated Leg Curl",                 "Hamstrings", 3, 27, 4050),
                ("Cable Pull-Through",              "Hamstrings", 2, 24, 3120),
                ("Cable Rope Crunch",               "Core",       3, 44, 5060),
                ("Hanging Knee Raise",              "Core",       3, 45, 0)
            ]

            history.exercises = correct.map {
                SessionHistoryExercise(
                    name: $0.name,
                    primaryMuscle: $0.muscle,
                    sets: $0.sets,
                    reps: $0.reps,
                    volume: $0.volume
                )
            }
            history.totalExercises = correct.count
            history.totalSets = correct.reduce(0) { $0 + $1.sets }
            history.totalVolume = correct.reduce(0) { $0 + $1.volume }
        }

        do {
            try context.save()
            print("✅ Apr 21 session items and SessionHistory restored from backup data.")
        } catch {
            print("⚠️ Apr 21 repair save failed: \(error)")
            return
        }

        UserDefaults.standard.set(true, forKey: completionKey)
    }
}
