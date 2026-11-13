// Domain/Analytics/ExerciseMuscleShares.swift
import Foundation

/// How much of one hard set of an exercise counts toward each fine muscle: the primary mover 1.0, a meaningful
/// synergist 0.5, a minor one 0.25. This is a coarse, reviewable estimate, not physiology: it exists so weekly volume per
/// muscle can credit indirect work (a bench press trains triceps and front delts) without double counting everything at
/// full value. The table is data; the review CSV (`ExerciseMuscleShares.csv()`) lists every row for checking.
///
/// A custom exercise has no row: its mapping is `CustomExercise.fineShares` (set by the lifter), else it is "unmapped".
enum ExerciseMuscleShares {

    /// Canonical exercise id -> fine muscle -> share (primary 1.0, secondary 0.25 ... 0.5).
    static let table: [String: [FineMuscle: Double]] = {
        var t: [String: [FineMuscle: Double]] = [:]
        for line in rows {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            var shares: [FineMuscle: Double] = [:]
            for pair in parts[1].split(separator: ",") {
                let kv = pair.split(separator: " ").map(String.init)
                if let muscle = FineMuscle(rawValue: kv[0]), let value = Double(kv[1]) { shares[muscle] = value }
            }
            t[parts[0]] = shares
        }
        return t
    }()

