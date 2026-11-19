// Domain/Analytics/PlannedVolume.swift
import Foundation
import SwiftData

/// Planned weekly hard sets per muscle for a block that does not exist yet, shown in every preview before seeding.
///
/// It is the same calculation as the actual volume of Meso Summary, with a different input: a planned slot's sets instead of
/// logged hard sets. Both credit muscles through `MuscleWeek.credit` (the muscle shares, synergist fractions and custom-exercise
/// mappings) and build their rows through `MuscleVolume.rows` (average over the weeks that count, the lifter's ranges, below /
/// within / above), so planned and actual cannot drift apart. Deload weeks are left out, as in the actual numbers. Planned
/// assumes every set is done; there is no adherence exclusion.
enum PlannedVolume {

    /// One planned week: whether it is a deload, and its working sets per exercise (a slot's `setsByWeek` for this week).
    struct Week: Equatable {
        let isDeload: Bool
        let slots: [Slot]
        struct Slot: Equatable { let exerciseId: String; let sets: Int }
    }

    struct Result {
        let rows: [MuscleVolumeSummary.Row]
        /// Non-deload weeks the averages cover.
        let averagedWeeks: Int
        /// Planned sets of exercises with no muscle mapping (a custom exercise the lifter has not mapped), summed over the
        /// block's non-deload weeks; they are in no muscle's number.
        let unmapped: [MuscleVolumeSummary.Unmapped]
        var unmappedSets: Int { unmapped.reduce(0) { $0 + $1.sets } }
        var isEmpty: Bool { averagedWeeks == 0 }
    }

    // MARK: - The calculation

    static func weeklyHardSets(weeks: [Week], customs: [CustomExercise] = [], profile: UserProfile? = nil,
                               nameFor: ((String) -> String)? = nil) -> Result {
        let shares = MuscleVolume.customShares(from: customs)
        var counted: [MuscleWeek] = []
        for week in weeks where !week.isDeload {
            var w = MuscleWeek(weekStart: Date(timeIntervalSince1970: Double(counted.count) * 7 * 86_400), sets: [:], directSets: [:],
                               sessions: 0, isComplete: true)
            for slot in week.slots { w.credit(exerciseId: slot.exerciseId, sets: Double(slot.sets), customShares: shares) }
            counted.append(w)
        }
        let ranges = profile?.muscleSetRanges ?? MuscleVolumeRanges.defaults
        let rows = MuscleVolume.rows(counted: counted, elapsed: counted, ranges: ranges)
        var unmappedTotals: [String: Double] = [:]
        for w in counted { for (id, n) in w.unmappedByExercise { unmappedTotals[id, default: 0] += n } }
        let editable = Set(customs.map(\.id))
        let unmapped = unmappedTotals.map { id, n in
            MuscleVolumeSummary.Unmapped(id: id, name: nameFor?(id) ?? customs.first { $0.id == id }?.name ?? ExerciseCatalog.displayName(for: id),
                                         sets: Int(n.rounded()), isEditable: editable.contains(id))
        }.sorted { ($1.sets, $0.name) < ($0.sets, $1.name) }
        return Result(rows: rows, averagedWeeks: counted.count, unmapped: unmapped)
    }

    // MARK: - Inputs

    /// The (fitted, overridden) template's weeks: every day's exercises resolved for the week (the same resolver seeding
    /// uses, so `setsByWeek` and the wave's default are honoured), deload weeks from the week rules.
    static func weeks(of template: ProgramTemplate) -> [Week] {
        (1...max(1, template.totalWeeks)).compactMap { weekNumber in
            guard let rule = template.rule(forWeek: weekNumber) else { return nil }
            var slots: [Week.Slot] = []
            for day in template.dayTemplates {
                guard let resolved = try? ProgramTemplateResolver.resolveDay(template: template, weekNumber: weekNumber, dayNumber: day.dayNumber) else { continue }
                slots += resolved.map { Week.Slot(exerciseId: $0.exerciseId, sets: max(0, $0.defaultSets)) }
            }
            return Week(isDeload: rule.isDeload, slots: slots)
        }
    }

    /// The onboarding / Change program preview: the fitted template with the preview's overrides applied (swap, delete,
    /// prescription and `setsByWeek` edits, added exercises), exactly as seeding applies them.
    static func weeklyHardSets(template: ProgramTemplate, overrides: PreviewOverrides?, customs: [CustomExercise] = [],
                               profile: UserProfile? = nil) -> Result {
        let effective = overrides.map { DUPProgramSeeder.applying(overrides: $0, to: template) } ?? template
        return weeklyHardSets(weeks: weeks(of: effective), customs: customs, profile: profile)
    }

    /// "Start next meso": the plan's sessions grouped by week. A week whose sessions are deload is a deload week.
    static func weeks(of plan: SessionItemEditService.NextMesoPlan) -> [Week] {
        Dictionary(grouping: plan.sessions, by: \.weekIndex).keys.sorted().map { index in
            let sessions = plan.sessions.filter { $0.weekIndex == index }
            let deload = sessions.contains { $0.letter.lowercased() == "deload" }
            let slots = sessions.flatMap(\.items).map { Week.Slot(exerciseId: $0.exerciseId, sets: max(0, $0.targetSets + $0.topCount)) }
            return Week(isDeload: deload, slots: slots)
        }
    }

