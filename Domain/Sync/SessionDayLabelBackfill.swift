import Foundation
import SwiftData

enum SessionDayLabelBackfill {
    private static let completionKey = "sessionDayLabelBackfill.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Session dayLabel backfill not needed.")
            return
        }

        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ Session dayLabel backfill failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        for session in sessions {
            let existing = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard existing.isEmpty else { continue }

            let notes = session.sessionNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !notes.isEmpty else { continue }

            // Expected DUP format:
            // "Pull · Strength wave"
            // "Upper A · Hypertrophy wave"
            let parts = notes.components(separatedBy: " · ")
            guard let first = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !first.isEmpty else { continue }

            session.dayLabel = first
            changedCount += 1
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ Session dayLabel backfill completed. Updated \(changedCount) sessions.")
            } else {
                print("ℹ️ Session dayLabel backfill found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Session dayLabel backfill save failed: \(error)")
        }
    }
}
