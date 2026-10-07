import Foundation
import SwiftData

/// One-shot, on-device driver for DUPMesoLengthConversion (10 -> 12 week DUP block).
///
/// SHIPS ARMED (`dryRun == false`). On the first launch that finds exactly one eligible active
/// 10-week block it runs the planner and, only if every gate passes, applies the conversion:
/// mutate -> verify the whole result (chains, 72 sessions, programIndex 1...72, dates, waves, ...)
/// -> one save. Any failed verification or failed save restores the store and leaves
/// `completionKey` unset, so the next launch retries; `completionKey` is set ONLY after the save
/// succeeds. After a successful write the full summary (counts, 18-chain table, each verification
/// line, scheduled-next-meso value) goes to the launch log.
///
/// Dry-run mode (`dryRun == true`, still available through the `dryRun:` parameter and used by the
/// tests) is strictly read-only: it prints the report (gates, week-10 before/after table, weeks
/// 11-12 summary, projected chains), stores it under `reportKey`, sets `dryRunLoggedKey`, and returns.
///
/// Time constraint: this must be installed and run before the first week-7 session completes (Fri
/// Nov 6, 2026), or week 7's result will not reach week 10 (carry-forward looks its target up when
/// the source session is saved).
enum TwelveWeekMesoConversionMigration {
    /// false = apply when every gate passes; true = read-only dry run.
    static let dryRun = false

    /// Bump this whenever the dry-run REPORT changes (new gates, columns, rules, copy semantics):
    /// the logged flag and stored report are keyed by it, so a changed report logs again on the
    /// next launch instead of being swallowed by the previous install's "already logged" flag.
    /// v2: loads are copied from the source week (v1 zeroed them) and the report shows
    /// before -> after loads, block id, gates, item table and chain table.
    static let reportVersion = "v2"

    static let completionKey = "twelveWeekMesoConversion.v1.completed"
    static var dryRunLoggedKey: String { "twelveWeekMesoConversion.v1.dryRunLogged.\(reportVersion)" }
    static var reportKey: String { "twelveWeekMesoConversion.v1.dryRunReport.\(reportVersion)" }

    static func runIfNeeded(in context: ModelContext,
                            dryRun: Bool = TwelveWeekMesoConversionMigration.dryRun,
                            hooks: DUPMesoLengthConversion.ApplyHooks = .init()) {
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
        if candidates.isEmpty, handleTwelveWeekBlocks(blocks, in: context, defaults: defaults) { return }
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
        // Earlier startup migrations share this context and may leave unsaved edits. Commit them first
        // (autosave would have), so apply() can roll back without ever discarding someone else's work.
        if context.hasChanges {
            do { try context.save() } catch {
                print("⚠️ 12-week conversion: could not flush pending changes before apply: \(error). Flag NOT set; will retry.")
                return
            }
        }
        do {
            let applied = try DUPMesoLengthConversion.apply(block: block, context: context, hooks: hooks)
            guard applied.didWrite else {
                print("⚠️ 12-week conversion: apply wrote nothing. Flags left unset.")
                return
            }
            // Only after the save inside apply() succeeded.
            defaults.set(true, forKey: completionKey)
            logPostWriteSummary(applied, block: block, context: context)
        } catch {
            // apply() has already rolled the context back for every failure after its first mutation.
            print("⛔️ 12-week conversion NOT applied (store unchanged, flag NOT set; will retry): \(error)")
        }
    }

    /// One-time (per install) warning marker for a 12-week block that is not the converted shape.
    static let shapeWarnedKey = "twelveWeekMesoConversion.v1.shapeWarned"

    /// No 10-week block is eligible: is there a 12-week block that is already the converted result
    /// (e.g. converted, then the completion flag was lost)? Returns true when it handled the launch.
    private static func handleTwelveWeekBlocks(_ blocks: [MesoBlock], in context: ModelContext, defaults: UserDefaults) -> Bool {
        let twelve = blocks.filter { $0.status == .active && !$0.isMaintenance && $0.totalWeeks == DUPMesoLengthConversion.targetTotalWeeks }
        guard !twelve.isEmpty else { return false }
        if twelve.count == 1, let block = twelve.first {
            let problems = DUPMesoLengthConversion.convertedShapeProblems(block: block, context: context)
            if problems.isEmpty {
                defaults.set(true, forKey: completionKey)
                defaults.set(true, forKey: dryRunLoggedKey)
                print("ℹ️ 12-week conversion: block already converted, nothing to do.")
                return true
            }
            warnOnce("'\(block.name)' is 12 weeks but not the converted shape: \(problems.joined(separator: "; "))", defaults: defaults)
        } else {
            warnOnce("\(twelve.count) active 12-week blocks — ambiguous", defaults: defaults)
        }
        return true
    }

    private static func warnOnce(_ detail: String, defaults: UserDefaults) {
        guard !defaults.bool(forKey: shapeWarnedKey) else { return }
        defaults.set(true, forKey: shapeWarnedKey)
        print("⚠️ 12-week conversion: \(detail). Nothing done; flags left unset.")
    }

    /// Everything a human needs from the launch log to trust the write.
    private static func logPostWriteSummary(_ r: DUPMesoLengthConversion.Report, block: MesoBlock, context: ModelContext) {
        var out: [String] = ["✅ 12-week conversion applied to '\(block.name)' (totalWeeks \(block.totalWeeks.map(String.init) ?? "nil"))"]
        out.append("sessions converted: \(r.sessionsConverted)   items converted: \(r.itemsConverted)")
        out.append("sessions created:   \(r.sessionsCreated)   items created:   \(r.itemsCreated)")
        out.append("== CREATED LINKS (\(r.postWriteChainTable.count)) ==")
        out += r.postWriteChainTable
        out.append("== VERIFICATION (ran before save) ==")
        out += r.verification.map { "  \($0)" }
        out.append("== SCHEDULED NEXT MESO (logged, not gated) ==")
        out.append("  " + scheduledNextMesoDescription(in: context))
        print(out.joined(separator: "\n"))
    }

    /// Reads the scheduled-next-meso value from AppState and from the UserDefaults mirror, without
    /// creating or changing anything.
    static func scheduledNextMesoDescription(in context: ModelContext) -> String {
        let state = (try? context.fetch(FetchDescriptor<AppState>()))?.first
        let fromState = state?.scheduledNextMesoStartDate
        let epoch = UserDefaults.standard.double(forKey: AppStateBridge.scheduledStartEpochKey)
        let fromDefaults: Date? = epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
        func f(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none" }
        return "AppState.scheduledNextMesoStartDate = \(f(fromState))\(state == nil ? " (no AppState row)" : ""); UserDefaults \(AppStateBridge.scheduledStartEpochKey) = \(f(fromDefaults))"
    }
}
