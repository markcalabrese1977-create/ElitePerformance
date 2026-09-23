// Domain/Sync/MesoProgramAlignmentRepair.swift
import Foundation
import SwiftData

/// One-shot repair aligning the active "10-Week DUP Meso" to the user's actual
/// program: day-label renames, exercise swaps/add/remove, and per-wave
/// prescription corrections.
///
/// Authorized as "Option 2": the canonical swap/add paths
/// (`ProgramDayDetailView.swapExercise` / `.addExercise` / `.applyPlanChangesToBlock`)
/// are `private` methods on SwiftUI Views and cannot be called from a migration,
/// and the meso-wide apply services copy wave-specific fields wholesale — which
/// would flatten weeks 2-10 onto week 1's wave. So this writes fields directly,
/// under these guardrails:
///
/// - New/swapped-in items are built by CALLING `DUPSessionMaterializer.makeSessionItems`
///   with a single-exercise `MaterializedProgramDay`, so construction, array
///   sizing (planned arrays = targetSets, actual arrays left empty) and the
///   flattening asymmetry (targetReps = repMin, targetRIR = targetRIRMax, both
///   taken from `WavePrescription`'s own computed properties) come from the
///   canonical builder rather than being restated here.
/// - Loads are only ever seeded through `LoadProjectionService.lastKnownLoad`
///   (the 38458d4 canonical re-seed). No load is written any other way.
/// - Swaps are IN PLACE on the existing item: identity and `order` are kept, and
///   `ExerciseSwapPropagationService` is deliberately NOT called because its
///   scope is every future planned session across all day types, which would
///   re-create the cross-day spillover this repair exists to correct.
/// - Set-count changes resize the planned AND actual arrays together, using
///   PlanMemoryEngine's documented BUG#1 extend/truncate rule.
///
/// Identity changes (swap/add/remove) apply to all 10 weeks. Prescription
/// changes apply to weeks 1-9; week 10 keeps `waveRaw == "deload"` and takes the
/// template's deload prescription for that exercise, or mirrors the replaced
/// item's week-10 values when the exercise is not in the base template.
enum MesoProgramAlignmentRepair {

    // MARK: - Mode

    /// While true: runs every gate, builds every change and prints the full plan,
    /// but writes nothing and never sets the completion flag.
    static let dryRun = true

    private static let completionKey = "mesoProgramAlignmentRepair.v1.completed"

    private static let expectedBlockName = "10-Week DUP Meso"
    private static let expectedSessionCount = 60

    private static var template: ProgramTemplate { DUP10WeekTemplate.template }

    // MARK: - Day renames (old template title -> new label)

    /// Also consumed by MesoCustomizationDiagnostic so it can still resolve days
    /// after this repair renames them.
    static let dayRenames: [(old: String, new: String)] = [
        ("Chest + Triceps",                      "Push A"),
        ("Back + Biceps",                        "Legs A"),
        ("Legs",                                 "Pull A"),
        ("Chest + Biceps + Triceps",             "Push B"),
        ("Posterior Chain + Core",               "Legs B"),
        ("Back + Shoulders + Biceps + Triceps",  "Pull B")
    ]

    // MARK: - Change model

    /// A prescription for one wave. `sets == nil` means "leave the set count alone".
    private struct WaveSpec {
        let repMin: Int
        let repMax: Int
        let rirMin: Int
        let rirMax: Int
        let sets: Int?

        init(_ repMin: Int, _ repMax: Int, rir: Int, sets: Int? = nil) {
            self.repMin = repMin
            self.repMax = repMax
            self.rirMin = rir
            self.rirMax = rir
            self.sets = sets
        }

        init(_ repMin: Int, _ repMax: Int, rirMin: Int, rirMax: Int, sets: Int? = nil) {
            self.repMin = repMin
            self.repMax = repMax
            self.rirMin = rirMin
            self.rirMax = rirMax
            self.sets = sets
        }

        /// The canonical prescription object, so the reps/RIR flattening
        /// asymmetry comes from WavePrescription rather than being restated.
        func prescription(for wave: WaveType, fallbackSets: Int) -> WavePrescription {
            let n = sets ?? fallbackSets
            return WavePrescription(
                wave: wave,
                setMin: n, setMax: n,
                repMin: repMin, repMax: repMax,
                targetRIRMin: rirMin, targetRIRMax: rirMax
            )
        }
    }

