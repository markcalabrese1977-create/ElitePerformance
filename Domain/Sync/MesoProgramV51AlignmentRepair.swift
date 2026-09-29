// Domain/Sync/MesoProgramV51AlignmentRepair.swift
import Foundation
import SwiftData

/// One-shot repair: align the active meso to program v5.1.
///
/// Five independent edits, applied to the single active non-maintenance block:
///
///  1. RIR changes on eight (day, exercise) pairs, weeks 1-9 (the deload week is
///     deliberately untouched). `plannedRIRsBySet` is rewritten only across its live
///     prefix — indices `0..<targetSets` — so an item carrying a padded tail from an
///     earlier set-count reduction (e.g. [2, 2, 2, 0] with targetSets 3) keeps that
///     trailing 0 instead of having it revived as a real RIR value.
///  2. Three exercise ADDs, built by calling `DUPSessionMaterializer.makeSessionItems`
///     with a synthetic single-exercise day — the same approach as
///     MesoProgramAlignmentRepair and PullALateralRaiseAddRepair — so `waveRaw`, the
///     rep/RIR/set ranges, the reps/RIR flattening asymmetry (`targetReps` = repMin,
///     `targetRIR` = targetRIRMax) and the `planned*` array sizing all come from the
///     materializer rather than being restated here and drifting from it.
///  3. One in-place SWAP (barbell_row → a custom chest-supported row) on Pull B.
///  4. A flat pushdown load on Push A / Push B.
///  5. A prescription note on hack_squat, Legs A.
///
/// Waves: A = weeks 1, 4, 7 · B = 2, 5, 8 · C = 3, 6, 9 · deload = 10.
///
/// SCOPE — planned sessions only. A `.completed` session is never a target: it is
/// skipped and logged, not gated and not written. Anything else in scope that fails
/// `isSafeToModify` (an `.inProgress` session, or a `.planned` one already carrying
/// logged data) is an anomaly and aborts the whole repair, so the gate has teeth
/// rather than silently degrading to "skip whatever isn't safe".
///
/// NAME SNAPSHOTS — the two custom exercises are resolved against the `CustomExercise`
/// SwiftData table, NOT via `ExerciseCatalog.displayName`. That helper reads
/// `ExerciseCatalog.all`, which merges built-ins with the *UserDefaults* custom mirror;
/// for a `custom_<uuid>` id that is missing from that mirror it falls through to the
/// prettified-id fallback and would stamp "A3e5e40e 8435 4d3f 899a 216b580c3020" into
/// `exerciseNameSnapshot`. The table is already gated here, so reading the name from it
/// is both correct and free. Built-in ids still go through the catalog.
///
/// SWAP SCOPE — `MesoProgramAlignmentRepair.applySwapInPlace` also cleared actuals,
/// `coachNote`, `prescriptionNotes` and `intensifierNotes`. This repair deliberately
/// does not: the spec is "keep the item, its order, and its prescription", and every
/// swap target is gated free of logged data, so clearing actuals would be a no-op while
/// clearing the notes would be an unrequested change.
///
/// ORDERING — no two items in a touched session may share an `order`. Inserts shift
/// later items and every shift is logged. The projected roster is built during the gate
/// pass and checked for ties, so a pre-existing collision aborts rather than being
/// carried forward.
///
/// Safety: all-or-nothing. Every gate is checked across every target before anything is
/// written, and one violation aborts the whole repair. The write plan is computed during
/// the gate pass, so the dry-run log is exactly what a live run would perform. `dryRun`
/// logs without saving; the completion flag is set only after a save actually succeeds,
/// so a dry or failed run retries on the next launch.
enum MesoProgramV51AlignmentRepair {

    /// Dry run reviewed on-device 2026-09-29: 131 writes, padded RIR tails preserved.
    private static let dryRun = false

    private static let completionKey = "mesoProgramV51AlignmentRepair.v1.completed"

    // MARK: - Day labels

