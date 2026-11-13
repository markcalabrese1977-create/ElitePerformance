// Domain/Analytics/MuscleVolume.swift
import Foundation

/// A weekly target band for one muscle, in weighted hard sets per week.
struct MuscleSetRange: Equatable {
    var min: Double
    var max: Double
}

/// Default weekly set ranges per fine muscle and how they are stored.
///
/// The defaults follow commonly cited hypertrophy guidance (roughly: a minimum effective volume of ~6-10 hard sets per
/// muscle per week, productive growth up to ~16-20, more than that rarely worth the recovery cost; small or heavily
/// indirectly-trained muscles - front delts, forearms, adductors, lower back - need little or no direct work). They are a
/// STARTING POINT, not a prescription: every number is adjustable per lifter and is stored on `UserProfile`
/// (`muscleSetRangesStored`, keys "<muscle>.min" / "<muscle>.max"; only overrides are stored, so a changed default
/// reaches lifters who never edited a range). Ranges apply to WEIGHTED sets (primary 1.0 + synergists 0.25-0.5).
enum MuscleVolumeRanges {

    static let defaults: [FineMuscle: MuscleSetRange] = [
        .chest: .init(min: 10, max: 20),
        .lats: .init(min: 10, max: 20),
        .upperBack: .init(min: 8, max: 20),
        .frontDelts: .init(min: 0, max: 10),
        .sideDelts: .init(min: 8, max: 22),
        .rearDelts: .init(min: 6, max: 20),
        .biceps: .init(min: 8, max: 20),
        .triceps: .init(min: 6, max: 18),
        .quads: .init(min: 8, max: 18),
        .hamstrings: .init(min: 6, max: 16),
        .glutes: .init(min: 4, max: 16),
        .calves: .init(min: 8, max: 18),
        .abs: .init(min: 4, max: 16),
        .forearms: .init(min: 0, max: 10),
        .adductors: .init(min: 0, max: 10),
        .lowerBack: .init(min: 0, max: 8),
    ]

    /// Defaults with the lifter's overrides applied. A malformed or inverted override (max < min) is ignored.
    static func resolved(stored: [String: Double]?) -> [FineMuscle: MuscleSetRange] {
        var out = defaults
        for m in FineMuscle.allCases {
            guard var r = out[m] else { continue }
            if let v = stored?["\(m.rawValue).min"], v >= 0 { r.min = v }
            if let v = stored?["\(m.rawValue).max"], v >= 0 { r.max = v }
            if r.max >= r.min { out[m] = r }
        }
        return out
    }

    /// The overrides to store for `ranges`: only the numbers that differ from the defaults; nil when there are none.
    static func overrides(for ranges: [FineMuscle: MuscleSetRange]) -> [String: Double]? {
        var out: [String: Double] = [:]
        for m in FineMuscle.allCases {
            guard let r = ranges[m], let d = defaults[m] else { continue }
            if r.min != d.min { out["\(m.rawValue).min"] = r.min }
            if r.max != d.max { out["\(m.rawValue).max"] = r.max }
        }
        return out.isEmpty ? nil : out
    }
}

extension UserProfile {
    /// The lifter's weekly set ranges (defaults + overrides). Setting stores only the differences from the defaults.
    var muscleSetRanges: [FineMuscle: MuscleSetRange] {
        get { MuscleVolumeRanges.resolved(stored: muscleSetRangesStored) }
        set { muscleSetRangesStored = MuscleVolumeRanges.overrides(for: newValue) }
    }
}

/// Hard sets per week per fine muscle.
struct MuscleWeek: Equatable {
    /// Monday (ISO week) 00:00 of the week.
    let weekStart: Date
    /// Weighted hard sets: each hard set credits every muscle with its share (primary 1.0, synergists 0.25-0.5).
    var sets: [FineMuscle: Double]
    /// Hard sets of exercises whose primary (share 1.0) is that muscle.
    var directSets: [FineMuscle: Double]
    /// Hard sets of exercises with no mapping (a custom exercise the lifter has not mapped): in no muscle's total.
    var unmappedSets: Double = 0
    var unmappedByExercise: [String: Double] = [:]
    /// Regular completed sessions in the week that logged hard sets.
    var sessions: Int
    /// Sessions the block scheduled in the week (by planned date, else date), and how many of them were completed.
    var plannedSessions: Int = 0
    var completedSessions: Int = 0
    /// Any session of the week was a deload (its sets are not hard sets of regular training).
    var hasDeload = false
    /// The week has fully elapsed at the `asOf` of the computation.
    var isComplete: Bool

