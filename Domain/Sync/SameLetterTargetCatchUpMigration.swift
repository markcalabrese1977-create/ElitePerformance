import Foundation
import SwiftData

/// One-time catch-up for the carry-forward fix that lets a hold or reduce overwrite an unedited,
/// already-planned same-letter target. Sessions completed BEFORE that fix left their targets at
/// the old seed (e.g. a 317.5 seed after a 300 x 12,12,10 "hold 300" session). This replays, once,
/// what carry-forward would now have written for every completed session of the active block.
///
/// ARMED (`dryRun = false`): on the first launch with exactly one active regular block it plans,
/// prints the full report (every row, every skipped item and the guard that skipped it) and
/// applies. Setting `dryRun` back to true makes it strictly read-only again: it only logs the
/// report, stores the text under `reportKey`, sets `dryRunLoggedKey` and returns.
///
/// Applying: one atomic save. The overwritten fields (suggestedLoad, plannedLoadsBySet) are
/// snapshotted first; if the post-conditions or the save fail, they are restored and nothing is
/// persisted. `completionKey` is set ONLY after a successful save (a failure leaves it unset so
/// it retries, never silently skipped).
///
/// The guards and the written value are NOT re-implemented here: they are
/// `PlanMemoryEngine.propagationDecision`, the exact function carry-forward's propagate path uses.
/// On top of it the catch-up adds only what carry-forward gets from its call site: a completed
/// source with a wave (wave-nil sources are skipped entirely), a same-letter target that is
/// planned and unlogged, and a non-empty target (an empty one is the seed path's job).
enum SameLetterTargetCatchUpMigration {
    /// false = armed: plan and apply. true = read-only (log the report only).
    static let dryRun = false

    /// Bump when the REPORT changes, so a changed report logs again instead of being swallowed
    /// by the previous install's "already logged" flag.
    static let reportVersion = "v1"

    static let completionKey = "sameLetterTargetCatchUp.v1.completed"
    static var dryRunLoggedKey: String { "sameLetterTargetCatchUp.v1.dryRunLogged.\(reportVersion)" }
    static var reportKey: String { "sameLetterTargetCatchUp.v1.dryRunReport.\(reportVersion)" }

    // MARK: - Plan

    struct Row {
        let targetItem: SessionItem
        let storedLoad: Double
        let storedPlan: [Double]
        let newLoad: Double
        let newPlan: [Double]
        let line: String
    }

    struct Plan {
        var rows: [Row] = []
        var skipped: [String] = []
        var unchanged = 0
        var text: String = ""
    }

    enum CatchUpError: Error, Equatable {
        case postConditionFailed(String)
    }