    private enum Op {
        /// Change prescriptions on an existing item, identity untouched.
        case prescription(exerciseId: String, byWave: [WaveType: WaveSpec])
        /// Swap in place: keep the item and its order, change identity + prescriptions.
        /// `deloadTemplateId` names the exercise whose template deload prescription
        /// week 10 should take; nil means mirror the replaced item's week-10 values.
        case swap(from: String, to: String, byWave: [WaveType: WaveSpec], deloadTemplateId: String?)
        /// Insert a new item immediately before `before`, in every week.
        case add(exerciseId: String, before: String, byWave: [WaveType: WaveSpec], deloadTemplateId: String?)
        /// Remove from every week.
        case remove(exerciseId: String)
        /// Set prescriptionNotes on the given waves' items.
        case notes(exerciseId: String, waves: Set<WaveType>, text: String)
    }

    private struct DayPlan {
        let oldTitle: String
        let ops: [Op]
    }

    // MARK: - The plan

    /// Bench top-set note. Recon (g): logging the top set as the LAST row is
    /// coaching-neutral — CoachingEngine evaluates only the first
    /// `min(targetSets, 3)` working sets, so a 4th row falls outside
    /// `primaryIndices` and `baseLoad` stays the last back-off set. Logged FIRST
    /// it would land inside primaryIndices and break progression, hence the
    /// explicit ordering instruction.
    private static let benchTopSetNote = "Top set 1 × 4–6 @2 first — log it as the LAST row"

