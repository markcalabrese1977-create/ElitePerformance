import Foundation
import SwiftData

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

    // MARK: - Custom Exercises (UserDefaults)

    private static let universalCustomKey = "custom_exercises_v2"
    
    private static let legacyCustomKeys = [
        "custom_exercises_mark_v1",
        "custom_exercises_angela_v1"
    ]

    private static func loadLegacyCustomExercises() -> [CatalogExercise] {
        var merged: [CatalogExercise] = []

        for key in legacyCustomKeys {
            guard let data = UserDefaults.standard.data(forKey: key) else { continue }
            guard let decoded = try? JSONDecoder().decode([CatalogExercise].self, from: data) else { continue }
            merged.append(contentsOf: decoded)
        }

        var seen: Set<String> = []
        return merged.filter { exercise in
            if seen.contains(exercise.id) { return false }
            seen.insert(exercise.id)
            return true
        }
    }

    static func customExercises(in context: ModelContext) -> [CatalogExercise] {
        let descriptor = FetchDescriptor<CustomExercise>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let results = (try? context.fetch(descriptor)) ?? []
        return results.map { $0.asCatalogExercise }
    }

    private static func saveCustom(_ list: [CatalogExercise]) {
        do {
            let data = try JSONEncoder().encode(list)
            UserDefaults.standard.set(data, forKey: universalCustomKey)
            NotificationCenter.default.post(name: .exerciseCatalogDidChange, object: nil)
        } catch { }
    }

    @discardableResult
    static func addCustomExercise(
        name: String,
        primaryMuscle: MuscleGroup,
        isCompound: Bool,
        in context: ModelContext
    ) -> CatalogExercise {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if let existingBuiltIn = builtIn.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedName
        }) {
            return existingBuiltIn
        }

        let existing = customExercises(in: context)
        if let existingCustom = existing.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedName
        }) {
            return existingCustom
        }

        let id = "custom_\(UUID().uuidString.lowercased())"
        let custom = CustomExercise(
            id: id,
            name: trimmed,
            primaryMuscleRaw: primaryMuscle.rawValue,
            isCompound: isCompound
        )
        context.insert(custom)
        try? context.save()
        NotificationCenter.default.post(name: .exerciseCatalogDidChange, object: nil)

        return CatalogExercise(id: id, name: trimmed, primaryMuscle: primaryMuscle, isCompound: isCompound)
    }

    static func deleteCustomExercises(ids: [String], in context: ModelContext) {
        let descriptor = FetchDescriptor<CustomExercise>()
        let all = (try? context.fetch(descriptor)) ?? []
        for item in all where ids.contains(item.id) {
            context.delete(item)
        }
        try? context.save()
        NotificationCenter.default.post(name: .exerciseCatalogDidChange, object: nil)
    }
    
    // MARK: - Chest / Push (horizontal / vertical)

    static let benchPress = CatalogExercise(
        id: "bench_press",
        name: "Bench Press",
        primaryMuscle: .chest,
        isCompound: true
    )

    static let closeGripBenchPress = CatalogExercise(
        id: "close_grip_bench_press",
        name: "Close Grip Bench Press",
        primaryMuscle: .chest,
        isCompound: true
    )

    static let pinPress = CatalogExercise(
        id: "pin_press",
        name: "Pin Press",
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
    static let machineChestPress = CatalogExercise(
        id: "machine_chest_press",
        name: "Machine Chest Press",
        primaryMuscle: .chest,
        isCompound: true
    )
    static let seatedCablePress = CatalogExercise(
        id: "seated_cable_press",
        name: "Seated Cable Press",
        primaryMuscle: .chest,
        isCompound: true
    )
    static let declineBenchPress = CatalogExercise(
            id: "decline_bench_press",
            name: "Decline Bench Press",
            primaryMuscle: .chest,
            isCompound: true
        )

        static let dumbbellFly = CatalogExercise(
            id: "dumbbell_fly",
            name: "Dumbbell Fly",
            primaryMuscle: .chest,
            isCompound: false
        )

        static let pecDeck = CatalogExercise(
            id: "pec_deck",
            name: "Pec Deck",
            primaryMuscle: .chest,
            isCompound: false
        )

        static let cableCrossover = CatalogExercise(
            id: "cable_crossover",
            name: "Cable Crossover",
            primaryMuscle: .chest,
            isCompound: false
        )

        static let pushUp = CatalogExercise(
            id: "push_up",
            name: "Push-Up",
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
    static let overheadRopeTricepExtension = CatalogExercise(
        id: "overhead_rope_tricep_extension",
        name: "Overhead Rope Tricep Extension",
        primaryMuscle: .triceps,
        isCompound: false
    )

    static let smithMachineDip = CatalogExercise(
        id: "smith_machine_dip",
        name: "Smith Machine Dip",
        primaryMuscle: .triceps,
        isCompound: true
    )

    static let tricepKickback = CatalogExercise(
        id: "tricep_kickback",
        name: "Tricep Kickback",
        primaryMuscle: .triceps,
        isCompound: false
    )

    static let singleArmCableTricepExtension = CatalogExercise(
        id: "single_arm_cable_tricep_extension",
        name: "Single-Arm Cable Tricep Extension",
        primaryMuscle: .triceps,
        isCompound: false
    )
    static let ezBarSkullCrusher = CatalogExercise(
            id: "ez_bar_skull_crusher",
            name: "EZ Bar Skull Crusher",
            primaryMuscle: .triceps,
            isCompound: false
        )

        static let dumbbellOverheadTricepExtension = CatalogExercise(
            id: "dumbbell_overhead_tricep_extension",
            name: "Dumbbell Overhead Tricep Extension",
            primaryMuscle: .triceps,
            isCompound: false
        )

        static let cableTricepPushdownStraightBar = CatalogExercise(
            id: "cable_tricep_pushdown_straight_bar",
            name: "Cable Tricep Pushdown (Straight Bar)",
            primaryMuscle: .triceps,
            isCompound: false
        )

        static let dip = CatalogExercise(
            id: "dip",
            name: "Dip",
            primaryMuscle: .triceps,
            isCompound: true
        )

        static let assistedDip = CatalogExercise(
            id: "assisted_dip",
            name: "Assisted Dip",
            primaryMuscle: .triceps,
            isCompound: true
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

    static let declineCableCrunch = CatalogExercise(
        id: "decline_cable_crunch",
        name: "Decline Cable Crunch",
        primaryMuscle: .core,
        isCompound: false
    )
    
    static let hangingStraightLegRaise = CatalogExercise(
        id: "hanging_straight_leg_raise",
        name: "Hanging Straight Leg Raise",
        primaryMuscle: .core,
        isCompound: true
    )
    
    static let hangingKneeRaise = CatalogExercise(
        id: "hanging_knee_raise",
        name: "Hanging Knee Raise",
        primaryMuscle: .core,
        isCompound: true
    )
    static let deadBug = CatalogExercise(
        id: "dead_bug",
        name: "Dead Bug",
        primaryMuscle: .core,
        isCompound: false
    )

    static let suitcaseCarry = CatalogExercise(
        id: "suitcase_carry",
        name: "Suitcase Carry",
        primaryMuscle: .core,
        isCompound: true
    )

    static let farmerCarry = CatalogExercise(
        id: "farmer_carry",
        name: "Farmer Carry",
        primaryMuscle: .core,
        isCompound: true
    )
    
    static let abWheelRollout = CatalogExercise(
            id: "ab_wheel_rollout",
            name: "Ab Wheel Rollout",
            primaryMuscle: .core,
            isCompound: true
        )

        static let cableWoodchop = CatalogExercise(
            id: "cable_woodchop",
            name: "Cable Woodchop",
            primaryMuscle: .core,
            isCompound: false
        )

        static let plank = CatalogExercise(
            id: "plank",
            name: "Plank",
            primaryMuscle: .core,
            isCompound: false
        )

        static let russianTwist = CatalogExercise(
            id: "russian_twist",
            name: "Russian Twist",
            primaryMuscle: .core,
            isCompound: false
        )

        static let declineSitUp = CatalogExercise(
            id: "decline_sit_up",
            name: "Decline Sit-Up",
            primaryMuscle: .core,
            isCompound: false
        )

        static let toesToBar = CatalogExercise(
            id: "toes_to_bar",
            name: "Toes to Bar",
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

    static let legPress = CatalogExercise(
        id: "leg_press",
        name: "Leg Press",
        primaryMuscle: .quads,
        isCompound: true
    )

    static let bulgarianSplitSquat = CatalogExercise(
        id: "bulgarian_split_squat",
        name: "Bulgarian Split Squat",
        primaryMuscle: .quads,
        isCompound: true
    )

    static let walkingLunge = CatalogExercise(
        id: "walking_lunge",
        name: "Walking Lunge",
        primaryMuscle: .quads,
        isCompound: true
    )

    static let cablePullThrough = CatalogExercise(
        id: "cable_pull_through",
        name: "Cable Pull-Through",
        primaryMuscle: .glutes,
        isCompound: true
    )

    static let backExtension45 = CatalogExercise(
        id: "back_extension_45",
        name: "45° Back Extension",
        primaryMuscle: .hamstrings,
        isCompound: true
    )

    static let benchBackExtension = CatalogExercise(
        id: "bench_back_extension",
        name: "Bench Back Extension",
        primaryMuscle: .hamstrings,
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
    
    static let seatedLegCurl = CatalogExercise(
        id: "seated_leg_curl",
        name: "Seated Leg Curl",
        primaryMuscle: .hamstrings,
        isCompound: false
    )
    static let gobletSquat = CatalogExercise(
            id: "goblet_squat",
            name: "Goblet Squat",
            primaryMuscle: .quads,
            isCompound: true
        )

        static let frontSquat = CatalogExercise(
            id: "front_squat",
            name: "Front Squat",
            primaryMuscle: .quads,
            isCompound: true
        )

        static let smithMachineSquat = CatalogExercise(
            id: "smith_machine_squat",
            name: "Smith Machine Squat",
            primaryMuscle: .quads,
            isCompound: true
        )

        static let sumoDeadlift = CatalogExercise(
            id: "sumo_deadlift",
            name: "Sumo Deadlift",
            primaryMuscle: .hamstrings,
            isCompound: true
        )

        static let conventionalDeadlift = CatalogExercise(
            id: "conventional_deadlift",
            name: "Conventional Deadlift",
            primaryMuscle: .hamstrings,
            isCompound: true
        )

        static let nordicCurl = CatalogExercise(
            id: "nordic_curl",
            name: "Nordic Curl",
            primaryMuscle: .hamstrings,
            isCompound: false
        )

        static let gluteBridge = CatalogExercise(
            id: "glute_bridge",
            name: "Glute Bridge",
            primaryMuscle: .glutes,
            isCompound: true
        )

        static let stepUp = CatalogExercise(
            id: "step_up",
            name: "Step-Up",
            primaryMuscle: .quads,
            isCompound: true
        )

        static let reverseHyperextension = CatalogExercise(
            id: "reverse_hyperextension",
            name: "Reverse Hyperextension",
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
    static let seatedCalfRaise = CatalogExercise(
        id: "seated_calf_raise",
        name: "Seated Calf Raise",
        primaryMuscle: .calves,
        isCompound: false
    )

    static let legPressCalfRaise = CatalogExercise(
        id: "leg_press_calf_raise",
        name: "Leg Press Calf Raise",
        primaryMuscle: .calves,
        isCompound: false
    )
    
    static let sledCalfPress = CatalogExercise(
        id: "sled_calf_press",
        name: "Sled Calf Press (Leg Press / Hack Squat)",
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
    
    static let chestSupportedInclineDumbbellRow = CatalogExercise(
        id: "chest_supported_incline_dumbbell_row",
        name: "Chest-Supported Incline DB Row",
        primaryMuscle: .back,
        isCompound: true
    )
    static let barbellRow = CatalogExercise(
            id: "barbell_row",
            name: "Barbell Row",
            primaryMuscle: .back,
            isCompound: true
        )

        static let tBarRow = CatalogExercise(
            id: "t_bar_row",
            name: "T-Bar Row",
            primaryMuscle: .back,
            isCompound: true
        )

        static let machineRow = CatalogExercise(
            id: "machine_row",
            name: "Machine Row",
            primaryMuscle: .back,
            isCompound: true
        )

        static let pullUp = CatalogExercise(
            id: "pull_up",
            name: "Pull-Up",
            primaryMuscle: .back,
            isCompound: true
        )

        static let chinUp = CatalogExercise(
            id: "chin_up",
            name: "Chin-Up",
            primaryMuscle: .back,
            isCompound: true
        )

        static let assistedPullUp = CatalogExercise(
            id: "assisted_pull_up",
            name: "Assisted Pull-Up",
            primaryMuscle: .back,
            isCompound: true
        )

        static let cablePullover = CatalogExercise(
            id: "cable_pullover",
            name: "Cable Pullover",
            primaryMuscle: .back,
            isCompound: false
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
    
    static let arnoldPress = CatalogExercise(
        id: "arnold_press",
        name: "Arnold Press",
        primaryMuscle: .shoulders,
        isCompound: true
    )

    static let singleArmCableLateralRaise = CatalogExercise(
        id: "single_arm_cable_lateral_raise",
        name: "Single-Arm Cable Lateral Raise",
        primaryMuscle: .shoulders,
        isCompound: false
    )
    static let dumbbellShoulderPress = CatalogExercise(
            id: "dumbbell_shoulder_press",
            name: "Dumbbell Shoulder Press",
            primaryMuscle: .shoulders,
            isCompound: true
        )

        static let machineShoulderPress = CatalogExercise(
            id: "machine_shoulder_press",
            name: "Machine Shoulder Press",
            primaryMuscle: .shoulders,
            isCompound: true
        )

        static let cableFacePull = CatalogExercise(
            id: "cable_face_pull",
            name: "Cable Face Pull",
            primaryMuscle: .shoulders,
            isCompound: false
        )

        static let uprightRow = CatalogExercise(
            id: "upright_row",
            name: "Upright Row",
            primaryMuscle: .shoulders,
            isCompound: true
        )

        static let dumbbellRearDeltFly = CatalogExercise(
            id: "dumbbell_rear_delt_fly",
            name: "Dumbbell Rear Delt Fly",
            primaryMuscle: .shoulders,
            isCompound: false
        )

        static let cableRearDeltFly = CatalogExercise(
            id: "cable_rear_delt_fly",
            name: "Cable Rear Delt Fly",
            primaryMuscle: .shoulders,
            isCompound: false
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

    static let cableRopeHammerCurl = CatalogExercise(
        id: "cable_rope_hammer_curl",
        name: "Cable Rope Hammer Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )
    static let singleArmCableCurl = CatalogExercise(
        id: "single_arm_cable_curl",
        name: "Single-Arm Cable Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )
    static let supinationPronationCurl = CatalogExercise(
        id: "supination_pronation_curl",
        name: "Supination / Pronation Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )
    static let ezBarReverseCurl = CatalogExercise(
        id: "ez_bar_reverse_curl",
        name: "EZ Bar Reverse Curl",
        primaryMuscle: .biceps,
        isCompound: false
    )
    static let barbellCurl = CatalogExercise(
            id: "barbell_curl",
            name: "Barbell Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

        static let concentrationCurl = CatalogExercise(
            id: "concentration_curl",
            name: "Concentration Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

        static let preacherCurl = CatalogExercise(
            id: "preacher_curl",
            name: "Preacher Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

        static let inclineDumbbellCurl = CatalogExercise(
            id: "incline_dumbbell_curl",
            name: "Incline Dumbbell Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

        static let cableOverheadCurl = CatalogExercise(
            id: "cable_overhead_curl",
            name: "Cable Overhead Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

        static let spiderCurl = CatalogExercise(
            id: "spider_curl",
            name: "Spider Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

        static let machineCurl = CatalogExercise(
            id: "machine_curl",
            name: "Machine Curl",
            primaryMuscle: .biceps,
            isCompound: false
        )

    // MARK: - All exercises array

    /// Master list used by lookups throughout the app.
    static var builtIn: [CatalogExercise] = [
        // Chest / push
                benchPress,
                closeGripBenchPress,
                pinPress,
                inclineDumbbellPress,
                seatedCableFly,
                dumbbellPress,
                machineChestPress,
                seatedCablePress,
                declineBenchPress,
                dumbbellFly,
                pecDeck,
                cableCrossover,
                pushUp,

                // Triceps
                        cableTricepRopePushdown,
                        overheadRopeTricepExtension,
                        smithMachineDip,
                        tricepKickback,
                        singleArmCableTricepExtension,
                        ezBarSkullCrusher,
                        dumbbellOverheadTricepExtension,
                        cableTricepPushdownStraightBar,
                        dip,
                        assistedDip,

                // Core
                        pallofPress,
                        cableRopeCrunch,
                        declineCableCrunch,
                        hangingStraightLegRaise,
                        hangingKneeRaise,
                        deadBug,
                        suitcaseCarry,
                        farmerCarry,
                        abWheelRollout,
                        cableWoodchop,
                        plank,
                        russianTwist,
                        declineSitUp,
                        toesToBar,

                // Quads / hinge / glutes
                        hackSquat,
                        legExtension,
                        legPress,
                        bulgarianSplitSquat,
                        walkingLunge,
                        romanianDeadlift,
                        lyingLegCurl,
                        seatedLegCurl,
                        machineHipThrust,
                        cableGluteKickback,
                        cablePullThrough,
                        backExtension45,
                        benchBackExtension,
                        gobletSquat,
                        frontSquat,
                        smithMachineSquat,
                        sumoDeadlift,
                        conventionalDeadlift,
                        nordicCurl,
                        gluteBridge,
                        stepUp,
                        reverseHyperextension,

        // Calves
        smithMachineCalves,
        seatedCalfRaise,
        legPressCalfRaise,
        sledCalfPress,

                // Back / pull
                        wideGripPulldown,
                        pulldownNormalGrip,
                        dumbbellRowSingleArm,
                        chestSupportedInclineDumbbellRow,
                        seatedCableRow,
                        barbellRow,
                        tBarRow,
                        machineRow,
                        pullUp,
                        chinUp,
                        assistedPullUp,
                        cablePullover,

                // Shoulders / rear delts
                        inclineRearDeltFly,
                        dumbbellLateralRaise,
                        seatedSmithMachineShoulderPress,
                        arnoldPress,
                        singleArmCableLateralRaise,
                        dumbbellShoulderPress,
                        machineShoulderPress,
                        cableFacePull,
                        uprightRow,
                        dumbbellRearDeltFly,
                        cableRearDeltFly,

                // Biceps / forearms
                        ezBarCurl,
                        hammerCurl,
                        cableRopeHammerCurl,
                        ezBarReverseCurl,
                        singleArmCableCurl,
                        supinationPronationCurl,
                        barbellCurl,
                        concentrationCurl,
                        preacherCurl,
                        inclineDumbbellCurl,
                        cableOverheadCurl,
                        spiderCurl,
                        machineCurl,
    ]
    static var all: [CatalogExercise] {
        let userDefaultsCustom: [CatalogExercise] = {
            guard let data = UserDefaults.standard.data(forKey: universalCustomKey),
                  let decoded = try? JSONDecoder().decode([CatalogExercise].self, from: data)
            else { return [] }
            return decoded
        }()

        // Merge built-in + UserDefaults custom, deduplicating by ID.
        // UserDefaults is the canonical store for custom exercises accessible
        // without a ModelContext — SwiftData is the source of truth but requires
        // a context to query, which static display functions don't have.
        var seen = Set<String>()
        var merged: [CatalogExercise] = []
        for ex in builtIn + userDefaultsCustom {
            if seen.insert(ex.id).inserted {
                merged.append(ex)
            }
        }
        return merged
    }
}
extension ExerciseCatalog {
    private static let legacyExerciseIdAliases: [String: String] = [
        "e8f675c1-2bc2-4eeb-a0b2-d701a6412f58": "seated_cable_press",
        "31c44a80-6c56-4e9d-aca1-ee754cd157b6": "arnold_press",
        "7ddaa8ff-55c5-4af5-891e-62676cdc9daf": "single_arm_cable_lateral_raise",
        "1cb4f3a7-65f2-4e9d-aca1-ee754cd157b6": "single_arm_cable_curl",
        "591028b2-9f09-4347-a245-6cf71e5f403d": "supination_pronation_curl"
    ]

    private static let legacyExerciseNameMap: [String: String] = [
        "591028b2-9f09-4347-a245-6cf71e5f403d": "Supination / Pronation Curl",
        "31c44a80-6c56-4e9d-aca1-ee754cd157b6": "Arnold Press",
        "7ddaa8ff-55c5-4af5-891e-62676cdc9daf": "Single-Arm Cable Lateral Raise",
        "e8f675c1-2bc2-4eeb-a0b2-d701a6412f58": "Seated Cable Press",
        "1cb4f3a7-65f2-4e9d-aca1-ee754cd157b6": "Single-Arm Cable Curl"
    ]

    static func canonicalExerciseId(for rawId: String) -> String {
        let normalized = normalizeLegacyId(rawId)
        return legacyExerciseIdAliases[normalized] ?? normalized
    }

    static func canonicalBuiltInId(forExerciseName name: String) -> String? {
        let normalized = normalizedExerciseName(name)

        if let builtIn = builtIn.first(where: {
            normalizedExerciseName($0.name) == normalized
        }) {
            return builtIn.id
        }

        return nil
    }

    static func resolvedExerciseId(
        rawId: String,
        snapshotName: String? = nil,
        fallbackName: String? = nil
    ) -> String {
        let canonicalById = canonicalExerciseId(for: rawId)

        // If the ID already resolves to a known built-in/custom catalog entry, use it.
        if all.contains(where: { $0.id == canonicalById }) {
            return canonicalById
        }

        // Name snapshot fallback
        if let snapshotName,
           let builtInId = canonicalBuiltInId(forExerciseName: snapshotName) {
            return builtInId
        }

        // UI/display fallback
        if let fallbackName,
           let builtInId = canonicalBuiltInId(forExerciseName: fallbackName) {
            return builtInId
        }

        return canonicalById
    }

    private static func normalizedExerciseName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    
    static func displayName(for exerciseId: String) -> String {
        let trimmedId = exerciseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return "Unknown Exercise" }

        let canonicalId = canonicalExerciseId(for: trimmedId)

        // 1) Direct built-in/custom match using canonical ID
        if let ex = all.first(where: { $0.id == canonicalId }) {
            return ex.name
        }

        // 2) Known legacy name fallback
        if let mapped = legacyExerciseNameMap[canonicalId],
           !mapped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return mapped
        }

        // 3) Opaque legacy token guard
        if looksLikeOpaqueLegacyId(trimmedId) || looksLikeOpaqueLegacyId(canonicalId) {
            return "Legacy / Custom Exercise"
        }

        // 4) Prettified fallback
        let pretty = canonicalId
            .replacingOccurrences(of: "custom_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let titleCased = pretty
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        return titleCased.isEmpty ? "Unknown Exercise" : titleCased
    }

    private static func normalizeLegacyId(_ rawId: String) -> String {
        let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let collapsedWhitespace = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        return collapsedWhitespace
    }

    private static func looksLikeOpaqueLegacyId(_ value: String) -> Bool {
        let lower = value.lowercased()

        let dashedUUID = lower.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil

        if dashedUUID { return true }

        let spacedUUID = lower.range(
            of: #"^[0-9a-f]{8}\s+[0-9a-f]{4}\s+[0-9a-f]{4}\s+[0-9a-f]{4}\s+[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil

        if spacedUUID { return true }

        if lower.contains("-"), lower.count >= 24, !lower.contains("_") {
            return true
        }

        if lower.contains(" "), lower.count >= 24, !lower.contains("_") {
            let compact = lower.replacingOccurrences(of: " ", with: "")
            if compact.range(of: #"^[0-9a-f]+$"#, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }
}

// MARK: - Exercise Cluster

extension ExerciseCatalog {
    /// Returns the progression cluster for a given exercise ID.
    /// Used by CoachingEngine and ProgressionEngine for cluster-aware load steps.
    static func cluster(for exerciseId: String) -> ExerciseCluster? {
        switch exerciseId {

        // MARK: Primary Chest Press
        case "bench_press",
                     "close_grip_bench_press",
                     "pin_press",
                     "incline_dumbbell_press",
                     "dumbbell_press",
                     "machine_chest_press",
                     "seated_cable_press",
                     "decline_bench_press",
                     "push_up":
                    return .primaryChestPress

        // MARK: Secondary Press / Arms
        case "cable_tricep_rope_pushdown",
                     "overhead_rope_tricep_extension",
                     "smith_machine_dip",
                     "tricep_kickback",
                     "single_arm_cable_tricep_extension",
                     "ez_bar_skull_crusher",
                     "dumbbell_overhead_tricep_extension",
                     "cable_tricep_pushdown_straight_bar",
                     "dip",
                     "assisted_dip",
                     "wide_grip_pulldown",
                     "pulldown_normal_grip",
                     "dumbbell_row_single_arm",
                     "seated_cable_row",
                     "chest_supported_incline_dumbbell_row",
                     "barbell_row",
                     "t_bar_row",
                     "machine_row",
                     "pull_up",
                     "chin_up",
                     "assisted_pull_up",
                     "seated_smith_machine_shoulder_press",
                     "arnold_press",
                     "dumbbell_shoulder_press",
                     "machine_shoulder_press",
                     "upright_row":
                    return .secondaryPressOrArms

        // MARK: Primary Leg
        case "hack_squat",
                     "leg_press",
                     "bulgarian_split_squat",
                     "walking_lunge",
                     "romanian_deadlift",
                     "machine_hip_thrust",
                     "goblet_squat",
                     "front_squat",
                     "smith_machine_squat",
                     "sumo_deadlift",
                     "conventional_deadlift",
                     "glute_bridge",
                     "step_up":
                    return .primaryLeg

        // MARK: Pump / Isolation
        case "seated_cable_fly",
                     "dumbbell_fly",
                     "pec_deck",
                     "cable_crossover",
                     "leg_extension",
                     "lying_leg_curl",
                     "seated_leg_curl",
                     "cable_glute_kickback",
                     "nordic_curl",
                     "reverse_hyperextension",
                     "smith_machine_calves",
                     "seated_calf_raise",
                     "leg_press_calf_raise",
                     "sled_calf_press",
                     "ez_bar_curl",
                     "hammer_curl",
                     "cable_rope_hammer_curl",
                     "single_arm_cable_curl",
                     "supination_pronation_curl",
                     "ez_bar_reverse_curl",
                     "barbell_curl",
                     "concentration_curl",
                     "preacher_curl",
                     "incline_dumbbell_curl",
                     "cable_overhead_curl",
                     "spider_curl",
                     "machine_curl",
                     "dumbbell_lateral_raise",
                     "single_arm_cable_lateral_raise",
                     "incline_rear_delt_fly",
                     "dumbbell_rear_delt_fly",
                     "cable_rear_delt_fly",
                     "cable_face_pull",
                     "cable_pullover",
                     "cable_rope_crunch",
                     "decline_cable_crunch",
                     "hanging_straight_leg_raise",
                     "hanging_knee_raise",
                     "ab_wheel_rollout",
                     "cable_woodchop",
                     "plank",
                     "decline_sit_up",
                     "toes_to_bar":
                    return .pumpIsolation

        // MARK: Low Back / Stability
        case "cable_pull_through",
                     "back_extension_45",
                     "bench_back_extension",
                     "pallof_press",
                     "dead_bug",
                     "suitcase_carry",
                     "farmer_carry",
                     "russian_twist":
                    return .lowBackStability

        default:
            return nil
        }
    }
}
