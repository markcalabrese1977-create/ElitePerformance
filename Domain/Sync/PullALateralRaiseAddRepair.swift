// Domain/Sync/PullALateralRaiseAddRepair.swift
import Foundation
import SwiftData

/// One-shot repair: add `dumbbell_lateral_raise` to every "Pull A" session of the
/// active block, weeks 1-10.
///
/// Construction goes through `DUPSessionMaterializer.makeSessionItems` with a
/// synthetic single-exercise day — the same approach as MesoProgramAlignmentRepair —
/// so `waveRaw`, the rep/RIR/set ranges, the reps/RIR flattening asymmetry and the
/// `planned*` array sizing all come from the materializer rather than being restated
/// here and drifting from it.
///
/// Per-week prescription:
/// - wave A (weeks 1, 4, 7): 3 × 10-12 @2
/// - wave B (weeks 2, 5, 8): 3 × 12-15 @2
/// - wave C (weeks 3, 6, 9): 3 × 15-20 @2
/// - deload (week 10): copied from the same week's Pull B lateral raise
///
/// Loads come from the SAME WEEK's Pull B lateral raise, which carries the same wave
/// letter and the same prescription, so the two sessions stay in step. Deliberately
/// NOT `LoadProjectionService.lastKnownLoad`, which reads future planned sessions and
/// would seed from a plan rather than from history.
///
/// Week 4 exception: 40, the per-letter carry-forward of week 1's earned bump
/// (35 × 12, 12, 12 @1 — top of the A range 10-12).
///
/// Safety: all-or-nothing. Every gate is checked across every target before anything
/// is written, and one violation aborts the whole repair. `dryRun` logs the full
/// intended result without saving; the completion flag is set only after a save
/// actually succeeds, so a dry or failed run retries on the next launch.
enum PullALateralRaiseAddRepair {

    /// Dry-run log reviewed and verified on-device 2026-09-27; now live.
    private static let dryRun = false

    private static let completionKey = "pullALateralRaiseAddRepair.v1.completed"

    private static let dayLabel = "Pull A"
    private static let pairedDayLabel = "Pull B"
    private static let weeks = 1...10

    private static let exerciseId = "dumbbell_lateral_raise"
    /// The new item goes directly after this one.
    private static let anchorExerciseId = "hammer_curl"

    // MARK: - Week 4 carry-forward exception

    private static let carryForwardWeek = 4
    private static let carryForwardLoad: Double = 40.0

    // MARK: - Per-wave prescription

    private static func prescription(for wave: WaveType) -> WavePrescription? {
        switch wave {
        case .a: return spec(repMin: 10, repMax: 12)
        case .b: return spec(repMin: 12, repMax: 15)
        case .c: return spec(repMin: 15, repMax: 20)
        case .deload: return nil   // copied from the same week's Pull B item
        }
    }

    private static func spec(repMin: Int, repMax: Int) -> WavePrescription {
        WavePrescription(
            wave: .a,          // unused by the fields we read; the day carries the real wave
            setMin: 3,
            setMax: 3,
            repMin: repMin,
            repMax: repMax,
            targetRIRMin: 2,
            targetRIRMax: 2,
            intensifier: .none,
            intensifierNotes: nil
        )
    }

