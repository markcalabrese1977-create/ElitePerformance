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
    /// Load derived from same-wave progression (no e1RM floor available or same-wave won).
    case sameWaveProgression
    /// No usable history — load cannot be projected.
    case noHistory
}

struct LoadProjection {
    let suggestedLoad: Double
    let basis: LoadProjectionBasis
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
/// 3. Same-wave progression — last same-wave session + increment if reps earned it
/// 4. No history — returns nil
///
/// The higher of (1 or 2) vs (3) wins. Same-wave progression is never undercut by e1RM.
enum LoadProjectionService {

    /// Project the next suggested load for a given exercise.
    ///
    /// - Parameters:
    ///   - exerciseId: The exercise to project load for.
    ///   - targetReps: The target rep count for the next session.
    ///   - targetRIR: The target RIR for the next session.
    ///   - repMin: Minimum of the prescribed rep range.
    ///   - repMax: Maximum of the prescribed rep range.
    ///   - currentWaveRaw: The wave type of the next session (for same-wave matching).
    ///   - allSessions: All sessions, sorted chronologically.
    ///   - activeMesoSessionIDs: Persistent IDs of sessions in the current meso.
    ///   - loadIncrement: Preferred load increment (from UserProfile). Defaults to 2.5.
    ///   - referenceDate: Date for decay calculation. Defaults to today.
    /// - Returns: A `LoadProjection` with the suggested load and its basis, or nil if no history.
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

                // Override reason — adjust how this session contributes to e1RM
                if let reason = item.loadOverrideReason {
                    switch reason {
                    case .jointTenderness, .generalFatigue:
                        // Session was compromised — exclude entirely
                        return nil
                    case .equipmentConstraint, .deliberateDeload:
                        // Load was artificially low — use suggested load as capacity proxy
                        guard item.suggestedLoad > 0 else { return nil }
                        let proxyReps = item.targetReps > 0 ? item.targetReps : 8
                        let proxyE1RM = E1RMCalculator.e1RM(load: item.suggestedLoad, reps: proxyReps)
                        guard proxyE1RM > 0 else { return nil }
                        return (e1rm: proxyE1RM, date: s.date, sessionID: s.persistentModelID)
                    }
                }

                // Normal path — RIR-weighted e1RM from actuals
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

        guard !allCandidates.isEmpty else {
            return nil
        }

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

        // Best e1RM = higher of current meso peak or cross-meso baseline
        let bestE1RM = max(currentMesoPeakE1RM, crossMesoE1RM)
        let e1rmBasis: LoadProjectionBasis = currentMesoPeakE1RM >= crossMesoE1RM
            ? .currentMesoPeak(e1rm: currentMesoPeakE1RM)
            : .crossMesoBaseline(e1rm: crossMesoE1RM)

        // Translate best e1RM to target wave's load
        let e1rmFloorLoad: Double = {
            guard bestE1RM > 0 else { return 0 }
            let raw = E1RMCalculator.load(for: bestE1RM, reps: effectiveTargetReps, targetRIR: targetRIR)
            return E1RMCalculator.rounded(raw, increment: loadIncrement)
        }()

        // MARK: - Same-wave progression

        let sameWaveLoad: Double = {
            // Find most recent session with actual work for this exercise, same wave preferred
            let sessionsWithWork = allSessions
                .filter { Calendar.current.startOfDay(for: $0.date) < today }
                .filter { s in
                    s.items.contains { item in
                        ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonicalId &&
                        (item.actualLoads.contains { $0 > 0 } || item.actualReps.contains { $0 > 0 })
                    }
                }

            // Pass 1 — same wave
            let lastSameWave = currentWaveRaw.flatMap { wave -> Session? in
                let w = wave.lowercased()
                return sessionsWithWork.last { s in
                    s.items.first?.waveRaw?.lowercased() == w
                }
            }

            // Pass 2 — any session
            let lastAny = sessionsWithWork.last

            guard let lastSession = lastSameWave ?? lastAny,
                  let lastItem = lastSession.items.first(where: {
                      ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
                  }) else { return 0 }

            let setCount = max(1, lastItem.targetSets)
            let lastLoad: Double = {
                let actuals = Array(lastItem.actualLoads.prefix(setCount)).filter { $0 > 0 }
                if let first = actuals.first { return first }
                let planned = Array(lastItem.plannedLoadsBySet.prefix(setCount)).filter { $0 > 0 }
                return planned.first ?? lastItem.suggestedLoad
            }()
            guard lastLoad > 0 else { return 0 }

            // Gather reps
            var repsBySet: [Int] = []
            for idx in 0..<setCount {
                let actual = idx < lastItem.actualReps.count ? lastItem.actualReps[idx] : 0
                if actual > 0 { repsBySet.append(actual); continue }
                let planned = idx < lastItem.plannedRepsBySet.count ? lastItem.plannedRepsBySet[idx] : 0
                if planned > 0 { repsBySet.append(planned); continue }
                repsBySet.append(lastItem.targetReps)
            }

            let prescribedMax = lastItem.repMax ?? repMax
            let prescribedMin = lastItem.repMin ?? repMin
            let earnedWeight = repsBySet.allSatisfy { $0 >= prescribedMax }
            let missesCount = repsBySet.filter { $0 < (prescribedMin - 1) }.count
            let tooMuchFatigue = missesCount >= 2

            if tooMuchFatigue {
                return (lastLoad * 0.95 / loadIncrement).rounded() * loadIncrement
            }
            if earnedWeight {
                return ((lastLoad + loadIncrement) / loadIncrement).rounded() * loadIncrement
            }
            return (lastLoad / loadIncrement).rounded() * loadIncrement
        }()

        // MARK: - Final decision

        // Use whichever is higher — e1RM floor or same-wave progression
        // Same-wave progression is never undercut by the e1RM floor
        if e1rmFloorLoad > 0 && e1rmFloorLoad >= sameWaveLoad {
            return LoadProjection(suggestedLoad: e1rmFloorLoad, basis: e1rmBasis)
        }

        if sameWaveLoad > 0 {
            return LoadProjection(suggestedLoad: sameWaveLoad, basis: .sameWaveProgression)
        }

        return nil
    }

    // MARK: - Active Meso Helper

    /// Fetch the set of session persistent IDs belonging to the active meso block.
    static func activeMesoSessionIDs(from context: ModelContext) -> Set<PersistentIdentifier> {
        let descriptor = FetchDescriptor<MesoBlock>()
        let blocks = (try? context.fetch(descriptor)) ?? []
        let active = blocks.first { $0.status == .active }
        return Set(active?.sessions.map { $0.persistentModelID } ?? [])
    }
}