    static func weeklyHardSets(plan: SessionItemEditService.NextMesoPlan, customs: [CustomExercise] = [], profile: UserProfile? = nil) -> Result {
        weeklyHardSets(weeks: weeks(of: plan), customs: customs, profile: profile)
    }
}

// MARK: - The block to compare with

enum LastBlockComparison {

    /// The block whose actual average a preview shows next to the plan, with exactly the numbers and exclusions of Meso Summary
    /// (`MuscleVolume.summary(wholeBlock: true)`).
    struct Source {
        let summary: MuscleVolumeSummary
        let blockName: String?
        let isActive: Bool
    }

    /// The active block when it has at least `minimumWeeks` complete weeks counted by Meso Summary's exclusions (weeks under 70%
    /// and deload weeks are not counted); otherwise the latest completed regular block (not the active one). Nil when neither
    /// exists. A block being replaced mid-way (Change program) is the comparison that matters most.
    static let minimumWeeks = 2

    static func source(snapshot: AnalyticsSnapshot, customs: [CustomExercise], profile: UserProfile?, asOf: Date,
                       activeMesoKey: String?) -> Source? {
        if let activeMesoKey {
            let s = MuscleVolume.summary(snapshot: snapshot, customs: customs, profile: profile, asOf: asOf, mesoKey: activeMesoKey, wholeBlock: true)
            if s.averagedWeeks >= minimumWeeks, !s.isEmpty {
                return Source(summary: s, blockName: s.blockName, isActive: true)
            }
        }
        let others = snapshot.sessions.filter { $0.status == .completed && !$0.isMaintenance && $0.mesoKey != activeMesoKey && $0.mesoKey != "none" }
        guard let latest = others.max(by: { $0.date < $1.date }) else { return nil }
        let s = MuscleVolume.summary(snapshot: snapshot, customs: customs, profile: profile, asOf: asOf, mesoKey: latest.mesoKey, wholeBlock: true)
        guard s.averagedWeeks >= 1, !s.isEmpty else { return nil }
        return Source(summary: s, blockName: s.blockName, isActive: false)
    }

    /// A specific block (Start next meso compares with the block being copied): its Meso Summary numbers, when it has at least
    /// one complete week.
    static func source(snapshot: AnalyticsSnapshot, customs: [CustomExercise], profile: UserProfile?, asOf: Date,
                       explicitMesoKey: String) -> Source? {
        let s = MuscleVolume.summary(snapshot: snapshot, customs: customs, profile: profile, asOf: asOf, mesoKey: explicitMesoKey, wholeBlock: true)
        guard s.averagedWeeks >= 1, !s.isEmpty else { return nil }
        return Source(summary: s, blockName: s.blockName, isActive: false)
    }

    /// A block's key as analytics keys it.
    static func key(for meso: MesoBlock) -> String { meso.id?.uuidString ?? "\(meso.persistentModelID)" }
}

// MARK: - The card

/// What the "Weekly volume" card shows: rows (below and above first), the one-line summary, the unmapped count and the footer.
struct PlannedVolumeCardModel {
    struct Row: Identifiable, Equatable {
        var id: FineMuscle { muscle }
        let muscle: FineMuscle
        let planned: Double
        let lastBlock: Double?
        let range: MuscleSetRange
        let status: MuscleVolume.Status
    }

    let rows: [Row]
    let unmappedSets: Int
    let hasComparison: Bool
    let lastBlockName: String?
    let lastBlockIsActive: Bool

    static let footer = "Planned assumes every set is done. Last block shows what was actually done."

    init(planned: PlannedVolume.Result, last: LastBlockComparison.Source?) {
        let lastByMuscle = last.map { Dictionary(uniqueKeysWithValues: $0.summary.rows.map { ($0.muscle, $0.average) }) }
        let all = planned.rows.map { r in
            Row(muscle: r.muscle, planned: r.average, lastBlock: lastByMuscle?[r.muscle], range: r.range, status: r.status)
        }
        // below, then above, then within; each group in muscle order.
        let order: [MuscleVolume.Status: Int] = [.below: 0, .above: 1, .within: 2]
        rows = all.enumerated().sorted { a, b in
            let (oa, ob) = (order[a.element.status] ?? 3, order[b.element.status] ?? 3)
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)
        unmappedSets = planned.unmappedSets
        hasComparison = last != nil
        lastBlockName = last?.blockName
        lastBlockIsActive = last?.isActive ?? false
    }

    var below: [Row] { rows.filter { $0.status == .below } }
    var above: [Row] { rows.filter { $0.status == .above } }

    /// "2 muscles below range: Side delts, Calves", "All muscles within range", with an above part when there is one.
    var summaryLine: String {
        func part(_ rows: [Row], _ word: String) -> String {
            "\(rows.count) muscle\(rows.count == 1 ? "" : "s") \(word) range: " + rows.map { $0.muscle.displayName }.joined(separator: ", ")
        }
        var parts: [String] = []
        if !below.isEmpty { parts.append(part(below, "below")) }
        if !above.isEmpty { parts.append(part(above, "above")) }
        return parts.isEmpty ? "All muscles within range" : parts.joined(separator: " · ")
    }
}
