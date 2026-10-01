import Foundation
import SwiftData

/// One-shot, on-device driver for DUPMesoLengthConversion (10 -> 12 week DUP block).
///
/// SHIPS AS A DRY RUN. While `dryRun` is true this migration is strictly read-only: on the first
/// launch that finds an eligible active block it runs the planner, prints the full report (gates,
/// week-10 before/after table, weeks 11-12 clone summary, projected chains), stores the same text
/// in UserDefaults under `reportKey`, sets `dryRunLoggedKey`, and returns. A single install
/// therefore yields one on-device dry-run log and nothing else.
///
/// Applying is a separate, deliberate change: flip `dryRun` to false. Then, on the next launch,
/// it applies only if every gate passes, and `completionKey` is set ONLY after the save succeeds
/// (an unsafe plan or a failed save leaves it unset so it is retried, never silently skipped).
///
/// Time constraint: apply before the first week-7 session completes (Fri Nov 6, 2026), or week
/// 7's result will not reach week 10 (carry-forward looks its target up when the source session
/// is saved).
enum TwelveWeekMesoConversionMigration {
    /// Flip to false (its own commit) to apply. Read-only while true.
    static let dryRun = true

    /// Bump this whenever the dry-run REPORT changes (new gates, columns, rules, copy semantics):
    /// the logged flag and stored report are keyed by it, so a changed report logs again on the
    /// next launch instead of being swallowed by the previous install's "already logged" flag.
    /// v2: loads are copied from the source week (v1 zeroed them) and the report shows
    /// before -> after loads, block id, gates, item table and chain table.
    static let reportVersion = "v2"

    static let completionKey = "twelveWeekMesoConversion.v1.completed"
    static var dryRunLoggedKey: String { "twelveWeekMesoConversion.v1.dryRunLogged.\(reportVersion)" }
    static var reportKey: String { "twelveWeekMesoConversion.v1.dryRunReport.\(reportVersion)" }

    static func runIfNeeded(in context: ModelContext, dryRun: Bool = TwelveWeekMesoConversionMigration.dryRun) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: completionKey) {
            print("ℹ️ 12-week conversion not needed.")
            return
        }
        if dryRun, defaults.bool(forKey: dryRunLoggedKey) {
            print("ℹ️ 12-week conversion dry run already logged on this install.")
            return
        }

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ 12-week conversion: could not fetch meso blocks — nothing done.")
            return
        }
        let candidates = blocks.filter {
            $0.status == .active && !$0.isMaintenance && $0.totalWeeks == DUPMesoLengthConversion.sourceTotalWeeks
        }
        guard candidates.count == 1, let block = candidates.first else {
            // No eligible block yet (fresh install / empty store) or ambiguous: leave every flag
            // unset so it is evaluated again on a later launch.
            print("ℹ️ 12-week conversion: \(candidates.count) eligible active 10-week blocks — nothing done, will retry.")
            return
        }

        let report = DUPMesoLengthConversion.dryRun(block: block, context: context)
        print("🧪 12-week conversion DRY RUN for '\(block.name)':\n\(report.text)")

        if dryRun {
            defaults.set(report.text, forKey: reportKey)
            defaults.set(true, forKey: dryRunLoggedKey)
            print("🧪 12-week conversion dry run logged (read-only; nothing was written to the store).")
            return
        }

        guard report.isSafe else {
            print("⛔️ 12-week conversion refused: \(report.blockers.count) blocker(s). Flags left unset; will retry.")
            return
        }
        do {
            let applied = try DUPMesoLengthConversion.apply(block: block, context: context)
            guard applied.didWrite else {
                print("⚠️ 12-week conversion: apply wrote nothing. Flags left unset.")
                return
            }
            // Only after the save inside apply() succeeded.
            defaults.set(true, forKey: completionKey)
            print("✅ 12-week conversion applied:\n\(applied.lines.last ?? "")")
        } catch {
            print("⚠️ 12-week conversion save failed: \(error). Flag NOT set; will retry.")
        }
    }
}
