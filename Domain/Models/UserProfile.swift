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
// now-removed usesKilograms computed property) was dropped here. This
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

    /// Per-exercise "fixed load" exemptions: canonical exerciseIds whose load never
    /// auto-progresses (fixed-load track; the lifter raises it).
    ///
    /// Nothing is exempt by default. Stored OPTIONAL so the additive SwiftData lightweight
    /// migration (existing rows get nil) and an old backup without the field both read as the
    /// default (empty) without any backfill. Use `exemptExerciseIds` / `isProgressionExempt`,
    /// never this raw column.
    var exemptExerciseIdsStored: [String]? = nil

    static let defaultExemptExerciseIds: [String] = []

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
        bodyWeight: Double? = nil
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
    }
}