    private static let pushA = "Push A"
    private static let pushB = "Push B"
    private static let pullA = "Pull A"
    private static let pullB = "Pull B"
    private static let legsA = "Legs A"

    /// Log order.
    private static let dayOrder = [pushA, pushB, pullA, pullB, legsA]

    private static let allWeeks = 1...10

    // MARK: - Custom exercise ids (gated against the CustomExercise table)

    private static let lowToHighCableFlyId = "custom_a3e5e40e-8435-4d3f-899a-216b580c3020"
    private static let chestSupportedRowId = "custom_491c982e-3d5e-4753-be54-f6b244faa19b"

    private static var requiredCustomIds: [String] {
        [lowToHighCableFlyId, chestSupportedRowId]
    }

    // MARK: - Step 1 · RIR changes (weeks 1-9; week 10 deload untouched)

    private struct RIRChange {
        let day: String
        let exerciseId: String
        let rirMin: Int
        let rirMax: Int
    }

    private static let rirWeeks = 1...9

    private static let rirChanges: [RIRChange] = [
        RIRChange(day: pushA, exerciseId: "incline_rear_delt_fly",  rirMin: 1, rirMax: 1),
        RIRChange(day: pullA, exerciseId: "incline_rear_delt_fly",  rirMin: 1, rirMax: 1),
        RIRChange(day: pushB, exerciseId: "seated_cable_fly",       rirMin: 1, rirMax: 1),
        RIRChange(day: pullA, exerciseId: "dumbbell_lateral_raise", rirMin: 1, rirMax: 1),
        RIRChange(day: pushB, exerciseId: "dumbbell_lateral_raise", rirMin: 1, rirMax: 1),
        RIRChange(day: pullB, exerciseId: "dumbbell_lateral_raise", rirMin: 1, rirMax: 1),
        RIRChange(day: pullA, exerciseId: "hammer_curl",            rirMin: 1, rirMax: 2),
        RIRChange(day: pullB, exerciseId: "hammer_curl",            rirMin: 1, rirMax: 2)
    ]

    // MARK: - Step 2 · Adds

    private enum Placement {
        case last
        case before(String)
    }

    private struct AddPrescription {
        let sets: Int
        let repMin: Int
        let repMax: Int
        let rirMin: Int
        let rirMax: Int
        let load: Double
    }

    private struct AddSpec {
        let step: String
        let day: String
        let exerciseId: String
        let weeks: ClosedRange<Int>
        let placement: Placement
        let a: AddPrescription
        let b: AddPrescription
        let c: AddPrescription

        /// Uniform deload prescription: 2 × 10-12 @ RIR 3-4, seeded from the B week.
        var deload: AddPrescription {
            AddPrescription(sets: 2, repMin: 10, repMax: 12, rirMin: 3, rirMax: 4, load: b.load)
        }

        func prescription(for wave: WaveType) -> AddPrescription {
            switch wave {
            case .a:      return a
            case .b:      return b
            case .c:      return c
            case .deload: return deload
            }
        }
    }

    private static let addSpecs: [AddSpec] = [
        AddSpec(
            step: "2a",
            day: pushA,
            exerciseId: "single_arm_cable_lateral_raise",
            weeks: 2...10,
            placement: .last,
            a: AddPrescription(sets: 3, repMin: 10, repMax: 12, rirMin: 1, rirMax: 1, load: 25.0),
            b: AddPrescription(sets: 3, repMin: 12, repMax: 15, rirMin: 1, rirMax: 1, load: 22.5),
            c: AddPrescription(sets: 3, repMin: 15, repMax: 20, rirMin: 1, rirMax: 1, load: 20.0)
        ),
        AddSpec(
            step: "2b",
            day: pushB,
            exerciseId: lowToHighCableFlyId,
            weeks: 2...10,
            placement: .before("cable_tricep_rope_pushdown"),
            a: AddPrescription(sets: 3, repMin: 8,  repMax: 10, rirMin: 1, rirMax: 1, load: 27.5),
            b: AddPrescription(sets: 3, repMin: 10, repMax: 12, rirMin: 1, rirMax: 1, load: 25.0),
            c: AddPrescription(sets: 3, repMin: 12, repMax: 15, rirMin: 1, rirMax: 1, load: 22.5)
        ),
        AddSpec(
            step: "2c",
            day: pullB,
            exerciseId: "cable_rear_delt_fly",
            weeks: 1...10,
            placement: .last,
            a: AddPrescription(sets: 3, repMin: 10, repMax: 12, rirMin: 1, rirMax: 1, load: 37.5),
            b: AddPrescription(sets: 3, repMin: 12, repMax: 15, rirMin: 1, rirMax: 1, load: 35.0),
            c: AddPrescription(sets: 3, repMin: 15, repMax: 20, rirMin: 1, rirMax: 1, load: 32.5)
        )
    ]

