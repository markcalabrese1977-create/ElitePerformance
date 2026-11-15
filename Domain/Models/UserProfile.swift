// Domain/Models/UserProfile.swift
import Foundation
import SwiftData


// MARK: - Core profile enums

enum TrainingExperience: String, CaseIterable, Codable {
    case new
    case intermediate
    case advanced

    /// Short label for buttons / chips in onboarding
    var label: String {
        switch self {
        case .new:
            return "New"
        case .intermediate:
            return "Some experience"
        case .advanced:
            return "Advanced"
        }
    }
}

enum PrimaryGoal: String, Codable {
    case hypertrophy
    case strength
    case fatLoss
    case longevity
}

enum InjuryFlag: String, Codable {
    case lowBack
    case knees
    case shoulders
    case elbows
    case wrists
    case hips
}

enum EquipmentProfile: String, Codable {
    case homeGym
    case commercial
    case dumbbellsOnly
}

/// Coarse equipment preset the program fitter works from. Empty/unset resolves to `.fullGym`.
enum EquipmentPreset: String, Codable, CaseIterable {
    case fullGym
    case homeBarbell
    case dumbbellsBench
    case machinesOnly

    /// Equipment tags a lifter on this preset can be assumed to have.
    var defaultEquipment: Set<GearTag> {
        switch self {
        case .fullGym:        return Set(GearTag.allCases)
        case .homeBarbell:    return [.barbell, .ezBar, .dumbbell, .bench, .rack, .pullUpBar]
        case .dumbbellsBench: return [.dumbbell, .bench]
        case .machinesOnly:   return [.machine, .cable, .smith]
        }
    }

    /// Closest legacy `EquipmentProfile`, kept in step so existing readers of `equipmentProfile` still work.
    var legacyProfile: EquipmentProfile {
        switch self {
        case .fullGym, .machinesOnly: return .commercial
        case .homeBarbell:            return .homeGym
        case .dumbbellsBench:         return .dumbbellsOnly
        }
    }

    init(legacy: EquipmentProfile) {
        switch legacy {
        case .commercial:    self = .fullGym
        case .homeGym:       self = .homeBarbell
        case .dumbbellsOnly: self = .dumbbellsBench
        }
    }
}

/// A piece of gear an exercise can require. Bodyweight-only exercises require none.
enum GearTag: String, Codable, CaseIterable, Hashable {
    case barbell
    case ezBar
    case dumbbell
    case bench
    case rack
    case cable
    case machine
    case smith
    case pullUpBar
    case dipStation
}


// MARK: - UserProfile model
//
// Q18 cleanup: unitPreferenceRaw (the actual stored attribute backing the
// now-removed usesKilograms computed property) was dropped here. kg support later added `unitRaw`
// (a different column; the old backup key `unitPreferenceRaw` is still ignored on import). This
// codebase has no VersionedSchema/SchemaMigrationPlan anywhere — UserProfile
// is registered via a plain Schema([...]) + ModelContainer(for:configurations:)
// in App/ElitePerformanceApp.swift — so SwiftData's lightweight/automatic
// migration handles the dropped column on next launch; no migration plan to
// update.
@Model
final class UserProfile {
    var profileId: UUID
    var createdAt: Date

    var experienceRaw: String
    var primaryGoalRaw: String
    var daysPerWeek: Int
    var sessionLengthMinutes: Int
    var equipmentProfileRaw: String
    var injuryFlagRaws: [String]
    var minLoadIncrement: Double
    var bodyWeight: Double?

    /// The unit the lifter sees and types loads in. nil = lb (every existing row, every old backup, a fresh
    /// install that never picked). Stored OPTIONAL so the additive SwiftData migration needs no backfill.
    /// Every load the app stores (planned, actual, max load, bodyWeight) stays in lb whatever this says;
    /// only `minLoadIncrement` is stored in this unit. Use `loadUnit`, never this raw column.
    var unitRaw: String? = nil

    var loadUnit: LoadUnit {
        get { LoadUnit(rawValue: unitRaw ?? "") ?? .lb }
        set { unitRaw = newValue == .lb ? nil : newValue.rawValue }
    }

