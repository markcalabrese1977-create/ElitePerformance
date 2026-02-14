import Foundation

// MARK: - Namespaced capability tags to avoid collisions

enum ExerciseCap {

    enum Pattern: String, CaseIterable {
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

    enum Priority: String, CaseIterable {
        case quadBias
        case gluteBias
        case latBias
        case upperBackBias

        case shoulderFriendly
        case lowBackFriendly
    }

    enum Equipment: String, CaseIterable {
        case barbell
        case dumbbell
        case cable
        case machine
        case bodyweight
    }

    struct Capability {
        let patterns: Set<Pattern>
        let priority: Set<Priority>
        let equipment: Set<Equipment>

        init(
            patterns: Set<Pattern>,
            priority: Set<Priority> = [],
            equipment: Set<Equipment>
        ) {
            self.patterns = patterns
            self.priority = priority
            self.equipment = equipment
        }
    }

    enum Profile {
        case fullGym
        case homeGym
        case dumbbellOnly
    }
}

// MARK: - Capability lookup (keyed by CatalogExercise.id)

enum ExerciseCapabilities {

    static let map: [String: ExerciseCap.Capability] = [

        // MARK: Chest / Push
        "bench_press": .init(
            patterns: [.horizontalPress],
            equipment: [.barbell]
        ),
        "incline_dumbbell_press": .init(
            patterns: [.horizontalPress],
            priority: [.shoulderFriendly],
            equipment: [.dumbbell]
        ),
        "seated_cable_fly": .init(
            patterns: [.horizontalPress],
            equipment: [.cable]
        ),
        "dumbbell_press": .init(
            patterns: [.horizontalPress],
            priority: [.shoulderFriendly],
            equipment: [.dumbbell]
        ),
        "machine_chest_press": .init(
            patterns: [.horizontalPress],
            priority: [.shoulderFriendly],
            equipment: [.machine]
        ),

        // MARK: Triceps
        "cable_tricep_rope_pushdown": .init(
            patterns: [.triceps],
            equipment: [.cable]
        ),
        "overhead_rope_tricep_extension": .init(
            patterns: [.triceps],
            equipment: [.cable]
        ),
        "smith_machine_dip": .init(
            patterns: [.triceps, .horizontalPress],
            equipment: [.machine]
        ),
        "tricep_kickback": .init(
            patterns: [.triceps],
            equipment: [.dumbbell]
        ),
        "single_arm_cable_tricep_extension": .init(
            patterns: [.triceps],
            equipment: [.cable]
        ),

        // MARK: Core / Carries
        "pallof_press": .init(
            patterns: [.coreAntiRotation],
            equipment: [.cable]
        ),
        "cable_rope_crunch": .init(
            patterns: [.coreFlexion],
            equipment: [.cable]
        ),
        "hanging_straight_leg_raise": .init(
            patterns: [.coreFlexion],
            equipment: [.bodyweight]
        ),
        "hanging_knee_raise": .init(
            patterns: [.coreFlexion],
            equipment: [.bodyweight]
        ),
        "dead_bug": .init(
            patterns: [.coreAntiRotation],
            priority: [.lowBackFriendly],
            equipment: [.bodyweight]
        ),
        "suitcase_carry": .init(
            patterns: [.carry, .coreAntiRotation],
            equipment: [.dumbbell]
        ),
        "farmer_carry": .init(
            patterns: [.carry],
            equipment: [.dumbbell]
        ),

        // MARK: Quads / Hinge / Glutes
        "hack_squat": .init(
            patterns: [.squat],
            priority: [.quadBias],
            equipment: [.machine]
        ),
        "leg_press": .init(
            patterns: [.squat],
            priority: [.quadBias],
            equipment: [.machine]
        ),
        "bulgarian_split_squat": .init(
            patterns: [.unilateralLeg, .squat],
            priority: [.quadBias],
            equipment: [.dumbbell, .bodyweight]
        ),
        "walking_lunge": .init(
            patterns: [.unilateralLeg, .squat],
            priority: [.quadBias],
            equipment: [.dumbbell, .bodyweight]
        ),
        "leg_extension": .init(
            patterns: [.squat],
            priority: [.quadBias],
            equipment: [.machine]
        ),
        "romanian_deadlift": .init(
            patterns: [.hinge],
            equipment: [.barbell]
        ),
        "lying_leg_curl": .init(
            patterns: [.hinge],
            priority: [.lowBackFriendly],
            equipment: [.machine]
        ),
        "seated_leg_curl": .init(
            patterns: [.hinge],
            priority: [.lowBackFriendly],
            equipment: [.machine]
        ),
        "machine_hip_thrust": .init(
            patterns: [.hipExtension],
            priority: [.gluteBias, .lowBackFriendly],
            equipment: [.machine]
        ),
        "cable_glute_kickback": .init(
            patterns: [.hipExtension],
            priority: [.gluteBias],
            equipment: [.cable]
        ),
        "cable_pull_through": .init(
            patterns: [.hinge, .hipExtension],
            priority: [.gluteBias, .lowBackFriendly],
            equipment: [.cable]
        ),
        "back_extension_45": .init(
            patterns: [.hinge, .hipExtension],
            priority: [.lowBackFriendly],
            equipment: [.bodyweight, .machine]
        ),
        "bench_back_extension": .init(
            patterns: [.hinge, .hipExtension],
            priority: [.lowBackFriendly],
            equipment: [.bodyweight]
        ),

        // MARK: Back / Pull
        "wide_grip_pulldown": .init(
            patterns: [.verticalPull],
            priority: [.latBias],
            equipment: [.cable, .machine]
        ),
        "pulldown_normal_grip": .init(
            patterns: [.verticalPull],
            priority: [.latBias],
            equipment: [.cable, .machine]
        ),
        "dumbbell_row_single_arm": .init(
            patterns: [.horizontalPull],
            priority: [.upperBackBias],
            equipment: [.dumbbell]
        ),
        "seated_cable_row": .init(
            patterns: [.horizontalPull],
            priority: [.upperBackBias],
            equipment: [.cable]
        ),
        "chest_supported_incline_dumbbell_row": .init(
            patterns: [.horizontalPull],
            priority: [.upperBackBias, .lowBackFriendly],
            equipment: [.dumbbell]
        ),

        // MARK: Shoulders / Rear delts
        "incline_rear_delt_fly": .init(
            patterns: [.delts],
            priority: [.shoulderFriendly],
            equipment: [.dumbbell]
        ),
        "dumbbell_lateral_raise": .init(
            patterns: [.delts],
            priority: [.shoulderFriendly],
            equipment: [.dumbbell]
        ),
        "seated_smith_machine_shoulder_press": .init(
            patterns: [.verticalPress],
            priority: [.shoulderFriendly],
            equipment: [.machine]
        ),

        // MARK: Biceps
        "ez_bar_curl": .init(
            patterns: [.biceps],
            equipment: [.barbell]
        ),
        "hammer_curl": .init(
            patterns: [.biceps],
            equipment: [.dumbbell]
        ),
        "cable_rope_hammer_curl": .init(
            patterns: [.biceps],
            equipment: [.cable]
        ),
        "single_arm_cable_curl": .init(
            patterns: [.biceps],
            equipment: [.cable]
        ),
        "ez_bar_reverse_curl": .init(
            patterns: [.biceps],
            equipment: [.barbell]
        )
    ]

    static func capability(for exerciseId: String) -> ExerciseCap.Capability? {
        map[exerciseId]
    }
}

// MARK: - Profile support (kept separate to avoid collisions)

extension ExerciseCap.Capability {
    func supports(_ profile: ExerciseCap.Profile) -> Bool {
        switch profile {
        case .fullGym:
            return true
        case .homeGym:
            return !equipment.contains(.machine) && !equipment.contains(.cable)
        case .dumbbellOnly:
            return equipment.isSubset(of: [.dumbbell, .bodyweight])
        }
    }
}
