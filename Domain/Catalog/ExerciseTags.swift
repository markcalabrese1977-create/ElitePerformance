import Foundation

enum MovementPattern: String, Codable, CaseIterable {
    case squat
    case hinge
    case unilateralLeg
    case horizontalPress
    case verticalPress
    case horizontalPull
    case verticalPull
    case hipExtension
    case delts
    case biceps
    case triceps
    case coreFlexion
    case coreAntiRotation
    case carry
}

enum PriorityTag: String, Codable, CaseIterable {
    case quadBias
    case gluteBias
    case latBias
    case upperBackBias
    case shoulderFriendly
    case lowBackFriendly
}

enum EquipmentTag: String, Codable, CaseIterable {
    case barbell
    case dumbbell
    case cable
    case machine
    case bodyweight
}

struct ExerciseTags: Codable, Hashable {
    var patterns: Set<MovementPattern>
    var priority: Set<PriorityTag> = []
    var equipment: Set<EquipmentTag>
}
