// Domain/Programs/FullBody2DayTemplate.swift
import Foundation

enum FullBody2DayTemplate {

    // MARK: - Week Rules
    // Linear 3-week wave — same as PPL, appropriate for lower frequency
    // Wave A (weeks 1,4,7): volume accumulation — higher reps, RIR 3
    // Wave B (weeks 2,5,8): moderate intensity — mid reps, RIR 2
    // Wave C (weeks 3,6,9): peak intensity — lower reps, RIR 1
    // Week 10: deload

    static let weekRules: [ProgramWeekRule] = [
        .init(weekNumber: 1,  wave: .a,      notes: "Volume accumulation — establish baseline"),
        .init(weekNumber: 2,  wave: .b,      notes: "Moderate intensity — build on week 1"),
        .init(weekNumber: 3,  wave: .c,      notes: "Peak intensity — push performance"),
        .init(weekNumber: 4,  wave: .a,      notes: "Second cycle — build on previous A wave"),
        .init(weekNumber: 5,  wave: .b,      notes: nil),
        .init(weekNumber: 6,  wave: .c,      notes: nil),
        .init(weekNumber: 7,  wave: .a,      notes: "Third cycle"),
        .init(weekNumber: 8,  wave: .b,      notes: nil),
        .init(weekNumber: 9,  wave: .c,      notes: "Meso intensity high point"),
        .init(weekNumber: 10, wave: .deload, notes: "Deload — systemic recovery")
    ]

    static let template = ProgramTemplate(
        id: "fullbody_2day_v1",
        name: "2-Day Full Body",
        totalWeeks: 10,
        trainingDaysPerWeek: 2,
        weekRules: weekRules,
        dayTemplates: [dayA, dayB]
    )

    // MARK: - Day A
    // Push-biased full body — horizontal push anchor, vertical pull, quad primary

    static let dayA = ProgramDayTemplate(
        id: "fb2_day_a",
        dayNumber: 1,
        title: "Full Body A",
        role: "Push-biased — horizontal press, vertical pull, quad primary",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "fb2_a_bench",
                order: 1,
                exerciseId: ExerciseCatalog.benchPress.id,
                priority: .anchor,
                notes: "Primary horizontal push. Drive load progression here.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_a_pulldown",
                order: 2,
                exerciseId: ExerciseCatalog.wideGripPulldown.id,
                priority: .anchor,
                notes: "Primary vertical pull. Superset with bench if time is tight.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_a_hack",
                order: 3,
                exerciseId: ExerciseCatalog.hackSquat.id,
                priority: .anchor,
                notes: "Primary quad compound. Controlled — not a max effort day.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_a_rdl",
                order: 4,
                exerciseId: ExerciseCatalog.romanianDeadlift.id,
                priority: .standard,
                notes: "Hip hinge — hamstring and glute. Keep it controlled.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_a_lateral",
                order: 5,
                exerciseId: ExerciseCatalog.dumbbellLateralRaise.id,
                priority: .standard,
                notes: "Shoulder width. Light and controlled.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_a_curl",
                order: 6,
                exerciseId: ExerciseCatalog.ezBarCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_a_tricep",
                order: 7,
                exerciseId: ExerciseCatalog.cableTricepRopePushdown.id,
                priority: .standard,
                notes: nil,
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

    // MARK: - Day B
    // Pull-biased full body — horizontal pull anchor, chest accessory, posterior chain primary

    static let dayB = ProgramDayTemplate(
        id: "fb2_day_b",
        dayNumber: 2,
        title: "Full Body B",
        role: "Pull-biased — horizontal row, chest accessory, posterior chain primary",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "fb2_b_row",
                order: 1,
                exerciseId: ExerciseCatalog.seatedCableRow.id,
                priority: .anchor,
                notes: "Primary horizontal pull. Drive load progression here.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_b_incline",
                order: 2,
                exerciseId: ExerciseCatalog.inclineDumbbellPress.id,
                priority: .anchor,
                notes: "Upper chest — different angle from Day A bench.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_b_hip_thrust",
                order: 3,
                exerciseId: ExerciseCatalog.machineHipThrust.id,
                priority: .anchor,
                notes: "Primary glute compound.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_b_leg_press",
                order: 4,
                exerciseId: ExerciseCatalog.legPress.id,
                priority: .standard,
                notes: "Quad volume — different stimulus from hack squat on Day A.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_b_rear_delt",
                order: 5,
                exerciseId: ExerciseCatalog.inclineRearDeltFly.id,
                priority: .standard,
                notes: "Rear delt and upper back health.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "fb2_b_hammer",
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
            ),
            ProgramExerciseTemplate(
                id: "fb2_b_oh_tricep",
                order: 7,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .standard,
                notes: "Long head tricep — different angle from Day A pushdown.",
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
}
