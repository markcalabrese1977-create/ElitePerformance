import Foundation
import SwiftData

/// One-time rebuild of `PRIndex` under the 12-rep record rule, and of `SessionItem.isPR` (derived from the same records).
///
/// A record is the best e1RM of a set of 12 reps or fewer (`BestSetRule`). Index rows written before that rule can hold
/// a long set's inflated "best" (a 20-rep set), so the index is rebuilt once from the completed sessions with the single
/// PR definition (`PRRebuildService`), which also recomputes every completed session's `isPR` flag so the flags match the
/// index. `PRIndex` is derived data and is not part of the backup; `isPR` is (a backup round-trips it as carried, so an import
/// does not rewrite it), and it is recomputed here once per install. On a store with no sessions (a fresh install, before a restore) it does nothing and does NOT mark
/// itself done; a backup import rebuilds the index itself.
enum PRIndexRuleBackfill {
    private static let completionKey = "prIndexTwelveRepRule.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            BackfillLog.note("ℹ️ PRIndex 12-rep rebuild not needed.")
            return
        }
        guard let sessions = try? context.fetch(FetchDescriptor<Session>()), !sessions.isEmpty else {
            BackfillLog.note("ℹ️ PRIndex 12-rep rebuild: no sessions yet, will run once there are.")
            return
        }
        do {
            try PRRebuildService.rebuild(in: context, recomputeFlags: true)
            UserDefaults.standard.set(true, forKey: completionKey)
            BackfillLog.note("✅ PRIndex rebuilt under the 12-rep rule.")
        } catch {
            BackfillLog.note("⚠️ PRIndex 12-rep rebuild failed: \(error)")
        }
    }
}
