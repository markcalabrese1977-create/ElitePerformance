// Domain/Sync/MesoCustomizationDiagnostic.swift
import Foundation
import SwiftData

/// READ-ONLY startup diagnostic. Dumps the active meso's per-slot state against
/// its base template so cross-day customization spillover can be assessed.
///
/// Why: `PreviewOverrides.slotOverrides` is keyed by `exerciseId` alone, and
/// `DUPProgramSeeder.applying(overrides:to:)` maps that one dictionary over every
/// day template. In a template where an exerciseId appears on more than one day
/// (confirmed for "10-Week DUP Meso" and "5-Day Upper / Lower + Pump" — see
/// TemplateSlotKeyInvariantTests), a single customize/swap/delete in the
/// onboarding preview was applied to EVERY day carrying that id.
///
/// This type writes nothing — no SwiftData mutation, no `context.save()`, no
/// UserDefaults, no AppState — and has no completion flag, so it re-runs every
/// launch until it is deleted.
///
/// Alignment note: `ProgramTemplateResolver.resolveDay` maps EVERY slot of a day
/// template, including `.optional` ones, so session items correspond 1:1 with
/// template slots by their `order` value. A swap preserves `order` and changes
/// `exerciseId`; a delete removes the slot entirely; an addition is appended at
/// `maxOrder + 10 * n`. Alignment here is therefore by `order`, and anything that
/// does not line up is reported rather than guessed at.
enum MesoCustomizationDiagnostic {

    private static let header = "🔍 CUSTOMIZATION DIAGNOSTIC — read-only"

    private static let knownTemplates: [ProgramTemplate] = [
        DUP10WeekTemplate.template,
        PPL6DayTemplate.template,
        Hybrid5DayTemplate.template,
        UpperLower4DayTemplate.template,
        PPL3WeekTemplate.template,
        FullBody2DayTemplate.template
    ]

    // MARK: - Entry point

    static func run(in context: ModelContext) {
        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("\(header)\nABORT — could not fetch meso blocks.")
            return
        }

        let active = blocks.filter { $0.status == .active && $0.isMaintenance == false }
        guard active.count == 1, let meso = active.first else {
            print("\(header)\nABORT — expected exactly one active non-maintenance meso block, found \(active.count).")
            return
        }

        guard let template = knownTemplates.first(where: { $0.name == meso.name }) else {
            print("\(header)\nABORT — could not resolve a template from block name '\(meso.name)'. Known: \(knownTemplates.map(\.name).joined(separator: ", ")).")
            return
        }

        let totalWeeks = meso.totalWeeks ?? template.totalWeeks

        // exerciseId -> day titles it appears on, within THIS template.
        var daysByExerciseId: [String: [String]] = [:]
        for day in template.dayTemplates {
            for slot in day.exerciseTemplates {
                daysByExerciseId[slot.exerciseId, default: []].append(day.title)
            }
        }
        let dupKeyIds = Set(daysByExerciseId.filter { $0.value.count > 1 }.keys)

        print("""
            \(header)
            Block '\(meso.name)' · template '\(template.name)' · \(totalWeeks) weeks · \(template.dayTemplates.count) days · \(meso.sessions.count) sessions
            Cross-day duplicated exerciseIds in this template: \(dupKeyIds.isEmpty ? "none" : dupKeyIds.sorted().joined(separator: ", "))
            Legend: CHANGED = differs from template · SWAPPED · DELETED · DUP-KEY = id on >1 day · ADDED = per-day keyed, unaffected by the bug
            """)

        // Collected for the spillover section: (exerciseId, dayTitle) -> state
        var statesByDupId: [String: [(day: String, state: SlotState)]] = [:]

        for day in template.dayTemplates.sorted(by: { $0.dayNumber < $1.dayNumber }) {
            let dayStates = reportDay(
                day: day,
                meso: meso,
                template: template,
                totalWeeks: totalWeeks,
                dupKeyIds: dupKeyIds
            )
            for (slotId, state) in dayStates where dupKeyIds.contains(slotId) {
                statesByDupId[slotId, default: []].append((day: day.title, state: state))
            }
        }

