// Domain/Programs/UpperLower4DayTemplate.swift
import Foundation

enum UpperLower4DayTemplate {

    // MARK: - Week Rules
    // A/B/C wave rotation across 9 hard weeks + deload
    // Wave A: moderate load, moderate volume — repeatable baseline
    // Wave B: volume peak — higher reps, pump focus
    // Wave C: intensity peak — heavier loading, lower reps
    // Week 10: deload

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
        id: "upper_lower_4day_v1",
        name: "4-Day Upper / Lower",
        totalWeeks: 10,
        trainingDaysPerWeek: 4,
        weekRules: weekRules,
        dayTemplates: [upperA, lowerA, upperB, lowerB]
    )

    // MARK: - Upper A

    static let upperA = ProgramDayTemplate(
        id: "ul_upper_a",
        dayNumber: 1,
        title: "Upper A",
        role: "Horizontal push and pull — strength focus",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ul_ua_bench",
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
                id: "ul_ua_row",
                order: 2,
                exerciseId: ExerciseCatalog.seatedCableRow.id,
                priority: .anchor,
                notes: "Primary horizontal pull. Match push volume.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ul_ua_incline_db",
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
                id: "ul_ua_pulldown",
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
                id: "ul_ua_tricep",
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
                id: "ul_ua_curl",
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

    // MARK: - Lower A

    static let lowerA = ProgramDayTemplate(
        id: "ul_lower_a",
        dayNumber: 2,
        title: "Lower A",
        role: "Quad dominant — squat pattern primary",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ul_la_hack",
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
                id: "ul_la_rdl",
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
                id: "ul_la_leg_extension",
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
                id: "ul_la_leg_curl",
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
                id: "ul_la_calves",
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

    // MARK: - Upper B

    static let upperB = ProgramDayTemplate(
        id: "ul_upper_b",
        dayNumber: 3,
        title: "Upper B",
        role: "Shoulder and detail upper — pump focus",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ul_ub_shoulder_press",
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
                id: "ul_ub_db_row",
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
                id: "ul_ub_fly",
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
                id: "ul_ub_lateral",
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
                id: "ul_ub_rear_delt",
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
                id: "ul_ub_curl",
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
                id: "ul_ub_oh_tricep",
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

    // MARK: - Lower B

    static let lowerB = ProgramDayTemplate(
        id: "ul_lower_b",
        dayNumber: 4,
        title: "Lower B",
        role: "Posterior chain dominant — glute and hamstring focus",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ul_lb_hip_thrust",
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
                id: "ul_lb_leg_press",
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
                id: "ul_lb_leg_curl",
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
                id: "ul_lb_kickback",
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
                id: "ul_lb_calves",
                order: 5,
                exerciseId: ExerciseCatalog.seatedCalfRaise.id,
                priority: .standard,
                notes: "Soleus focus — different from standing calf work.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 15, repMax: 20, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ul_lb_crunch",
                order: 6,
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
