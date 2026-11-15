import Foundation
import SwiftData

/// The analytics start date (`AppState.activeMesoStartDate`, mirrored to the defaults) follows the ACTIVE block's own start date.
/// Seeding sets it; this re-syncs it silently at launch if the two ever differ (a restore from an older backup, an old repair),
/// which is what the Settings "Sync meso start date" button used to do by hand. It changes only that date: no session, no
/// scheduled next meso, no snooze. One log line per launch.
enum MesoStartDateResync {
    static func runIfNeeded(in context: ModelContext) {
        guard let active = (try? context.fetch(FetchDescriptor<MesoBlock>()))?.first(where: { $0.status == .active }) else {
            BackfillLog.note("ℹ️ meso start date re-sync not needed (no active block).")
            return
        }
        let cal = Calendar.current
        let wanted = cal.startOfDay(for: active.startDate)
        // Only an existing, different date is corrected; a store with no AppState row or no date is left as it is.
        guard let state = (try? context.fetch(FetchDescriptor<AppState>()))?.first,
              let stored = state.activeMesoStartDate, cal.startOfDay(for: stored) != wanted else {
            BackfillLog.note("ℹ️ meso start date re-sync not needed.")
            return
        }
        let current: Date? = cal.startOfDay(for: stored)
        AppStateBridge.setActiveMesoStartDate(wanted, in: context)
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        BackfillLog.note("✅ meso start date re-synced: \(current.map { $0.formatted(f) } ?? "unset") -> \(wanted.formatted(f)).")
    }
}