    /// The last `minLoadIncrement` the lifter had in each unit, remembered when they switch away from it (the live
    /// value is `minLoadIncrement`, in the current unit). nil = never switched away: the unit's default applies.
    var savedIncrementLb: Double? = nil
    var savedIncrementKg: Double? = nil

    /// True from a unit switch until the lifter answers the "round planned loads" offer (Round or Keep as is).
    /// nil / false = nothing to offer, so a lifter who never switched is never prompted.
    var roundOfferPending: Bool? = nil

    func savedIncrement(for unit: LoadUnit) -> Double? { unit == .lb ? savedIncrementLb : savedIncrementKg }

    /// Remembers the live increment as `unit`'s last value.
    func rememberIncrement(for unit: LoadUnit) {
        if unit == .lb { savedIncrementLb = minLoadIncrement } else { savedIncrementKg = minLoadIncrement }
    }

    /// The increment a unit starts with the first time it is chosen: lb 2.5 (5 for dumbbells only), kg 1.25 (2.5).
    func defaultIncrement(for unit: LoadUnit) -> Double {
        UnitAwareRounding.defaultIncrement(unit: unit, coarse: equipmentProfile == .dumbbellsOnly)
    }

    /// Switches how loads are shown and typed. Stored loads are lb and never change here. The increment (stored in the
    /// current unit) is remembered for the unit being left and restored for the one being entered (its default the
    /// first time). The round offer is raised: the planned loads may now be off the new unit's steps.
    func switchLoadUnit(to new: LoadUnit) {
        let old = loadUnit
        guard new != old else { return }
        rememberIncrement(for: old)
        loadUnit = new
        minLoadIncrement = savedIncrement(for: new) ?? defaultIncrement(for: new)
        roundOfferPending = true
    }

    /// Per-exercise "fixed load" exemptions: canonical exerciseIds whose load never
    /// auto-progresses (fixed-load track; the lifter raises it).
    ///
    /// Nothing is exempt by default. Stored OPTIONAL so the additive SwiftData lightweight
    /// migration (existing rows get nil) and an old backup without the field both read as the
    /// default (empty) without any backfill. Use `exemptExerciseIds` / `isProgressionExempt`,
    /// never this raw column.
    var exemptExerciseIdsStored: [String]? = nil

    static let defaultExemptExerciseIds: [String] = []

    /// Per-exercise "max load": the heaviest load the plan may write or seed for an exercise (canonical
    /// exerciseId -> load, in the lifter's unit). No entry means no cap. Stored OPTIONAL so the additive
    /// SwiftData migration (existing rows get nil) and an old backup without the field both read as
    /// "no caps". Use `maxLoadByExercise` / `maxLoad(for:)`, never this raw column.
    var maxLoadByExerciseStored: [String: Double]? = nil

    /// Per-exercise load step (canonical exerciseId -> step, in the lifter's unit): how much one earned increase adds and what the
    /// plan rounds to for that lift. No entry means the default load step (`minLoadIncrement`). Stored OPTIONAL for the additive
    /// migration; use `loadStepByExercise` / `loadStep(for:)`, never this raw column.
    var loadStepByExerciseStored: [String: Double]? = nil

    /// Weekly hard-set range overrides per fine muscle for analytics ("<muscle>.min" / "<muscle>.max" -> weighted sets
    /// per week). Only numbers that differ from `MuscleVolumeRanges.defaults` are stored; nil = all defaults. Stored
    /// OPTIONAL for the additive migration. Use `muscleSetRanges`, never this raw column.
    var muscleSetRangesStored: [String: Double]? = nil

    var maxLoadByExercise: [String: Double] {
        get { maxLoadByExerciseStored ?? [:] }
        set { maxLoadByExerciseStored = newValue }
    }

    /// The cap for `exerciseId` (any legacy alias spelling), or nil when there is none.
    func maxLoad(for exerciseId: String) -> Double? {
        Self.maxLoad(for: exerciseId, in: maxLoadByExercise)
    }

    /// Profile-optional variant for callers that may run before a profile exists: no profile, no cap.
    static func maxLoad(for exerciseId: String, profile: UserProfile?) -> Double? {
        maxLoad(for: exerciseId, in: profile?.maxLoadByExercise ?? [:])
    }

