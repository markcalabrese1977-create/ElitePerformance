// Domain/Sync/LegsAWaveRestoreMigration.swift
import Foundation
import SwiftData

/// One-shot repair for the flattened "Legs A" weeks in the active 10-week DUP meso.
///
/// What happened: the Program tab's "Apply changes to future sessions" toggle defaulted
/// to ON, so editing week 1's Legs A plan copied that session's whole prescription —
/// `waveRaw` included — onto every other Legs A week. The A/B/C undulation was
/// overwritten with the A-wave numbers: weeks 2-10 all read `waveRaw == "a"`. The
/// propagation itself is now blocked by `WavePrescriptionGuard`; this restores the data.
///
/// Source of truth: the 2026-09-22 backup (`ElitePerformance_Backup_v1_2026-09-22_20-40-51`),
/// read at dev time and embedded below as a static table — the device cannot read that file.
/// The 2026-09-25 backup that would normally be used no longer exists; the user verified
/// externally that for this exact scope (Legs A, weeks 2-10, these five exercises, these
/// 14 fields) the two backups are identical — 45 items, 0 field differences.
///
/// Scope, deliberately narrow:
/// - Active block only, `dayLabel == "Legs A"`, weeks 2-10. Week 1 is completed and is
///   never read or written.
/// - Five exercises, matched by session `weekInMeso` + canonical `exerciseId`.
/// - Two exceptions: `farmer_carry` / `pallof_press` are never restored (farmer_carry was
///   swapped to pallof_press on 09-25, then pallof_press was removed on 09-26 — the slot
///   stays empty), and week 4's Single Leg Press takes 390 rather than its backup load,
///   that being the per-letter carry-forward of the earned bump from the 09-26 session.
///
/// Safety: this is all-or-nothing. Every gate below is checked against live data across
/// every target BEFORE anything is written; a single violation aborts the whole repair
/// and writes nothing. `dryRun` logs the full before/after without saving, and the
/// completion flag is only set after a save actually succeeds, so a failed or dry run
/// is retried on the next launch.
enum LegsAWaveRestoreMigration {

    /// Flip to `false` only after the dry-run log has been reviewed on-device.
    private static let dryRun = true

    private static let completionKey = "legsAWaveRestoreMigration.v1.completed"

    private static let dayLabel = "Legs A"
    private static let weeks = 2...10

    /// Never restored — see the type doc. Their presence means the data has drifted
    /// from what this table was built against, so the repair aborts.
    private static let forbiddenExerciseIds: Set<String> = ["farmer_carry", "pallof_press"]

    /// The exact roster weeks 2-10 must have, canonical ids.
    private static let expectedExerciseIds: Set<String> = [
        "hack_squat",
        "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",   // Single Leg Press
        "leg_extension",
        "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",   // Seated Smith Machine Calf Raise
        "lying_leg_curl"
    ]

    /// The flattened value every targeted item currently carries. If an item reads
    /// anything else the data has moved since this table was built — abort.
    private static let expectedCurrentWaveRaw = "a"

    // MARK: - Week 4 carry-forward exception

    private static let carryForwardWeek = 4
    private static let carryForwardExerciseId = "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef"
    private static let carryForwardLoad: Double = 390.0

    // MARK: - Restore table (embedded from the 2026-09-22 backup)

    private struct Restore {
        let week: Int
        let exerciseId: String
        let waveRaw: String?
        let repMin: Int?
        let repMax: Int?
        let targetReps: Int
        let targetRIR: Int
        let targetRIRMin: Int?
        let targetRIRMax: Int?
        let targetSets: Int
        let setMin: Int?
        let setMax: Int?
        let plannedRepsBySet: [Int]
        let plannedLoadsBySet: [Double]
        let plannedRIRsBySet: [Int]
        let suggestedLoad: Double
    }

