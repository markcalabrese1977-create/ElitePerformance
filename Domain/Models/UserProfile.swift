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
}

enum EquipmentProfile: String, Codable {
    case homeGym
    case commercial
    case dumbbellsOnly
}


// MARK: - UserProfile model
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
    var unitPreferenceRaw: String

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
        set { equipmentProfileRaw = newValue.rawValue }
    }
    var injuryFlags: [InjuryFlag] {
        get { injuryFlagRaws.compactMap { InjuryFlag(rawValue: $0) } }
        set { injuryFlagRaws = newValue.map { $0.rawValue } }
    }
    var usesKilograms: Bool {
        get { unitPreferenceRaw == "kg" }
        set { unitPreferenceRaw = newValue ? "kg" : "lbs" }
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
        usesKilograms: Bool = false
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
        self.unitPreferenceRaw = usesKilograms ? "kg" : "lbs"
    }
}
