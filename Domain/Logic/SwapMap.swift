import Foundation

/// Provides simple swap options for a given exercise based on the catalog.
///
/// v1.0:
/// - If we have explicit overrides for an exercise id, use those.
/// - Otherwise, return other exercises with the same primary muscle,
///   excluding the exercise itself.
struct SwapMap {

    /// Returns swap candidates for the given exercise id.
    static func swapOptions(for exerciseId: String) -> [CatalogExercise] {
        guard let current = ExerciseCatalog.all.first(where: { $0.id == exerciseId }) else {
            return []
        }

        // 1) Explicit overrides for certain movements
        if let overrides = explicitOverrides[exerciseId], !overrides.isEmpty {
            return overrides
        }

        // 2) Default: same primary muscle, excluding this exact exercise
        let sameMuscle = ExerciseCatalog.all.filter {
            $0.id != current.id && $0.primaryMuscle == current.primaryMuscle
        }

        return sameMuscle
    }

    /// Explicit overrides for common "problem" exercises.
    /// These let us steer toward joint-friendly swaps and keep the intent of the plan.
    private static let explicitOverrides: [String: [CatalogExercise]] = [
        // Chest: if barbell bench is rough on shoulders, bias DB/machine
        "bench_press": [
            ExerciseCatalog.dumbbellPress,
            ExerciseCatalog.machineChestPress,
            ExerciseCatalog.seatedCableFly
        ],

        "incline_dumbbell_press": [
            ExerciseCatalog.machineChestPress,
            ExerciseCatalog.benchPress,
            ExerciseCatalog.seatedCableFly
        ],

        // Hack squat issues → leg press / Bulgarian / leg extension
        "hack_squat": [
            ExerciseCatalog.legPress,
            ExerciseCatalog.bulgarianSplitSquat,
            ExerciseCatalog.legExtension
        ],

        // Leg press issues → hack / Bulgarian / walking lunge
        "leg_press": [
            ExerciseCatalog.hackSquat,
            ExerciseCatalog.bulgarianSplitSquat,
            ExerciseCatalog.walkingLunge
        ],

        // Lying leg curl → seated curl / RDL if needed
        "lying_leg_curl": [
            ExerciseCatalog.seatedLegCurl,
            ExerciseCatalog.romanianDeadlift
        ],

        // Calves: if Smith calves sucks, prefer seated / leg press calves
        "smith_machine_calves": [
            ExerciseCatalog.seatedCalfRaise,
            ExerciseCatalog.legPressCalfRaise
        ],

        // Cable pull-through → hip thrust / RDL / back extension
        "cable_pull_through": [
            ExerciseCatalog.machineHipThrust,
            ExerciseCatalog.romanianDeadlift,
            ExerciseCatalog.backExtension45
        ],

        // Back extension cluster – bench + 45°
        "back_extension_45": [
            ExerciseCatalog.benchBackExtension,
            ExerciseCatalog.romanianDeadlift
        ],
        "bench_back_extension": [
            ExerciseCatalog.backExtension45,
            ExerciseCatalog.romanianDeadlift
        ],

        // Core / carries cluster
        "pallof_press": [
            ExerciseCatalog.suitcaseCarry,
            ExerciseCatalog.farmerCarry,
            ExerciseCatalog.deadBug
        ],
        "suitcase_carry": [
            ExerciseCatalog.farmerCarry,
            ExerciseCatalog.pallofPress
        ],

        // Triceps cluster: rope pushdown ↔ overhead ↔ Smith dip ↔ kickback
        "cable_tricep_rope_pushdown": [
            ExerciseCatalog.overheadRopeTricepExtension,
            ExerciseCatalog.smithMachineDip,
            ExerciseCatalog.tricepKickback
        ],
        "overhead_rope_tricep_extension": [
            ExerciseCatalog.cableTricepRopePushdown,
            ExerciseCatalog.smithMachineDip
        ],
        "smith_machine_dip": [
            ExerciseCatalog.cableTricepRopePushdown,
            ExerciseCatalog.overheadRopeTricepExtension
        ],
        "tricep_kickback": [
            ExerciseCatalog.cableTricepRopePushdown,
            ExerciseCatalog.overheadRopeTricepExtension
        ],

        // Biceps: existing reverse curl case preserved
        "ez_bar_reverse_curl": [
            ExerciseCatalog.cableRopeHammerCurl,
            ExerciseCatalog.hammerCurl,
            ExerciseCatalog.ezBarCurl
        ]
    ]
}
