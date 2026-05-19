// Domain/Logic/LoadProjectionService.swift
import Foundation
import SwiftData

// MARK: - Output Types

/// How the suggested load was derived — drives coaching message specificity.
enum LoadProjectionBasis {
    /// Load derived from best RIR-weighted e1RM within the current meso.
    case currentMesoPeak(e1rm: Double)
    /// Load derived from decay-weighted e1RM baseline across prior mesos.
    case crossMesoBaseline(e1rm: Double)
    /// Same-wave progression with consecutive clean sessions confirmed — increase earned.
    case consecutiveCleanProgression(sessions: Int)
    /// Same-wave progression — last session was clean but not yet confirmed over multiple sessions.
    case sameWaveProgression
    /// No usable history — load cannot be projected.
    case noHistory
}

struct LoadProjection {
    let suggestedLoad: Double
    let basis: LoadProjectionBasis
    /// Number of consecutive clean same-wave sessions detected. Used by coaching message.
    let consecutiveCleanCount: Int
}

// MARK: - Service

/// Canonical load projection logic.
///
/// Single source of truth for computing the next suggested load for an exercise.
/// Used by both PlanMemoryEngine (automatic carry-forward) and Auto+ (manual refresh).
///
/// Decision hierarchy:
/// 1. Current meso peak e1RM (RIR-weighted, no decay) — reflects true current capacity
/// 2. Cross-meso decay-weighted e1RM baseline — longer-term context from prior mesos
/// 3. Same-wave progression with consecutive clean session tracking:
///    - 0 clean sessions → hold load
///    - 1 clean session → hold, note that one more earns the increase
///    - 2+ consecutive clean sessions → increase
/// 4. No history — returns nil
///
/// The higher of (1 or 2) vs (3) wins. Same-wave progression is never undercut by e1RM.
enum LoadProjectionService {

    // MARK: - Clean Session Evaluation (public — used by CoachingEngine call sites)

    /// Evaluate whether a single session item represents a clean performance.
    /// Clean = reps ≥ prescribedMin, RIR on target, no fatigue/pain flags,
    /// no compromising load override reason.
    static func isCleanSession(_ item: SessionItem, prescribedMin: Int) -> Bool {
        if let reason = item.loadOverrideReason {
            switch reason {
            case .jointTenderness, .generalFatigue: return false
            case .equipmentConstraint, .deliberateDeload: break
            }
        }

        let hasFatigue = item.setFeedbackBySet.contains {
            $0 == SetFeedback.soreness.rawValue ||
            $0 == SetFeedback.disruption.rawValue ||
            $0 == SetFeedback.pain.rawValue
        }
        if hasFatigue { return false }

        let bestReps = item.actualReps.filter { $0 > 0 }.max() ?? 0
        guard bestReps >= prescribedMin else { return false }

        let validRIRs = item.actualRIRs.enumerated().compactMap { idx, rir -> Int? in
            guard idx < item.actualLoads.count, item.actualLoads[idx] > 0 else { return nil }
            return rir
        }
        if !validRIRs.isEmpty {
            let avgRIR = Double(validRIRs.reduce(0, +)) / Double(validRIRs.count)
            if avgRIR < Double(item.targetRIR) - 0.5 { return false }
        }
        return true
    }

