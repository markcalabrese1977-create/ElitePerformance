// Domain/Analytics/SetRecord.swift
import Foundation
import SwiftData

/// A value-type snapshot of one session, for analytics. Built by `SetRecordBuilder`, the only analytics code that
/// reads `Session`.
struct SessionRecord: Equatable {
    /// Stable within a run: the session UUID, else its persistent id.
    let key: String
    /// The completion time for a completed session (completion overwrites `Session.date`), else the scheduled day.
    let date: Date
    /// `Session.plannedDate`: nil when unknown. Never moved by completion.
    let plannedDate: Date?
    let completedAt: Date?
    let status: SessionStatus
    let weekIndex: Int
    let dayLabel: String?
    let mesoKey: String
    let mesoName: String?
    let isMaintenance: Bool
    let isInsertedDeload: Bool
    /// `Session.isDeloadWeek` (a deload-wave item, or the deload band of a non-wave block).
    let isDeloadWeek: Bool
    let readiness: SessionReadiness
    let readinessStars: Int
    /// HealthKit workout duration in seconds; 0 when the session has no workout summary.
    let hkDuration: Double

    /// A session whose numbers describe normal training: not a deload, not maintenance.
    var isRegularTraining: Bool { !isDeloadWeek && !isInsertedDeload && !isMaintenance }
}

/// One logged (or skipped) row of one exercise in one session. Loads are stored lb.
struct SetRecord: Equatable {
    let sessionKey: String
    let sessionDate: Date
    let status: SessionStatus
    let weekIndex: Int
    let dayLabel: String?
    let mesoKey: String

    /// Canonical exercise id (legacy aliases resolved).
    let exerciseId: String
    let exerciseName: String
    let muscle: MuscleGroup?
    let isBodyweight: Bool

    /// "a" / "b" / "c" when the item carries a wave letter, else nil. A deload-wave item has no letter.
    let waveLetter: String?
    let isDeloadWaveItem: Bool
    let isInsertedDeload: Bool
    let isDeloadWeek: Bool
    let isMaintenance: Bool

    let rowIndex: Int
    let isTop: Bool
    /// The prescription's reps for this row (`plannedRepsBySet`), nil when the item has no planned entry.
    let plannedReps: Int?
    let reps: Int
    /// The load as logged (stored lb); 0 for bodyweight work.
    let load: Double
    /// nil when the RIR array has no entry for the row. A stored 0 cannot be told from "not recorded".
    let rir: Int?
    let isSkipped: Bool
    let isRestPause: Bool
    let isDrop: Bool
    let feedback: SetFeedback
    /// 0 = not rated.
    let pump: Int
    /// The item's load-override reason (per exercise, not per set).
    let loadOverride: LoadOverrideReason?
    let readiness: SessionReadiness
    let readinessStars: Int
    let hkDuration: Double

    /// Passed `WorkingSetFilter.workingRows` for its item: real evidence for e1RM, PRs and same-load comparisons.
    let isWorkingSet: Bool
    /// Passed `WorkingSetFilter.hardSetRows` for its item (before the deload / maintenance exclusion).
    let isHardSetRow: Bool

    // MARK: Derived

    /// Deload by any of its three marks.
    var isDeloadContext: Bool { isDeloadWeek || isInsertedDeload || isDeloadWaveItem }

    /// Completed, not a deload, not maintenance.
    var isRegularCompleted: Bool { status == .completed && !isDeloadContext && !isMaintenance }

    /// A hard set: a hard-set row of regular completed training.
    var countsAsHardSet: Bool { isHardSetRow && isRegularCompleted }

    /// A working set of regular completed training: the sets e1RM, PRs and chains are built from.
    var isPerformanceSet: Bool { isWorkingSet && isRegularCompleted }

    /// Epley e1RM of this row through `E1RMCalculator` (0 without load and reps).
    var e1RM: Double { E1RMCalculator.e1RM(load: load, reps: reps) }

    /// A set the lifter flagged with fatigue, pain or disruption (soreness is informational and not counted).
    var hasFatigueFlag: Bool { feedback == .fatigue || feedback == .pain || feedback == .disruption }
}

struct AnalyticsSnapshot: Equatable {
    var sessions: [SessionRecord]
    var sets: [SetRecord]
}