    /// completed / planned (1 when nothing was planned).
    var adherence: Double { plannedSessions == 0 ? 1 : Double(completedSessions) / Double(plannedSessions) }
    /// A week with fewer than `MuscleVolume.minAdherence` of its planned sessions done: its volume understates the plan.
    var isIncomplete: Bool { adherence < MuscleVolume.minAdherence }
}

enum MuscleVolume {
    enum Status: String { case below, within, above }

    /// A week with less than this fraction of its planned sessions completed is reported separately.
    static let minAdherence = 0.70

    /// The block the lifter is in: the meso of the latest completed regular (non-maintenance) session.
    static func currentMesoKey(in snapshot: AnalyticsSnapshot) -> String? {
        snapshot.sessions.filter { $0.status == .completed && !$0.isMaintenance }
            .max { $0.date < $1.date }?.mesoKey
    }

    /// The lifter's saved mappings of custom exercises (id -> shares). Customs without one are absent.
    static func customShares(from customs: [CustomExercise]) -> [String: [FineMuscle: Double]] {
        var out: [String: [FineMuscle: Double]] = [:]
        for c in customs { if let s = c.fineShares { out[c.id] = s } }
        return out
    }

    /// Suggested mappings (closest built-in by name) for customs the lifter has not mapped. For REPORTS that mark them as
    /// suggestions; the totals of the app never use them.
    static func suggestedShares(for customs: [CustomExercise]) -> [String: [FineMuscle: Double]] {
        var out: [String: [FineMuscle: Double]] = [:]
        for c in customs where c.fineShares == nil {
            if let s = MuscleSuggester.suggest(name: c.name, coarse: MuscleGroup(rawValue: c.primaryMuscleRaw) ?? .chest) { out[c.id] = s.shares }
        }
        return out
    }

    /// Hard sets per fine muscle per calendar (ISO) week, oldest first. A hard set is the P1 definition
    /// (`SetRecord.countsAsHardSet`: regular completed training, warm-ups, skips and rest-pause/drop add-ons out, the
    /// base set of a rest-pause/drop series in once). `mesoKey` restricts to one block (nil: all training).
    /// A built-in uses its table row, a custom exercise `customShares`; anything else is counted as unmapped and credited to
    /// no muscle.
    static func weekly(in snapshot: AnalyticsSnapshot, mesoKey: String? = nil, asOf: Date,
                       customShares: [String: [FineMuscle: Double]] = [:]) -> [MuscleWeek] {
        var byWeek: [Date: MuscleWeek] = [:]
        var sessionKeys: [Date: Set<String>] = [:]
        func week(_ ws: Date) -> MuscleWeek {
            byWeek[ws] ?? MuscleWeek(weekStart: ws, sets: [:], directSets: [:], sessions: 0, isComplete: ws.addingTimeInterval(7 * 86_400) <= asOf)
        }
        for s in snapshot.sets where s.countsAsHardSet && s.sessionDate <= asOf {
            if let mesoKey, s.mesoKey != mesoKey { continue }
            let ws = FatigueMonitor.weekStart(s.sessionDate)
            var w = week(ws)
            if let shares = ExerciseMuscleShares.shares(for: s.exerciseId) ?? customShares[s.exerciseId], !shares.isEmpty {
                for (m, share) in shares {
                    w.sets[m, default: 0] += share
                    if share >= 1 { w.directSets[m, default: 0] += 1 }
                }
            } else {
                w.unmappedSets += 1
                w.unmappedByExercise[s.exerciseId, default: 0] += 1
            }
            byWeek[ws] = w
            sessionKeys[ws, default: []].insert(s.sessionKey)
        }
        // Schedule adherence per week, from the block's session records.
        for r in snapshot.sessions where r.date <= asOf || (r.plannedDate ?? r.date) <= asOf {
            if let mesoKey, r.mesoKey != mesoKey { continue }
            if r.isMaintenance || (r.isInsertedDeload && r.status != .completed) { continue }
            let ws = FatigueMonitor.weekStart(r.plannedDate ?? r.date)
            guard byWeek[ws] != nil else { continue }
            var w = byWeek[ws]!
            w.plannedSessions += 1
            if r.status == .completed { w.completedSessions += 1 }
            if r.isDeloadWeek || r.isInsertedDeload { w.hasDeload = true }
            byWeek[ws] = w
        }
        return byWeek.keys.sorted().map { ws in
            var w = byWeek[ws]!
            w.sessions = sessionKeys[ws]?.count ?? 0
            return w
        }
    }

    static func status(_ sets: Double, range: MuscleSetRange) -> Status {
        sets < range.min ? .below : (sets > range.max ? .above : .within)
    }
}