    /// "exercise_id|muscle share, muscle share" (parsed once above; a typo in a muscle name drops that share and the
    /// coverage test fails on it).
    private static let rows: [String] = [

        "bench_press|chest 1, triceps .5, frontDelts .5",
        "close_grip_bench_press|triceps 1, chest .5, frontDelts .25",
        "pin_press|chest 1, triceps .5, frontDelts .5",
        "incline_dumbbell_press|chest 1, frontDelts .5, triceps .5",
        "seated_cable_fly|chest 1, frontDelts .25",
        "dumbbell_press|chest 1, triceps .5, frontDelts .5",
        "machine_chest_press|chest 1, triceps .5, frontDelts .25",
        "seated_cable_press|chest 1, triceps .5, frontDelts .25",
        "decline_bench_press|chest 1, triceps .5, frontDelts .25",
        "dumbbell_fly|chest 1, frontDelts .25",
        "pec_deck|chest 1",
        "cable_crossover|chest 1, frontDelts .25",
        "push_up|chest 1, triceps .5, frontDelts .5",
        "cable_tricep_rope_pushdown|triceps 1",
        "overhead_rope_tricep_extension|triceps 1",
        "smith_machine_dip|triceps 1, chest .5, frontDelts .25",
        "tricep_kickback|triceps 1",
        "single_arm_cable_tricep_extension|triceps 1",
        "ez_bar_skull_crusher|triceps 1",
        "dumbbell_overhead_tricep_extension|triceps 1",
        "cable_tricep_pushdown_straight_bar|triceps 1",
        "dip|triceps 1, chest .5, frontDelts .25",
        "assisted_dip|triceps 1, chest .5, frontDelts .25",
        "pallof_press|abs 1",
        "cable_rope_crunch|abs 1",
        "decline_cable_crunch|abs 1",
        "hanging_straight_leg_raise|abs 1, forearms .25",
        "hanging_knee_raise|abs 1, forearms .25",
        "dead_bug|abs 1",
        "suitcase_carry|abs 1, forearms .5, lowerBack .25",
        "farmer_carry|forearms 1, upperBack .5, abs .5",
        "ab_wheel_rollout|abs 1, lats .25",
        "cable_woodchop|abs 1",
        "plank|abs 1",
        "russian_twist|abs 1",
        "decline_sit_up|abs 1",
        "toes_to_bar|abs 1, lats .25, forearms .25",
        "hack_squat|quads 1, glutes .5, adductors .25",
        "leg_press|quads 1, glutes .5, adductors .25",
        "bulgarian_split_squat|quads 1, glutes .5, adductors .25",
        "walking_lunge|quads 1, glutes .5, adductors .25",
        "cable_pull_through|glutes 1, hamstrings .5, lowerBack .25",
        "back_extension_45|lowerBack 1, glutes .5, hamstrings .5",
        "bench_back_extension|lowerBack 1, glutes .5, hamstrings .5",
        "leg_extension|quads 1",
        "romanian_deadlift|hamstrings 1, glutes .5, lowerBack .5",
        "lying_leg_curl|hamstrings 1",
        "machine_hip_thrust|glutes 1, hamstrings .25",
        "cable_glute_kickback|glutes 1",
        "seated_leg_curl|hamstrings 1",
        "goblet_squat|quads 1, glutes .5, adductors .25",
        "front_squat|quads 1, glutes .5, adductors .25",
        "smith_machine_squat|quads 1, glutes .5, adductors .25",
        "sumo_deadlift|glutes 1, adductors .5, hamstrings .5, quads .5, lowerBack .5",
        "conventional_deadlift|hamstrings 1, glutes .5, lowerBack .5, upperBack .5, quads .25, forearms .25",
        "nordic_curl|hamstrings 1, glutes .25",
        "glute_bridge|glutes 1, hamstrings .25",
        "step_up|quads 1, glutes .5",
        "reverse_hyperextension|glutes 1, hamstrings .5, lowerBack .5",
        "smith_machine_calves|calves 1",
        "seated_calf_raise|calves 1",
        "leg_press_calf_raise|calves 1",
        "sled_calf_press|calves 1",
        "wide_grip_pulldown|lats 1, biceps .5, upperBack .25",
        "pulldown_normal_grip|lats 1, biceps .5, upperBack .25",
        "dumbbell_row_single_arm|lats 1, upperBack .5, biceps .5, rearDelts .25",
        "seated_cable_row|upperBack 1, lats .5, biceps .5, rearDelts .25",
        "chest_supported_incline_dumbbell_row|upperBack 1, lats .5, biceps .5, rearDelts .5",
        "barbell_row|upperBack 1, lats .5, biceps .5, rearDelts .25, lowerBack .25",
        "t_bar_row|upperBack 1, lats .5, biceps .5, rearDelts .25, lowerBack .25",
        "machine_row|upperBack 1, lats .5, biceps .5, rearDelts .25",
        "pull_up|lats 1, biceps .5, upperBack .25",
        "chin_up|lats 1, biceps .5, upperBack .25",
        "assisted_pull_up|lats 1, biceps .5, upperBack .25",
        "cable_pullover|lats 1, triceps .25",
        "incline_rear_delt_fly|rearDelts 1, upperBack .5",
        "dumbbell_lateral_raise|sideDelts 1",
        "seated_smith_machine_shoulder_press|frontDelts 1, sideDelts .5, triceps .5",
        "arnold_press|frontDelts 1, sideDelts .5, triceps .5",
        "single_arm_cable_lateral_raise|sideDelts 1",
        "dumbbell_shoulder_press|frontDelts 1, sideDelts .5, triceps .5",
        "machine_shoulder_press|frontDelts 1, sideDelts .5, triceps .5",
        "cable_face_pull|rearDelts 1, upperBack .5, sideDelts .25",
        "upright_row|sideDelts 1, upperBack .5, frontDelts .25",
        "dumbbell_rear_delt_fly|rearDelts 1, upperBack .5",
        "cable_rear_delt_fly|rearDelts 1, upperBack .5",
        "ez_bar_curl|biceps 1, forearms .25",
        "hammer_curl|biceps 1, forearms .5",
        "cable_rope_hammer_curl|biceps 1, forearms .5",
        "single_arm_cable_curl|biceps 1",
        "supination_pronation_curl|biceps 1, forearms .25",
        "ez_bar_reverse_curl|forearms 1, biceps .5",
        "barbell_curl|biceps 1, forearms .25",
        "concentration_curl|biceps 1",
        "preacher_curl|biceps 1",
        "incline_dumbbell_curl|biceps 1",
        "cable_overhead_curl|biceps 1",
        "spider_curl|biceps 1",
        "machine_curl|biceps 1",
        "barbell_back_squat|quads 1, glutes .5, adductors .25, lowerBack .25",
        "barbell_overhead_press|frontDelts 1, sideDelts .5, triceps .5",
        "landmine_press|frontDelts 1, chest .5, triceps .5",
        "barbell_hip_thrust|glutes 1, hamstrings .25",
        "dumbbell_romanian_deadlift|hamstrings 1, glutes .5, lowerBack .5",
        "dumbbell_single_leg_calf_raise|calves 1",
        "bodyweight_calf_raise|calves 1",
        "dumbbell_pullover|lats 1, chest .5, triceps .25",
    ]

    /// The built-in shares for an exercise (any legacy id spelling); nil for a custom or unknown exercise, whose mapping
    /// is the lifter's (`CustomExercise.fineShares`) - never guessed here.
    static func shares(for exerciseId: String) -> [FineMuscle: Double]? {
        table[ExerciseCatalog.canonicalExerciseId(for: exerciseId)]
    }

    /// Review CSV: one row per built-in exercise, the shares in the fixed muscle order of `FineMuscle.allCases`.
    static func csv() -> String {
        let muscles = FineMuscle.allCases
        var lines = ["exercise_id,name,coarse_muscle,compound," + muscles.map(\.rawValue).joined(separator: ",")]
        for e in ExerciseCatalog.builtIn.sorted(by: { ($0.primaryMuscle.rawValue, $0.name) < ($1.primaryMuscle.rawValue, $1.name) }) {
            let row = table[e.id] ?? [:]
            let cells = muscles.map { m in row[m].map { $0 == 1 ? "1" : String(format: "%g", $0) } ?? "" }
            lines.append(([e.id, "\"\(e.name)\"", e.primaryMuscle.rawValue, e.isCompound ? "yes" : "no"] + cells).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
