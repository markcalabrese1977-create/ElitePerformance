// Domain/Analytics/SetRecord.swift
import Foundation
import SwiftData

/// A value-type snapshot of one session, for analytics. Built by `SetRecordBuilder`, the only analytics code that
/// reads `Session`.
struct PrescribedLift: Hashable {
    let exerciseId: String
    /// "a" / "b" / "c", or "" when the item has no letter (and none can be derived).
    let letter: String
    /// Prescribed working sets (`SessionItem.targetSets`; the per-set arrays are padded and not a set count).
    var sets: Int = 0
}

struct SessionRecord: Equatable {
    /// Stable within a run: the session UUID, else its persistent id.
    let key: String
    /// The completion time for a completed session (completion overwrites `Session.date`), else the scheduled day.
    let date: Date
    /// `Session.plannedDate`: nil when unknown. Never moved by completion.
    let plannedDate: Date?
    /// `plannedDate` was recorded at creation (`Session.plannedDateExact`); a backfilled date is not.
    let plannedDateIsExact: Bool
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
    /// The lifts this session prescribes (canonical id + wave letter), whatever its status. Used to tell whether a lift is
    /// still programmed in the rest of a block.
    var prescribedLifts: [PrescribedLift] = []

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
    /// The planned load of this row (`plannedLoadsBySet`, stored lb), nil when absent or 0.
    let plannedLoad: Double?
    /// The row's prescription: rep range and RIR target. A top row reads the top set's own values.
    let repMin: Int?
    let repMax: Int?
    let targetRIRMin: Int?
    let targetRIRMax: Int?
    let targetRIR: Int
    let reps: Int
    /// The load as logged (stored lb); 0 for bodyweight work.
    let load: Double
    /// The load used for e1RM and records: the logged load, or for a bodyweight lift with no logged load the lifter's
    /// body weight (`E1RMCalculator.effectiveLoad`). 0 when there is neither: such a row is reps-only (no e1RM, no PR).
    var effectiveLoad: Double = 0
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
    /// The user edited this item's plan by hand (`SessionItem.planEdited`): its planned loads are theirs, not the engine's.
    let planEdited: Bool
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

    /// Raw Epley e1RM of this row on the effective load, ANY rep count (0 without load and reps). Only for comparing a lift
    /// with itself (stalls, fatigue, meso comparison); every displayed strength number uses `BestSetRule.e1RM`, which explains why.
    var e1RM: Double { E1RMCalculator.e1RM(load: effectiveLoad, reps: reps) }

    /// The e1RM a RECORD may use: only sets of 12 reps or fewer (`BestSetRule`); 0 for a longer set. PRs, records and PR
    /// badges share this definition with the Meso Summary rows.
    var recordE1RM: Double { BestSetRule.e1RM(load: effectiveLoad, reps: reps) }

    /// A working set of any completed session, maintenance and deload included: what records and lifetime history read.
    /// (Seeds, fatigue baselines and meso-over-meso comparisons use `isPerformanceSet`, which leaves those sessions out.)
    var isRecordSet: Bool { isWorkingSet && status == .completed }

    /// A hard set of any completed session (lifetime history). `countsAsHardSet` is the regular-training version.
    var isLifetimeHardSet: Bool { isHardSetRow && status == .completed }

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

        func effective(_ load: Double, isBodyweight: Bool) -> Double {
            if load > 0 { return load }
            if isBodyweight, let bw = bodyWeight, bw > 0 { return bw }
            return 0
        }
        var sessionRecords: [SessionRecord] = []
        var setRecords: [SetRecord] = []

        func letterOf(_ item: SessionItem) -> String? {
            let raw = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return WavePrescriptionGuard.isWaveLetter(raw) ? raw : nil
        }

