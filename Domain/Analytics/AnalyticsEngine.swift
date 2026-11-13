// Domain/Analytics/AnalyticsEngine.swift
import Foundation
import SwiftData

/// The one entry point the screens read analytics through. Everything here is built on the shared definitions:
/// `WorkingSetFilter` (which rows are real work), `E1RMCalculator` (the only e1RM) and `PersonalRecords` (the only PR).
///
/// Two layers:
/// - **Item level** (`ItemStats`, static, no snapshot): one `SessionItem`'s set count, reps, volume and best working-set
///   e1RM. Screens that already walk sessions item by item use this.
/// - **History level** (`AnalyticsEngine` instance): a snapshot of many sessions, for questions that span sessions:
///   records, PR events, volume per exercise.
///
/// Lifetime history (these numbers) counts every completed session, maintenance and deload included. Seeds, fatigue
/// baselines and meso-over-meso comparisons use the regular-training variants in `SetRecord` instead.
struct AnalyticsEngine {

    let snapshot: AnalyticsSnapshot

    init(sessions: [Session], customExercises: [CustomExercise] = [], bodyWeight: Double? = nil) {
        snapshot = SetRecordBuilder.build(sessions: sessions, customExercises: customExercises, bodyWeight: bodyWeight)
    }

    // MARK: - Item level

    struct ItemStats: Equatable {
        /// Hard sets: logged, non-skipped, non-warm-up rows (rest-pause / drop rows count once; bodyweight rows count).
        var sets = 0
        var reps = 0
        /// Sum of effective load x reps over the hard sets (stored lb x reps).
        var volume = 0.0
        /// Best working-set e1RM (Epley on the effective load); 0 when there is none (or a bodyweight lift has no body weight).
        var bestE1RM = 0.0
        /// The set that gave `bestE1RM` (effective load, reps).
        var bestLoad = 0.0
        var bestReps = 0

        /// Stats of one item. `bodyWeight` is the lifter's, for bodyweight lifts.
        static func of(_ item: SessionItem, bodyWeight: Double?, customExercises: [CustomExercise] = []) -> ItemStats {
            let isBodyweight = ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customExercises)
            var out = ItemStats()
            func effective(_ load: Double) -> Double {
                if load > 0 { return load }
                if isBodyweight, let bw = bodyWeight, bw > 0 { return bw }
                return 0
            }
            for row in WorkingSetFilter.hardSetRows(of: item, isBodyweight: isBodyweight) {
                out.sets += 1
                out.reps += row.reps
                out.volume += effective(row.load) * Double(row.reps)
            }
            for row in WorkingSetFilter.workingRows(of: item, isBodyweight: isBodyweight) {
                let load = effective(row.load)
                let e1rm = E1RMCalculator.e1RM(load: load, reps: row.reps)
                if e1rm > out.bestE1RM { out.bestE1RM = e1rm; out.bestLoad = load; out.bestReps = row.reps }
            }
            return out
        }
    }

    // MARK: - History level

    /// The session key the snapshot uses (so a screen can look a `Session` up).
    static func sessionKey(_ s: Session) -> String { s.id?.uuidString ?? "\(s.persistentModelID)" }

    /// Best working-set e1RM per canonical exercise over every completed session in the snapshot.
    var records: [String: PersonalRecords.Best] { PersonalRecords.bests(from: snapshot.sets) }

    /// Exercise ids that set a new record (strictly above every earlier session) IN `session`. A lift's first-ever
    /// session is a baseline, not a record, and is not included.
    func recordExerciseIds(in session: Session) -> Set<String> {
        let key = Self.sessionKey(session)
        return Set(PersonalRecords.events(from: snapshot.sets).filter { $0.sessionKey == key && !$0.isBaseline }.map(\.exerciseId))
    }

    /// Lifetime hard-set volume (effective load x reps, stored lb) per canonical exercise, completed sessions only.
    func volumeByExercise() -> [String: Double] {
        var out: [String: Double] = [:]
        for r in snapshot.sets where r.isLifetimeHardSet { out[r.exerciseId, default: 0] += r.effectiveLoad * Double(r.reps) }
        return out
    }

    /// Records that stand more than `threshold` above the next best session, for the lifter to verify.
    func suspectRecords(threshold: Double = 1.25) -> [PersonalRecords.Suspect] {
        PersonalRecords.suspects(from: snapshot.sets, threshold: threshold)
    }

    // MARK: - Meso

    /// End-of-meso analysis. Meso-over-meso comparisons leave maintenance blocks out of the prior peaks.
    static func mesoAnalysis(meso: MesoBlock, allPriorSessions: [Session], bodyWeight: Double? = nil) -> MesoAnalysis? {
        MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: allPriorSessions, bodyWeight: bodyWeight)
    }
}
