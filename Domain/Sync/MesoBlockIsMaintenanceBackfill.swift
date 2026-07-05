import Foundation
import SwiftData

/// One-time backfill for `MesoBlock.isMaintenance`.
///
/// The `isMaintenance` flag was added after maintenance blocks already existed
/// in the wild. Those older blocks defaulted to `isMaintenance == false`
/// (migration-safe default), which hides them from features that gate on the
/// flag — e.g. the "Extend Maintenance Block" action in MesoSummaryView.
///
/// Both maintenance seeder paths hard-code the block name `"Maintenance Block"`,
/// so an exact name match reliably identifies pre-flag maintenance blocks. We
/// deliberately use exact-equals (not `contains("maintenance")`) so a regular
/// meso a user happened to rename can never be wrongly promoted, and we only
/// ever set `true` — never `false` — so a correctly-flagged block is untouched.
enum MesoBlockIsMaintenanceBackfill {
    private static let completionKey = "mesoBlockIsMaintenanceBackfill.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ MesoBlock isMaintenance backfill not needed.")
            return
        }

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ MesoBlock isMaintenance backfill failed: could not fetch meso blocks.")
            return
        }

        var changedCount = 0

        for block in blocks where !block.isMaintenance && block.name == "Maintenance Block" {
            block.isMaintenance = true
            changedCount += 1
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ MesoBlock isMaintenance backfill completed. Updated \(changedCount) blocks.")
            } else {
                print("ℹ️ MesoBlock isMaintenance backfill found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ MesoBlock isMaintenance backfill save failed: \(error)")
        }
    }
}
