// Domain/Programs/ExerciseTraits.swift
import Foundation

/// What movement an exercise trains. Substitutions stay inside one pattern, so a swap never drops a pattern.
enum ExercisePattern: String, Codable, CaseIterable, Hashable {
    case horizontalPress
    case chestFly
    case verticalPress
    case shoulderIsolation
    case verticalPull
    case horizontalPull
    case squat
    case hipHinge
    case gluteBridge
    case kneeExtension
    case kneeFlexion
    case calfRaise
    case elbowFlexion
    case elbowExtension
    case coreFlexion
    case coreStability
}

/// Equipment, movement pattern and joint stress for a built-in catalog exercise.
///
/// Lives in its own table keyed by canonical catalog id, NOT on `CatalogExercise` (which is JSON-persisted for
/// customs). Custom exercises have no entry, so `traits(for:)` is nil and the fitter never auto-chooses them.
struct ExerciseTraits: Equatable {
    /// Gear REQUIRED to do the exercise. Empty means no gear.
    let equipment: Set<GearTag>
    let pattern: ExercisePattern
    /// Joint stress 0 (none), 1 (some), 2 (high). Joints absent from the dictionary are 0.
    let jointStress: [InjuryFlag: Int]

    init(equipment: Set<GearTag>, pattern: ExercisePattern, stress: [InjuryFlag: Int] = [:]) {
        self.equipment = equipment
        self.pattern = pattern
        self.jointStress = stress
    }

    func stress(for joint: InjuryFlag) -> Int { jointStress[joint] ?? 0 }

    /// True when every required piece of gear is in `available`.
    func isAvailable(with available: Set<GearTag>) -> Bool { equipment.isSubset(of: available) }

    /// Traits for a catalog id (legacy aliases resolved). nil for customs and unknown ids.
    static func traits(for exerciseId: String) -> ExerciseTraits? {
        table[ExerciseCatalog.canonicalExerciseId(for: exerciseId)]
    }

