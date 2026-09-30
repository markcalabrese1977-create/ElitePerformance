// Domain/Sync/PlannedBodyweightSnapshotRepair.swift
import Foundation
import SwiftData

/// One-shot repair for two leftovers that the older run-once migrations can no longer
/// fix on a device whose completion flags are already set:
///
/// 1. Phantom bodyweight loads on PLANNED sessions of the ACTIVE meso. Every bodyweight
///    item (ExerciseCatalog.isBodyweight, incl. SwiftData custom exercises) with
///    suggestedLoad > 0 or any plannedLoadsBySet entry > 0 gets suggestedLoad = 0 and
///    plannedLoadsBySet = zeros sized to targetSets (no padding beyond targetSets).
///    Expected: exactly 9 pull_up items (Pull A, weeks 2-10). Any other count aborts.
///
/// 2. UUID-derived exerciseNameSnapshot values ("8dbee258 E3d5 43db 8761 Ba78910e8a80")
///    are replaced with the CustomExercise.name for the item's exerciseId.
///    Expected: exactly 14 items (5 custom_8dbee25…, 5 custom_7f4ffc4…, 4 custom_e040754…).
///    Any other count, or any exerciseId missing from the CustomExercise table, aborts.
///
/// Safety: Part 1 only touches sessions that are `.planned` with no logged data
/// (isSafeToModify); actuals are never touched. Part 2 is display metadata only and is
/// not gated by session status (completed-session recaps show the snapshot), but the
/// session status is logged per item. The whole repair is validated before anything is
/// written: any failed expectation aborts with NO writes (and no completion flag, so a
/// later build can retry). One atomic save; the completion flag is set only after it
/// succeeds.
///
/// dryRun is ON: the repair logs exactly what it would write, writes nothing and never
/// sets the flag. Flip `dryRun` to false only after the dry-run log has been reviewed.
enum PlannedBodyweightSnapshotRepair {
    static let completionKey = "plannedBodyweightSnapshotRepair.v1.completed"

    /// Ship as a dry run. Flip to false after reviewing the log.
    static let dryRun = true

    private static let expectedBodyweightCount = 9
    private static let expectedSnapshotCount = 14
    private static let expectedSnapshotPrefixCounts: [String: Int] = [
        "custom_8dbee25": 5,
        "custom_7f4ffc4": 5,
        "custom_e040754": 4
    ]

    private static let tag = "PBSR"

    // MARK: - Plan types

    private struct LoadFix {
        let item: SessionItem
        let session: Session
        let beforeSuggested: Double
        let beforePlanned: [Double]
        let afterPlanned: [Double]
    }

