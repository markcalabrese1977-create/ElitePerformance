// Domain/Programs/PPL6DayTemplate.swift
import Foundation

/// 6-day Push/Pull/Legs, run twice through the week (A/B split).
///
/// Structural rationale:
/// - Each muscle group gets exactly 2 weekly exposures, spaced via PPL/PPL/Rest
///   ordering rather than back-to-back, consistent with hypertrophy frequency
///   research showing 2x/week outperforms 1x/week at equal volume.
/// - Primary compound anchors are IDENTICAL across A/B for each day-type, so
///   LoadProjectionService and e1RM tracking have continuous, repeated exposure
///   to progress against — the app's whole progression system depends on
///   tracking the same exercise across sessions, not novel exercises each time.
/// - Accessory/isolation work varies by angle between A/B (not by muscle group),
///   which is the actually-supported rationale for exercise variation —
///   distributing regional mechanical tension and reducing repetitive identical
///   joint-angle loading — distinct from the weaker "muscle confusion" claim.
/// - Weekly volume per muscle group is split evenly across its two sessions
///   rather than front-loaded onto one day.
enum PPL6DayTemplate {

    // MARK: - Week Rules
    // Same 3-week wave cycle + deload structure as the 3-day PPL template.

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
        id: "ppl_6day_v1",
        name: "6-Day Push / Pull / Legs",
        totalWeeks: 10,
        trainingDaysPerWeek: 6,
        weekRules: weekRules,
        dayTemplates: [pushA, pullA, legsA, pushB, pullB, legsB]
    )

    // MARK: - Push A (day 1) — same roster as 3-day PPL Push

    static let pushA = ProgramDayTemplate(
        id: "ppl6_push_a",
        dayNumber: 1,
        title: "Push A",
        role: "Chest, shoulders, triceps",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl6_push_a_bench",
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
                id: "ppl6_push_a_incline_db",
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
                id: "ppl6_push_a_fly",
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
                id: "ppl6_push_a_lateral",
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
                id: "ppl6_push_a_pushdown",
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

    // MARK: - Pull A (day 2) — same roster as 3-day PPL Pull

    static let pullA = ProgramDayTemplate(
        id: "ppl6_pull_a",
        dayNumber: 2,
        title: "Pull A",
        role: "Back, biceps, rear delts",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl6_pull_a_pulldown",
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
                id: "ppl6_pull_a_row",
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
                id: "ppl6_pull_a_db_row",
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
                id: "ppl6_pull_a_rear_delt",
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
                id: "ppl6_pull_a_curl",
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
                id: "ppl6_pull_a_hammer",
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

    // MARK: - Legs A (day 3) — same roster as 3-day PPL Legs

    static let legsA = ProgramDayTemplate(
        id: "ppl6_legs_a",
        dayNumber: 3,
        title: "Legs A",
        role: "Quads, hamstrings, glutes, calves",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl6_legs_a_hack",
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
                id: "ppl6_legs_a_rdl",
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
                id: "ppl6_legs_a_leg_extension",
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
                id: "ppl6_legs_a_leg_curl",
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
                id: "ppl6_legs_a_hip_thrust",
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
                id: "ppl6_legs_a_calves",
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
                id: "ppl6_legs_a_crunch",
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

    // MARK: - Push B (day 4) — same anchor pattern, angle-varied accessories

    static let pushB = ProgramDayTemplate(
        id: "ppl6_push_b",
        dayNumber: 4,
        title: "Push B",
        role: "Chest, shoulders, triceps — angle variation from Push A",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl6_push_b_machine_press",
                order: 1,
                exerciseId: ExerciseCatalog.machineChestPress.id,
                priority: .anchor,
                notes: "Primary chest compound, machine variation. Drive progression here first.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_push_b_decline",
                order: 2,
                exerciseId: ExerciseCatalog.declineBenchPress.id,
                priority: .standard,
                notes: "Lower chest emphasis — opposite angle from Push A's incline work.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_push_b_fly",
                order: 3,
                exerciseId: ExerciseCatalog.dumbbellFly.id,
                priority: .standard,
                notes: "Chest isolation, free-weight variation for stretch overload.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_push_b_lateral",
                order: 4,
                exerciseId: ExerciseCatalog.singleArmCableLateralRaise.id,
                priority: .standard,
                notes: "Shoulder width work, unilateral cable variation for constant tension.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_push_b_overhead_tricep",
                order: 5,
                exerciseId: ExerciseCatalog.overheadRopeTricepExtension.id,
                priority: .standard,
                notes: "Tricep finisher, overhead angle biases the long head.",
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

    // MARK: - Pull B (day 5) — same anchor pattern, angle-varied accessories

    static let pullB = ProgramDayTemplate(
        id: "ppl6_pull_b",
        dayNumber: 5,
        title: "Pull B",
        role: "Back, biceps, rear delts — angle variation from Pull A",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl6_pull_b_pulldown",
                order: 1,
                exerciseId: ExerciseCatalog.pulldownNormalGrip.id,
                priority: .anchor,
                notes: "Primary back compound, narrower grip — biases mid-back differently from Pull A's wide grip.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_pull_b_barbell_row",
                order: 2,
                exerciseId: ExerciseCatalog.barbellRow.id,
                priority: .anchor,
                notes: "Primary horizontal pull, free-weight variation for more total-back loading.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_pull_b_chest_supported_row",
                order: 3,
                exerciseId: ExerciseCatalog.chestSupportedInclineDumbbellRow.id,
                priority: .standard,
                notes: "Chest-supported variation removes lower-back demand, different pull angle from Pull A.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_pull_b_rear_delt",
                order: 4,
                exerciseId: ExerciseCatalog.cableRearDeltFly.id,
                priority: .standard,
                notes: "Rear delt work, cable variation for constant tension through the arc.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 15, repMax: 20, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 15, repMax: 20, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_pull_b_hammer",
                order: 5,
                exerciseId: ExerciseCatalog.cableRopeHammerCurl.id,
                priority: .standard,
                notes: "Brachialis and forearm work, cable variation for constant tension.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_pull_b_preacher",
                order: 6,
                exerciseId: ExerciseCatalog.preacherCurl.id,
                priority: .standard,
                notes: "Bicep isolation, preacher angle isolates the short head and removes momentum.",
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

    // MARK: - Legs B (day 6) — same anchor pattern, angle-varied accessories

    static let legsB = ProgramDayTemplate(
        id: "ppl6_legs_b",
        dayNumber: 6,
        title: "Legs B",
        role: "Quads, hamstrings, glutes, calves — angle variation from Legs A",
        exerciseTemplates: [
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_leg_press",
                order: 1,
                exerciseId: ExerciseCatalog.legPress.id,
                priority: .anchor,
                notes: "Primary quad compound, machine variation — reduced spinal loading vs Legs A's hack squat.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 4, setMax: 4, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 4, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_sumo_deadlift",
                order: 2,
                exerciseId: ExerciseCatalog.sumoDeadlift.id,
                priority: .anchor,
                notes: "Primary hip hinge, wide stance shifts emphasis toward glutes and adductors vs Legs A's RDL.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 6,  repMax: 8,  targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 4, repMin: 4,  repMax: 6,  targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8,  repMax: 10, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 4, 4, 4, 4, 5, 4, 5, 5, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_bulgarian_split_squat",
                order: 3,
                exerciseId: ExerciseCatalog.bulgarianSplitSquat.id,
                priority: .standard,
                notes: "Unilateral quad work, addresses asymmetries that bilateral compounds can mask.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_seated_leg_curl",
                order: 4,
                exerciseId: ExerciseCatalog.seatedLegCurl.id,
                priority: .standard,
                notes: "Hamstring isolation, seated angle biases a different hip/knee position than Legs A's lying curl.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_back_extension",
                order: 5,
                exerciseId: ExerciseCatalog.benchBackExtension.id,
                priority: .standard,
                notes: "Posterior chain / glute-hamstring tie-in, complements the hip-thrust pattern from Legs A.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_calves",
                order: 6,
                exerciseId: ExerciseCatalog.seatedCalfRaise.id,
                priority: .standard,
                notes: "Seated angle biases the soleus differently than Legs A's standing smith machine variation.",
                prescriptions: [
                    .init(wave: .a, setMin: 3, setMax: 4, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 3, setMax: 4, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 3, setMax: 3, repMin: 8,  repMax: 10, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 2, setMax: 2, repMin: 12, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
            ),
            ProgramExerciseTemplate(
                id: "ppl6_legs_b_hanging_knee_raise",
                order: 7,
                exerciseId: ExerciseCatalog.hangingKneeRaise.id,
                priority: .firstCut,
                notes: "Core finisher. Skip if time is short.",
                prescriptions: [
                    .init(wave: .a, setMin: 2, setMax: 3, repMin: 12, repMax: 15, targetRIRMin: 3, targetRIRMax: 3),
                    .init(wave: .b, setMin: 2, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    .init(wave: .c, setMin: 2, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 1, targetRIRMax: 2),
                    .init(wave: .deload, setMin: 0, setMax: 0, repMin: 0, repMax: 0, targetRIRMin: 0, targetRIRMax: 0, intensifier: .customNoteOnly, intensifierNotes: "Skip during deload.")
                ],
                setsByWeek: [2, 2, 2, 2, 2, 2, 2, 2, 2, 0]
            )
        ]
    )
}