    // MARK: - Step 3 · Swap

    private static let swapDay = pullB
    private static let swapWeeks = 1...10
    private static let swapFromId = "barbell_row"
    private static let swapToId = chestSupportedRowId

    private static func swapLoad(for wave: WaveType) -> Double {
        switch wave {
        case .a:      return 205.0
        case .b:      return 195.0
        case .c:      return 185.0
        case .deload: return 195.0
        }
    }

    // MARK: - Step 4 · Pushdown loads

    private static let pushdownId = "cable_tricep_rope_pushdown"
    private static let pushdownDays = [pushA, pushB]
    private static let pushdownWeeks = 2...10
    private static let pushdownLoad: Double = 60.0

    // MARK: - Step 5 · Note

    private static let noteDay = legsA
    private static let noteWeeks = 1...10
    private static let noteExerciseId = "hack_squat"
    private static let noteText = "Wide stance, toe-out. Progress reps, then load."

    // MARK: - Waves

    private static func waveFor(week: Int) -> WaveType {
        switch week {
        case 1, 4, 7: return .a
        case 2, 5, 8: return .b
        case 3, 6, 9: return .c
        default:      return .deload
        }
    }

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Meso v5.1 alignment not needed.")
            return
        }

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ Meso v5.1 alignment: could not fetch meso blocks — aborting, nothing written.")
            return
        }

        // MARK: Gate — exactly one active, non-maintenance block

        let active = blocks.filter { $0.status == .active && !$0.isMaintenance }
        guard active.count == 1, let block = active.first else {
            print("⛔️ Meso v5.1 alignment ABORTED — expected exactly 1 active non-maintenance block, found \(active.count). Nothing written.")
            return
        }

        var violations: [String] = []

        // MARK: Gate — the custom exercise ids exist in the custom exercise table

        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        for id in requiredCustomIds {
            let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
            let matches = customs.filter { ExerciseCatalog.canonicalExerciseId(for: $0.id) == canonical }
            if matches.count != 1 {
                violations.append("custom exercise \(id): expected 1 row in the custom exercise table, found \(matches.count)")
            }
        }

        // MARK: Resolve target sessions per day

        /// Every day/week this repair touches at all, so the log covers the whole scope.
        var scope: [String: Set<Int>] = [:]
        func widen(_ day: String, _ weeks: ClosedRange<Int>) {
            scope[day, default: []].formUnion(weeks)
        }
        for change in rirChanges { widen(change.day, rirWeeks) }
        for spec in addSpecs { widen(spec.day, spec.weeks) }
        widen(swapDay, swapWeeks)
        for day in pushdownDays { widen(day, pushdownWeeks) }
        widen(noteDay, noteWeeks)

        /// day → week → session, for weeks that resolve to exactly one session.
        var targets: [String: [Int: Session]] = [:]
        /// day → weeks skipped because the session is already completed.
        var completedWeeks: [String: Set<Int>] = [:]

        for day in dayOrder {
            guard let weeks = scope[day] else { continue }
            let byWeek = Dictionary(
                grouping: block.sessions.filter {
                    $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == day
                },
                by: { $0.weekInMeso ?? -1 }
            )

            for week in weeks.sorted() {
                let found = byWeek[week] ?? []

                // Target resolution must be unambiguous for every day/week in scope.
                guard found.count == 1, let session = found.first else {
                    violations.append("\(day) wk\(week): expected exactly 1 session in scope, found \(found.count)")
                    continue
                }

                // Completed sessions are never touched — skipped, not gated.
                if session.status == .completed {
                    completedWeeks[day, default: []].insert(week)
                    continue
                }

                // Gate — everything else in scope must be planned with no logged data.
                if !isSafeToModify(session) {
                    violations.append("\(day) wk\(week) \(format(session.date)): not safe to modify (status=\(session.status.rawValue), hasLoggedData=\(hasLoggedData(session)))")
                    continue
                }

                targets[day, default: [:]][week] = session
            }
        }

        // MARK: Plan every write, gating as we go

        var log: [String] = []
        var writes: [() -> Void] = []
        var totals: [String: Int] = [:]
        var shifts = 0
        var skipped = 0

        func bump(_ step: String) { totals[step, default: 0] += 1 }

        for day in dayOrder {
            guard let weeks = scope[day] else { continue }
            log.append("")
            log.append("── \(day)")

            for week in weeks.sorted() {
                let wave = waveFor(week: week)

                if completedWeeks[day]?.contains(week) == true {
                    log.append("   ·· wk\(week)  — SKIPPED (session completed; never touched)")
                    skipped += 1
                    continue
                }

                guard let session = targets[day]?[week] else {
                    // Already recorded as a violation above.
                    continue
                }

                var lines: [String] = []

                /// Projected roster: the single source for both the log and the writes,
                /// so a dry run previews exactly what a live run performs.
                var projected: [(id: String, order: Int)] = session.items.map {
                    (ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId), $0.order)
                }

                // ── Step 1 · RIR
                if rirWeeks.contains(week) {
                    for change in rirChanges where change.day == day {
                        guard let item = requireExactlyOne(
                            change.exerciseId, in: session,
                            step: "1", day: day, week: week, into: &violations
                        ) else { continue }

                        let newRIR = change.rirMax          // materializer rule: targetRIR = targetRIRMax
                        let beforeRIRs = item.plannedRIRsBySet

                        // Only the first `targetSets` entries are live sets. Some items carry a
                        // padded tail (e.g. [2, 2, 2, 0] with targetSets 3) left behind by an
                        // earlier set-count reduction; rewriting the whole array would revive
                        // that trailing slot as a real RIR value. Write the live prefix and
                        // leave the tail exactly as found.
                        let liveCount = min(max(0, item.targetSets), beforeRIRs.count)
                        var afterRIRs = beforeRIRs
                        for index in 0..<liveCount { afterRIRs[index] = newRIR }
                        let padded = beforeRIRs.count > liveCount

                        lines.append("      ~ \(change.exerciseId)   [step 1 · RIR]")
                        lines.append("          targetRIRMin/Max   \(opt(item.targetRIRMin))/\(opt(item.targetRIRMax)) → \(change.rirMin)/\(change.rirMax)")
                        lines.append("          targetRIR          \(item.targetRIR) → \(newRIR)")
                        lines.append("          plannedRIRsBySet   \(beforeRIRs) → \(afterRIRs)\(padded ? "   [targetSets \(item.targetSets); wrote indices 0..<\(liveCount), padded tail preserved]" : "")\(afterRIRs == beforeRIRs ? "   [no-op on the array]" : "")")

                        writes.append {
                            item.targetRIRMin = change.rirMin
                            item.targetRIRMax = change.rirMax
                            item.targetRIR = newRIR
                            item.plannedRIRsBySet = afterRIRs
                        }
                        bump("1")
                    }
                }

                // ── Step 2 · Adds
                for spec in addSpecs where spec.day == day && spec.weeks.contains(week) {
                    // Gate — must not already be present on a week we are writing to.
                    if let existing = findItem(spec.exerciseId, in: session) {
                        violations.append("\(day) wk\(week): already contains \(spec.exerciseId) at order \(existing.order) — step \(spec.step) would duplicate")
                        continue
                    }

                    let insertOrder: Int
                    var anchorNote: String

                    switch spec.placement {
                    case .last:
                        let maxOrder = session.items.map(\.order).max() ?? 0
                        insertOrder = maxOrder + 1
                        anchorNote = "last (previous max order \(maxOrder))"

                    case .before(let anchorId):
                        guard let anchor = requireExactlyOne(
                            anchorId, in: session,
                            step: spec.step, day: day, week: week, into: &violations
                        ) else { continue }
                        insertOrder = anchor.order
                        anchorNote = "directly before \(anchorId) @ \(anchor.order)"
                    }

                    let p = spec.prescription(for: wave)
                    let name = resolvedName(for: spec.exerciseId, customs: customs)
                    let item = buildItem(
                        exerciseId: spec.exerciseId,
                        name: name,
                        order: insertOrder,
                        wave: wave,
                        prescription: p
                    )

                    lines.append("      + \(spec.exerciseId)   \(name)   [step \(spec.step) · ADD]")
                    lines.append("          order              nil → \(insertOrder)   (\(anchorNote))")
                    lines.append("          waveRaw            \(item.waveRaw ?? "nil")")
                    lines.append("          sets × reps        \(item.targetSets) × \(item.targetReps)   (setMin/Max \(opt(item.setMin))/\(opt(item.setMax)), repMin/Max \(opt(item.repMin))/\(opt(item.repMax)))")
                    lines.append("          targetRIR          \(item.targetRIR)   (min/max \(opt(item.targetRIRMin))/\(opt(item.targetRIRMax)))")
                    lines.append("          suggestedLoad      \(fmt(p.load))\(wave == .deload ? "   [deload: B-week seed]" : "")")
                    lines.append("          plannedReps        \(item.plannedRepsBySet)")
                    lines.append("          plannedLoads       \(item.plannedLoadsBySet)")
                    lines.append("          plannedRIRs        \(item.plannedRIRsBySet)")
                    lines.append("          priority/intens.   \(item.priorityRaw ?? "nil") / \(item.intensifierRaw ?? "nil")   planEdited \(item.planEdited)   prescriptionNotes \(opt(item.prescriptionNotes))")

                    // Shift later items so nothing shares an order.
                    let later = session.items
                        .filter { $0.order >= insertOrder }
                        .sorted { $0.order < $1.order }

                    if later.isEmpty {
                        lines.append("          no later items — no shift needed")
                    } else {
                        lines.append("          shifting \(later.count) later item(s) +1: " + later.map {
                            "\(ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId)) \($0.order)→\($0.order + 1)"
                        }.joined(separator: ", "))
                        shifts += later.count
                    }

                    // Mirror the shift + insert into the projection.
                    projected = projected.map { $0.order >= insertOrder ? ($0.id, $0.order + 1) : $0 }
                    projected.append((ExerciseCatalog.canonicalExerciseId(for: spec.exerciseId), insertOrder))

                    writes.append {
                        for other in later { other.order += 1 }
                        context.insert(item)
                        session.items.append(item)
                    }
                    bump(spec.step)
                }

                // ── Step 3 · Swap
                if day == swapDay, swapWeeks.contains(week) {
                    if let item = requireExactlyOne(
                        swapFromId, in: session,
                        step: "3", day: day, week: week, into: &violations
                    ) {
                        let load = swapLoad(for: wave)
                        let name = resolvedName(for: swapToId, customs: customs)
                        let beforeLoads = item.plannedLoadsBySet
                        let afterLoads = Array(repeating: load, count: beforeLoads.count)

                        lines.append("      ⇄ \(swapFromId) → \(swapToId)   [step 3 · SWAP in place]")
                        lines.append("          order              \(item.order) (unchanged)   prescription unchanged")
                        lines.append("          exerciseNameSnap.  \(opt(item.exerciseNameSnapshot)) → \(name)")
                        lines.append("          suggestedLoad      \(fmt(item.suggestedLoad)) → \(fmt(load))")
                        lines.append("          plannedLoadsBySet  \(beforeLoads.map(fmt)) → \(afterLoads.map(fmt))")

                        projected = projected.map {
                            $0.id == ExerciseCatalog.canonicalExerciseId(for: swapFromId)
                                ? (ExerciseCatalog.canonicalExerciseId(for: swapToId), $0.order)
                                : $0
                        }

                        writes.append {
                            item.exerciseId = swapToId
                            item.exerciseNameSnapshot = name
                            item.suggestedLoad = load
                            item.plannedLoadsBySet = afterLoads
                        }
                        bump("3")
                    }
                }

                // ── Step 4 · Pushdown loads
                if pushdownDays.contains(day), pushdownWeeks.contains(week) {
                    if let item = requireExactlyOne(
                        pushdownId, in: session,
                        step: "4", day: day, week: week, into: &violations
                    ) {
                        let beforeLoads = item.plannedLoadsBySet
                        let afterLoads = Array(repeating: pushdownLoad, count: beforeLoads.count)

                        lines.append("      ~ \(pushdownId)   [step 4 · LOAD]")
                        lines.append("          suggestedLoad      \(fmt(item.suggestedLoad)) → \(fmt(pushdownLoad))")
                        lines.append("          plannedLoadsBySet  \(beforeLoads.map(fmt)) → \(afterLoads.map(fmt))")

                        writes.append {
                            item.suggestedLoad = pushdownLoad
                            item.plannedLoadsBySet = afterLoads
                        }
                        bump("4")
                    }
                }

                // ── Step 5 · Note
                if day == noteDay, noteWeeks.contains(week) {
                    if let item = requireExactlyOne(
                        noteExerciseId, in: session,
                        step: "5", day: day, week: week, into: &violations
                    ) {
                        lines.append("      ~ \(noteExerciseId)   [step 5 · NOTE]")
                        lines.append("          prescriptionNotes  \(opt(item.prescriptionNotes)) → \"\(noteText)\"")

                        writes.append { item.prescriptionNotes = noteText }
                        bump("5")
                    }
                }

                // ── Per-week log
                if lines.isEmpty {
                    log.append("   ·· wk\(week)  \(format(session.date))  [wave \(wave.rawValue)]  — no changes in scope")
                    continue
                }

                log.append("   ── wk\(week)  \(format(session.date))  [wave \(wave.rawValue)]")
                log.append(contentsOf: lines)

                let roster = projected.sorted { $0.order < $1.order }
                log.append("          roster after: " + roster.map { "\($0.order):\($0.id)" }.joined(separator: ", "))

                // Gate — no order ties anywhere in a session we touch.
                let orders = roster.map(\.order)
                if Set(orders).count != orders.count {
                    let dupes = Set(orders.filter { o in orders.filter { $0 == o }.count > 1 }).sorted()
                    violations.append("\(day) wk\(week): resulting roster has order tie(s) at \(dupes)")
                }
            }
        }

        guard violations.isEmpty else {
            print("""
            ⛔️ Meso v5.1 alignment ABORTED — nothing written. \(violations.count) gate violation(s):
            \(violations.map { "   • " + $0 }.joined(separator: "\n"))
            """)
            return
        }

        // MARK: Write (or, under dryRun, describe)

        let banner = dryRun ? "DRY RUN — nothing written" : "LIVE — writing"
        let summary = """

        ══ Meso program v5.1 alignment · \(banner) ══
        block: \(block.name)   waves: A=1,4,7  B=2,5,8  C=3,6,9  deload=10
        \(log.joined(separator: "\n"))

        ══ TOTALS ══
           step 1  RIR changes .................. \(totals["1", default: 0]) item(s)
           step 2a single-arm cable lat raise ... \(totals["2a", default: 0]) added
           step 2b low to high cable fly ........ \(totals["2b", default: 0]) added
           step 2c cable rear delt fly .......... \(totals["2c", default: 0]) added
           step 3  barbell row swap ............. \(totals["3", default: 0]) swapped
           step 4  pushdown loads ............... \(totals["4", default: 0]) item(s)
           step 5  hack squat note .............. \(totals["5", default: 0]) item(s)
           order shifts ......................... \(shifts)
           sessions skipped (completed) ......... \(skipped)
           total writes ......................... \(writes.count)
        ══
        """

        guard !dryRun else {
            print(summary)
            print("ℹ️ Meso v5.1 alignment: dry run only — no save, completion flag NOT set.")
            return
        }

        for write in writes { write() }

        do {
            try context.save()
            print(summary)
            print("✅ Meso v5.1 alignment complete.")
        } catch {
            print(summary)
            print("⚠️ Meso v5.1 alignment save failed: \(error). Nothing persisted; will retry next launch.")
            return  // do not mark complete
        }

        UserDefaults.standard.set(true, forKey: completionKey)
    }

    // MARK: - Construction

    /// Builds a new item by CALLING the materializer with a single-exercise day, so the
    /// field set, array sizing and the reps/RIR flattening asymmetry come from
    /// `DUPSessionMaterializer`. Loads and the name snapshot are seeded afterwards.
    private static func buildItem(
        exerciseId: String,
        name: String,
        order: Int,
        wave: WaveType,
        prescription p: AddPrescription
    ) -> SessionItem {
        let spec = WavePrescription(
            wave: wave,
            setMin: p.sets,
            setMax: p.sets,
            repMin: p.repMin,
            repMax: p.repMax,
            targetRIRMin: p.rirMin,
            targetRIRMax: p.rirMax,
            intensifier: .none,
            intensifierNotes: nil
        )
        let plan = ResolvedExercisePlan(
            order: order,
            exerciseId: exerciseId,
            priority: .standard,
            notes: nil,                       // prescriptionNotes nil
            wave: wave,
            setMin: spec.setMin,
            setMax: spec.setMax,
            repMin: spec.repMin,
            repMax: spec.repMax,
            targetRIRMin: spec.targetRIRMin,
            targetRIRMax: spec.targetRIRMax,
            intensifier: spec.intensifier,
            intensifierNotes: spec.intensifierNotes,
            defaultSets: spec.defaultSetCount,
            defaultTargetReps: spec.defaultTargetReps,
            defaultTargetRIR: spec.defaultTargetRIR
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

        // The materializer seeds loads at 0 and the snapshot from ExerciseCatalog.
        item.suggestedLoad = p.load
        item.plannedLoadsBySet = Array(repeating: p.load, count: item.plannedLoadsBySet.count)
        item.exerciseNameSnapshot = name
        return item
    }

    // MARK: - Helpers

    /// Custom-aware display name — see the note on `ExerciseCatalog.displayName` above.
    private static func resolvedName(for id: String, customs: [CustomExercise]) -> String {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        if let custom = customs.first(where: {
            ExerciseCatalog.canonicalExerciseId(for: $0.id) == canonical
        }) {
            return custom.name
        }
        return ExerciseCatalog.displayName(for: id)
    }

    /// Gate — the item a step expects must be present exactly once. Returns it, or
    /// records a violation and returns nil.
    private static func requireExactlyOne(
        _ exerciseId: String,
        in session: Session,
        step: String,
        day: String,
        week: Int,
        into violations: inout [String]
    ) -> SessionItem? {
        let matches = items(exerciseId, in: session)
        guard matches.count == 1 else {
            violations.append("\(day) wk\(week): step \(step) expects exactly 1 \(exerciseId), found \(matches.count)")
            return nil
        }
        return matches[0]
    }

    private static func items(_ id: String, in session: Session) -> [SessionItem] {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        return session.items.filter {
            ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
        }
    }

    private static func findItem(_ id: String, in session: Session) -> SessionItem? {
        items(id, in: session).first
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

    /// `nonisolated` so it can be passed by value to `map` from a synchronous context.
    private nonisolated static func fmt(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