    /// Compute consecutive clean same-wave sessions for an exercise.
    /// Lightweight — used by CoachingEngine at call sites without needing full projection.
    static func consecutiveCleanCount(
        exerciseId: String,
        waveRaw: String?,
        repMin: Int,
        allSessions: [Session],
        referenceDate: Date = Date()
    ) -> Int {
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let today = Calendar.current.startOfDay(for: referenceDate)

        let sessionsWithWork = allSessions
            .filter { Calendar.current.startOfDay(for: $0.date) < today }
            .filter { s in
                s.items.contains { item in
                    ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonicalId &&
                    item.actualLoads.contains { $0 > 0 }
                }
            }

        let sameWaveSessions: [Session] = {
            guard let wave = waveRaw?.lowercased(), !wave.isEmpty else { return sessionsWithWork }
            let filtered = sessionsWithWork.filter { s in
                s.items.first?.waveRaw?.lowercased() == wave
            }
            return filtered.isEmpty ? sessionsWithWork : filtered
        }()

        var count = 0
        for session in sameWaveSessions.suffix(3).reversed() {
            guard let item = session.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            }) else { break }
            if isCleanSession(item, prescribedMin: repMin) {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Full Projection

    static func project(
        exerciseId: String,
        targetReps: Int,
        targetRIR: Int,
        repMin: Int,
        repMax: Int,
        currentWaveRaw: String?,
        allSessions: [Session],
        activeMesoSessionIDs: Set<PersistentIdentifier>,
        loadIncrement: Double = 2.5,
        referenceDate: Date = Date()
    ) -> LoadProjection? {

        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let today = Calendar.current.startOfDay(for: referenceDate)
        let effectiveTargetReps = targetReps > 0 ? targetReps : (repMin + repMax) / 2

        // MARK: - Build RIR-weighted e1RM candidates (exclude today)

        typealias E1RMCandidate = (e1rm: Double, date: Date, sessionID: PersistentIdentifier)

        let allCandidates: [E1RMCandidate] = allSessions
            .filter { Calendar.current.startOfDay(for: $0.date) < today }
            .compactMap { s -> E1RMCandidate? in
                guard let item = s.items.first(where: {
                    ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
                }) else { return nil }

                if let reason = item.loadOverrideReason {
                    switch reason {
                    case .jointTenderness, .generalFatigue:
                        return nil
                    case .equipmentConstraint, .deliberateDeload:
                        guard item.suggestedLoad > 0 else { return nil }
                        let proxyReps = item.targetReps > 0 ? item.targetReps : 8
                        let proxyE1RM = E1RMCalculator.e1RM(load: item.suggestedLoad, reps: proxyReps)
                        guard proxyE1RM > 0 else { return nil }
                        return (e1rm: proxyE1RM, date: s.date, sessionID: s.persistentModelID)
                    }
                }

                let setCount = min(item.actualLoads.count, item.actualReps.count)
                guard setCount > 0 else { return nil }

                let sets: [(load: Double, reps: Int, actualRIR: Int)] = (0..<setCount).compactMap { idx in
                    let load = item.actualLoads[idx]
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { return nil }
                    let rir = idx < item.actualRIRs.count ? item.actualRIRs[idx] : item.targetRIR
                    return (load: load, reps: reps, actualRIR: rir)
                }

                let sessionTargetRIR = item.targetRIR > 0 ? item.targetRIR : 2
                let weightedE1RM = E1RMCalculator.rirWeightedE1RM(from: sets, targetRIR: sessionTargetRIR)
                guard weightedE1RM > 0 else { return nil }
                return (e1rm: weightedE1RM, date: s.date, sessionID: s.persistentModelID)
            }

        guard !allCandidates.isEmpty else { return nil }

        // MARK: - Current meso peak (no decay)

        let currentMesoPeakE1RM: Double = allCandidates
            .filter { activeMesoSessionIDs.contains($0.sessionID) }
            .map { $0.e1rm }
            .max() ?? 0

        // MARK: - Cross-meso decay-weighted baseline

        let crossMesoCandidates = allCandidates
            .filter { !activeMesoSessionIDs.contains($0.sessionID) }
        let crossMesoE1RM = E1RMCalculator.decayWeightedE1RM(
            from: crossMesoCandidates.map { ($0.e1rm, $0.date) },
            referenceDate: referenceDate
        )

        let bestE1RM = max(currentMesoPeakE1RM, crossMesoE1RM)
        let e1rmBasis: LoadProjectionBasis = currentMesoPeakE1RM >= crossMesoE1RM
            ? .currentMesoPeak(e1rm: currentMesoPeakE1RM)
            : .crossMesoBaseline(e1rm: crossMesoE1RM)

        let e1rmFloorLoad: Double = {
            guard bestE1RM > 0 else { return 0 }
            let raw = E1RMCalculator.load(for: bestE1RM, reps: effectiveTargetReps, targetRIR: targetRIR)
            return E1RMCalculator.rounded(raw, increment: loadIncrement)
        }()

        // MARK: - Same-wave sessions with consecutive clean tracking

        let sessionsWithWork = allSessions
            .filter { Calendar.current.startOfDay(for: $0.date) < today }
            .filter { s in
                s.items.contains { item in
                    ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonicalId &&
                    (item.actualLoads.contains { $0 > 0 } || item.actualReps.contains { $0 > 0 })
                }
            }

        let sameWaveSessions: [Session] = {
            guard let wave = currentWaveRaw?.lowercased(), !wave.isEmpty else { return [] }
            return sessionsWithWork.filter { s in
                s.items.first?.waveRaw?.lowercased() == wave
            }
        }()

        let candidateSessions = sameWaveSessions.isEmpty ? sessionsWithWork : sameWaveSessions

        guard let lastSession = candidateSessions.last,
              let lastItem = lastSession.items.first(where: {
                  ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
              }) else {
            if e1rmFloorLoad > 0 {
                return LoadProjection(suggestedLoad: e1rmFloorLoad, basis: e1rmBasis, consecutiveCleanCount: 0)
            }
            return nil
        }

        let setCount = max(1, lastItem.targetSets)
        let lastLoad: Double = {
            let actuals = Array(lastItem.actualLoads.prefix(setCount)).filter { $0 > 0 }
            if let first = actuals.first { return first }
            let planned = Array(lastItem.plannedLoadsBySet.prefix(setCount)).filter { $0 > 0 }
            return planned.first ?? lastItem.suggestedLoad
        }()
        guard lastLoad > 0 else {
            if e1rmFloorLoad > 0 {
                return LoadProjection(suggestedLoad: e1rmFloorLoad, basis: e1rmBasis, consecutiveCleanCount: 0)
            }
            return nil
        }

        let prescribedMin = lastItem.repMin ?? repMin
        let prescribedMax = lastItem.repMax ?? repMax

        // Count consecutive clean sessions using the promoted static method
        let recentSameWave = Array(candidateSessions.suffix(3))
        var consecutiveClean = 0
        for session in recentSameWave.reversed() {
            guard let item = session.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            }) else { break }
            if isCleanSession(item, prescribedMin: prescribedMin) {
                consecutiveClean += 1
            } else {
                break
            }
        }

