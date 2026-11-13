// Domain/Analytics/AnalyticsScreens.swift
import Foundation

/// Weekly sets per muscle for the Analytics tab: the current block, the last four elapsed weeks vs the lifter's ranges.
struct MuscleVolumeSummary {
    struct Row: Identifiable {
        var id: FineMuscle { muscle }
        let muscle: FineMuscle
        let range: MuscleSetRange
        /// Weighted sets per week, averaged over the weeks that count (`averagedWeeks`).
        let average: Double
        /// Direct sets (exercises whose primary is this muscle), same weeks.
        let directAverage: Double
        let status: MuscleVolume.Status
        /// One value per week in `weeks` (oldest first), for the sparkline.
        let series: [Double]
    }
    struct Unmapped: Identifiable {
        let id: String
        let name: String
        /// Hard sets in the block, in no muscle's total.
        let sets: Int
        /// A saved custom exercise the mapping editor can open (false for an exercise that no longer exists).
        let isEditable: Bool
    }

    let blockName: String?
    /// Elapsed weeks of the block, oldest first, at most `sparklineWeeks`; the last four are the averaging window.
    let weeks: [MuscleWeek]
    let rows: [Row]
    let unmapped: [Unmapped]
    /// How many weeks the averages cover (the window's weeks that are neither under 70% adherence nor deload).
    let averagedWeeks: Int
    var windowWeeks: [MuscleWeek] { Array(weeks.suffix(4)) }
    var isEmpty: Bool { weeks.isEmpty }
    static let sparklineWeeks = 8
}

extension MuscleVolume {

    /// The summary for the lifter's current block as of `asOf`.
    /// - Parameters:
    ///   - mesoKey: the block to summarise (nil: the lifter's current block).
    ///   - wholeBlock: true averages EVERY complete week of the block (the Meso Summary); false the last four (the Analytics tab).
    static func summary(snapshot: AnalyticsSnapshot, customs: [CustomExercise], profile: UserProfile?, asOf: Date,
                        mesoKey: String? = nil, wholeBlock: Bool = false) -> MuscleVolumeSummary {
        guard let meso = mesoKey ?? currentMesoKey(in: snapshot) else {
            return MuscleVolumeSummary(blockName: nil, weeks: [], rows: [], unmapped: [], averagedWeeks: 0)
        }
        let all = weekly(in: snapshot, mesoKey: meso, asOf: asOf, customShares: customShares(from: customs))
        let completeWeeks = all.filter(\.isComplete)
        let elapsed = wholeBlock ? completeWeeks : Array(completeWeeks.suffix(MuscleVolumeSummary.sparklineWeeks))
        let window = wholeBlock ? elapsed : Array(elapsed.suffix(4))
        var counted = window.filter { !$0.isIncomplete && !$0.hasDeload }
        if counted.isEmpty { counted = window }          // nothing clean to average: use what there is
        let ranges = profile?.muscleSetRanges ?? MuscleVolumeRanges.defaults
        let rows: [MuscleVolumeSummary.Row] = FineMuscle.allCases.map { m in
            let avg = counted.isEmpty ? 0 : counted.map { $0.sets[m] ?? 0 }.reduce(0, +) / Double(counted.count)
            let direct = counted.isEmpty ? 0 : counted.map { $0.directSets[m] ?? 0 }.reduce(0, +) / Double(counted.count)
            let r = ranges[m] ?? MuscleVolumeRanges.defaults[m] ?? MuscleSetRange(min: 0, max: 0)
            return .init(muscle: m, range: r, average: avg, directAverage: direct, status: status(avg, range: r),
                         series: elapsed.map { $0.sets[m] ?? 0 })
        }
        // Unmapped: every exercise with hard sets in the block that has no built-in row and no saved mapping.
        let editable = Set(customs.map(\.id))
        let mapped = Set(customShares(from: customs).keys)
        var counts: [String: (name: String, sets: Int)] = [:]
        for s in snapshot.sets where s.countsAsHardSet && s.mesoKey == meso && s.sessionDate <= asOf {
            if ExerciseMuscleShares.shares(for: s.exerciseId) != nil || mapped.contains(s.exerciseId) { continue }
            counts[s.exerciseId, default: (s.exerciseName, 0)].sets += 1
        }
        let unmapped = counts.map { MuscleVolumeSummary.Unmapped(id: $0.key, name: $0.value.name, sets: $0.value.sets, isEditable: editable.contains($0.key)) }
            .sorted { ($1.sets, $0.name) < ($0.sets, $1.name) }
        return MuscleVolumeSummary(
            blockName: snapshot.sessions.first { $0.mesoKey == meso }?.mesoName, weeks: elapsed, rows: rows,
            unmapped: unmapped, averagedWeeks: counted.count)
    }
}

extension AnalyticsEngine {

    /// Muscle volume for the current block (see `MuscleVolume.summary`).
    func muscleVolume(customs: [CustomExercise], profile: UserProfile?, asOf: Date = Date()) -> MuscleVolumeSummary {
        MuscleVolume.summary(snapshot: snapshot, customs: customs, profile: profile, asOf: asOf)
    }

    /// Stall flags (current block) for one lift, whatever its wave letter.
    func stalls(forExerciseId id: String, customs: [CustomExercise], profile: UserProfile?, asOf: Date = Date()) -> [Stall] {
        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        return StallDetector.stalls(
            in: snapshot, loadIncrementLb: incrementLb, asOf: asOf, unit: unit,
            maxLoad: { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) },
            isFixedLoad: { UserProfile.isProgressionExempt(exerciseId: $0, profile: profile) }
        ).filter { $0.exerciseId == canonical }
    }
}

extension Stall {
    /// Chip text for the exercise history sheet.
    var chipText: String {
        let letterText = letter.isEmpty ? "" : "\(letter.uppercased()): "
        switch status {
        case .stalled: return "\(letterText)Stalled: no new best in \(exposuresSinceBest) exposures"
        case .noLongerProgrammed: return "\(letterText)No longer programmed"
        }
    }
}

extension CustomExercise {
    /// Saves the lifter's fine mapping. The primary is always 1.0 and never also a synergist: a share on the primary is
    /// dropped, as are shares outside (0, 0.5] and unknown muscles. A nil primary clears the mapping (secondaries too).
    func setFineMapping(primary: FineMuscle?, secondary: [FineMuscle: Double]) {
        guard let primary else {
            fineMuscleRaw = nil
            fineSecondaryShares = nil
            return
        }
        fineMuscleRaw = primary.rawValue
        let clean = Dictionary(uniqueKeysWithValues: secondary
            .filter { $0.key != primary && $0.value > 0 && $0.value <= 0.5 }
            .map { ($0.key.rawValue, $0.value) })
        fineSecondaryShares = clean.isEmpty ? nil : clean
    }

    /// One-time cleanup of mappings saved before the editor dropped a share on the primary (or kept a share with no
    /// primary): rewrites the stored fields through `setFineMapping`. Returns true when something changed.
    @discardableResult
    func sanitizeFineMapping() -> Bool {
        let before = (fineMuscleRaw, fineSecondaryShares)
        let primary = fineMuscleRaw.flatMap(FineMuscle.init(rawValue:))
        var secondary: [FineMuscle: Double] = [:]
        for (k, v) in fineSecondaryShares ?? [:] { if let m = FineMuscle(rawValue: k) { secondary[m] = v } }
        if primary == nil && fineMuscleRaw != nil { fineMuscleRaw = nil }       // an unknown primary is no primary
        setFineMapping(primary: primary, secondary: secondary)
        return before.0 != fineMuscleRaw || before.1 != fineSecondaryShares
    }
}