    private struct NameFix {
        let item: SessionItem
        let session: Session
        let before: String
        let after: String
    }

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext, dryRun: Bool = PlannedBodyweightSnapshotRepair.dryRun) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Planned bodyweight / snapshot repair not needed.")
            return
        }

        var log: [String] = []
        func line(_ s: String) { log.append("\(tag)| \(s)") }
        func abort(_ reason: String) {
            line("ABORTED — no writes, flag not set: \(reason)")
            print("⚠️ Planned bodyweight / snapshot repair aborted:\n" + log.joined(separator: "\n"))
        }

        line(dryRun ? "DRY RUN — nothing will be written, flag will not be set" : "LIVE RUN")

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()),
              let sessions = try? context.fetch(FetchDescriptor<Session>()),
              let customs = try? context.fetch(FetchDescriptor<CustomExercise>()) else {
            abort("could not fetch blocks/sessions/custom exercises")
            return
        }

        // ---------- Part 1: planned bodyweight phantom loads, active meso ----------

        let active = blocks.filter { $0.status == .active }
        guard active.count == 1, let activeMeso = active.first else {
            abort("expected exactly 1 active meso, found \(active.count)")
            return
        }
        line("Part 1 — active meso \"\(activeMeso.name)\" (id \(activeMeso.id?.uuidString ?? "nil"))")

        let mesoSessions = sessions.filter { $0.meso?.persistentModelID == activeMeso.persistentModelID }
        let plannedSessions = mesoSessions.filter { $0.status == .planned }
        line("  sessions in active meso: \(mesoSessions.count); planned: \(plannedSessions.count)")

        var loadFixes: [LoadFix] = []
        var skippedUnsafe: [String] = []
        for session in plannedSessions.sorted(by: { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }) {
            let safe = isSafeToModify(session)
            for item in session.items.sorted(by: { $0.order < $1.order }) {
                guard ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customs) else { continue }
                let hasPhantom = item.suggestedLoad > 0 || item.plannedLoadsBySet.contains { $0 > 0 }
                guard hasPhantom else { continue }
                guard safe else {
                    skippedUnsafe.append("\(describe(session)) item \(idOf(item)) \(item.exerciseId) (logged data present)")
                    continue
                }
                loadFixes.append(LoadFix(
                    item: item,
                    session: session,
                    beforeSuggested: item.suggestedLoad,
                    beforePlanned: item.plannedLoadsBySet,
                    afterPlanned: Array(repeating: 0, count: max(0, item.targetSets))
                ))
            }
        }

        for fix in loadFixes {
            var s = "  \(describe(fix.session)) | item \(idOf(fix.item)) | \(fix.item.exerciseId) | "
            s += "suggestedLoad \(fix.beforeSuggested) -> 0.0 | "
            s += "plannedLoadsBySet \(fix.beforePlanned) -> \(fix.afterPlanned) (targetSets=\(fix.item.targetSets)"
            if fix.beforePlanned.count != fix.item.targetSets {
                s += ", NOTE before.count=\(fix.beforePlanned.count) != targetSets"
            }
            s += ")"
            line(s)
        }
        for s in skippedUnsafe { line("  SKIPPED unsafe: \(s)") }
        line("  candidates=\(loadFixes.count) expected=\(expectedBodyweightCount) skippedUnsafe=\(skippedUnsafe.count)")
        let exerciseIds = Set(loadFixes.map { $0.item.exerciseId })
        line("  distinct exerciseIds among candidates: \(exerciseIds.sorted())")

        // Informational only: phantom-looking bodyweight plan values outside this repair's scope.
        var outOfScope: [String: Int] = [:]
        let inScopeIds = Set(plannedSessions.map { $0.persistentModelID })
        for session in sessions where !inScopeIds.contains(session.persistentModelID) {
            let scope = "\(session.status.rawValue)/\(session.meso?.persistentModelID == activeMeso.persistentModelID ? "active-meso" : "other-meso")"
            for item in session.items {
                guard ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customs) else { continue }
                if item.suggestedLoad > 0 || item.plannedLoadsBySet.contains(where: { $0 > 0 }) {
                    outOfScope[scope, default: 0] += 1
                }
            }
        }
        line("  out-of-scope bodyweight items with nonzero suggestedLoad/plannedLoadsBySet (NOT touched): \(outOfScope.isEmpty ? "none" : outOfScope.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")

        guard loadFixes.count == expectedBodyweightCount, skippedUnsafe.isEmpty else {
            abort("Part 1 count \(loadFixes.count) (skippedUnsafe \(skippedUnsafe.count)) != expected \(expectedBodyweightCount)")
            return
        }

        // ---------- Part 2: UUID-derived exerciseNameSnapshot ----------

        line("Part 2 — UUID-derived exerciseNameSnapshot (all sessions; customs in table: \(customs.count))")
        let customById = Dictionary(customs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var nameFixes: [NameFix] = []
        var missingIds: [String] = []
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            for item in session.items.sorted(by: { $0.order < $1.order }) {
                let current = item.exerciseNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard looksUUIDDerived(current) else { continue }
                guard let custom = customById[item.exerciseId] else {
                    missingIds.append(item.exerciseId)
                    continue
                }
                let resolved = custom.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resolved.isEmpty, !looksUUIDDerived(resolved) else {
                    missingIds.append("\(item.exerciseId) (unusable name)")
                    continue
                }
                nameFixes.append(NameFix(item: item, session: session, before: current, after: resolved))
            }
        }

        for fix in nameFixes {
            line("  \(describe(fix.session)) [\(fix.session.status.rawValue)] | item \(idOf(fix.item)) | \(fix.item.exerciseId) | \"\(fix.before)\" -> \"\(fix.after)\"")
        }
        var perPrefix: [String: Int] = [:]
        var unmatchedPrefix: [String] = []
        for fix in nameFixes {
            let id = fix.item.exerciseId.lowercased()
            if let p = expectedSnapshotPrefixCounts.keys.first(where: { id.hasPrefix($0) }) {
                perPrefix[p, default: 0] += 1
            } else {
                unmatchedPrefix.append(fix.item.exerciseId)
            }
        }
        line("  candidates=\(nameFixes.count) expected=\(expectedSnapshotCount); per-prefix \(perPrefix.sorted { $0.key < $1.key }) expected \(expectedSnapshotPrefixCounts.sorted { $0.key < $1.key })")
        if !missingIds.isEmpty { line("  exerciseIds NOT in CustomExercise table: \(missingIds)") }
        if !unmatchedPrefix.isEmpty { line("  exerciseIds outside expected prefixes: \(unmatchedPrefix)") }

        guard missingIds.isEmpty else {
            abort("Part 2: \(missingIds.count) exerciseId(s) not in CustomExercise table")
            return
        }
        guard nameFixes.count == expectedSnapshotCount,
              unmatchedPrefix.isEmpty,
              perPrefix == expectedSnapshotPrefixCounts else {
            abort("Part 2 count/breakdown differs from expected")
            return
        }

        // ---------- Dry run stops here ----------

        if dryRun {
            line("DRY RUN RESULT: would write Part 1 = \(loadFixes.count) items, Part 2 = \(nameFixes.count) items. Nothing written, flag not set.")
            print("🧪 Planned bodyweight / snapshot repair (dry run):\n" + log.joined(separator: "\n"))
            return
        }

        // ---------- Apply (single atomic save) ----------

        for fix in loadFixes {
            fix.item.suggestedLoad = 0
            fix.item.plannedLoadsBySet = fix.afterPlanned
        }
        for fix in nameFixes {
            fix.item.exerciseNameSnapshot = fix.after
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            line("SAVE FAILED: \(error) — rolled back, flag not set (will retry next launch)")
            print("⚠️ Planned bodyweight / snapshot repair save failed:\n" + log.joined(separator: "\n"))
            return
        }

        // After-state log, read back from the saved objects.
        for fix in loadFixes {
            line("  AFTER \(describe(fix.session)) | item \(idOf(fix.item)) | suggestedLoad \(fix.item.suggestedLoad) | plannedLoadsBySet \(fix.item.plannedLoadsBySet)")
        }
        for fix in nameFixes {
            line("  AFTER item \(idOf(fix.item)) | snapshot \"\(fix.item.exerciseNameSnapshot ?? "nil")\"")
        }
        line("WROTE Part 1 = \(loadFixes.count) items, Part 2 = \(nameFixes.count) items.")
        UserDefaults.standard.set(true, forKey: completionKey)
        print("✅ Planned bodyweight / snapshot repair complete:\n" + log.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func isSafeToModify(_ session: Session) -> Bool {
        guard session.status == .planned else { return false }
        return !hasLoggedData(session)
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains { item in
            item.isCompleted ||
            item.actualLoads.contains { $0 > 0 } ||
            item.actualReps.contains { $0 > 0 }
        }
    }

    /// "8dbee258 E3d5 43db 8761 Ba78910e8a80": 8 hex + 3×4 alphanumerics + 12 alphanumerics,
    /// single-space separated (a dashed UUID that was word-split and title-cased).
    private static func looksUUIDDerived(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-Fa-f]{8} [0-9A-Za-z]{4} [0-9A-Za-z]{4} [0-9A-Za-z]{4} [0-9A-Za-z]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func idOf(_ item: SessionItem) -> String { item.id?.uuidString ?? "nil-id" }

    private static func describe(_ session: Session) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "session \(session.id?.uuidString ?? "nil-id") W\(session.weekIndex) \(session.dayLabel ?? "-") \(f.string(from: session.date))"
    }
}
