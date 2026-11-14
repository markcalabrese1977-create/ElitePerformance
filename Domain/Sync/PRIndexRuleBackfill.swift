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
    /// The version of the PR rule this backfill rebuilds for. BUMP IT whenever the record rule changes (what counts as a
    /// record, a baseline, or a "best set"): every device whose stored version is lower rebuilds once at its next launch.
    ///   v1: best e1RM from sets of 12 reps or fewer (`BestSetRule`).
    ///   v2: a lift's baseline is its first-ever trained session at any rep count (`PersonalRecords.events`), so the
    ///       record events, and the `isPR` copy derived from them, changed for a lift first trained with long sets.
    static let currentVersion = 2

    private static let versionKey = "prIndexRuleVersion"
    /// Written by the original (unversioned) backfill; a device that has it ran v1.
    private static let legacyV1Key = "prIndexTwelveRepRule.v1.completed"

    /// The rule version this device has applied: 0 = never, 1 = the unversioned original, else the stored number.
    static var storedVersion: Int {
        let d = UserDefaults.standard
        let v = d.integer(forKey: versionKey)
        if v > 0 { return v }
        return d.bool(forKey: legacyV1Key) ? 1 : 0
    }

    /// Test support: forget what this device applied.
    static func resetStoredVersion() {
        UserDefaults.standard.removeObject(forKey: versionKey)
        UserDefaults.standard.removeObject(forKey: legacyV1Key)
    }

    /// Test support: pretend this device ran the original v1 backfill.
    static func markAppliedUnderV1() {
        UserDefaults.standard.removeObject(forKey: versionKey)
        UserDefaults.standard.set(true, forKey: legacyV1Key)
    }

    static func runIfNeeded(in context: ModelContext) {
        let stored = storedVersion
        if stored >= currentVersion {
            BackfillLog.note("ℹ️ PRIndex rule v\(currentVersion) rebuild not needed.")
            return
        }
        guard let sessions = try? context.fetch(FetchDescriptor<Session>()), !sessions.isEmpty else {
            BackfillLog.note("ℹ️ PRIndex rule rebuild: no sessions yet, will run once there are.")
            return
        }
        do {
            try PRRebuildService.rebuild(in: context, recomputeFlags: true)
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
            BackfillLog.note("✅ PRIndex rebuilt under rule v\(currentVersion) (was \(stored == 0 ? "never run" : "v\(stored)")).")
        } catch {
            BackfillLog.note("⚠️ PRIndex rule rebuild failed: \(error)")
        }
    }
}
