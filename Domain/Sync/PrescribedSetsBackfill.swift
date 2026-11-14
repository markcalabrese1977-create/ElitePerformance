import Foundation
import SwiftData

/// One-time backfill for `SessionItem.prescribedSets`.
///
/// `prescribedSets` (the number of back-off sets the program prescribes, as opposed to what a
/// session ran after an in-session Add Set) was added after items already existed, so they decode
/// with nil. On a PLANNED session `targetSets` is the prescription, so it is copied across; that
/// is what lets the next-meso clone tell the prescription from an Add Set on an older, completed
/// session of the same letter (`SessionItemEditService.prescribedSetCount`).
///
/// Scope is deliberately narrow: only items with a nil `prescribedSets`, only in sessions whose
/// status is `.planned`. An in-progress or completed session may already carry an Add Set in its
/// `targetSets`, so it is never read as the prescription and never touched. No other field changes
/// (not even `updatedAt`). Idempotent. On a store with no sessions yet (a fresh install, before a
/// restore) it does nothing and does NOT mark itself done, so it still runs after a restore.
enum PrescribedSetsBackfill {
    private static let completionKey = "prescribedSetsBackfill.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            BackfillLog.note("ℹ️ prescribedSets backfill not needed.")
            return
        }

        guard let sessions = try? context.fetch(FetchDescriptor<Session>()) else {
            BackfillLog.note("⚠️ prescribedSets backfill failed: could not fetch sessions.")
            return
        }
        guard !sessions.isEmpty else {
            BackfillLog.note("ℹ️ prescribedSets backfill: no sessions yet, will run once there are.")
            return
        }

        var changedCount = 0
        for session in sessions where session.status == .planned {
            for item in session.items where item.prescribedSets == nil {
                item.prescribedSets = item.targetSets
                changedCount += 1
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                BackfillLog.note("✅ prescribedSets backfill completed. Updated \(changedCount) items.")
            } else {
                BackfillLog.note("ℹ️ prescribedSets backfill found nothing to update.")
            }
            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            BackfillLog.note("⚠️ prescribedSets backfill save failed: \(error)")
        }
    }
}
