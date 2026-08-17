// Domain/Programs/PPL3WeekTemplate.swift
import Foundation

enum PPL3WeekTemplate {

    // MARK: - Week Rules
    // 9 hard weeks in 3-week linear wave cycles + 1 deload
    // Wave 1 (weeks 1,4,7): volume accumulation — higher reps, RIR 3
    // Wave 2 (weeks 2,5,8): moderate intensity — mid reps, RIR 2
    // Wave 3 (weeks 3,6,9): peak intensity — lower reps, RIR 1
    // Week 10: deload

    static let weekRules: [ProgramWeekRule] = [
        .init(weekNumber: 1,  wave: .a,      notes: "Volume accumulation — establish baseline"),
        .init(weekNumber: 2,  wave: .b,      notes: "Moderate intensity — build on week 1"),
        .init(weekNumber: 3,  wave: .c,      notes: "Peak intensity — push performance"),
        .init(weekNumber: 4,  wave: .a,      notes: "Volume accumulation — second cycle"),
        .init(weekNumber: 5,  wave: .b,      notes: nil),
        .init(weekNumber: 6,  wave: .c,      notes: nil),
        .init(weekNumber: 7,  wave: .a,      notes: "Volume accumulation — third cycle"),
        .init(weekNumber: 8,  wave: .b,      notes: nil),
        .init(weekNumber: 9,  wave: .c,      notes: "Peak intensity — meso high point"),
        .init(weekNumber: 10, wave: .deload, notes: "Deload — systemic recovery")
    ]

    static let template = ProgramTemplate(
        id: "ppl_3day_v1",
        name: "3-Day Push / Pull / Legs",
        totalWeeks: 10,
        trainingDaysPerWeek: 3,
        weekRules: weekRules,
        dayTemplates: [push, pull, legs]
    )

    // MARK: - Push Day

    static let push = ProgramDayTemplate(
        id: "ppl_push",
        dayNumber: 1,
        title: "Push",
        role: "Chest, shoulders, triceps",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl_push_bench",
                order: 1,
                exerciseId: ExerciseCatalog.benchPress.id,
                priority: .anchor,
                notes: "Primary chest compound. Drive progression here first.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_push_incline_db",
                order: 2,
                exerciseId: ExerciseCatalog.inclineDumbbellPress.id,
                priority: .standard,
                notes: "Upper chest emphasis. Keep shoulder-friendly range.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_push_fly",
                order: 3,
                exerciseId: ExerciseCatalog.seatedCableFly.id,
                priority: .standard,
                notes: "Chest isolation. Prioritize stretch and contraction over load.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_push_lateral",
                order: 4,
                exerciseId: ExerciseCatalog.dumbbellLateralRaise.id,
                priority: .standard,
                notes: "Shoulder width work. Light and controlled.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_push_pushdown",
                order: 5,
                exerciseId: ExerciseCatalog.cableTricepRopePushdown.id,
                priority: .standard,
                notes: "Tricep finisher.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            )
        ]
    )

    // MARK: - Pull Day

    static let pull = ProgramDayTemplate(
        id: "ppl_pull",
        dayNumber: 2,
        title: "Pull",
        role: "Back, biceps, rear delts",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl_pull_pulldown",
                order: 1,
                exerciseId: ExerciseCatalog.wideGripPulldown.id,
                priority: .anchor,
                notes: "Primary back compound. Drive vertical pull progression here.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_pull_row",
                order: 2,
                exerciseId: ExerciseCatalog.seatedCableRow.id,
                priority: .anchor,
                notes: "Primary horizontal pull. Focus on scapular retraction.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_pull_db_row",
                order: 3,
                exerciseId: ExerciseCatalog.dumbbellRowSingleArm.id,
                priority: .standard,
                notes: "Unilateral row for balance and detail.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_pull_rear_delt",
                order: 4,
                exerciseId: ExerciseCatalog.inclineRearDeltFly.id,
                priority: .standard,
                notes: "Rear delt and upper back health work.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_pull_curl",
                order: 5,
                exerciseId: ExerciseCatalog.ezBarCurl.id,
                priority: .standard,
                notes: "Bicep isolation.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_pull_hammer",
                order: 6,
                exerciseId: ExerciseCatalog.hammerCurl.id,
                priority: .standard,
                notes: "Brachialis and forearm work.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            )
        ]
    )

    // MARK: - Legs Day

    static let legs = ProgramDayTemplate(
        id: "ppl_legs",
        dayNumber: 3,
        title: "Legs",
        role: "Quads, hamstrings, glutes, calves",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl_legs_hack",
                order: 1,
                exerciseId: ExerciseCatalog.hackSquat.id,
                priority: .anchor,
                notes: "Primary quad compound. Drive progression here.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_legs_rdl",
                order: 2,
                exerciseId: ExerciseCatalog.romanianDeadlift.id,
                priority: .anchor,
                notes: "Primary hip hinge. Hamstring and glute focus.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_legs_leg_extension",
                order: 3,
                exerciseId: ExerciseCatalog.legExtension.id,
                priority: .standard,
                notes: "Quad isolation. Controlled eccentric.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_legs_leg_curl",
                order: 4,
                exerciseId: ExerciseCatalog.lyingLegCurl.id,
                priority: .standard,
                notes: "Hamstring isolation.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_legs_hip_thrust",
                order: 5,
                exerciseId: ExerciseCatalog.machineHipThrust.id,
                priority: .standard,
                notes: "Glute focus. Full hip extension at top.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_legs_calves",
                order: 6,
                exerciseId: ExerciseCatalog.smithMachineCalves.id,
                priority: .standard,
                notes: "Full range calf raise. Pause at stretch.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl_legs_crunch",
                order: 7,
                exerciseId: ExerciseCatalog.cableRopeCrunch.id,
                priority: .firstCut,
                notes: "Core finisher. Skip if time is short.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip during deload.")
                ],
                setsByWeek: [2, 2, 2, 2, 2, 2, 2, 2, 2, 0]
            )
        ]
    )
}