    private static func maxLoad(for exerciseId: String, in map: [String: Double]) -> Double? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        for (key, value) in map where value > 0 && ExerciseCatalog.canonicalExerciseId(for: key) == canonical {
            return value
        }
        return nil
    }

    /// Set (or, with nil / a non-positive value, clear) the cap for one exercise (canonical-id aware).
    func setMaxLoad(_ value: Double?, exerciseId: String) {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        var map = maxLoadByExercise.filter { ExerciseCatalog.canonicalExerciseId(for: $0.key) != canonical }
        if let value, value > 0 { map[canonical] = value }
        maxLoadByExercise = map
    }

    var loadStepByExercise: [String: Double] {
        get { loadStepByExerciseStored ?? [:] }
        set { loadStepByExerciseStored = newValue }
    }

    /// The lifter's own step for `exerciseId` (any legacy alias spelling), or nil when none is set.
    static func loadStepOverride(for exerciseId: String, profile: UserProfile?) -> Double? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        for (key, value) in profile?.loadStepByExercise ?? [:] where value > 0 && ExerciseCatalog.canonicalExerciseId(for: key) == canonical { return value }
        return nil
    }

    /// The step every reader uses for `exerciseId`: the per-exercise override, else the default load step
    /// (`minLoadIncrement`), else (no profile yet) the unit's default. The cluster default applies below all of these, and
    /// only where no step is passed (`CoachingEngine.loadIncrement`).
    static func loadStep(for exerciseId: String, profile: UserProfile?, unit: LoadUnit? = nil) -> Double {
        if let o = loadStepOverride(for: exerciseId, profile: profile) { return o }
        if let m = profile?.minLoadIncrement, m > 0 { return m }
        return UnitAwareRounding.defaultIncrement(unit: unit ?? profile?.loadUnit ?? .lb)
    }

    /// Set (or, with nil / a non-positive value, clear) the step for one exercise (canonical-id aware).
    func setLoadStep(_ value: Double?, exerciseId: String) {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        var map = loadStepByExercise.filter { ExerciseCatalog.canonicalExerciseId(for: $0.key) != canonical }
        if let value, value > 0 { map[canonical] = value }
        loadStepByExercise = map
    }

    /// The cap that applies to PLAN-WRITTEN loads of `exerciseId`: nil when there is no cap, and nil for a
    /// fixed-load exercise (its load never moves, so a cap must not move it either) or a bodyweight one.
    static func effectiveMaxLoad(for exerciseId: String, profile: UserProfile?,
                                 customExercises: [CustomExercise] = []) -> Double? {
        guard let cap = maxLoad(for: exerciseId, profile: profile) else { return nil }
        if isProgressionExempt(exerciseId: exerciseId, profile: profile) { return nil }
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) { return nil }
        return cap
    }

    /// `min(load, cap)` when a cap applies to this exercise; `load` otherwise.
    static func clampedLoad(_ load: Double, exerciseId: String, profile: UserProfile?,
                            customExercises: [CustomExercise] = []) -> Double {
        guard let cap = effectiveMaxLoad(for: exerciseId, profile: profile, customExercises: customExercises) else { return load }
        return min(load, cap)
    }

    /// Optional birthdate the lifter enters when HealthKit has no date of birth; HealthKit's wins when
    /// both exist. Only used for age-based heart-rate zones; nil means no age is assumed.
    var birthDateOverride: Date? = nil

    /// Equipment preset the fitter works from. Stored OPTIONAL so the additive SwiftData migration (existing
    /// rows get nil) and old backups both read as "derive from the legacy `equipmentProfileRaw`". Use
    /// `equipmentPreset`, never this raw column.
    var equipmentPresetRaw: String? = nil

    /// Optional explicit gear checklist (GearTag raw values). nil or empty means "use the preset's
    /// defaults". Use `equipmentChecklist` / `effectiveEquipment`.
    var equipmentChecklistRaws: [String]? = nil

    var equipmentPreset: EquipmentPreset {
        get {
            if let raw = equipmentPresetRaw {
                // "bodyweight" was a preset in an unreleased draft; it reads as the closest remaining one.
                if raw == "bodyweight" { return .dumbbellsBench }
                if let preset = EquipmentPreset(rawValue: raw) { return preset }
            }
            return EquipmentPreset(legacy: equipmentProfile)
        }
        set {
            equipmentPresetRaw = newValue.rawValue
            equipmentProfileRaw = newValue.legacyProfile.rawValue
        }
    }

    var equipmentChecklist: Set<GearTag> {
        get { Set((equipmentChecklistRaws ?? []).compactMap { GearTag(rawValue: $0) }) }
        set { equipmentChecklistRaws = newValue.isEmpty ? nil : newValue.map(\.rawValue).sorted() }
    }

    /// Gear the fitter may assume: the checklist when the lifter filled one in, else the preset's defaults.
    var effectiveEquipment: Set<GearTag> {
        let checklist = equipmentChecklist
        return checklist.isEmpty ? equipmentPreset.defaultEquipment : checklist
    }

    var exemptExerciseIds: [String] {
        get { exemptExerciseIdsStored ?? Self.defaultExemptExerciseIds }
        set { exemptExerciseIdsStored = newValue }
    }

    /// True when `exerciseId` (any legacy alias spelling) is on the fixed-load list.
    func isProgressionExempt(exerciseId: String) -> Bool {
        Self.isProgressionExempt(exerciseId: exerciseId, in: exemptExerciseIds)
    }

    /// Profile-optional variant for callers that may run before a profile exists:
    /// no profile resolves to the default list.
    static func isProgressionExempt(exerciseId: String, profile: UserProfile?) -> Bool {
        isProgressionExempt(exerciseId: exerciseId, in: profile?.exemptExerciseIds ?? defaultExemptExerciseIds)
    }

    private static func isProgressionExempt(exerciseId: String, in list: [String]) -> Bool {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        return list.contains { ExerciseCatalog.canonicalExerciseId(for: $0) == canonical }
    }

    /// Turn the exemption on or off for one exercise (canonical-id aware).
    func setProgressionExempt(_ exempt: Bool, exerciseId: String) {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        var list = exemptExerciseIds.filter { ExerciseCatalog.canonicalExerciseId(for: $0) != canonical }
        if exempt { list.append(canonical) }
        exemptExerciseIds = list
    }

    var experience: TrainingExperience {
        get { TrainingExperience(rawValue: experienceRaw) ?? .intermediate }
        set { experienceRaw = newValue.rawValue }
    }
    var primaryGoal: PrimaryGoal {
        get { PrimaryGoal(rawValue: primaryGoalRaw) ?? .hypertrophy }
        set { primaryGoalRaw = newValue.rawValue }
    }
    var equipmentProfile: EquipmentProfile {
        get { EquipmentProfile(rawValue: equipmentProfileRaw) ?? .commercial }
        // A direct change to the legacy profile (Settings picker, onboarding) supersedes any stored preset,
        // so the preset re-derives from it.
        set {
            equipmentProfileRaw = newValue.rawValue
            equipmentPresetRaw = nil
        }
    }
    var injuryFlags: [InjuryFlag] {
        get { injuryFlagRaws.compactMap { InjuryFlag(rawValue: $0) } }
        set { injuryFlagRaws = newValue.map { $0.rawValue } }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        experience: TrainingExperience = .intermediate,
        primaryGoal: PrimaryGoal = .hypertrophy,
        daysPerWeek: Int = 4,
        sessionLengthMinutes: Int = 60,
        equipmentProfile: EquipmentProfile = .commercial,
        injuryFlags: [InjuryFlag] = [],
        minLoadIncrement: Double = 2.5,
        bodyWeight: Double? = nil,
        unit: LoadUnit = .lb
    ) {
        self.profileId = id
        self.createdAt = createdAt
        self.experienceRaw = experience.rawValue
        self.primaryGoalRaw = primaryGoal.rawValue
        self.daysPerWeek = daysPerWeek
        self.sessionLengthMinutes = sessionLengthMinutes
        self.equipmentProfileRaw = equipmentProfile.rawValue
        self.injuryFlagRaws = injuryFlags.map { $0.rawValue }
        self.minLoadIncrement = minLoadIncrement
        self.bodyWeight = bodyWeight
        self.unitRaw = unit == .lb ? nil : unit.rawValue
    }
}
