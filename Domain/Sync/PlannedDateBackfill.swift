import Foundation
import SwiftData

/// One-time backfill for `Session.plannedDate`.
///
/// `plannedDate` (the day a session is scheduled for, which completion never changes) was added after sessions
/// already existed, so they decode with nil. On a PLANNED session `date` still is the scheduled day, so it is copied
/// across. A completed or in-progress session has no recoverable planned day (`date` was overwritten with the
/// completion time), so it keeps nil, which readers treat as "unknown" and never as "on time" or "missed".
///
/// Scope is deliberately narrow: only sessions with a nil `plannedDate` whose status is `.planned`. No other field
/// changes (not even `updatedAt`). Idempotent. On a store with no sessions yet (a fresh install, before a restore) it
/// does nothing and does NOT mark itself done, so it still runs after a restore.
enum PlannedDateBackfill {
    private static let completionKey = "plannedDateBackfill.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ plannedDate backfill not needed.")
            return
        }

        guard let sessions = try? context.fetch(FetchDescriptor<Session>()) else {
            print("⚠️ plannedDate backfill failed: could not fetch sessions.")
            return
        }
        guard !sessions.isEmpty else {
            print("ℹ️ plannedDate backfill: no sessions yet, will run once there are.")
            return
        }

        var changedCount = 0
        for session in sessions where session.status == .planned && session.plannedDate == nil {
            session.plannedDate = session.date
            changedCount += 1
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ plannedDate backfill completed. Updated \(changedCount) sessions.")
            } else {
                print("ℹ️ plannedDate backfill found nothing to update.")
            }
            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ plannedDate backfill save failed: \(error)")
        }
    }
}