        // Same-wave load decision based on consecutive clean count
        var repsBySet: [Int] = []
        for idx in 0..<setCount {
            let actual = idx < lastItem.actualReps.count ? lastItem.actualReps[idx] : 0
            if actual > 0 { repsBySet.append(actual); continue }
            let planned = idx < lastItem.plannedRepsBySet.count ? lastItem.plannedRepsBySet[idx] : 0
            if planned > 0 { repsBySet.append(planned); continue }
            repsBySet.append(lastItem.targetReps)
        }

        let missesCount = repsBySet.filter { $0 < (prescribedMin - 1) }.count
        let tooMuchFatigue = missesCount >= 2

        let sameWaveLoad: Double = {
            if tooMuchFatigue {
                return (lastLoad * 0.95 / loadIncrement).rounded() * loadIncrement
            }
            if consecutiveClean >= 2 {
                return ((lastLoad + loadIncrement) / loadIncrement).rounded() * loadIncrement
            }
            return (lastLoad / loadIncrement).rounded() * loadIncrement
        }()

        let sameWaveBasis: LoadProjectionBasis = consecutiveClean >= 2
            ? .consecutiveCleanProgression(sessions: consecutiveClean)
            : .sameWaveProgression

        // MARK: - Final decision

        if e1rmFloorLoad > 0 && e1rmFloorLoad >= sameWaveLoad {
            return LoadProjection(
                suggestedLoad: e1rmFloorLoad,
                basis: e1rmBasis,
                consecutiveCleanCount: consecutiveClean
            )
        }

        if sameWaveLoad > 0 {
            return LoadProjection(
                suggestedLoad: sameWaveLoad,
                basis: sameWaveBasis,
                consecutiveCleanCount: consecutiveClean
            )
        }

        return nil
    }

    // MARK: - Active Meso Helper

    static func activeMesoSessionIDs(from context: ModelContext) -> Set<PersistentIdentifier> {
        let descriptor = FetchDescriptor<MesoBlock>()
        let blocks = (try? context.fetch(descriptor)) ?? []
        let active = blocks.first { $0.status == .active }
        return Set(active?.sessions.map { $0.persistentModelID } ?? [])
    }
}
