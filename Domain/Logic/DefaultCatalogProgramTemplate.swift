import Foundation

struct CatalogDayPlan {
    let title: String
    let exercises: [CatalogExercise]
}

struct CatalogExercisePrescription {
    let targetSets: Int
    let targetReps: Int
    let targetRIR: Int
    let plannedRepsBySet: [Int]
    let plannedLoadsBySet: [Double]
    let plannedRIRsBySet: [Int]
}

enum DefaultCatalogProgramTemplate {
    static func dayPlan(
        for globalIndex: Int,
        template: ProgramApplicationService.CatalogTemplateKind
    ) -> CatalogDayPlan {
        switch template {
        case .defaultPPL:
            return defaultPPLDayPlan(for: globalIndex)
        case .upperLower:
            return upperLowerDayPlan(for: globalIndex)
        }
    }

    static func prescription(
        goal: Goal,
        isDeload: Bool
    ) -> CatalogExercisePrescription {
        let targetSets = isDeload ? 2 : 3
        let targetReps: Int
        let targetRIR: Int

        switch goal {
        case .strength:
            targetReps = 5
            targetRIR = isDeload ? 3 : 2

        case .fatLoss:
            targetReps = 12
            targetRIR = isDeload ? 3 : 2

        case .hypertrophy, .longevity:
            fallthrough
        @unknown default:
            targetReps = 10
            targetRIR = isDeload ? 3 : 2
        }

        return CatalogExercisePrescription(
            targetSets: targetSets,
            targetReps: targetReps,
            targetRIR: targetRIR,
            plannedRepsBySet: Array(repeating: targetReps, count: targetSets),
            plannedLoadsBySet: Array(repeating: 0.0, count: targetSets),
            plannedRIRsBySet: Array(repeating: targetRIR, count: targetSets)
        )
    }

    private static func defaultPPLDayPlan(for globalIndex: Int) -> CatalogDayPlan {
        switch globalIndex % 3 {
        case 0:
            return CatalogDayPlan(
                title: "Push",
                exercises: [
                    ExerciseCatalog.benchPress,
                    ExerciseCatalog.inclineDumbbellPress,
                    ExerciseCatalog.seatedCableFly,
                    ExerciseCatalog.cableTricepRopePushdown,
                    ExerciseCatalog.dumbbellLateralRaise
                ]
            )

        case 1:
            return CatalogDayPlan(
                title: "Pull",
                exercises: [
                    ExerciseCatalog.wideGripPulldown,
                    ExerciseCatalog.dumbbellRowSingleArm,
                    ExerciseCatalog.seatedCableRow,
                    ExerciseCatalog.inclineRearDeltFly,
                    ExerciseCatalog.ezBarCurl,
                    ExerciseCatalog.hammerCurl
                ]
            )

        default:
            return CatalogDayPlan(
                title: "Legs",
                exercises: [
                    ExerciseCatalog.hackSquat,
                    ExerciseCatalog.legExtension,
                    ExerciseCatalog.romanianDeadlift,
                    ExerciseCatalog.lyingLegCurl,
                    ExerciseCatalog.machineHipThrust,
                    ExerciseCatalog.cableGluteKickback,
                    ExerciseCatalog.smithMachineCalves,
                    ExerciseCatalog.cableRopeCrunch
                ]
            )
        }
    }

    private static func upperLowerDayPlan(for globalIndex: Int) -> CatalogDayPlan {
        switch globalIndex % 4 {
        case 0:
            return CatalogDayPlan(
                title: "Upper A",
                exercises: [
                    ExerciseCatalog.benchPress,
                    ExerciseCatalog.wideGripPulldown,
                    ExerciseCatalog.inclineDumbbellPress,
                    ExerciseCatalog.seatedCableRow,
                    ExerciseCatalog.cableTricepRopePushdown,
                    ExerciseCatalog.hammerCurl
                ]
            )

        case 1:
            return CatalogDayPlan(
                title: "Lower A",
                exercises: [
                    ExerciseCatalog.hackSquat,
                    ExerciseCatalog.romanianDeadlift,
                    ExerciseCatalog.legExtension,
                    ExerciseCatalog.lyingLegCurl,
                    ExerciseCatalog.smithMachineCalves,
                    ExerciseCatalog.cableRopeCrunch
                ]
            )

        case 2:
            return CatalogDayPlan(
                title: "Upper B",
                exercises: [
                    ExerciseCatalog.inclineDumbbellPress,
                    ExerciseCatalog.seatedCableRow,
                    ExerciseCatalog.seatedCableFly,
                    ExerciseCatalog.wideGripPulldown,
                    ExerciseCatalog.dumbbellLateralRaise,
                    ExerciseCatalog.ezBarCurl
                ]
            )

        default:
            return CatalogDayPlan(
                title: "Lower B",
                exercises: [
                    ExerciseCatalog.machineHipThrust,
                    ExerciseCatalog.legExtension,
                    ExerciseCatalog.lyingLegCurl,
                    ExerciseCatalog.cableGluteKickback,
                    ExerciseCatalog.smithMachineCalves,
                    ExerciseCatalog.cableRopeCrunch
                ]
            )
        }
    }
}
