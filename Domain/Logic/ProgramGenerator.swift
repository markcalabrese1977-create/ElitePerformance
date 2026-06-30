// Domain/Logic/ProgramGenerator.swift
import Foundation
import SwiftData

/// Retained for load anchoring only.
/// seedInitialProgram() has been replaced by DUPProgramSeeder + catalog templates.
enum ProgramGenerator {

    /// Seed suggested loads for all sessions in a newly created meso block by
    /// reading e1RM directly from prior session history (decay-weighted).
    ///
    /// This is a one-time, read-from-history anchoring operation, not an
    /// ongoing carry-forward/progression decision, so it deliberately does
    /// NOT route through LoadProjectionService.project(). That function's
    /// deload guard (added for PlanMemoryEngine's carry-forward, to stop
    /// maintenance items from being progressively overloaded) would
    /// otherwise unconditionally return nil here too: every maintenance item
    /// is seeded with waveRaw == "deload", so every call would be silently
    /// defeated, leaving suggestedLoad at 0 regardless of how much real
    /// history exists. The guard is correct for its intended caller; this
    /// caller just shouldn't have been going through it.
    ///
    /// Mirrors MaintenanceProgramSeeder.anchorLoadsFromFullHistory's
    /// direct-history approach, used by the sibling Path-B seeding flow.
    static func anchorLoadsForNewMeso(mesoBlock: MesoBlock, context: ModelContext) {
        let profileDescriptor = FetchDescriptor<UserProfile>()
        let profile = try? context.fetch(profileDescriptor).first
        let loadIncrement: Double = profile?.minLoadIncrement ?? 2.5
        let bodyWeight = profile?.bodyWeight

        let allSessionsDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        guard let allSessions = try? context.fetch(allSessionsDescriptor) else { return }

        let mesoSessionIDs = Set(mesoBlock.sessions.map { $0.persistentModelID })
        // Excludes maintenance-block sessions from the anchoring pool — they're
        // deliberately lighter (RIR 3-4, higher reps) and shouldn't drag the
        // decay-weighted average down. Does NOT exclude a regular meso's own deload
        // week — that's a separate, deferred issue (see roadmap).
        let historicalSessions = allSessions.filter {
            !mesoSessionIDs.contains($0.persistentModelID) && $0.meso?.isMaintenance != true
        }

        for session in mesoBlock.sessions.sorted(by: { $0.date < $1.date }) {
            for item in session.items {
                guard item.suggestedLoad == 0 else { continue }

                let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                let candidates = historicalSessions.compactMap { s -> (e1rm: Double, date: Date)? in
                    guard let match = s.items.first(where: {
                        ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
                    }) else { return nil }

                    let setCount = min(match.actualLoads.count, match.actualReps.count)
                    guard setCount > 0 else { return nil }

                    var bestE1RM = 0.0
                    for idx in 0..<setCount {
                        let reps = match.actualReps[idx]
                        guard reps > 0 else { continue }
                        let load = E1RMCalculator.effectiveLoad(
                            actualLoad: match.actualLoads[idx],
                            exerciseId: match.exerciseId,
                            bodyWeight: bodyWeight
                        )
                        guard load > 0 else { continue }
                        let e1rm = E1RMCalculator.e1RM(load: load, reps: reps)
                        bestE1RM = max(bestE1RM, e1rm)
                    }
                    guard bestE1RM > 0 else { return nil }
                    return (e1rm: bestE1RM, date: s.date)
                }

                guard !candidates.isEmpty else { continue }

                let decayWeighted = E1RMCalculator.decayWeightedE1RM(
                    from: candidates.map { ($0.e1rm, $0.date) }
                )
                guard decayWeighted > 0 else { continue }

                let rawLoad = E1RMCalculator.load(for: decayWeighted, reps: item.targetReps, targetRIR: item.targetRIR)
                let anchored = E1RMCalculator.rounded(rawLoad, increment: loadIncrement)
                guard anchored > 0 else { continue }

                item.suggestedLoad = anchored
                item.plannedLoadsBySet = Array(
                    repeating: anchored,
                    count: max(item.plannedLoadsBySet.count, item.targetSets)
                )
            }
        }

        try? context.save()
    }
}