    private static func waveFor(week: Int) -> WaveType {
        switch week {
        case 1, 4, 7: return .a
        case 2, 5, 8: return .b
        case 3, 6, 9: return .c
        default: return .deload
        }
    }

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Pull A lateral raise add not needed.")
            return
        }

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ Pull A lateral raise add: could not fetch meso blocks — aborting, nothing written.")
            return
        }

        // MARK: Gate — exactly one active, non-maintenance block

        let active = blocks.filter { $0.status == .active && !$0.isMaintenance }
        guard active.count == 1, let block = active.first else {
            print("⛔️ Pull A lateral raise add ABORTED — expected exactly 1 active non-maintenance block, found \(active.count). Nothing written.")
            return
        }

        let pullA = sessions(in: block, labelled: dayLabel)
        let pullB = sessions(in: block, labelled: pairedDayLabel)

        var violations: [String] = []

        // MARK: Gate — exactly 10 Pull A sessions, one per week

        if pullA.count != weeks.count {
            violations.append("expected \(weeks.count) '\(dayLabel)' sessions, found \(pullA.count)")
        }
        let byWeek = Dictionary(grouping: pullA, by: { $0.weekInMeso ?? -1 })
        for week in weeks {
            let count = byWeek[week]?.count ?? 0
            if count != 1 {
                violations.append("week \(week): expected 1 '\(dayLabel)' session, found \(count)")
            }
        }

        let pullBByWeek = Dictionary(grouping: pullB, by: { $0.weekInMeso ?? -1 })

        /// Week 1 is skipped (not a write target) when the raise is already there —
        /// added by hand on the Today tab. Skipped weeks are not gated.
        var skippedWeeks: Set<Int> = []
        if let week1 = byWeek[1]?.first, findItem(exerciseId, in: week1) != nil {
            skippedWeeks.insert(1)
        }

        for week in weeks {
            guard let session = byWeek[week]?.first else { continue }
            let tag = "wk\(week) \(format(session.date))"

            guard !skippedWeeks.contains(week) else { continue }

            // Gate — safe to modify
            if !isSafeToModify(session) {
                violations.append("\(tag): not safe to modify (status=\(session.status.rawValue), hasLoggedData=\(hasLoggedData(session)))")
            }

            // Already present on a week we are not skipping → would duplicate
            if findItem(exerciseId, in: session) != nil {
                violations.append("\(tag): already contains \(exerciseId) — would duplicate")
            }

            // Placement is defined relative to hammer_curl; without it there is no anchor
            if findItem(anchorExerciseId, in: session) == nil {
                violations.append("\(tag): no \(anchorExerciseId) to place after — insertion point undefined")
            }

            // Gate — the same week's Pull B has a lateral raise to copy from
            guard let pairedSession = pullBByWeek[week]?.first else {
                violations.append("\(tag): no '\(pairedDayLabel)' session in week \(week) to copy loads from")
                continue
            }
            if findItem(exerciseId, in: pairedSession) == nil {
                violations.append("\(tag): week \(week) '\(pairedDayLabel)' has no \(exerciseId) to copy from")
            }
            // The deload prescription is copied from Pull B, so it must be resolvable
            if waveFor(week: week) == .deload, let paired = findItem(exerciseId, in: pairedSession) {
                if paired.repMin == nil || paired.repMax == nil || paired.targetRIRMin == nil || paired.targetRIRMax == nil || paired.setMin == nil {
                    violations.append("\(tag): week \(week) '\(pairedDayLabel)' \(exerciseId) has an incomplete prescription to copy for the deload week")
                }
            }
        }

        guard violations.isEmpty else {
            print("""
            ⛔️ Pull A lateral raise add ABORTED — nothing written. \(violations.count) gate violation(s):
            \(violations.map { "   • " + $0 }.joined(separator: "\n"))
            """)
            return
        }

        // MARK: Write (or, under dryRun, describe)

        var log: [String] = []
        var added = 0
        var shifted = 0
        var exceptions = 0

        for week in weeks {
            guard let session = byWeek[week]?.first else { continue }
            let tag = "wk\(week)  \(format(session.date))  \(dayLabel)"

            if skippedWeeks.contains(week) {
                let existing = findItem(exerciseId, in: session)
                log.append("── \(tag)  — SKIPPED (already contains \(exerciseId)\(existing.map { ", order \($0.order)" } ?? ""); added on the Today tab)")
                continue
            }

            let wave = waveFor(week: week)
            guard let paired = findItem(exerciseId, in: pullBByWeek[week]!.first!),
                  let anchor = findItem(anchorExerciseId, in: session) else { continue }

            let resolved = resolvedPrescription(for: wave, copyingFrom: paired)
            let isException = (week == carryForwardWeek)
            // Pull B's scalar load, re-spread over the materialized set count — Pull B's
            // own array can carry a stale trailing 0 from an earlier set-count change.
            let load = isException ? carryForwardLoad : paired.suggestedLoad

            let newOrder = anchor.order + 1
            let later = session.items.filter { $0.order >= newOrder }.sorted { $0.order < $1.order }

            let item = buildItem(order: newOrder, wave: wave, prescription: resolved, load: load)

            log.append("── \(tag)  [wave \(wave.rawValue)]")
            log.append("   + \(exerciseId)  \(ExerciseCatalog.displayName(for: exerciseId))")
            log.append("       order            \(newOrder)  (directly after \(anchorExerciseId) @ \(anchor.order))")
            log.append("       waveRaw          \(item.waveRaw ?? "nil")")
            log.append("       sets × reps      \(item.targetSets) × \(item.targetReps)   (setMin/Max \(opt(item.setMin))/\(opt(item.setMax)), repMin/Max \(opt(item.repMin))/\(opt(item.repMax)))")
            log.append("       targetRIR        \(item.targetRIR)   (min/max \(opt(item.targetRIRMin))/\(opt(item.targetRIRMax)))")
            log.append("       suggestedLoad    \(load)\(isException ? "   [week 4 carry-forward exception]" : "   (from wk\(week) \(pairedDayLabel))")")
            log.append("       plannedReps      \(item.plannedRepsBySet)")
            log.append("       plannedLoads     \(item.plannedLoadsBySet)\(isException ? "   [week 4 carry-forward exception]" : "")")
            log.append("       plannedRIRs      \(item.plannedRIRsBySet)")
            log.append("       priority/intens. \(item.priorityRaw ?? "nil") / \(item.intensifierRaw ?? "nil")   planEdited \(item.planEdited)   prescriptionNotes \(opt(item.prescriptionNotes))")

            if later.isEmpty {
                log.append("       no later items — no shift needed")
            } else {
                log.append("       shifting \(later.count) later item(s) +1: " + later.map { "\($0.exerciseId) \($0.order)→\($0.order + 1)" }.joined(separator: ", "))
                shifted += later.count
            }

            if !dryRun {
                for other in later {
                    other.order += 1
                }
                context.insert(item)
                session.items.append(item)
            }

            // Resulting roster, with the shift and insertion reflected whether or not we wrote
            var roster = session.items
                .filter { $0.id != item.id }
                .map { (name: $0.exerciseId, order: dryRun && $0.order >= newOrder ? $0.order + 1 : $0.order) }
            roster.append((name: exerciseId, order: newOrder))
            log.append("       roster after: " + roster.sorted { $0.order < $1.order }.map { "\($0.order):\($0.name)" }.joined(separator: ", "))

            added += 1
            if isException { exceptions += 1 }
        }

        let banner = dryRun ? "DRY RUN — nothing written" : "LIVE — writing"
        let summary = """

        ══ Pull A lateral raise add · \(banner) ══
        block: \(block.name)   scope: \(dayLabel) weeks \(weeks.lowerBound)-\(weeks.upperBound)   loads from: same-week \(pairedDayLabel)
        \(log.joined(separator: "\n"))
        ══ TOTALS: \(added) item(s) added, \(skippedWeeks.count) week(s) skipped, \(shifted) order shift(s), \(exceptions) exception write(s) ══
        """

        guard !dryRun else {
            print(summary)
            print("ℹ️ Pull A lateral raise add: dry run only — no save, completion flag NOT set.")
            return
        }

        do {
            try context.save()
            print(summary)
            print("✅ Pull A lateral raise add complete.")
        } catch {
            print(summary)
            print("⚠️ Pull A lateral raise add save failed: \(error). Nothing persisted; will retry next launch.")
            return  // do not mark complete
        }

        UserDefaults.standard.set(true, forKey: completionKey)
    }

    // MARK: - Construction

    /// The prescription to materialize from: the per-wave spec, or for the deload week
    /// the same week's Pull B item, read field by field.
    private static func resolvedPrescription(for wave: WaveType, copyingFrom paired: SessionItem) -> WavePrescription {
        if let spec = prescription(for: wave) { return spec }
        return WavePrescription(
            wave: wave,
            setMin: paired.setMin ?? paired.targetSets,
            setMax: paired.setMax ?? paired.targetSets,
            repMin: paired.repMin ?? paired.targetReps,
            repMax: paired.repMax ?? paired.targetReps,
            targetRIRMin: paired.targetRIRMin ?? paired.targetRIR,
            targetRIRMax: paired.targetRIRMax ?? paired.targetRIR,
            intensifier: .none,
            intensifierNotes: nil
        )
    }

    /// Builds the item by CALLING the materializer with a single-exercise day, then
    /// seeds the load across the arrays the materializer sized.
    private static func buildItem(
        order: Int,
        wave: WaveType,
        prescription: WavePrescription,
        load: Double
    ) -> SessionItem {
        let plan = ResolvedExercisePlan(
            order: order,
            exerciseId: exerciseId,
            priority: .standard,
            notes: nil,
            wave: wave,
            setMin: prescription.setMin,
            setMax: prescription.setMax,
            repMin: prescription.repMin,
            repMax: prescription.repMax,
            targetRIRMin: prescription.targetRIRMin,
            targetRIRMax: prescription.targetRIRMax,
            intensifier: prescription.intensifier,
            intensifierNotes: prescription.intensifierNotes,
            defaultSets: prescription.defaultSetCount,
            defaultTargetReps: prescription.defaultTargetReps,
            defaultTargetRIR: prescription.defaultTargetRIR
        )
        let day = MaterializedProgramDay(
            templateId: "",
            weekNumber: 0,
            wave: wave,
            dayNumber: 0,
            title: "",
            role: "",
            exercises: [plan]
        )
        let item = DUPSessionMaterializer.makeSessionItems(from: day)[0]

        // The materializer seeds loads at 0; this repair sources them from Pull B.
        item.suggestedLoad = load
        item.plannedLoadsBySet = Array(repeating: load, count: item.plannedLoadsBySet.count)
        return item
    }

    // MARK: - Helpers

    private static func sessions(in block: MesoBlock, labelled label: String) -> [Session] {
        block.sessions
            .filter { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == label }
            .filter { weeks.contains($0.weekInMeso ?? -1) }
            .sorted { ($0.weekInMeso ?? 0) < ($1.weekInMeso ?? 0) }
    }

    private static func findItem(_ id: String, in session: Session) -> SessionItem? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        return session.items.first {
            ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
        }
    }

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

    private static func opt<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
