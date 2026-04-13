import Foundation

enum DUP10WeekTemplate {
    static let weekRules: [ProgramWeekRule] = [
        .init(weekNumber: 1, wave: .a, notes: nil),
        .init(weekNumber: 2, wave: .b, notes: nil),
        .init(weekNumber: 3, wave: .c, notes: nil),
        .init(weekNumber: 4, wave: .a, notes: nil),
        .init(weekNumber: 5, wave: .b, notes: nil),
        .init(weekNumber: 6, wave: .c, notes: nil),
        .init(weekNumber: 7, wave: .a, notes: nil),
        .init(weekNumber: 8, wave: .b, notes: nil),
        .init(weekNumber: 9, wave: .c, notes: nil),
        .init(weekNumber: 10, wave: .deload, notes: "Same exercise menu, 2 sets per exercise, 3–4 RIR, no intensifiers")
    ]

    static let template = ProgramTemplate(
        id: "dup_10_week_v1",
        name: "10-Week DUP Meso",
        totalWeeks: 10,
        trainingDaysPerWeek: 6,
        weekRules: weekRules,
        dayTemplates: [
            d1,
            d2,
            d3,
            d4,
            d5,
            d6
        ]
    )

    // MARK: - D1

    static let d1 = ProgramDayTemplate(
        id: "d1",
        dayNumber: 1,
        title: "Chest + Triceps",
        role: "Main press performance day",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "d1_bench",
                order: 1,
                exerciseId: ExerciseCatalog.benchPress.id,
                priority: .anchor,
                notes: "Bench remains the true anchor here. No special bench techniques.",
                prescriptions: [
                    .init(wave: .a, setMin: 4, setMax: 4, repMin: 4, repMax: 6, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 6, repMax: 8, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 6, repMax: 8, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d1_incline_db",
                order: 2,
                exerciseId: ExerciseCatalog.inclineDumbbellPress.id,
                priority: .standard,
                notes: "Incline stays shortened-ROM and shoulder-aware.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 6, repMax: 8, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d1_fly",
                order: 3,
                exerciseId: ExerciseCatalog.seatedCableFly.id,
                priority: .standard,
                notes: "C-week intensifier is fly only.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(
                        wave: .c,
                        setMin: 3,
                        setMax: 3,
                        repMin: 12,
                        repMax: 15,
                        targetRIRMin: 1,
                        targetRIRMax: 1,
                        intensifier: .dropSetLast,
                        intensifierNotes: "Drop set on final set only."
                    ),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d1_pushdown",
                order: 4,
                exerciseId: ExerciseCatalog.cableTricepRopePushdown.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d1_oh_rope",
                order: 5,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            )
        ]
    )

    // MARK: - D2

    static let d2 = ProgramDayTemplate(
        id: "d2",
        dayNumber: 2,
        title: "Back + Biceps",
        role: "Main back performance day",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "d2_wide_pulldown",
                order: 1,
                exerciseId: ExerciseCatalog.wideGripPulldown.id,
                priority: .anchor,
                notes: "Main back progression day.",
                prescriptions: [
                    .init(wave: .a, setMin: 4, setMax: 4, repMin: 5, repMax: 7, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d2_cable_row",
                order: 2,
                exerciseId: ExerciseCatalog.seatedCableRow.id,
                priority: .anchor,
                notes: "C-week intensifier is row only.",
                prescriptions: [
                    .init(wave: .a, setMin: 4, setMax: 4, repMin: 6, repMax: 8, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(
                        wave: .c,
                        setMin: 3,
                        setMax: 4,
                        repMin: 10,
                        repMax: 12,
                        targetRIRMin: 1,
                        targetRIRMax: 2,
                        intensifier: .restPauseLast,
                        intensifierNotes: "Rest-pause on final set only."
                    ),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d2_db_row",
                order: 3,
                exerciseId: ExerciseCatalog.dumbbellRowSingleArm.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d2_sup_pron",
                order: 4,
                exerciseId: ExerciseCatalog.supinationPronationCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d2_hammer",
                order: 5,
                exerciseId: ExerciseCatalog.hammerCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            )
        ]
    )

    // MARK: - D3

    static let d3 = ProgramDayTemplate(
        id: "d3",
        dayNumber: 3,
        title: "Legs",
        role: "Main quad day with controlled ham support",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "d3_hack",
                order: 1,
                exerciseId: ExerciseCatalog.hackSquat.id,
                priority: .anchor,
                notes: "D3 stays controlled. No hero leg programming.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 5, repMax: 7, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d3_leg_press",
                order: 2,
                exerciseId: ExerciseCatalog.legPress.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d3_leg_extension",
                order: 3,
                exerciseId: ExerciseCatalog.legExtension.id,
                priority: .anchor,
                notes: "Extension remains the cleaner closer. C-week intensifier is extension only.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(
                        wave: .c,
                        setMin: 3,
                        setMax: 3,
                        repMin: 12,
                        repMax: 20,
                        targetRIRMin: 1,
                        targetRIRMax: 1,
                        intensifier: .dropSetLast,
                        intensifierNotes: "Drop set on final set only."
                    ),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d3_leg_curl",
                order: 4,
                exerciseId: ExerciseCatalog.lyingLegCurl.id,
                priority: .standard,
                notes: "Use seated curl equivalent if needed.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d3_calf",
                order: 5,
                exerciseId: ExerciseCatalog.legPressCalfRaise.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d3_kickback",
                order: 6,
                exerciseId: ExerciseCatalog.cableGluteKickback.id,
                priority: .optional,
                notes: "Optional. Skip in C week unless clearly fresh.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip unless clearly fresh."),
                    .init(wave: .deload, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip during deload.")
                ]
            )
        ]
    )

    // MARK: - D4

    static let d4 = ProgramDayTemplate(
        id: "d4",
        dayNumber: 4,
        title: "Chest + Biceps + Triceps",
        role: "Hypertrophy-biased upper accessory day",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "d4_cable_press",
                order: 1,
                exerciseId: ExerciseCatalog.seatedCablePress.id,
                priority: .standard,
                notes: "Not a second heavy chest day.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d4_fly",
                order: 2,
                exerciseId: ExerciseCatalog.seatedCableFly.id,
                priority: .anchor,
                notes: "Upper hypertrophy accumulation. C-week intensifier is fly only.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(
                        wave: .c,
                        setMin: 3,
                        setMax: 4,
                        repMin: 12,
                        repMax: 15,
                        targetRIRMin: 1,
                        targetRIRMax: 1,
                        intensifier: .dropSetLast,
                        intensifierNotes: "Drop set on final set only."
                    ),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d4_cable_curl",
                order: 3,
                exerciseId: ExerciseCatalog.singleArmCableCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d4_hammer",
                order: 4,
                exerciseId: ExerciseCatalog.hammerCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d4_pushdown",
                order: 5,
                exerciseId: ExerciseCatalog.cableTricepRopePushdown.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d4_oh_rope",
                order: 6,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .firstCut,
                notes: "Optional / first cut if arms are already fried.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 0, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1, intensifier: .customNoteOnly, intensifierNotes: "Skip or do 2 light sets only."),
                    .init(wave: .deload, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip during deload.")
                ]
            )
        ]
    )

    // MARK: - D5

    static let d5 = ProgramDayTemplate(
        id: "d5",
        dayNumber: 5,
        title: "Posterior Chain + Core",
        role: "Glute/ham anchor day",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "d5_hip_thrust",
                order: 1,
                exerciseId: ExerciseCatalog.machineHipThrust.id,
                priority: .anchor,
                notes: "Hard, but not another leg war.",
                prescriptions: [
                    .init(wave: .a, setMin: 4, setMax: 4, repMin: 6, repMax: 8, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2, intensifier: .squeezePauseLast, intensifierNotes: "Use a 1-second squeeze."),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d5_leg_curl",
                order: 2,
                exerciseId: ExerciseCatalog.seatedLegCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d5_pull_through",
                order: 3,
                exerciseId: ExerciseCatalog.cablePullThrough.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d5_rope_crunch",
                order: 4,
                exerciseId: ExerciseCatalog.cableRopeCrunch.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d5_knee_raise",
                order: 5,
                exerciseId: ExerciseCatalog.hangingKneeRaise.id,
                priority: .firstCut,
                notes: "Skip if smoked.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 0, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 1, intensifier: .customNoteOnly, intensifierNotes: "Do or skip depending on fatigue."),
                    .init(wave: .deload, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip during deload.")
                ]
            )
        ]
    )

    // MARK: - D6

    static let d6 = ProgramDayTemplate(
        id: "d6",
        dayNumber: 6,
        title: "Back + Shoulders + Biceps + Triceps",
        role: "Upper accumulation day",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "d6_normal_pulldown",
                order: 1,
                exerciseId: ExerciseCatalog.pulldownNormalGrip.id,
                priority: .anchor,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 6, repMax: 8, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d6_arnold",
                order: 2,
                exerciseId: ExerciseCatalog.arnoldPress.id,
                priority: .standard,
                notes: "Shoulder work gets higher-rep bias as the wave rises.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d6_lateral",
                order: 3,
                exerciseId: ExerciseCatalog.singleArmCableLateralRaise.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d6_sup_pron",
                order: 4,
                exerciseId: ExerciseCatalog.supinationPronationCurl.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d6_oh_rope",
                order: 5,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 4)
                ]
            ),
            ProgramExerciseTemplate(
                id: "d6_rear_delt",
                order: 6,
                exerciseId: ExerciseCatalog.inclineRearDeltFly.id,
                priority: .firstCut,
                notes: "No automatic intensifier here. Rear delt work is expendable if fatigue is high.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 1, targetRIRMax: 1),
                    .init(wave: .deload, setMin: 0, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 4, intensifier: .customNoteOnly, intensifierNotes: "Optional during deload.")
                ]
            )
        ]
    )
}