/// Builds the snapshot. This is the only analytics code that touches `Session` / `SessionItem`; everything else
/// takes records, so it can be tested without SwiftData.
enum SetRecordBuilder {

    static func build(
        sessions: [Session],
        customExercises: [CustomExercise] = [],
        bodyWeight: Double? = nil
    ) -> AnalyticsSnapshot {
        var customById: [String: CatalogExercise] = [:]
        for c in customExercises { customById[c.id] = c.asCatalogExercise }

        var sessionRecords: [SessionRecord] = []
        var setRecords: [SetRecord] = []

        for session in sessions {
            let sessionKey = session.id?.uuidString ?? "\(session.persistentModelID)"
            let mesoKey = session.meso.map { $0.id?.uuidString ?? "\($0.persistentModelID)" } ?? "none"
            let isMaintenance = session.meso?.isMaintenance == true
            let isInserted = session.insertedDeload == true
            let isDeloadWeek = session.isDeloadWeek

            sessionRecords.append(SessionRecord(
                key: sessionKey, date: session.date, plannedDate: session.plannedDate, completedAt: session.completedAt,
                status: session.status, weekIndex: session.weekIndex, dayLabel: session.dayLabel,
                mesoKey: mesoKey, mesoName: session.meso?.name,
                isMaintenance: isMaintenance, isInsertedDeload: isInserted, isDeloadWeek: isDeloadWeek,
                readiness: session.readiness, readinessStars: session.readinessStars, hkDuration: session.hkDuration
            ))

            for item in session.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let catalog = ExerciseCatalog.all.first { $0.id == canonical } ?? customById[canonical] ?? customById[item.exerciseId]
                let isBodyweight = catalog?.isBodyweight ?? ExerciseCatalog.isBodyweight(exerciseId: canonical)
                let name = catalog?.name
                    ?? item.exerciseNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? canonical

                let rawWave = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let letter: String? = WavePrescriptionGuard.isWaveLetter(rawWave) ? rawWave : nil
                let isDeloadWaveItem = rawWave == "deload"

                let working = Set(WorkingSetFilter.workingRows(of: item, isBodyweight: isBodyweight).map(\.index))
                let hard = Set(WorkingSetFilter.hardSetRows(of: item, isBodyweight: isBodyweight).map(\.index))
                let rowCount = max(item.actualReps.count, item.restPausePatternsBySet.count)

                func at<T>(_ a: [T], _ i: Int) -> T? { a.indices.contains(i) ? a[i] : nil }

                for i in 0..<rowCount {
                    let reps = at(item.actualReps, i) ?? 0
                    let skipped = WorkingSetFilter.isSkipped(item, row: i)
                    guard reps > 0 || skipped else { continue }
                    let pattern = at(item.restPausePatternsBySet, i) ?? ""
                    setRecords.append(SetRecord(
                        sessionKey: sessionKey, sessionDate: session.date, status: session.status,
                        weekIndex: session.weekIndex, dayLabel: session.dayLabel, mesoKey: mesoKey,
                        exerciseId: canonical, exerciseName: name, muscle: catalog?.primaryMuscle, isBodyweight: isBodyweight,
                        waveLetter: letter, isDeloadWaveItem: isDeloadWaveItem,
                        isInsertedDeload: isInserted, isDeloadWeek: isDeloadWeek, isMaintenance: isMaintenance,
                        rowIndex: i, isTop: item.isTopRow(i), plannedReps: at(item.plannedRepsBySet, i), reps: reps, load: at(item.actualLoads, i) ?? 0,
                        rir: at(item.actualRIRs, i),
                        isSkipped: skipped,
                        isRestPause: at(item.usedRestPauseFlags, i) == true || (!pattern.isEmpty && !skipped),
                        isDrop: !(at(item.dropSetPatternsBySet, i) ?? "").isEmpty,
                        feedback: SetFeedback(rawValue: at(item.setFeedbackBySet, i) ?? "") ?? .none,
                        pump: at(item.pumpRatingsBySet, i) ?? 0,
                        loadOverride: item.loadOverrideReason,
                        readiness: session.readiness, readinessStars: session.readinessStars, hkDuration: session.hkDuration,
                        isWorkingSet: working.contains(i), isHardSetRow: hard.contains(i)
                    ))
                }
            }
        }
        return AnalyticsSnapshot(sessions: sessionRecords, sets: setRecords)
    }
}
