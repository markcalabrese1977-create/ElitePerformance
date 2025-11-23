// Domain/Models/UserProfile.swift

import Foundation

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

enum TrainingStyle: String, Codable {
    case topSetBackoff
    case straightSets
}

enum RIRComfort: String, Codable {
    case simple
    case rirAware
}

// MARK: - UserProfile model
/// Long-term preference snapshot. We *don’t* need Codable right now,
/// so we drop it to avoid compiler errors on nested types.
struct UserProfile: Identifiable {
    let id: UUID
    let userId: UUID

    var trainingExperience: TrainingExperience
    var daysPerWeek: Int
    var sessionLengthMinutes: Int

    var primaryGoal: PrimaryGoal
    var priorityMuscles: [MuscleGroup]

    var injuryFlags: [InjuryFlag]
    var equipmentProfile: EquipmentProfile

    var trainingStyle: TrainingStyle
    var rirComfort: RIRComfort
}