        reportSpillover(statesByDupId: statesByDupId, daysByExerciseId: daysByExerciseId)
    }

    // MARK: - Per-slot state

    private struct SlotState {
        var currentExerciseId: String?          // nil == deleted
        var setsByWeekCurrent: [Int?]
        var setsByWeekTemplate: [Int]
        var wavesCurrent: [WaveType: String]    // rendered "8-10 @RIR 2-3"
        var wavesTemplate: [WaveType: String]
        var ambiguity: String?

        /// Canonical form used to decide whether two days ended up identical.
        var signature: String {
            let waves = [WaveType.a, .b, .c, .deload]
                .map { "\($0.rawValue):\(wavesCurrent[$0] ?? "-")" }
                .joined(separator: "|")
            let sets = setsByWeekCurrent.map { $0.map(String.init) ?? "-" }.joined(separator: ",")
            return "\(currentExerciseId ?? "<deleted>")#\(sets)#\(waves)"
        }
    }

    // MARK: - Day report

    /// - Returns: template exerciseId -> resolved state, for the spillover section.
    private static func reportDay(
        day: ProgramDayTemplate,
        meso: MesoBlock,
        template: ProgramTemplate,
        totalWeeks: Int,
        dupKeyIds: Set<String>
    ) -> [(String, SlotState)] {

        var lines: [String] = ["", "── \(day.title)  (day \(day.dayNumber))"]

        // Accept the post-repair label too: MesoProgramAlignmentRepair renames
        // these days, and this diagnostic must keep resolving them afterwards.
        let acceptedLabels = Set([day.title] + MesoProgramAlignmentRepair.dayRenames
            .filter { $0.old == day.title }
            .map(\.new))

        let daySessions = meso.sessions
            .filter { acceptedLabels.contains($0.dayLabel ?? "") }
            .sorted { $0.weekIndex < $1.weekIndex }

        guard !daySessions.isEmpty else {
            lines.append("   AMBIGUOUS — no sessions carry any of \(acceptedLabels.sorted()). Cannot align.")
            print(lines.joined(separator: "\n"))
            return []
        }

        if let current = daySessions.first?.dayLabel, current != day.title {
            lines[1] += "  [labelled '\(current)']"
        }

        // weekIndex -> session. A repeated week makes the whole day ambiguous.
        var sessionByWeek: [Int: Session] = [:]
        var repeatedWeeks: [Int] = []
        for session in daySessions {
            if sessionByWeek[session.weekIndex] != nil {
                repeatedWeeks.append(session.weekIndex)
            } else {
                sessionByWeek[session.weekIndex] = session
            }
        }
        if !repeatedWeeks.isEmpty {
            lines.append("   AMBIGUOUS — week(s) \(repeatedWeeks.sorted().map(String.init).joined(separator: ", ")) have more than one '\(day.title)' session. Cannot align by week.")
            print(lines.joined(separator: "\n"))
            return []
        }

        let presentWeeks = sessionByWeek.keys.sorted()
        let missingWeeks = (1...totalWeeks).filter { sessionByWeek[$0] == nil }
        if !missingWeeks.isEmpty {
            lines.append("   NOTE — no session for week(s) \(missingWeeks.map(String.init).joined(separator: ", ")); those columns print '-'.")
        }

        // A duplicated `order` inside one session makes that session unalignable.
        for week in presentWeeks {
            let orders = sessionByWeek[week]!.items.map(\.order)
            if Set(orders).count != orders.count {
                lines.append("   AMBIGUOUS — week \(week) has items sharing the same `order` value \(orders.sorted()). Cannot align by order.")
                print(lines.joined(separator: "\n"))
                return []
            }
        }

        // Roster drift across weeks: the set of orders should be identical.
        let orderSets = presentWeeks.map { Set(sessionByWeek[$0]!.items.map(\.order)) }
        if let first = orderSets.first, !orderSets.allSatisfy({ $0 == first }) {
            let detail = presentWeeks.map { week in
                "w\(week):[\(sessionByWeek[week]!.items.map(\.order).sorted().map(String.init).joined(separator: ","))]"
            }.joined(separator: " ")
            lines.append("   AMBIGUOUS — roster differs between weeks, so no single alignment exists. Orders per week: \(detail)")
            lines.append("   (Reporting per-slot anyway below; treat every row on this day as unverified.)")
        }

        let templateOrders = Set(day.exerciseTemplates.map(\.order))
        var results: [(String, SlotState)] = []

        for slot in day.exerciseTemplates.sorted(by: { $0.order < $1.order }) {
            var state = SlotState(
                currentExerciseId: nil,
                setsByWeekCurrent: [],
                setsByWeekTemplate: [],
                wavesCurrent: [:],
                wavesTemplate: [:],
                ambiguity: nil
            )

            // Current exercise id, cross-checked across every week.
            var idsSeen: Set<String> = []
            for week in presentWeeks {
                if let item = sessionByWeek[week]!.items.first(where: { $0.order == slot.order }) {
                    idsSeen.insert(item.exerciseId)
                }
            }
            if idsSeen.count > 1 {
                state.ambiguity = "exerciseId differs across weeks: \(idsSeen.sorted().joined(separator: ", "))"
            }
            state.currentExerciseId = idsSeen.count == 1 ? idsSeen.first : idsSeen.sorted().first

            // Sets by week.
            for week in 1...totalWeeks {
                let item = sessionByWeek[week]?.items.first(where: { $0.order == slot.order })
                state.setsByWeekCurrent.append(item?.targetSets)
                let wave = template.rule(forWeek: week)?.wave ?? .a
                state.setsByWeekTemplate.append(slot.sets(forWeek: week, wave: wave))
            }

            // Per wave — read from the first week whose rule uses that wave.
            for wave in [WaveType.a, .b, .c, .deload] {
                if let prescription = slot.prescription(for: wave) {
                    state.wavesTemplate[wave] = renderRange(
                        repMin: prescription.repMin, repMax: prescription.repMax,
                        rirMin: prescription.targetRIRMin, rirMax: prescription.targetRIRMax
                    )
                }
                guard let week = (1...totalWeeks).first(where: { template.rule(forWeek: $0)?.wave == wave }),
                      let item = sessionByWeek[week]?.items.first(where: { $0.order == slot.order })
                else { continue }
                state.wavesCurrent[wave] = renderRange(
                    repMin: item.repMin, repMax: item.repMax,
                    rirMin: item.targetRIRMin, rirMax: item.targetRIRMax
                )
            }

            lines.append(contentsOf: renderSlot(slot: slot, state: state, isDupKey: dupKeyIds.contains(slot.exerciseId)))
            results.append((slot.exerciseId, state))
        }

        // Added exercises — any item order not present in the template.
        let referenceWeek = presentWeeks.first!
        let added = sessionByWeek[referenceWeek]!.items
            .filter { !templateOrders.contains($0.order) }
            .sorted { $0.order < $1.order }

        if added.isEmpty {
            lines.append("   ADDED: none")
        } else {
            lines.append("   ADDED (\(added.count)) — keyed per day, unaffected by the slotOverrides bug:")
            for item in added {
                let setsByWeek = (1...totalWeeks)
                    .map { week -> String in
                        guard let match = sessionByWeek[week]?.items.first(where: { $0.order == item.order }) else { return "-" }
                        return String(match.targetSets)
                    }
                    .joined(separator: ",")
                lines.append("     [ord \(item.order)] \(item.exerciseId) (\(displayName(item.exerciseId)))  sets [\(setsByWeek)]")
            }
        }

        print(lines.joined(separator: "\n"))
        return results
    }

    // MARK: - Slot rendering

    private static func renderSlot(
        slot: ProgramExerciseTemplate,
        state: SlotState,
        isDupKey: Bool
    ) -> [String] {
        var out: [String] = []

        var markers: [String] = []
        if isDupKey { markers.append("DUP-KEY") }
        if slot.priority == .optional { markers.append("optional-slot (not shown in preview, so never customizable there)") }

        let deleted = (state.currentExerciseId == nil)
        let swapped = !deleted && state.currentExerciseId != slot.exerciseId
        if deleted { markers.append("DELETED") }
        if swapped { markers.append("SWAPPED") }

        out.append("   [ord \(slot.order)] \(markers.isEmpty ? "" : markers.joined(separator: " "))")

        if let ambiguity = state.ambiguity {
            out.append("       AMBIGUOUS — \(ambiguity)")
        }

        if deleted {
            out.append("       id:     \(slot.exerciseId) (\(displayName(slot.exerciseId))) → <no item on any week>")
            return out
        }

        let currentId = state.currentExerciseId ?? slot.exerciseId
        if swapped {
            out.append("       id:     \(slot.exerciseId) (\(displayName(slot.exerciseId))) → \(currentId) (\(displayName(currentId)))")
        } else {
            out.append("       id:     \(currentId) (\(displayName(currentId)))")
        }

        let currentSets = state.setsByWeekCurrent.map { $0.map(String.init) ?? "-" }.joined(separator: ",")
        let templateSets = state.setsByWeekTemplate.map(String.init).joined(separator: ",")
        let setsChanged = zip(state.setsByWeekCurrent, state.setsByWeekTemplate).contains { $0 != nil && $0 != $1 }
        out.append("       sets:   cur [\(currentSets)]  tpl [\(templateSets)]\(setsChanged ? "   CHANGED" : "")")

        for wave in [WaveType.a, .b, .c, .deload] {
            let current = state.wavesCurrent[wave]
            let templateValue = state.wavesTemplate[wave]
            guard current != nil || templateValue != nil else { continue }
            let changed = (current != nil && templateValue != nil && current != templateValue)
            out.append("       wave \(wave.displayName.padding(toLength: 6, withPad: " ", startingAt: 0)) cur \((current ?? "-").padding(toLength: 18, withPad: " ", startingAt: 0)) tpl \(templateValue ?? "-")\(changed ? "   CHANGED" : "")")
        }

        return out
    }

    // MARK: - Spillover summary

    private static func reportSpillover(
        statesByDupId: [String: [(day: String, state: SlotState)]],
        daysByExerciseId: [String: [String]]
    ) {
        var lines = ["", "══ SPILLOVER SUMMARY — cross-day duplicated exerciseIds ══"]

        guard !statesByDupId.isEmpty else {
            lines.append("No cross-day duplicated exerciseIds resolved on this block. Nothing can have spilled over.")
            print(lines.joined(separator: "\n"))
            return
        }

        for exerciseId in statesByDupId.keys.sorted() {
            let entries = statesByDupId[exerciseId]!
            let expectedDays = daysByExerciseId[exerciseId] ?? []
            lines.append("")
            lines.append("• \(exerciseId) (\(displayName(exerciseId))) — template days: \(expectedDays.joined(separator: ", "))")

            for entry in entries {
                let state = entry.state
                let currentSets = state.setsByWeekCurrent.map { $0.map(String.init) ?? "-" }.joined(separator: ",")
                lines.append("    \(entry.day):")
                lines.append("      id   \(state.currentExerciseId ?? "<deleted>")")
                lines.append("      sets [\(currentSets)]")
                let waves = [WaveType.a, .b, .c, .deload]
                    .compactMap { wave -> String? in
                        guard let value = state.wavesCurrent[wave] else { return nil }
                        return "\(wave.displayName) \(value)"
                    }
                    .joined(separator: " · ")
                lines.append("      wave \(waves.isEmpty ? "-" : waves)")
            }

            let signatures = Set(entries.map(\.state.signature))
            if entries.count < expectedDays.count {
                lines.append("    ⇒ resolved on \(entries.count) of \(expectedDays.count) template days; comparison is partial.")
            }
            if signatures.count == 1 {
                lines.append("    ⇒ IDENTICAL across the \(entries.count) day(s) resolved — consistent with one edit having been applied to all of them.")
            } else {
                lines.append("    ⇒ DIFFERENT across days (\(signatures.count) distinct states) — these days diverged, so not every change was applied everywhere.")
            }
        }

        lines.append("")
        lines.append("Read: IDENTICAL does NOT prove spillover — a day may legitimately share the template's untouched defaults.")
        lines.append("Compare each day's rows above against 'tpl' to see whether the shared state is an edit or just the default.")
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func renderRange(repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?) -> String {
        let reps: String
        switch (repMin, repMax) {
        case let (min?, max?): reps = (min == max) ? "\(min)" : "\(min)-\(max)"
        case let (min?, nil):  reps = "\(min)-?"
        case let (nil, max?):  reps = "?-\(max)"
        default:               reps = "?"
        }

        let rir: String
        switch (rirMin, rirMax) {
        case let (min?, max?): rir = (min == max) ? "\(min)" : "\(min)-\(max)"
        case let (min?, nil):  rir = "\(min)-?"
        case let (nil, max?):  rir = "?-\(max)"
        default:               rir = "?"
        }

        return "\(reps) @RIR \(rir)"
    }

    private static func displayName(_ exerciseId: String) -> String {
        ExerciseCatalog.displayName(for: exerciseId)
    }
}
