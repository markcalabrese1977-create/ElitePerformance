// Domain/Logic/ProgramGenerator.swift
import Foundation
import SwiftData

/// Retained for load anchoring only.
/// seedInitialProgram() has been replaced by DUPProgramSeeder + catalog templates.
enum ProgramGenerator {

    /// Seed suggested loads for all sessions in a newly created meso block
    /// using LoadProjectionService against completed sessions from prior mesos.
    static func anchorLoadsForNewMeso(mesoBlock: MesoBlock, context: ModelContext) {
        let profileDescriptor = FetchDescriptor<UserProfile>()
        let profile = try? context.fetch(profileDescriptor).first
        let loadIncrement: Double = profile?.minLoadIncrement ?? 2.5
        let bodyWeight = profile?.bodyWeight

        let allSessionsDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        guard let allSessions = try? context.fetch(allSessionsDescriptor) else { return }

        let activeMesoIDs = Set(mesoBlock.sessions.map { $0.persistentModelID })

        for session in mesoBlock.sessions.sorted(by: { $0.date < $1.date }) {
            for item in session.items {
                guard item.suggestedLoad == 0 else { continue }

                let projection = LoadProjectionService.project(
                    exerciseId: item.exerciseId,
                    targetReps: item.targetReps,
                    targetRIR: item.targetRIR,
                    repMin: item.repMin ?? item.targetReps,
                    repMax: item.repMax ?? item.targetReps,
                    currentWaveRaw: item.waveRaw,
                    allSessions: allSessions,
                    activeMesoSessionIDs: activeMesoIDs,
                    loadIncrement: loadIncrement,
                    bodyWeight: bodyWeight
                )

                guard let projection = projection, projection.suggestedLoad > 0 else { continue }

                let anchored = projection.suggestedLoad
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