    private static func formatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE MMM d"
        return df
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// Read-only. Never mutates the store.
    static func plan(block: MesoBlock, context: ModelContext) -> Plan {
        let engine = PlanMemoryEngine(context: context)
        let inputs = engine.loadPolicyInputs()
        let all = ((try? context.fetch(FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]))) ?? [])
        let blockSessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        let df = formatter()

        func label(_ session: Session, _ item: SessionItem) -> String {
            "\(df.string(from: session.date)) wk\(session.weekIndex) \(session.dayLabel ?? "?") "
            + "[\((item.waveRaw ?? "-").uppercased())] \(item.exerciseNameSnapshot ?? item.exerciseId)"
        }

        var plan = Plan()
        var rowsByTarget: [PersistentIdentifier: Row] = [:]
        var order: [PersistentIdentifier] = []   // chronological insertion order

        for source in blockSessions where source.status == .completed {
            for item in source.items.sorted(by: { $0.order < $1.order }) {
                let who = "\(label(source, item)) (source, \(df.string(from: source.date)))"
                guard let wave = item.waveRaw?.lowercased(), !wave.isEmpty else {
                    plan.skipped.append("\(who): wave-nil source (excluded)")
                    continue
                }
                guard engine.hasMeaningfulPlan(item) else {
                    plan.skipped.append("\(who): no meaningful plan on the source")
                    continue
                }
                guard let target = PlanMemoryEngine.nextTargetItem(for: item, after: source, in: all) else {
                    plan.skipped.append("\(who): end of chain (no later same-letter, same-day target)")
                    continue
                }
                guard let owner = blockSessions.first(where: { $0.items.contains { $0 === target } }) else {
                    plan.skipped.append("\(who): target is outside the active block")
                    continue
                }
                let tLabel = label(owner, target)
                guard owner.status == .planned else {
                    plan.skipped.append("\(tLabel): target session is \(owner.status.rawValue), not planned")
                    continue
                }
                let logged = target.isCompleted
                    || target.actualReps.contains(where: { $0 > 0 })
                    || target.actualLoads.contains(where: { $0 > 0 })
                guard !logged else {
                    plan.skipped.append("\(tLabel): target already has logged sets")
                    continue
                }
                guard !engine.isPlanEffectivelyEmpty(target) else {
                    plan.skipped.append("\(tLabel): empty target (seed path, not propagate)")
                    continue
                }

                let decision = engine.propagationDecision(
                    sourceItem: item, targetItem: target, session: source, allSessions: all,
                    activeMesoIDs: inputs.activeMesoIDs, loadIncrement: inputs.loadIncrement,
                    bodyWeight: inputs.bodyWeight, customExercises: inputs.customExercises,
                    progressionEnabled: inputs.progressionEnabled,
                    isProgressionExempt: UserProfile.isProgressionExempt(
                        exerciseId: item.exerciseId, profile: inputs.profile)
                )
                switch decision {
                case .skip(let guardName):
                    plan.skipped.append("\(tLabel): \(guardName)")
                case .write(let newLoad):
                    let newPlan = PlanMemoryEngine.propagatedPlan(newLoad, for: target)
                    if target.suggestedLoad == newLoad && target.plannedLoadsBySet == newPlan {
                        plan.unchanged += 1
                        continue
                    }
                    let sets = zip(item.actualReps, item.actualLoads)
                        .filter { $0 > 0 || $1 > 0 }
                        .map { "\(fmt($1))x\($0)" }.joined(separator: ",")
                    let rirs = item.actualRIRs.map(String.init).joined(separator: "/")
                    let line = "\(tLabel): \(fmt(target.suggestedLoad)) -> \(fmt(newLoad))"
                        + "   (from \(df.string(from: source.date)) wk\(source.weekIndex): \(sets) @RIR \(rirs))"
                    let row = Row(targetItem: target, storedLoad: target.suggestedLoad,
                                  storedPlan: target.plannedLoadsBySet, newLoad: newLoad,
                                  newPlan: newPlan, line: line)
                    let key = target.persistentModelID
                    if rowsByTarget[key] == nil { order.append(key) }
                    rowsByTarget[key] = row          // exactly one predecessor; the later wins if not
                }
            }
        }
        plan.rows = order.compactMap { rowsByTarget[$0] }

        var lines = ["SAME-LETTER TARGET CATCH-UP — block '\(block.name)'",
                     "rows to write: \(plan.rows.count)   already equal: \(plan.unchanged)   skipped: \(plan.skipped.count)",
                     ""]
        lines.append("WRITE (\(plan.rows.count)):")
        lines += plan.rows.map { "  " + $0.line }
        lines.append("")
        lines.append("SKIPPED (\(plan.skipped.count)):")
        lines += plan.skipped.map { "  " + $0 }
        plan.text = lines.joined(separator: "\n")
        return plan
    }

    // MARK: - Apply

    /// Every field EXCEPT the two the catch-up may write, for every item and its session.
    static func fingerprint(of context: ModelContext) -> [String: String] {
        var out: [String: String] = [:]
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        for s in sessions {
            for i in s.items {
                let key = "\(s.persistentModelID.hashValue)|\(i.persistentModelID.hashValue)"
                out[key] = [
                    "\(s.status.rawValue)", "\(s.date.timeIntervalSince1970)", "\(s.weekIndex)", s.dayLabel ?? "",
                    "\(i.order)", i.exerciseId, "\(i.targetSets)", "\(i.targetReps)", "\(i.targetRIR)",
                    "\(i.plannedRepsBySet)", "\(i.plannedRIRsBySet)", "\(i.actualReps)", "\(i.actualLoads)",
                    "\(i.actualRIRs)", "\(i.planEdited)", i.coachNote ?? "", i.waveRaw ?? "", "\(i.isCompleted)"
                ].joined(separator: "¦")
            }
        }
        return out
    }

    /// Writes the plan in one atomic save. On any failure the overwritten fields are restored and
    /// the error is rethrown; nothing is persisted. Returns the number of rows written.
    @discardableResult
    static func apply(plan: Plan, context: ModelContext, save: (() throws -> Void)? = nil) throws -> Int {
        guard !plan.rows.isEmpty else { return 0 }
        let snapshot = plan.rows.map { ($0.targetItem, $0.storedLoad, $0.storedPlan) }
        func restore() {
            for (item, load, perSet) in snapshot {
                item.suggestedLoad = load
                item.plannedLoadsBySet = perSet
            }
            context.rollback()
        }

        let before = fingerprint(of: context)
        for row in plan.rows {
            row.targetItem.suggestedLoad = row.newLoad
            row.targetItem.plannedLoadsBySet = row.newPlan
        }

        // Post-conditions, checked BEFORE anything is saved.
        let after = fingerprint(of: context)
        guard before == after else {
            restore()
            throw CatchUpError.postConditionFailed("a field other than suggestedLoad/plannedLoadsBySet changed")
        }
        let changed = plan.rows.filter {
            $0.targetItem.suggestedLoad != $0.storedLoad || $0.targetItem.plannedLoadsBySet != $0.storedPlan
        }.count
        guard changed == plan.rows.count else {
            restore()
            throw CatchUpError.postConditionFailed("changed items (\(changed)) != dry-run rows (\(plan.rows.count))")
        }

        do {
            try (save ?? { try context.save() })()
        } catch {
            restore()
            throw error
        }
        return plan.rows.count
    }

    /// First line of the report in the launch log: "APPLY" when this launch may write, "DRY RUN" only when read-only.
    static func logHeader(dryRun: Bool) -> String {
        "🧪 Same-letter catch-up \(dryRun ? "DRY RUN" : "APPLY"):"
    }

    // MARK: - Driver

    static func runIfNeeded(
        in context: ModelContext,
        dryRun: Bool = SameLetterTargetCatchUpMigration.dryRun,
        defaults: UserDefaults = .standard,
        save: (() throws -> Void)? = nil
    ) {
        if defaults.bool(forKey: completionKey) {
            print("ℹ️ Same-letter catch-up not needed.")
            return
        }
        if dryRun, defaults.bool(forKey: dryRunLoggedKey) {
            print("ℹ️ Same-letter catch-up dry run already logged on this install.")
            return
        }
        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ Same-letter catch-up: could not fetch meso blocks — nothing done.")
            return
        }
        let candidates = blocks.filter { $0.status == .active && !$0.isMaintenance }
        guard candidates.count == 1, let block = candidates.first else {
            print("ℹ️ Same-letter catch-up: \(candidates.count) active regular blocks — nothing done, will retry.")
            return
        }

        let plan = Self.plan(block: block, context: context)
        print("\(logHeader(dryRun: dryRun))\n\(plan.text)")

        if dryRun {
            defaults.set(plan.text, forKey: reportKey)
            defaults.set(true, forKey: dryRunLoggedKey)
            print("🧪 Same-letter catch-up dry run logged (read-only; nothing was written to the store).")
            return
        }

        do {
            let written = try apply(plan: plan, context: context, save: save)
            // Only after the save succeeded (or there was nothing to write).
            defaults.set(true, forKey: completionKey)
            print("✅ Same-letter catch-up applied: \(written) target(s) updated.")
        } catch {
            print("⚠️ Same-letter catch-up failed: \(error). Rolled back; flag NOT set; will retry.")
        }
    }
}