    static let table: [String: ExerciseTraits] = [
        "bench_press": ExerciseTraits(equipment: [.barbell, .bench, .rack], pattern: .horizontalPress, stress: [.shoulders: 1, .elbows: 1, .wrists: 1]),
        "close_grip_bench_press": ExerciseTraits(equipment: [.barbell, .bench, .rack], pattern: .horizontalPress, stress: [.shoulders: 1, .elbows: 2, .wrists: 1]),
        "pin_press": ExerciseTraits(equipment: [.barbell, .bench, .rack], pattern: .horizontalPress, stress: [.shoulders: 1, .elbows: 1, .wrists: 1]),
        "incline_dumbbell_press": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .horizontalPress, stress: [.shoulders: 1]),
        "seated_cable_fly": ExerciseTraits(equipment: [.cable], pattern: .chestFly),
        "dumbbell_press": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .horizontalPress, stress: [.shoulders: 1]),
        "machine_chest_press": ExerciseTraits(equipment: [.machine], pattern: .horizontalPress),
        "seated_cable_press": ExerciseTraits(equipment: [.cable], pattern: .horizontalPress),
        "decline_bench_press": ExerciseTraits(equipment: [.barbell, .bench, .rack], pattern: .horizontalPress, stress: [.elbows: 1, .wrists: 1]),
        "dumbbell_fly": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .chestFly, stress: [.shoulders: 2, .elbows: 1]),
        "pec_deck": ExerciseTraits(equipment: [.machine], pattern: .chestFly, stress: [.shoulders: 1]),
        "cable_crossover": ExerciseTraits(equipment: [.cable], pattern: .chestFly, stress: [.shoulders: 1]),
        "push_up": ExerciseTraits(equipment: [], pattern: .horizontalPress, stress: [.shoulders: 1, .wrists: 1]),
        "cable_tricep_rope_pushdown": ExerciseTraits(equipment: [.cable], pattern: .elbowExtension, stress: [.elbows: 1]),
        "overhead_rope_tricep_extension": ExerciseTraits(equipment: [.cable], pattern: .elbowExtension, stress: [.shoulders: 1, .elbows: 1]),
        "tricep_kickback": ExerciseTraits(equipment: [.dumbbell], pattern: .elbowExtension, stress: [.elbows: 1]),
        "single_arm_cable_tricep_extension": ExerciseTraits(equipment: [.cable], pattern: .elbowExtension, stress: [.elbows: 1]),
        "ez_bar_skull_crusher": ExerciseTraits(equipment: [.ezBar, .bench], pattern: .elbowExtension, stress: [.shoulders: 1, .elbows: 2, .wrists: 1]),
        "dumbbell_overhead_tricep_extension": ExerciseTraits(equipment: [.dumbbell], pattern: .elbowExtension, stress: [.shoulders: 1, .elbows: 1]),
        "cable_tricep_pushdown_straight_bar": ExerciseTraits(equipment: [.cable], pattern: .elbowExtension, stress: [.elbows: 1, .wrists: 1]),
        "dip": ExerciseTraits(equipment: [.dipStation], pattern: .elbowExtension, stress: [.shoulders: 2, .elbows: 2, .wrists: 1]),
        "assisted_dip": ExerciseTraits(equipment: [.machine], pattern: .elbowExtension, stress: [.shoulders: 2, .elbows: 1]),
        "pallof_press": ExerciseTraits(equipment: [.cable], pattern: .coreStability),
        "cable_rope_crunch": ExerciseTraits(equipment: [.cable], pattern: .coreFlexion, stress: [.lowBack: 1]),
        "decline_cable_crunch": ExerciseTraits(equipment: [.bench, .cable], pattern: .coreFlexion, stress: [.lowBack: 1]),
        "hanging_straight_leg_raise": ExerciseTraits(equipment: [.pullUpBar], pattern: .coreFlexion, stress: [.lowBack: 1, .shoulders: 1, .wrists: 1, .hips: 1]),
        "hanging_knee_raise": ExerciseTraits(equipment: [.pullUpBar], pattern: .coreFlexion, stress: [.shoulders: 1, .wrists: 1]),
        "dead_bug": ExerciseTraits(equipment: [], pattern: .coreStability),
        "suitcase_carry": ExerciseTraits(equipment: [.dumbbell], pattern: .coreStability, stress: [.lowBack: 1]),
        "farmer_carry": ExerciseTraits(equipment: [.dumbbell], pattern: .coreStability, stress: [.lowBack: 1, .wrists: 1]),
        "ab_wheel_rollout": ExerciseTraits(equipment: [], pattern: .coreStability, stress: [.lowBack: 2, .shoulders: 1]),
        "cable_woodchop": ExerciseTraits(equipment: [.cable], pattern: .coreStability, stress: [.lowBack: 1]),
        "plank": ExerciseTraits(equipment: [], pattern: .coreStability),
        "russian_twist": ExerciseTraits(equipment: [], pattern: .coreStability, stress: [.lowBack: 1]),
        "decline_sit_up": ExerciseTraits(equipment: [.bench], pattern: .coreFlexion, stress: [.lowBack: 1, .hips: 1]),
        "toes_to_bar": ExerciseTraits(equipment: [.pullUpBar], pattern: .coreFlexion, stress: [.lowBack: 1, .shoulders: 2, .wrists: 1, .hips: 1]),
        "hack_squat": ExerciseTraits(equipment: [.machine], pattern: .squat, stress: [.knees: 2, .hips: 1]),
        "leg_press": ExerciseTraits(equipment: [.machine], pattern: .squat, stress: [.lowBack: 1, .knees: 1, .hips: 1]),
        "bulgarian_split_squat": ExerciseTraits(equipment: [.bench], pattern: .squat, stress: [.knees: 2, .hips: 1]),
        "walking_lunge": ExerciseTraits(equipment: [], pattern: .squat, stress: [.knees: 2, .hips: 1]),
        "cable_pull_through": ExerciseTraits(equipment: [.cable], pattern: .hipHinge, stress: [.lowBack: 1]),
        "back_extension_45": ExerciseTraits(equipment: [.machine], pattern: .hipHinge, stress: [.lowBack: 1, .hips: 1]),
        "leg_extension": ExerciseTraits(equipment: [.machine], pattern: .kneeExtension, stress: [.knees: 2]),
        "romanian_deadlift": ExerciseTraits(equipment: [.barbell], pattern: .hipHinge, stress: [.lowBack: 2, .hips: 1]),
        "lying_leg_curl": ExerciseTraits(equipment: [.machine], pattern: .kneeFlexion),
        "machine_hip_thrust": ExerciseTraits(equipment: [.machine], pattern: .gluteBridge, stress: [.lowBack: 1, .hips: 1]),
        "cable_glute_kickback": ExerciseTraits(equipment: [.cable], pattern: .gluteBridge, stress: [.lowBack: 1]),
        "seated_leg_curl": ExerciseTraits(equipment: [.machine], pattern: .kneeFlexion),
        "goblet_squat": ExerciseTraits(equipment: [.dumbbell], pattern: .squat, stress: [.hips: 1]),
        "front_squat": ExerciseTraits(equipment: [.barbell, .rack], pattern: .squat, stress: [.lowBack: 1, .knees: 2, .wrists: 2, .hips: 1]),
        "smith_machine_squat": ExerciseTraits(equipment: [.smith], pattern: .squat, stress: [.lowBack: 1, .knees: 1]),
        "sumo_deadlift": ExerciseTraits(equipment: [.barbell], pattern: .hipHinge, stress: [.lowBack: 2, .knees: 1, .wrists: 1, .hips: 2]),
        "conventional_deadlift": ExerciseTraits(equipment: [.barbell], pattern: .hipHinge, stress: [.lowBack: 2, .wrists: 1, .hips: 1]),
        "nordic_curl": ExerciseTraits(equipment: [], pattern: .kneeFlexion, stress: [.knees: 2]),
        "glute_bridge": ExerciseTraits(equipment: [], pattern: .gluteBridge),
        "step_up": ExerciseTraits(equipment: [.bench], pattern: .squat, stress: [.knees: 1, .hips: 1]),
        "reverse_hyperextension": ExerciseTraits(equipment: [.machine], pattern: .hipHinge, stress: [.lowBack: 1, .hips: 1]),
        "smith_machine_calves": ExerciseTraits(equipment: [.smith], pattern: .calfRaise),
        "seated_calf_raise": ExerciseTraits(equipment: [.machine], pattern: .calfRaise),
        "leg_press_calf_raise": ExerciseTraits(equipment: [.machine], pattern: .calfRaise),
        "sled_calf_press": ExerciseTraits(equipment: [.machine], pattern: .calfRaise),
        "wide_grip_pulldown": ExerciseTraits(equipment: [.cable], pattern: .verticalPull, stress: [.shoulders: 1, .elbows: 1]),
        "pulldown_normal_grip": ExerciseTraits(equipment: [.cable], pattern: .verticalPull, stress: [.elbows: 1]),
        "dumbbell_row_single_arm": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .horizontalPull, stress: [.lowBack: 1]),
        "seated_cable_row": ExerciseTraits(equipment: [.cable], pattern: .horizontalPull, stress: [.lowBack: 1]),
        "chest_supported_incline_dumbbell_row": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .horizontalPull),
        "barbell_row": ExerciseTraits(equipment: [.barbell], pattern: .horizontalPull, stress: [.lowBack: 2, .elbows: 1]),
        "t_bar_row": ExerciseTraits(equipment: [.barbell], pattern: .horizontalPull, stress: [.lowBack: 2]),
        "machine_row": ExerciseTraits(equipment: [.machine], pattern: .horizontalPull),
        "pull_up": ExerciseTraits(equipment: [.pullUpBar], pattern: .verticalPull, stress: [.shoulders: 1, .elbows: 2, .wrists: 1]),
        "chin_up": ExerciseTraits(equipment: [.pullUpBar], pattern: .verticalPull, stress: [.shoulders: 1, .elbows: 2, .wrists: 1]),
        "assisted_pull_up": ExerciseTraits(equipment: [.machine], pattern: .verticalPull, stress: [.shoulders: 1, .elbows: 1]),
        "cable_pullover": ExerciseTraits(equipment: [.cable], pattern: .verticalPull, stress: [.shoulders: 1]),
        "incline_rear_delt_fly": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .shoulderIsolation),
        "dumbbell_lateral_raise": ExerciseTraits(equipment: [.dumbbell], pattern: .shoulderIsolation, stress: [.shoulders: 1]),
        "seated_smith_machine_shoulder_press": ExerciseTraits(equipment: [.bench, .smith], pattern: .verticalPress, stress: [.shoulders: 2, .elbows: 1, .wrists: 1]),
        "arnold_press": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .verticalPress, stress: [.shoulders: 2, .elbows: 1, .wrists: 1]),
        "single_arm_cable_lateral_raise": ExerciseTraits(equipment: [.cable], pattern: .shoulderIsolation, stress: [.shoulders: 1]),
        "dumbbell_shoulder_press": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .verticalPress, stress: [.shoulders: 2, .elbows: 1, .wrists: 1]),
        "machine_shoulder_press": ExerciseTraits(equipment: [.machine], pattern: .verticalPress, stress: [.shoulders: 1]),
        "cable_face_pull": ExerciseTraits(equipment: [.cable], pattern: .shoulderIsolation),
        "upright_row": ExerciseTraits(equipment: [.barbell], pattern: .shoulderIsolation, stress: [.shoulders: 2, .elbows: 1, .wrists: 2]),
        "dumbbell_rear_delt_fly": ExerciseTraits(equipment: [.dumbbell], pattern: .shoulderIsolation),
        "cable_rear_delt_fly": ExerciseTraits(equipment: [.cable], pattern: .shoulderIsolation),
        "ez_bar_curl": ExerciseTraits(equipment: [.ezBar], pattern: .elbowFlexion, stress: [.elbows: 1]),
        "hammer_curl": ExerciseTraits(equipment: [.dumbbell], pattern: .elbowFlexion, stress: [.elbows: 1]),
        "cable_rope_hammer_curl": ExerciseTraits(equipment: [.cable], pattern: .elbowFlexion),
        "single_arm_cable_curl": ExerciseTraits(equipment: [.cable], pattern: .elbowFlexion),
        "supination_pronation_curl": ExerciseTraits(equipment: [.dumbbell], pattern: .elbowFlexion, stress: [.elbows: 1, .wrists: 1]),
        "ez_bar_reverse_curl": ExerciseTraits(equipment: [.ezBar], pattern: .elbowFlexion, stress: [.elbows: 1, .wrists: 1]),
        "barbell_curl": ExerciseTraits(equipment: [.barbell], pattern: .elbowFlexion, stress: [.elbows: 1, .wrists: 1]),
        "concentration_curl": ExerciseTraits(equipment: [.dumbbell], pattern: .elbowFlexion, stress: [.elbows: 1]),
        "preacher_curl": ExerciseTraits(equipment: [.machine], pattern: .elbowFlexion, stress: [.elbows: 2]),
        "incline_dumbbell_curl": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .elbowFlexion, stress: [.shoulders: 1, .elbows: 1]),
        "cable_overhead_curl": ExerciseTraits(equipment: [.cable], pattern: .elbowFlexion, stress: [.shoulders: 1]),
        "spider_curl": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .elbowFlexion, stress: [.elbows: 1]),
        "machine_curl": ExerciseTraits(equipment: [.machine], pattern: .elbowFlexion),
        "barbell_back_squat": ExerciseTraits(equipment: [.barbell, .rack], pattern: .squat, stress: [.lowBack: 1, .knees: 2, .hips: 1]),
        "barbell_overhead_press": ExerciseTraits(equipment: [.barbell, .rack], pattern: .verticalPress, stress: [.lowBack: 1, .shoulders: 2, .elbows: 1, .wrists: 1]),
        "barbell_hip_thrust": ExerciseTraits(equipment: [.barbell, .bench], pattern: .gluteBridge, stress: [.lowBack: 1, .hips: 1]),
        "dumbbell_romanian_deadlift": ExerciseTraits(equipment: [.dumbbell], pattern: .hipHinge, stress: [.lowBack: 1, .hips: 1]),
        "dumbbell_single_leg_calf_raise": ExerciseTraits(equipment: [.dumbbell], pattern: .calfRaise),
        "bodyweight_calf_raise": ExerciseTraits(equipment: [], pattern: .calfRaise),
        "dumbbell_pullover": ExerciseTraits(equipment: [.dumbbell, .bench], pattern: .verticalPull, stress: [.shoulders: 1]),
    ]
}
