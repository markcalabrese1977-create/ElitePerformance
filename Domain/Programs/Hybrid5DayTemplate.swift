// Domain/Programs/Hybrid5DayTemplate.swift
import Foundation

enum Hybrid5DayTemplate {

    // MARK: - Week Rules
    // A/B/C wave rotation across 9 hard weeks + deload
    // Same wave structure as Upper/Lower — rotating stimulus across the week
    // Day 5 is a pump/weak-point day that stays higher rep across all waves

    static let weekRules: [ProgramWeekRule] = [
        .init(weekNumber: 1,  wave: .a,      notes: "Baseline week — establish working loads"),
        .init(weekNumber: 2,  wave: .b,      notes: "Volume peak — higher reps, accumulate work"),
        .init(weekNumber: 3,  wave: .c,      notes: "Intensity peak — heavier loads, lower reps"),
        .init(weekNumber: 4,  wave: .a,      notes: "Second A wave — build on week 1 baseline"),
        .init(weekNumber: 5,  wave: .b,      notes: nil),
        .init(weekNumber: 6,  wave: .c,      notes: nil),
        .init(weekNumber: 7,  wave: .a,      notes: "Third A wave"),
        .init(weekNumber: 8,  wave: .b,      notes: nil),
        .init(weekNumber: 9,  wave: .c,      notes: "Meso intensity high point"),
        .init(weekNumber: 10, wave: .deload, notes: "Deload — systemic recovery")
    ]

    static let template = ProgramTemplate(
        id: "hybrid_5day_v1",
        name: "5-Day Upper / Lower + Pump",
        totalWeeks: 10,
        trainingDaysPerWeek: 5,
        weekRules: weekRules,
        dayTemplates: [upperA, lowerA, upperB, lowerB, pump]
    )

    // MARK: - Upper A (Horizontal push/pull — strength focus)

