//
//  UserProfile.swift
//  ElitePerformance
//
//  Created by Mark Calabrese on 11/14/25.
//

// Domain/Models/UserProfile.swift

import Foundation

enum TrainingExperience: String, Codable {
    case new
    case intermediate
    case advanced
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

struct UserProfile: Identifiable, Codable {
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