    private static let table: [Restore] = [
        Restore(week: 2, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 4, setMax: 4,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [365.0, 365.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 365.0),
        Restore(week: 2, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "b", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [12, 12, 12], plannedLoadsBySet: [337.5, 337.5, 337.5],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 337.5),
        Restore(week: 2, exerciseId: "hack_squat",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 4, setMax: 4,
                plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [317.5, 317.5, 317.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 317.5),
        Restore(week: 2, exerciseId: "leg_extension",
                waveRaw: "b", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 3,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [207.5, 207.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 207.5),
        Restore(week: 2, exerciseId: "lying_leg_curl",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [115.0, 115.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 115.0),
        Restore(week: 3, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 4,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [347.5, 347.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 347.5),
        Restore(week: 3, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "c", repMin: 15, repMax: 20,
                targetReps: 15, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [15, 15, 15], plannedLoadsBySet: [315.0, 315.0, 315.0],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 315.0),
        Restore(week: 3, exerciseId: "hack_squat",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 3, setMax: 4,
                plannedRepsBySet: [12, 12, 12], plannedLoadsBySet: [302.5, 302.5, 302.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 302.5),
        Restore(week: 3, exerciseId: "leg_extension",
                waveRaw: "c", repMin: 15, repMax: 20,
                targetReps: 15, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 3,
                plannedRepsBySet: [15, 15], plannedLoadsBySet: [192.5, 192.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 192.5),
        Restore(week: 3, exerciseId: "lying_leg_curl",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [125.0, 125.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 125.0),
        Restore(week: 4, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "a", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 4, setMax: 4,
                plannedRepsBySet: [8, 8], plannedLoadsBySet: [385.0, 385.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 385.0),
        Restore(week: 4, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "a", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [355.0, 355.0, 355.0],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 355.0),
        Restore(week: 4, exerciseId: "hack_squat",
                waveRaw: "a", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 4, setMax: 4,
                plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [332.5, 332.5, 332.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 332.5),
        Restore(week: 4, exerciseId: "leg_extension",
                waveRaw: "a", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 3,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [217.5, 217.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 217.5),
        Restore(week: 4, exerciseId: "lying_leg_curl",
                waveRaw: "a", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [8, 8], plannedLoadsBySet: [115.0, 115.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 115.0),
        Restore(week: 5, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 4, setMax: 4,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [365.0, 365.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 365.0),
        Restore(week: 5, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "b", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [12, 12, 12], plannedLoadsBySet: [337.5, 337.5, 337.5],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 337.5),
        Restore(week: 5, exerciseId: "hack_squat",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 4, setMax: 4,
                plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [317.5, 317.5, 317.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 317.5),
        Restore(week: 5, exerciseId: "leg_extension",
                waveRaw: "b", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 3,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [207.5, 207.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 207.5),
        Restore(week: 5, exerciseId: "lying_leg_curl",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [115.0, 115.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 115.0),
        Restore(week: 6, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 4,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [347.5, 347.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 347.5),
        Restore(week: 6, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "c", repMin: 15, repMax: 20,
                targetReps: 15, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [15, 15, 15], plannedLoadsBySet: [315.0, 315.0, 315.0],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 315.0),
        Restore(week: 6, exerciseId: "hack_squat",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 3, setMax: 4,
                plannedRepsBySet: [12, 12, 12], plannedLoadsBySet: [302.5, 302.5, 302.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 302.5),
        Restore(week: 6, exerciseId: "leg_extension",
                waveRaw: "c", repMin: 15, repMax: 20,
                targetReps: 15, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 3,
                plannedRepsBySet: [15, 15], plannedLoadsBySet: [192.5, 192.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 192.5),
        Restore(week: 6, exerciseId: "lying_leg_curl",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [125.0, 125.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 125.0),
        Restore(week: 7, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "a", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 4, setMax: 4,
                plannedRepsBySet: [8, 8], plannedLoadsBySet: [385.0, 385.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 385.0),
        Restore(week: 7, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "a", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [355.0, 355.0, 355.0],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 355.0),
        Restore(week: 7, exerciseId: "hack_squat",
                waveRaw: "a", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 4, setMax: 4,
                plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [332.5, 332.5, 332.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 332.5),
        Restore(week: 7, exerciseId: "leg_extension",
                waveRaw: "a", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 3,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [217.5, 217.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 217.5),
        Restore(week: 7, exerciseId: "lying_leg_curl",
                waveRaw: "a", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [8, 8], plannedLoadsBySet: [115.0, 115.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 115.0),
        Restore(week: 8, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 4, setMax: 4,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [365.0, 365.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 365.0),
        Restore(week: 8, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "b", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [12, 12, 12], plannedLoadsBySet: [337.5, 337.5, 337.5],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 337.5),
        Restore(week: 8, exerciseId: "hack_squat",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 4, setMax: 4,
                plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [317.5, 317.5, 317.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 317.5),
        Restore(week: 8, exerciseId: "leg_extension",
                waveRaw: "b", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 3,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [207.5, 207.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 207.5),
        Restore(week: 8, exerciseId: "lying_leg_curl",
                waveRaw: "b", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [115.0, 115.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 115.0),
        Restore(week: 9, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 3, setMax: 4,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [347.5, 347.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 347.5),
        Restore(week: 9, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "c", repMin: 15, repMax: 20,
                targetReps: 15, targetRIR: 1, targetRIRMin: 1, targetRIRMax: 1,
                targetSets: 3, setMin: 3, setMax: 3,
                plannedRepsBySet: [15, 15, 15], plannedLoadsBySet: [315.0, 315.0, 315.0],
                plannedRIRsBySet: [1, 1, 1], suggestedLoad: 315.0),
        Restore(week: 9, exerciseId: "hack_squat",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 3, setMin: 3, setMax: 4,
                plannedRepsBySet: [12, 12, 12], plannedLoadsBySet: [302.5, 302.5, 302.5],
                plannedRIRsBySet: [2, 2, 2], suggestedLoad: 302.5),
        Restore(week: 9, exerciseId: "leg_extension",
                waveRaw: "c", repMin: 15, repMax: 20,
                targetReps: 15, targetRIR: 2, targetRIRMin: 1, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 3,
                plannedRepsBySet: [15, 15], plannedLoadsBySet: [192.5, 192.5],
                plannedRIRsBySet: [2, 2], suggestedLoad: 192.5),
        Restore(week: 9, exerciseId: "lying_leg_curl",
                waveRaw: "c", repMin: 12, repMax: 15,
                targetReps: 12, targetRIR: 2, targetRIRMin: 2, targetRIRMax: 2,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [12, 12], plannedLoadsBySet: [125.0, 125.0],
                plannedRIRsBySet: [2, 2], suggestedLoad: 125.0),
        Restore(week: 10, exerciseId: "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef",
                waveRaw: "deload", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 4, targetRIRMin: 3, targetRIRMax: 4,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [8, 8], plannedLoadsBySet: [365.0, 365.0],
                plannedRIRsBySet: [4, 4], suggestedLoad: 365.0),
        Restore(week: 10, exerciseId: "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822",
                waveRaw: "deload", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 4, targetRIRMin: 3, targetRIRMax: 4,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [312.5, 312.5],
                plannedRIRsBySet: [4, 4], suggestedLoad: 312.5),
        Restore(week: 10, exerciseId: "hack_squat",
                waveRaw: "deload", repMin: 8, repMax: 10,
                targetReps: 8, targetRIR: 4, targetRIRMin: 3, targetRIRMax: 4,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [8, 8], plannedLoadsBySet: [315.0, 315.0],
                plannedRIRsBySet: [4, 4], suggestedLoad: 315.0),
        Restore(week: 10, exerciseId: "leg_extension",
                waveRaw: "deload", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 4, targetRIRMin: 3, targetRIRMax: 4,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [205.0, 205.0],
                plannedRIRsBySet: [4, 4], suggestedLoad: 205.0),
        Restore(week: 10, exerciseId: "lying_leg_curl",
                waveRaw: "deload", repMin: 10, repMax: 12,
                targetReps: 10, targetRIR: 4, targetRIRMin: 3, targetRIRMax: 4,
                targetSets: 2, setMin: 2, setMax: 2,
                plannedRepsBySet: [10, 10], plannedLoadsBySet: [115.0, 115.0],
                plannedRIRsBySet: [4, 4], suggestedLoad: 115.0),    ]

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Legs A wave restore not needed.")
            return
        }

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            print("⚠️ Legs A wave restore: could not fetch meso blocks — aborting, nothing written.")
            return
        }
        guard let active = blocks.first(where: { $0.status == .active }) else {
            print("⚠️ Legs A wave restore: no active block — aborting, nothing written.")
            return
        }

        let targets = active.sessions
            .filter { $0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == dayLabel }
            .filter { weeks.contains($0.weekInMeso ?? -1) }
            .sorted { ($0.weekInMeso ?? 0) < ($1.weekInMeso ?? 0) }

        // MARK: Gates — every one is checked across every target before anything is written

        var violations: [String] = []

        let foundWeeks = Set(targets.compactMap { $0.weekInMeso })
        let missingWeeks = Set(weeks).subtracting(foundWeeks)
        if !missingWeeks.isEmpty {
            violations.append("missing target sessions for week(s) \(missingWeeks.sorted()) in block '\(active.name)'")
        }
        if targets.count != weeks.count {
            violations.append("expected \(weeks.count) '\(dayLabel)' sessions in weeks \(weeks.lowerBound)-\(weeks.upperBound), found \(targets.count)")
        }

        for session in targets {
            let week = session.weekInMeso ?? -1
            let tag = "wk\(week) \(shortDate(session.date))"

            // Gate: planned, with no logged data
            guard isSafeToModify(session) else {
                violations.append("\(tag): not safe to modify (status=\(session.status.rawValue), hasLoggedData=\(hasLoggedData(session)))")
                continue
            }

            let canonical = session.items.map { (item: $0, id: ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId)) }

            // Gate: farmer_carry / pallof_press must be gone
            let forbidden = canonical.filter { forbiddenExerciseIds.contains($0.id) }
            if !forbidden.isEmpty {
                violations.append("\(tag): forbidden exercise(s) present — \(forbidden.map { $0.id }.sorted().joined(separator: ", "))")
            }

            // Gate: exactly the expected roster
            let presentIds = Set(canonical.map { $0.id })
            if presentIds != expectedExerciseIds {
                let missing = expectedExerciseIds.subtracting(presentIds)
                let extra = presentIds.subtracting(expectedExerciseIds)
                var detail: [String] = []
                if !missing.isEmpty { detail.append("missing \(missing.sorted())") }
                if !extra.isEmpty { detail.append("unexpected \(extra.sorted())") }
                violations.append("\(tag): roster mismatch — \(detail.joined(separator: "; "))")
            }

            for entry in canonical where expectedExerciseIds.contains(entry.id) {
                // Gate: current waveRaw is the flattened "a"
                let current = entry.item.waveRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if current != expectedCurrentWaveRaw {
                    violations.append("\(tag) \(entry.id): waveRaw is '\(entry.item.waveRaw ?? "nil")', expected '\(expectedCurrentWaveRaw)' — data has drifted")
                }
                // Gate: untouched by hand
                if entry.item.planEdited {
                    violations.append("\(tag) \(entry.id): planEdited is true — manual edit would be clobbered")
                }
                // Gate: the table covers it
                if restore(week: week, exerciseId: entry.id) == nil {
                    violations.append("\(tag) \(entry.id): no row in the restore table")
                }
            }
        }

        guard violations.isEmpty else {
            print("""
            ⛔️ Legs A wave restore ABORTED — nothing written. \(violations.count) gate violation(s):
            \(violations.map { "   • " + $0 }.joined(separator: "\n"))
            """)
            return
        }

        // MARK: Write (or, under dryRun, describe)

        var log: [String] = []
        var itemsTouched = 0
        var fieldsChanged = 0
        var exceptionsApplied = 0

        for session in targets {
            let week = session.weekInMeso ?? -1
            log.append("── wk\(week)  \(shortDate(session.date))  \(dayLabel)  [gates: planned ✓  planEdited=false ✓  waveRaw=a ✓  items \(session.items.count)/\(expectedExerciseIds.count) ✓]")

            var weekFields = 0
            var weekExceptions = 0

            let ordered = session.items.sorted { $0.order < $1.order }
            for item in ordered {
                let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                guard let spec = restore(week: week, exerciseId: canonicalId) else { continue }

                let isCarryForward = (week == carryForwardWeek && canonicalId == carryForwardExerciseId)
                let targetLoad = isCarryForward ? carryForwardLoad : spec.suggestedLoad
                let targetLoads = isCarryForward
                    ? Array(repeating: carryForwardLoad, count: spec.plannedLoadsBySet.count)
                    : spec.plannedLoadsBySet

                log.append("   \(displayName(for: item, canonicalId: canonicalId))")

                var lines: [String] = []
                func note(_ field: String, _ before: String, _ after: String, exception: Bool = false) {
                    guard before != after else { return }
                    lines.append("     \(pad(field, 18)) \(pad(before, 22)) →  \(after)\(exception ? "   [carry-forward exception]" : "")")
                    weekFields += 1
                    if exception { weekExceptions += 1 }
                }

                note("waveRaw", item.waveRaw ?? "nil", spec.waveRaw ?? "nil")
                note("repMin/repMax", "\(opt(item.repMin))/\(opt(item.repMax))", "\(opt(spec.repMin))/\(opt(spec.repMax))")
                note("targetReps", "\(item.targetReps)", "\(spec.targetReps)")
                note("targetRIR", "\(item.targetRIR)", "\(spec.targetRIR)")
                note("targetRIRMin/Max", "\(opt(item.targetRIRMin))/\(opt(item.targetRIRMax))", "\(opt(spec.targetRIRMin))/\(opt(spec.targetRIRMax))")
                note("targetSets", "\(item.targetSets)", "\(spec.targetSets)")
                note("setMin/setMax", "\(opt(item.setMin))/\(opt(item.setMax))", "\(opt(spec.setMin))/\(opt(spec.setMax))")
                note("plannedRepsBySet", "\(item.plannedRepsBySet)", "\(spec.plannedRepsBySet)")
                note("plannedLoadsBySet", "\(item.plannedLoadsBySet)", "\(targetLoads)", exception: isCarryForward)
                note("plannedRIRsBySet", "\(item.plannedRIRsBySet)", "\(spec.plannedRIRsBySet)")
                note("suggestedLoad", "\(item.suggestedLoad)", "\(targetLoad)", exception: isCarryForward)

                if lines.isEmpty {
                    log.append("     (already matches — no change)")
                } else {
                    log.append(contentsOf: lines)
                }

                if !dryRun {
                    item.waveRaw = spec.waveRaw
                    item.repMin = spec.repMin
                    item.repMax = spec.repMax
                    item.targetReps = spec.targetReps
                    item.targetRIR = spec.targetRIR
                    item.targetRIRMin = spec.targetRIRMin
                    item.targetRIRMax = spec.targetRIRMax
                    item.targetSets = spec.targetSets
                    item.setMin = spec.setMin
                    item.setMax = spec.setMax
                    item.plannedRepsBySet = spec.plannedRepsBySet
                    item.plannedLoadsBySet = targetLoads
                    item.plannedRIRsBySet = spec.plannedRIRsBySet
                    item.suggestedLoad = targetLoad
                }

                itemsTouched += 1
            }

            for forbiddenId in forbiddenExerciseIds.sorted() {
                log.append("   \(forbiddenId)  — SKIPPED (stays removed)")
            }

            log.append("── wk\(week) totals: \(ordered.count) items, \(weekFields) fields changed, \(weekExceptions) by exception")
            fieldsChanged += weekFields
            exceptionsApplied += weekExceptions
        }

        let banner = dryRun ? "DRY RUN — nothing written" : "LIVE — writing"
        let summary = """

        ══ Legs A wave restore · \(banner) ══
        block: \(active.name)   scope: \(dayLabel) weeks \(weeks.lowerBound)-\(weeks.upperBound)   source: 2026-09-22 backup
        \(log.joined(separator: "\n"))
        ══ TOTALS: \(targets.count) sessions, \(itemsTouched) items, \(fieldsChanged) fields, \(exceptionsApplied) exception writes ══
        """

        guard !dryRun else {
            print(summary)
            print("ℹ️ Legs A wave restore: dry run only — no save, completion flag NOT set.")
            return
        }

        do {
            try context.save()
            print(summary)
            print("✅ Legs A wave restore complete.")
        } catch {
            print(summary)
            print("⚠️ Legs A wave restore save failed: \(error). Nothing persisted; will retry next launch.")
            return  // do not mark complete
        }

        UserDefaults.standard.set(true, forKey: completionKey)
    }

    // MARK: - Helpers

    private static func restore(week: Int, exerciseId: String) -> Restore? {
        table.first { $0.week == week && $0.exerciseId == exerciseId }
    }

    private static func isSafeToModify(_ session: Session) -> Bool {
        guard session.status == .planned else { return false }
        return !hasLoggedData(session)
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains { item in
            item.isCompleted ||
            item.actualLoads.contains { $0 > 0 } ||
            item.actualReps.contains { $0 > 0 }
        }
    }

    private static func displayName(for item: SessionItem, canonicalId: String) -> String {
        if let snapshot = item.exerciseNameSnapshot, !snapshot.isEmpty {
            return "\(canonicalId)  \(snapshot)"
        }
        return canonicalId
    }

    private static func opt<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    /// Right-pads to `width` for column alignment. Unlike `padding(toLength:)`, a
    /// string longer than `width` is returned whole rather than truncated — these
    /// columns carry per-set arrays, and a truncated one would misreport the data.
    private static func pad(_ string: String, _ width: Int) -> String {
        guard string.count < width else { return string }
        return string + String(repeating: " ", count: width - string.count)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