        for session in sessions {
            // Some items (bodyweight lifts logged before waveRaw was written for them) carry no wave letter although the
            // session is one wave. Such an item takes the session's letter when its other items agree on one, so a lift's
            // letter chain is not broken by a missing tag. A "deload" item is never given a letter.
            var letterCounts: [String: Int] = [:]
            for item in session.items { if let l = letterOf(item) { letterCounts[l, default: 0] += 1 } }
            let sessionLetter: String? = {
                let top = letterCounts.max { $0.value < $1.value }
                guard let top, letterCounts.values.filter({ $0 == top.value }).count == 1 else { return nil }
                return top.key
            }()

            let sessionKey = session.id?.uuidString ?? "\(session.persistentModelID)"
            let mesoKey = session.meso.map { $0.id?.uuidString ?? "\($0.persistentModelID)" } ?? "none"
            let isMaintenance = session.meso?.isMaintenance == true
            let isInserted = session.insertedDeload == true
            let isDeloadWeek = session.isDeloadWeek

            sessionRecords.append(SessionRecord(
                key: sessionKey, date: session.date, plannedDate: session.plannedDate,
                plannedDateIsExact: session.plannedDate != nil && session.plannedDateExact == true, completedAt: session.completedAt,
                status: session.status, weekIndex: session.weekIndex, dayLabel: session.dayLabel,
                mesoKey: mesoKey, mesoName: session.meso?.name,
                isMaintenance: isMaintenance, isInsertedDeload: isInserted, isDeloadWeek: isDeloadWeek,
                readiness: session.readiness, readinessStars: session.readinessStars, hkDuration: session.hkDuration,
                prescribedLifts: session.items.map {
                    PrescribedLift(
                        exerciseId: ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId),
                        letter: letterOf($0) ?? ($0.waveRaw?.lowercased() == "deload" ? "" : (sessionLetter ?? "")),
                        sets: $0.targetSets)
                }
            ))

            for item in session.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let catalog = ExerciseCatalog.all.first { $0.id == canonical } ?? customById[canonical] ?? customById[item.exerciseId]
                let isBodyweight = catalog?.isBodyweight ?? ExerciseCatalog.isBodyweight(exerciseId: canonical)
                let name = catalog?.name
                    ?? item.exerciseNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? canonical

                let rawWave = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let isDeloadWaveItem = rawWave == "deload"
                let letter: String? = letterOf(item) ?? (isDeloadWaveItem ? nil : sessionLetter)

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
                        rowIndex: i, isTop: item.isTopRow(i), plannedReps: at(item.plannedRepsBySet, i),
                        plannedLoad: isBodyweight ? nil : at(item.plannedLoadsBySet, i).flatMap { $0 > 0 ? $0 : nil },
                        repMin: item.isTopRow(i) ? (item.topRepMin ?? item.repMin) : item.repMin,
                        repMax: item.isTopRow(i) ? (item.topRepMax ?? item.repMax) : item.repMax,
                        targetRIRMin: item.isTopRow(i) ? (item.topRIR ?? item.targetRIRMin) : item.targetRIRMin,
                        targetRIRMax: item.isTopRow(i) ? (item.topRIR ?? item.targetRIRMax) : item.targetRIRMax,
                        targetRIR: item.isTopRow(i) ? (item.topRIR ?? item.targetRIR) : item.targetRIR,
                        reps: reps, load: at(item.actualLoads, i) ?? 0,
                        effectiveLoad: effective(at(item.actualLoads, i) ?? 0, isBodyweight: isBodyweight),
                        rir: RIREntry.recorded(item, at: i),
                        isSkipped: skipped,
                        isRestPause: at(item.usedRestPauseFlags, i) == true || (!pattern.isEmpty && !skipped),
                        isDrop: !(at(item.dropSetPatternsBySet, i) ?? "").isEmpty,
                        feedback: SetFeedback(rawValue: at(item.setFeedbackBySet, i) ?? "") ?? .none,
                        pump: at(item.pumpRatingsBySet, i) ?? 0,
                        loadOverride: item.loadOverrideReason, planEdited: item.planEdited,
                        readiness: session.readiness, readinessStars: session.readinessStars, hkDuration: session.hkDuration,
                        isWorkingSet: working.contains(i), isHardSetRow: hard.contains(i)
                    ))
                }
            }
        }
        return AnalyticsSnapshot(sessions: sessionRecords, sets: setRecords)
    }
}
