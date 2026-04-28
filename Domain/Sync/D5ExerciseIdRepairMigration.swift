import Foundation
import SwiftData

enum D5ExerciseIdRepairMigration {
    private static let completionKey = "d5ExerciseIdRepairMigration.v3.completed"

    private static let correctOrderMap: [Int: (id: String, snapshot: String)] = [
        1: ("machine_hip_thrust",  "Machine Hip Thrust"),
        2: ("romanian_deadlift",   "Romanian Deadlift"),
        3: ("seated_leg_curl",     "Seated Leg Curl"),
        4: ("cable_pull_through",  "Cable Pull-Through"),
        5: ("cable_rope_crunch",   "Cable Rope Crunch"),
        6: ("hanging_knee_raise",  "Hanging Knee Raise")
    ]

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ D5 exercise ID repair not needed.")
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ D5 exercise ID repair failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        let cal = Calendar.current
        let cutoff = cal.date(from: DateComponents(year: 2026, month: 4, day: 28))!

        for session in sessions {
            // Only fix planned sessions — never touch completed sessions with real logged data
            guard session.status == .planned else { continue }

            let items = session.items.sorted { $0.order < $1.order }

            // Only target D5 sessions
            guard items.first?.exerciseId == "machine_hip_thrust" else { continue }

            // Only sessions from Apr 28 onwards
            guard cal.startOfDay(for: session.date) >= cal.startOfDay(for: cutoff) else { continue }

            for item in items {
                guard let correct = correctOrderMap[item.order] else { continue }

                var changed = false
                if item.exerciseId != correct.id {
                    item.exerciseId = correct.id
                    changed = true
                }
                if item.exerciseNameSnapshot != correct.snapshot {
                    item.exerciseNameSnapshot = correct.snapshot
                    changed = true
                }
                if changed { changedCount += 1 }
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ D5 exercise ID repair completed. Updated \(changedCount) items.")
            } else {
                print("ℹ️ D5 exercise ID repair found nothing to update.")
            }
            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ D5 exercise ID repair save failed: \(error)")
        }
    }
}