    static let upperA = ProgramDayTemplate(
        id: "h5_upper_a",
        dayNumber: 1,
        title: "Upper A",
        role: "Horizontal push and pull — strength focus",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "h5_ua_bench",
                order: 1,
                exerciseId: ExerciseCatalog.benchPress.id,
                priority: .anchor,
                notes: "Primary horizontal push. Drive load progression here.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ua_row",
                order: 2,
                exerciseId: ExerciseCatalog.seatedCableRow.id,
                priority: .anchor,
                notes: "Primary horizontal pull.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ua_incline",
                order: 3,
                exerciseId: ExerciseCatalog.inclineDumbbellPress.id,
                priority: .standard,
                notes: "Upper chest accessory.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ua_pulldown",
                order: 4,
                exerciseId: ExerciseCatalog.wideGripPulldown.id,
                priority: .standard,
                notes: "Vertical pull accessory.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ua_tricep",
                order: 5,
                exerciseId: ExerciseCatalog.cableTricepRopePushdown.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ua_curl",
                order: 6,
                exerciseId: ExerciseCatalog.hammerCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            )
        ]
    )

    // MARK: - Lower A (Quad dominant)

    static let lowerA = ProgramDayTemplate(
        id: "h5_lower_a",
        dayNumber: 2,
        title: "Lower A",
        role: "Quad dominant — squat pattern primary",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "h5_la_hack",
                order: 1,
                exerciseId: ExerciseCatalog.hackSquat.id,
                priority: .anchor,
                notes: "Primary quad compound.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_la_rdl",
                order: 2,
                exerciseId: ExerciseCatalog.romanianDeadlift.id,
                priority: .anchor,
                notes: "Hip hinge — hamstring and glute focus.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_la_leg_extension",
                order: 3,
                exerciseId: ExerciseCatalog.legExtension.id,
                priority: .standard,
                notes: "Quad isolation.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_la_leg_curl",
                order: 4,
                exerciseId: ExerciseCatalog.lyingLegCurl.id,
                priority: .standard,
                notes: "Hamstring isolation.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_la_calves",
                order: 5,
                exerciseId: ExerciseCatalog.smithMachineCalves.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            )
        ]
    )

    // MARK: - Upper B (Shoulder and detail — pump focus)

    static let upperB = ProgramDayTemplate(
        id: "h5_upper_b",
        dayNumber: 3,
        title: "Upper B",
        role: "Shoulder and detail upper — pump focus",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "h5_ub_shoulder_press",
                order: 1,
                exerciseId: ExerciseCatalog.arnoldPress.id,
                priority: .anchor,
                notes: "Primary shoulder press.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ub_db_row",
                order: 2,
                exerciseId: ExerciseCatalog.dumbbellRowSingleArm.id,
                priority: .anchor,
                notes: "Unilateral back work.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ub_fly",
                order: 3,
                exerciseId: ExerciseCatalog.seatedCableFly.id,
                priority: .standard,
                notes: "Chest detail and stretch.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ub_lateral",
                order: 4,
                exerciseId: ExerciseCatalog.dumbbellLateralRaise.id,
                priority: .standard,
                notes: "Shoulder width.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ub_rear_delt",
                order: 5,
                exerciseId: ExerciseCatalog.inclineRearDeltFly.id,
                priority: .standard,
                notes: "Rear delt and posture work.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ub_curl",
                order: 6,
                exerciseId: ExerciseCatalog.ezBarCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_ub_oh_tricep",
                order: 7,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .standard,
                notes: "Long head tricep emphasis.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            )
        ]
    )

    // MARK: - Lower B (Posterior chain dominant)

    static let lowerB = ProgramDayTemplate(
        id: "h5_lower_b",
        dayNumber: 4,
        title: "Lower B",
        role: "Posterior chain dominant — glute and hamstring focus",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "h5_lb_hip_thrust",
                order: 1,
                exerciseId: ExerciseCatalog.machineHipThrust.id,
                priority: .anchor,
                notes: "Primary glute compound.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_lb_leg_press",
                order: 2,
                exerciseId: ExerciseCatalog.legPress.id,
                priority: .standard,
                notes: "Quad volume — different stimulus from hack squat.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_lb_leg_curl",
                order: 3,
                exerciseId: ExerciseCatalog.seatedLegCurl.id,
                priority: .standard,
                notes: "Seated curl — different hamstring length than lying.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_lb_kickback",
                order: 4,
                exerciseId: ExerciseCatalog.cableGluteKickback.id,
                priority: .standard,
                notes: "Glute isolation — peak contraction focus.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_lb_calves",
                order: 5,
                exerciseId: ExerciseCatalog.seatedCalfRaise.id,
                priority: .standard,
                notes: "Soleus focus.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            )
        ]
    )

    // MARK: - Pump Day (Weak-point and detail work)
    // Stays higher rep across all waves — this day is never a strength day.
    // C wave reduces volume slightly but keeps rep ranges high.

    static let pump = ProgramDayTemplate(
        id: "h5_pump",
        dayNumber: 5,
        title: "Pump",
        role: "Weak-point and detail work — chest, shoulders, arms, glutes",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "h5_pump_fly",
                order: 1,
                exerciseId: ExerciseCatalog.seatedCableFly.id,
                priority: .anchor,
                notes: "Chest pump. Stretch-focused, not load-focused.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_pump_lateral",
                order: 2,
                exerciseId: ExerciseCatalog.singleArmCableLateralRaise.id,
                priority: .standard,
                notes: "Cable lateral — better resistance curve than dumbbells.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_pump_rear_delt",
                order: 3,
                exerciseId: ExerciseCatalog.inclineRearDeltFly.id,
                priority: .standard,
                notes: "Rear delt detail.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_pump_curl",
                order: 4,
                exerciseId: ExerciseCatalog.singleArmCableCurl.id,
                priority: .standard,
                notes: "Cable curl — peak contraction at top.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_pump_tricep",
                order: 5,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .standard,
                notes: "Long head pump.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_pump_hip_thrust",
                order: 6,
                exerciseId: ExerciseCatalog.cableGluteKickback.id,
                priority: .standard,
                notes: "Glute detail — complements the hip thrust on Lower B.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "h5_pump_crunch",
                order: 7,
                exerciseId: ExerciseCatalog.cableRopeCrunch.id,
                priority: .firstCut,
                notes: "Core finisher. Skip if time is short.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip during deload.")
                ],
                setsByWeek: [2, 2, 2, 2, 2, 2, 2, 2, 2, 0]
            )
        ]
    )
}
