import Foundation

/// Primary muscle group focus for an exercise.
/// This is intentionally coarse – we can refine later if needed.
enum MuscleGroup: String, Codable, CaseIterable {
    case chest
    case back
    case quads
    case hamstrings
    case glutes
    case shoulders
    case biceps
    case triceps
    case core
    case calves
    case fullBody
}

/// Static definition of an exercise in the catalog.
/// These are NOT per-session – they are the "dictionary" of movements the app knows about.
struct CatalogExercise: Identifiable, Hashable, Codable {
    let id: String           // stable string ID used by SessionItem.exerciseId
    let name: String         // display name
    let primaryMuscle: MuscleGroup
    let isCompound: Bool
}

/// Central catalog of all exercises the system understands right now.
/// SessionItem.exerciseId MUST always be one of these ids.
struct ExerciseCatalog {

    // MARK: - Chest / Push (horizontal / vertical)

    static let benchPress = CatalogExercise(
        id: "bench_press",
        name: "Bench Press",
        primaryMuscle: .chest,
        isCompound: true
    )

    static let inclineDumbbellPress = CatalogExercise(
        id: "incline_dumbbell_press",
        name: "Incline Dumbbell Press",
        primaryMuscle: .chest,
        isCompound: true
    )

    static let seatedCableFly = CatalogExercise(
        id: "seated_cable_fly",
        name: "Seated Cable Fly",
        primaryMuscle: .chest,
        isCompound: false
    )

    static let dumbbellPress = CatalogExercise(
        id: "dumbbell_press",
        name: "Dumbbell Press",
        primaryMuscle: .chest,
        isCompound: true
    )

    // MARK: - Triceps

    static let cableTricepRopePushdown = CatalogExercise(
        id: "cable_tricep_rope_pushdown",
        name: "Cable Tricep Rope Pushdown",
        primaryMuscle: .triceps,
        isCompound: false
    )

    // MARK: - Core / Anti-rotation

    static let pallofPress = CatalogExercise(
        id: "pallof_press",
        name: "Pallof Press",
        primaryMuscle: .core,
        isCompound: false
    )

    static let cableRopeCrunch = CatalogExercise(
        id: "cable_rope_crunch",
        name: "Cable Rope Crunch",
        primaryMuscle: .core,
        isCompound: false
    )

    static let hangingStraightLegRaise = CatalogExercise(
        id: "hanging_straight_leg_raise",
        name: "Hanging Straight Leg Raise",
        primaryMuscle: .core,
        isCompound: true
    )

    // MARK: - Quads / Hinge / Glutes

    static let hackSquat = CatalogExercise(
        id: "hack_squat",
        name: "Hack Squat",
        primaryMuscle: .quads,
        isCompound: true
    )

    static let legExtension = CatalogExercise(
        id: "leg_extension",
        name: "Leg Extension",
        primaryMuscle: .quads,
        isCompound: false
    )

    static let romanianDeadlift = CatalogExercise(
        id: "romanian_deadlift",
        name: "Romanian Deadlift",
        primaryMuscle: .hamstrings,
        isCompound: true
    )

    static let lyingLegCurl = CatalogExercise(
        id: "lying_leg_curl",
        name: "Lying Leg Curl",
        primaryMuscle: .hamstrings,
        isCompound: false
    )

    static let machineHipThrust = CatalogExercise(
        id: "machine_hip_thrust",
        name: "Machine Hip Thrust",
        primaryMuscle: .glutes,
        isCompound: true
    )

    static let cableGluteKickback = CatalogExercise(
        id: "cable_glute_kickback",
        name: "Cable Glute Kickback",
        primaryMuscle: .glutes,
        isCompound: false
    )

    // MARK: - Calves

    static let smithMachineCalves = CatalogExercise(
        id: "smith_machine_calves",
        name: "Smith Machine Calf Raise",
        primaryMuscle: .calves,
        isCompound: false
    )

    // MARK: - Back / Pull

    static let wideGripPulldown = CatalogExercise(
        id: "wide_grip_pulldown",
        name: "Wide Grip Pulldown",
        primaryMuscle: .back,
        isCompound: true
    )

    static let pulldownNormalGrip = CatalogExercise(
        id: "pulldown_normal_grip",
        name: "Pulldown (Normal Grip)",
        primaryMuscle: .back,
        isCompound: true
    )

    static let dumbbellRowSingleArm = CatalogExercise(
        id: "dumbbell_row_single_arm",
        name: "Dumbbell Row (Single Arm)",
        primaryMuscle: .back,
        isCompound: true
    )

    static let seatedCableRow = CatalogExercise(
        id: "seated_cable_row",
        name: "Seated Cable Row",
        primaryMuscle: .back,
        isCompound: true
    )

    // MARK: - Rear delts / Shoulders

    static let inclineRearDeltFly = CatalogExercise(
        id: "incline_rear_delt_fly",
        name: "Incline Rear Delt Fly",
        primaryMuscle: .shoulders,
        isCompound: false
    )

    static let dumbbellLateralRaise = CatalogExercise(
        id: "dumbbell_lateral_raise",
        name: "Dumbbell Lateral Raise",
        primaryMuscle: .shoulders,
        isCompound: false
    )

    static let seatedSmithMachineShoulderPress = CatalogExercise(
        id: "seated_smith_machine_shoulder_press",
        name: "Seated Smith Machine Shoulder Press",
        primaryMuscle: .shoulders,
        isCompound: true
    )

    // MARK: - Biceps / Forearms

    static let ezBarCurl = CatalogExercise(
        id: "ez_bar_curl",
        name: "EZ Bar Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )

    static let hammerCurl = CatalogExercise(
        id: "hammer_curl",
        name: "Hammer Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )

    static let ezBarReverseCurl = CatalogExercise(
        id: "ez_bar_reverse_curl",
        name: "EZ Bar Reverse Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )

    // MARK: - All exercises array

    /// Master list used by lookups throughout the app.
    static let all: [CatalogExercise] = [
        // Chest / push
        benchPress,
        inclineDumbbellPress,
        seatedCableFly,
        dumbbellPress,

        // Triceps
        cableTricepRopePushdown,

        // Core
        pallofPress,
        cableRopeCrunch,
        hangingStraightLegRaise,

        // Quads / hinge / glutes
        hackSquat,
        legExtension,
        romanianDeadlift,
        lyingLegCurl,
        machineHipThrust,
        cableGluteKickback,

        // Calves
        smithMachineCalves,

        // Back / pull
        wideGripPulldown,
        pulldownNormalGrip,
        dumbbellRowSingleArm,
        seatedCableRow,

        // Shoulders / rear delts
        inclineRearDeltFly,
        dumbbellLateralRaise,
        seatedSmithMachineShoulderPress,

        // Biceps / forearms
        ezBarCurl,
        hammerCurl,
        ezBarReverseCurl
    ]
}
