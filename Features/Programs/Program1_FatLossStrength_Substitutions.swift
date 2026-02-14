import Foundation

// MARK: - Program #1 slot IDs

enum Program1SlotId: String, CaseIterable {
    // Day A
    case A1_squat
    case A2_horizontalPress
    case A3_verticalPull
    case A4_hingeSecondary
    case A5_delts
    case A6_core

    // Day B
    case B1_hingePrimary
    case B2_verticalPress
    case B3_horizontalPull
    case B4_squatSecondary
    case B5_biceps
    case B6_triceps

    // Day C
    case C1_unilateralLeg
    case C2_horizontalPressSecondary
    case C3_verticalPullSecondary
    case C4_hipExtension
    case C5_upperBackRearDelts
    case C6_carryCore
}

struct SlotSpec {
    let required: Set<ExerciseCap.Pattern>
    let preferredPriority: Set<ExerciseCap.Priority>
    let rankedExerciseIds: [String]
    let fallbackAllowed: Set<ExerciseCap.Pattern>

    init(
        required: Set<ExerciseCap.Pattern>,
        preferredPriority: Set<ExerciseCap.Priority> = [],
        rankedExerciseIds: [String],
        fallbackAllowed: Set<ExerciseCap.Pattern> = []
    ) {
        self.required = required
        self.preferredPriority = preferredPriority
        self.rankedExerciseIds = rankedExerciseIds
        self.fallbackAllowed = fallbackAllowed
    }
}

enum Program1FatLossStrengthLibrary {
    static let specs: [Program1SlotId: SlotSpec] = [

        // Day A
        .A1_squat: .init(
            required: [.squat, .unilateralLeg],
            preferredPriority: [.quadBias],
            rankedExerciseIds: ["hack_squat", "leg_press", "bulgarian_split_squat", "walking_lunge", "leg_extension"]
        ),
        .A2_horizontalPress: .init(
            required: [.horizontalPress],
            rankedExerciseIds: ["machine_chest_press", "dumbbell_press", "bench_press", "incline_dumbbell_press", "seated_cable_fly"]
        ),
        .A3_verticalPull: .init(
            required: [.verticalPull],
            preferredPriority: [.latBias],
            rankedExerciseIds: ["pulldown_normal_grip", "wide_grip_pulldown"],
            fallbackAllowed: [.horizontalPull]
        ),
        .A4_hingeSecondary: .init(
            required: [.hinge, .hipExtension],
            preferredPriority: [.lowBackFriendly],
            rankedExerciseIds: ["cable_pull_through", "back_extension_45", "bench_back_extension", "romanian_deadlift"]
        ),
        .A5_delts: .init(
            required: [.delts],
            rankedExerciseIds: ["dumbbell_lateral_raise", "incline_rear_delt_fly"]
        ),
        .A6_core: .init(
            required: [.coreFlexion, .coreAntiRotation],
            preferredPriority: [.lowBackFriendly],
            rankedExerciseIds: ["cable_rope_crunch", "hanging_knee_raise", "hanging_straight_leg_raise", "dead_bug", "pallof_press"]
        ),

        // Day B
        .B1_hingePrimary: .init(
            required: [.hinge, .hipExtension],
            preferredPriority: [.lowBackFriendly],
            rankedExerciseIds: ["romanian_deadlift", "back_extension_45", "bench_back_extension", "cable_pull_through"]
        ),
        .B2_verticalPress: .init(
            required: [.verticalPress],
            rankedExerciseIds: ["seated_smith_machine_shoulder_press"]
        ),
        .B3_horizontalPull: .init(
            required: [.horizontalPull],
            preferredPriority: [.upperBackBias, .lowBackFriendly],
            rankedExerciseIds: ["chest_supported_incline_dumbbell_row", "seated_cable_row", "dumbbell_row_single_arm"]
        ),
        .B4_squatSecondary: .init(
            required: [.squat, .unilateralLeg],
            preferredPriority: [.quadBias],
            rankedExerciseIds: ["leg_press", "hack_squat", "bulgarian_split_squat", "walking_lunge", "leg_extension"]
        ),
        .B5_biceps: .init(
            required: [.biceps],
            rankedExerciseIds: ["ez_bar_curl", "hammer_curl", "cable_rope_hammer_curl", "single_arm_cable_curl", "ez_bar_reverse_curl"]
        ),
        .B6_triceps: .init(
            required: [.triceps],
            rankedExerciseIds: ["cable_tricep_rope_pushdown", "overhead_rope_tricep_extension", "single_arm_cable_tricep_extension", "tricep_kickback", "smith_machine_dip"]
        ),

        // Day C
        .C1_unilateralLeg: .init(
            required: [.unilateralLeg],
            preferredPriority: [.quadBias],
            rankedExerciseIds: ["bulgarian_split_squat", "walking_lunge"]
        ),
        .C2_horizontalPressSecondary: .init(
            required: [.horizontalPress],
            rankedExerciseIds: ["incline_dumbbell_press", "dumbbell_press", "bench_press", "machine_chest_press"]
        ),
        .C3_verticalPullSecondary: .init(
            required: [.verticalPull],
            preferredPriority: [.latBias],
            rankedExerciseIds: ["pulldown_normal_grip", "wide_grip_pulldown"],
            fallbackAllowed: [.horizontalPull]
        ),
        .C4_hipExtension: .init(
            required: [.hipExtension],
            preferredPriority: [.gluteBias, .lowBackFriendly],
            rankedExerciseIds: ["machine_hip_thrust", "cable_pull_through", "cable_glute_kickback", "back_extension_45", "bench_back_extension"]
        ),
        .C5_upperBackRearDelts: .init(
            required: [.horizontalPull, .delts],
            preferredPriority: [.upperBackBias],
            rankedExerciseIds: ["chest_supported_incline_dumbbell_row", "seated_cable_row", "dumbbell_row_single_arm", "incline_rear_delt_fly"]
        ),
        .C6_carryCore: .init(
            required: [.carry, .coreAntiRotation],
            rankedExerciseIds: ["farmer_carry", "suitcase_carry", "dead_bug", "pallof_press"]
        )
    ]
}