    private static var plan: [DayPlan] {
        [
            DayPlan(oldTitle: "Chest + Triceps", ops: [
                .prescription(exerciseId: "bench_press", byWave: [
                    .a: WaveSpec(0, 0, rirMin: 1, rirMax: 2),          // RIR only — reps/sets untouched
                    .b: WaveSpec(6, 8, rir: 2, sets: 3),
                    .c: WaveSpec(8, 10, rir: 2, sets: 3)
                ]),
                .notes(exerciseId: "bench_press", waves: [.b, .c], text: benchTopSetNote),
                .swap(from: "seated_cable_fly", to: "incline_rear_delt_fly", byWave: [
                    .a: WaveSpec(10, 12, rir: 2, sets: 3),
                    .b: WaveSpec(12, 15, rir: 2, sets: 3),
                    .c: WaveSpec(15, 20, rir: 2, sets: 3)
                ], deloadTemplateId: "incline_rear_delt_fly")
            ]),

            DayPlan(oldTitle: "Back + Biceps", ops: [
                .swap(from: "dumbbell_lateral_raise", to: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822", byWave: [
                    .a: WaveSpec(10, 12, rir: 1, sets: 3),
                    .b: WaveSpec(12, 15, rir: 1, sets: 3),
                    .c: WaveSpec(15, 20, rir: 1, sets: 3)
                ], deloadTemplateId: nil),                              // custom id — mirror replaced item's week 10
                .prescription(exerciseId: "leg_extension", byWave: [
                    .a: WaveSpec(0, 0, rirMin: 1, rirMax: 2),           // RIR only — reps/sets untouched
                    .b: WaveSpec(0, 0, rirMin: 1, rirMax: 2),
                    .c: WaveSpec(0, 0, rirMin: 1, rirMax: 2)
                ]),
                .add(exerciseId: "lying_leg_curl", before: "farmer_carry", byWave: [
                    .a: WaveSpec(8, 10, rir: 2, sets: 2),
                    .b: WaveSpec(10, 12, rir: 2, sets: 2),
                    .c: WaveSpec(12, 15, rir: 2, sets: 2)
                ], deloadTemplateId: "lying_leg_curl")
            ]),

            DayPlan(oldTitle: "Legs", ops: [
                .remove(exerciseId: "cable_glute_kickback"),
                .prescription(exerciseId: "t_bar_row", byWave: [
                    .c: WaveSpec(0, 0, rirMin: -1, rirMax: -1, sets: 3) // sets only — reps/RIR untouched
                ])
            ]),

            DayPlan(oldTitle: "Chest + Biceps + Triceps", ops: [
                .prescription(exerciseId: "decline_bench_press", byWave: [
                    .a: WaveSpec(0, 0, rirMin: 1, rirMax: 2),           // RIR only
                    .b: WaveSpec(6, 8, rir: 2),
                    .c: WaveSpec(8, 10, rir: 2)
                ])
            ]),

            DayPlan(oldTitle: "Posterior Chain + Core", ops: []),
            DayPlan(oldTitle: "Back + Shoulders + Biceps + Triceps", ops: [])
        ]
    }

    /// Sentinel meaning "this field is not being changed by this spec".
    private static let keep = 0
    private static let keepRIR = -1

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext) {
        var report: [String] = []

        func abort(_ reason: String) {
            print(([header(), "ABORT — \(reason)"] + report).joined(separator: "\n"))
        }

        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Meso program alignment repair not needed (already applied).")
            return
        }

        // MARK: Gates

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            abort("could not fetch meso blocks."); return
        }
        let active = blocks.filter { $0.status == .active && $0.isMaintenance == false }
        guard active.count == 1, let meso = active.first else {
            abort("expected exactly one active non-maintenance block, found \(active.count)."); return
        }
        guard meso.name == expectedBlockName else {
            abort("expected block named '\(expectedBlockName)', found '\(meso.name)'."); return
        }
        guard meso.sessions.count == expectedSessionCount else {
            abort("expected \(expectedSessionCount) sessions, found \(meso.sessions.count)."); return
        }

        let unsafe = meso.sessions.filter { !isSafeToModify($0) }
        guard unsafe.isEmpty else {
            let detail = unsafe.sorted { $0.date < $1.date }
                .map { "\(($0.dayLabel ?? "?")) w\($0.weekIndex) (status=\($0.status.rawValue), logged=\(hasLoggedData($0)))" }
                .joined(separator: "; ")
            abort("\(unsafe.count) of \(meso.sessions.count) sessions are not safe to modify: \(detail)"); return
        }

        // Every day must resolve by its CURRENT dayLabel.
        var sessionsByDay: [String: [Int: Session]] = [:]
        for dayPlan in plan {
            let daySessions = meso.sessions.filter { ($0.dayLabel ?? "") == dayPlan.oldTitle }
            guard !daySessions.isEmpty else {
                let newLabel = dayRenames.first { $0.old == dayPlan.oldTitle }?.new ?? "?"
                let alreadyRenamed = meso.sessions.contains { ($0.dayLabel ?? "") == newLabel }
                abort("no sessions carry dayLabel '\(dayPlan.oldTitle)'." + (alreadyRenamed ? " Sessions labelled '\(newLabel)' exist — the rename may already have been applied without the completion flag being set. Not writing." : " Present labels: \(Set(meso.sessions.compactMap(\.dayLabel)).sorted().joined(separator: ", "))"))
                return
            }
            guard daySessions.count == 10 else {
                abort("day '\(dayPlan.oldTitle)' has \(daySessions.count) sessions, expected 10."); return
            }
            var byWeek: [Int: Session] = [:]
            for session in daySessions {
                guard byWeek[session.weekIndex] == nil else {
                    abort("day '\(dayPlan.oldTitle)' has more than one session for week \(session.weekIndex)."); return
                }
                byWeek[session.weekIndex] = session
            }
            guard Set(byWeek.keys) == Set(1...10) else {
                abort("day '\(dayPlan.oldTitle)' weeks are \(byWeek.keys.sorted()), expected 1...10."); return
            }
            sessionsByDay[dayPlan.oldTitle] = byWeek
        }

        // Every target item must resolve by canonical exerciseId, in every week.
        for dayPlan in plan {
            let byWeek = sessionsByDay[dayPlan.oldTitle]!
            for op in dayPlan.ops {
                for required in requiredExerciseIds(op) {
                    let missing = (1...10).filter { week in
                        findItem(required, in: byWeek[week]!) == nil
                    }
                    guard missing.isEmpty else {
                        let found = byWeek[1]!.items.sorted { $0.order < $1.order }
                            .map { "\($0.order):\(ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId))" }
                            .joined(separator: ", ")
                        abort("day '\(dayPlan.oldTitle)': expected exerciseId '\(required)' in every week, missing in week(s) \(missing.map(String.init).joined(separator: ", ")). Week 1 currently holds: [\(found)]")
                        return
                    }
                }
            }
        }

        report.append(header())
        report.append("Block '\(meso.name)' · \(meso.sessions.count) sessions · starts \(format(meso.startDate))")
        report.append("Waves: A = weeks 1,4,7 · B = 2,5,8 · C = 3,6,9 · deload = 10 (from DUP10WeekTemplate.weekRules)")
        report.append("")

        // MARK: Apply

        var totals = Totals()

        for dayPlan in plan {
            let byWeek = sessionsByDay[dayPlan.oldTitle]!
            let newLabel = dayRenames.first { $0.old == dayPlan.oldTitle }!.new

            report.append("── \(dayPlan.oldTitle)  →  \(newLabel)")

            // 1) Rename + sessionNotes, all 10 weeks.
            for week in 1...10 {
                let session = byWeek[week]!
                if !dryRun { session.dayLabel = newLabel }
                totals.renamed += 1

                let wave = waveFor(week)
                let expectedNotes = "\(dayPlan.oldTitle) · \(wave.displayName) wave"
                let actualNotes = session.sessionNotes ?? ""
                if actualNotes == expectedNotes {
                    let rewritten = "\(newLabel) · \(wave.displayName) wave"
                    if !dryRun { session.sessionNotes = rewritten }
                    totals.notesRewritten += 1
                } else {
                    totals.notesLeft += 1
                    report.append("   NOTE w\(week): sessionNotes left as-is (not the materializer's generated string). Expected '\(expectedNotes)', found '\(actualNotes)'.")
                }
            }

            // 2) Item ops, week by week.
            var laterWeekCounts: [String: Int] = ["changed": 0, "added": 0, "removed": 0]

            for week in 1...10 {
                let session = byWeek[week]!
                let wave = waveFor(week)
                let verbose = (week <= 3)
                if verbose && !dayPlan.ops.isEmpty {
                    report.append("   ── week \(week) (wave \(wave.displayName))")
                }

                for op in dayPlan.ops {
                    let outcome = apply(
                        op: op,
                        session: session,
                        week: week,
                        wave: wave,
                        context: context,
                        report: &report,
                        verbose: verbose
                    )
                    totals.add(outcome)
                    if !verbose {
                        switch outcome {
                        case .changed: laterWeekCounts["changed"]! += 1
                        case .added:   laterWeekCounts["added"]! += 1
                        case .removed: laterWeekCounts["removed"]! += 1
                        case .none:    break
                        }
                    }
                }
            }

            if !dayPlan.ops.isEmpty {
                report.append("   weeks 4–10 summary: \(laterWeekCounts["changed"]!) changed, \(laterWeekCounts["added"]!) added, \(laterWeekCounts["removed"]!) removed")
            } else {
                report.append("   no item changes on this day (rename only)")
            }
            report.append("")
        }

        report.append("TOTALS: \(totals.renamed) sessions renamed · \(totals.notesRewritten) sessionNotes rewritten, \(totals.notesLeft) left · \(totals.changed) items changed · \(totals.added) added · \(totals.removed) removed")

        // MARK: Finish

        if dryRun {
            report.append("")
            report.append("DRY RUN — nothing was written and the completion flag was NOT set.")
            print(report.joined(separator: "\n"))
            return
        }

        do {
            try context.save()
        } catch {
            report.append("")
            report.append("⚠️ SAVE FAILED: \(error). Nothing persisted; flag not set, so this retries next launch.")
            print(report.joined(separator: "\n"))
            return
        }

        UserDefaults.standard.set(true, forKey: completionKey)
        report.append("")
        report.append("✅ Applied and saved.")
        print(report.joined(separator: "\n"))
    }

    // MARK: - Op application

    private enum Outcome { case none, changed, added, removed }

    private static func apply(
        op: Op,
        session: Session,
        week: Int,
        wave: WaveType,
        context: ModelContext,
        report: inout [String],
        verbose: Bool
    ) -> Outcome {
        switch op {

        case let .prescription(exerciseId, byWave):
            guard let item = findItem(exerciseId, in: session) else { return .none }
            // Week 10 keeps its deload prescription untouched.
            guard week < 10, let spec = byWave[wave] else { return .none }
            let before = snapshot(item)
            let after = plannedAfterPrescription(item: item, spec: spec, wave: wave)
            if !dryRun { applyPrescription(to: item, spec: spec, wave: wave) }
            if verbose { report.append("      \(before) → \(after)") }
            return .changed

        case let .swap(from, to, byWave, deloadTemplateId):
            guard let item = findItem(from, in: session) else { return .none }
            let before = snapshot(item)

            // Identity changes in every week, including 10.
            let seeded = LoadProjectionService.lastKnownLoad(for: to, currentSession: session, context: context)

            let spec: WaveSpec?
            if week < 10 {
                spec = byWave[wave]
            } else if let deloadTemplateId, let deload = templateDeloadPrescription(for: deloadTemplateId) {
                spec = WaveSpec(deload.repMin, deload.repMax, rirMin: deload.targetRIRMin, rirMax: deload.targetRIRMax, sets: deload.defaultSetCount)
            } else {
                spec = nil // mirror the replaced item's week-10 values: identity only
            }

            let after = plannedAfterSwap(item: item, to: to, spec: spec, wave: wave, seededLoad: seeded)
            if !dryRun {
                applySwapInPlace(item: item, to: to, seededLoad: seeded)
                if let spec { applyPrescription(to: item, spec: spec, wave: week < 10 ? wave : .deload) }
            }
            if verbose {
                report.append("      \(before) → \(after)")
                report.append("        lastKnownLoad('\(to)') = \(String(format: "%.1f", seeded))\(seeded > 0 ? "" : "  (no history — load left at 0)")")
            }
            return .changed

        case let .add(exerciseId, before, byWave, deloadTemplateId):
            guard let anchor = findItem(before, in: session) else { return .none }
            let insertOrder = anchor.order

            let spec: WaveSpec?
            if week < 10 {
                spec = byWave[wave]
            } else if let deloadTemplateId, let deload = templateDeloadPrescription(for: deloadTemplateId) {
                spec = WaveSpec(deload.repMin, deload.repMax, rirMin: deload.targetRIRMin, rirMax: deload.targetRIRMax, sets: deload.defaultSetCount)
            } else {
                spec = nil
            }
            guard let spec else { return .none }

            let effectiveWave: WaveType = (week < 10) ? wave : .deload
            let seeded = LoadProjectionService.lastKnownLoad(for: exerciseId, currentSession: session, context: context)
            let newItem = buildItem(exerciseId: exerciseId, order: insertOrder, wave: effectiveWave, spec: spec)
            if seeded > 0 {
                newItem.suggestedLoad = seeded
                newItem.plannedLoadsBySet = Array(repeating: seeded, count: newItem.targetSets)
            }

            if !dryRun {
                for other in session.items where other.order >= insertOrder {
                    other.order += 1
                }
                session.items.append(newItem)
            }

            if verbose {
                report.append("      + ADD \(snapshot(newItem)) (inserted at order \(insertOrder), before '\(before)')")
                report.append("        lastKnownLoad('\(exerciseId)') = \(String(format: "%.1f", seeded))\(seeded > 0 ? "" : "  (no history — load left at 0)")")
            }
            return .added

        case let .remove(exerciseId):
            guard let item = findItem(exerciseId, in: session) else { return .none }
            let before = snapshot(item)
            let removedOrder = item.order
            if !dryRun {
                session.items.removeAll { $0 === item }
                context.delete(item)
                for other in session.items where other.order > removedOrder {
                    other.order -= 1
                }
            }
            if verbose { report.append("      − REMOVE \(before)") }
            return .removed

        case let .notes(exerciseId, waves, text):
            guard week < 10, waves.contains(wave), let item = findItem(exerciseId, in: session) else { return .none }
            if !dryRun { item.prescriptionNotes = text }
            if verbose { report.append("      note on \(exerciseId): \"\(text)\"") }
            return .none  // counted with the prescription change, not separately
        }
    }

    // MARK: - Field writes

    private static func applySwapInPlace(item: SessionItem, to newId: String, seededLoad: Double) {
        // Mirrors ProgramDayDetailView.swapExercise: identity changes, the
        // prescription shape stays, loads/actuals/notes reset, then the canonical
        // re-seed. ExerciseSwapPropagationService is deliberately not called.
        item.exerciseId = newId
        item.exerciseNameSnapshot = ExerciseCatalog.displayName(for: newId)
        item.suggestedLoad = 0
        item.plannedLoadsBySet = Array(repeating: 0.0, count: item.plannedLoadsBySet.count)
        item.actualLoads = Array(repeating: 0.0, count: item.actualLoads.count)
        item.actualReps = Array(repeating: 0, count: item.actualReps.count)
        item.actualRIRs = Array(repeating: 0, count: item.actualRIRs.count)
        item.coachNote = nil
        item.prescriptionNotes = nil
        item.intensifierNotes = nil

        if seededLoad > 0 {
            item.suggestedLoad = seededLoad
            item.plannedLoadsBySet = Array(repeating: seededLoad, count: item.plannedLoadsBySet.count)
        }
    }

    private static func applyPrescription(to item: SessionItem, spec: WaveSpec, wave: WaveType) {
        let fallbackSets = max(1, item.targetSets)
        let prescription = spec.prescription(for: wave, fallbackSets: fallbackSets)

        if spec.repMin != keep || spec.repMax != keep {
            item.repMin = spec.repMin
            item.repMax = spec.repMax
            item.targetReps = prescription.defaultTargetReps      // = repMin
        }
        if spec.rirMin != keepRIR || spec.rirMax != keepRIR {
            item.targetRIRMin = spec.rirMin
            item.targetRIRMax = spec.rirMax
            item.targetRIR = prescription.defaultTargetRIR        // = targetRIRMax
        }

        if let sets = spec.sets, sets != item.targetSets {
            resize(item, to: sets)
        }

        // Keep the per-set plan consistent with the scalars, the way the
        // materializer seeds them.
        item.plannedRepsBySet = Array(repeating: item.targetReps, count: item.targetSets)
        item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: item.targetSets)
        item.plannedLoadsBySet = resized(item.plannedLoadsBySet, to: item.targetSets)
    }

    /// Resizes every per-set array together. PlanMemoryEngine's BUG#1 rule:
    /// extend by repeating the last element (0 when empty), truncate with prefix.
    /// Actual arrays that are empty stay empty, matching the materializer.
    private static func resize(_ item: SessionItem, to count: Int) {
        item.targetSets = count
        item.plannedRepsBySet = resized(item.plannedRepsBySet, to: count)
        item.plannedRIRsBySet = resized(item.plannedRIRsBySet, to: count)
        item.plannedLoadsBySet = resized(item.plannedLoadsBySet, to: count)
        if !item.actualReps.isEmpty  { item.actualReps  = resized(item.actualReps, to: count) }
        if !item.actualLoads.isEmpty { item.actualLoads = resized(item.actualLoads, to: count) }
        if !item.actualRIRs.isEmpty  { item.actualRIRs  = resized(item.actualRIRs, to: count) }
    }

    private static func resized<T>(_ array: [T], to count: Int, zero: T) -> [T] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: array.last ?? zero, count: count - array.count)
    }

    private static func resized(_ array: [Int], to count: Int) -> [Int] { resized(array, to: count, zero: 0) }
    private static func resized(_ array: [Double], to count: Int) -> [Double] { resized(array, to: count, zero: 0.0) }

    // MARK: - Canonical item construction

    /// Builds a new item by CALLING the materializer with a single-exercise day,
    /// so field set, array sizing and the reps/RIR flattening asymmetry all come
    /// from `DUPSessionMaterializer` rather than being restated here.
    private static func buildItem(exerciseId: String, order: Int, wave: WaveType, spec: WaveSpec) -> SessionItem {
        let prescription = spec.prescription(for: wave, fallbackSets: 3)
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
            templateId: template.id,
            weekNumber: 0,
            wave: wave,
            dayNumber: 0,
            title: "",
            role: "",
            exercises: [plan]
        )
        return DUPSessionMaterializer.makeSessionItems(from: day)[0]
    }

    // MARK: - Lookups

    private static func waveFor(_ week: Int) -> WaveType {
        template.rule(forWeek: week)?.wave ?? .a
    }

    private static func findItem(_ exerciseId: String, in session: Session) -> SessionItem? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        return session.items.first {
            ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
        }
    }

    /// The base template's deload prescription for an exercise, looked up by id
    /// across every day (the user's block has drifted from the template, so the
    /// exercise may sit on a different day than the template puts it on).
    private static func templateDeloadPrescription(for exerciseId: String) -> WavePrescription? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        for day in template.dayTemplates {
            for slot in day.exerciseTemplates
            where ExerciseCatalog.canonicalExerciseId(for: slot.exerciseId) == canonical {
                if let deload = slot.prescription(for: .deload) { return deload }
            }
        }
        return nil
    }

    private static func requiredExerciseIds(_ op: Op) -> [String] {
        switch op {
        case let .prescription(exerciseId, _): return [exerciseId]
        case let .swap(from, _, _, _):         return [from]
        case let .add(_, before, _, _):        return [before]
        case let .remove(exerciseId):          return [exerciseId]
        case let .notes(exerciseId, _, _):     return [exerciseId]
        }
    }

    // MARK: - Rendering

    private static func header() -> String {
        dryRun ? "🧪 DRY RUN — no writes" : "🔧 MESO PROGRAM ALIGNMENT REPAIR"
    }

    private static func snapshot(_ item: SessionItem) -> String {
        let reps = range(item.repMin, item.repMax)
        let rir = range(item.targetRIRMin, item.targetRIRMax)
        let loads = item.plannedLoadsBySet.map { String(format: "%.0f", $0) }.joined(separator: ",")
        return "\(item.exerciseId) (\(ExerciseCatalog.displayName(for: item.exerciseId))) \(item.targetSets)×\(reps) @RIR \(rir) loads[\(loads)]"
    }

    private static func plannedAfterPrescription(item: SessionItem, spec: WaveSpec, wave: WaveType) -> String {
        let sets = spec.sets ?? item.targetSets
        let reps = (spec.repMin == keep && spec.repMax == keep)
            ? range(item.repMin, item.repMax)
            : range(spec.repMin, spec.repMax)
        let rir = (spec.rirMin == keepRIR && spec.rirMax == keepRIR)
            ? range(item.targetRIRMin, item.targetRIRMax)
            : range(spec.rirMin, spec.rirMax)
        let loads = resized(item.plannedLoadsBySet, to: sets).map { String(format: "%.0f", $0) }.joined(separator: ",")
        return "\(item.exerciseId) \(sets)×\(reps) @RIR \(rir) loads[\(loads)]"
    }

    private static func plannedAfterSwap(item: SessionItem, to newId: String, spec: WaveSpec?, wave: WaveType, seededLoad: Double) -> String {
        let sets = spec?.sets ?? item.targetSets
        let reps = (spec == nil || (spec!.repMin == keep && spec!.repMax == keep))
            ? range(item.repMin, item.repMax)
            : range(spec!.repMin, spec!.repMax)
        let rir = (spec == nil || (spec!.rirMin == keepRIR && spec!.rirMax == keepRIR))
            ? range(item.targetRIRMin, item.targetRIRMax)
            : range(spec!.rirMin, spec!.rirMax)
        let loads = Array(repeating: seededLoad, count: sets).map { String(format: "%.0f", $0) }.joined(separator: ",")
        return "\(newId) (\(ExerciseCatalog.displayName(for: newId))) \(sets)×\(reps) @RIR \(rir) loads[\(loads)]"
    }

    private static func range(_ lo: Int?, _ hi: Int?) -> String {
        switch (lo, hi) {
        case let (l?, h?): return l == h ? "\(l)" : "\(l)-\(h)"
        case let (l?, nil): return "\(l)-?"
        case let (nil, h?): return "?-\(h)"
        default: return "?"
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd EEE"
        return formatter.string(from: date)
    }

    // MARK: - Safety (same predicate as Week6UpperBCleanupMigration)

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

    // MARK: - Totals

    private struct Totals {
        var renamed = 0
        var notesRewritten = 0
        var notesLeft = 0
        var changed = 0
        var added = 0
        var removed = 0

        mutating func add(_ outcome: Outcome) {
            switch outcome {
            case .changed: changed += 1
            case .added:   added += 1
            case .removed: removed += 1
            case .none:    break
            }
        }
    }
}
