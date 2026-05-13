import Foundation
import SwiftData

struct BackupSnapshotImportResult {
    let mesoBlockCount: Int
    let sessionCount: Int
    let sessionHistoryCount: Int
    let exerciseNoteCount: Int
    let customExerciseCount: Int
}

enum BackupSnapshotImporter {
    static func importFullBackupJSON(from url: URL, modelContext: ModelContext) throws -> BackupSnapshotImportResult {
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(BackupSnapshotV1.self, from: data)

        try clearExistingBackupManagedData(in: modelContext)

        // MARK: - AppState
        if let dto = snapshot.appState {
            let appState = AppState(
                id: dto.id,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                activeMesoStartDate: dto.activeMesoStartDate,
                scheduledNextMesoStartDate: dto.scheduledNextMesoStartDate,
                mesoPromptSnoozeUntil: dto.mesoPromptSnoozeUntil,
                mesoAnchorDate: dto.mesoAnchorDate,
                mesoAnchorDayNumber: dto.mesoAnchorDayNumber,
                appModeRaw: dto.appModeRaw
            )
            modelContext.insert(appState)
        }

        // MARK: - MesoBlocks
        var mesoById: [UUID: MesoBlock] = [:]

        for dto in snapshot.mesoBlocks {
            let status = MesoStatus(rawValue: dto.statusRaw) ?? .draft

            let block = MesoBlock(
                id: dto.id,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                name: dto.name,
                startDate: dto.startDate,
                status: status,
                notes: dto.notes
            )

            modelContext.insert(block)

            if let id = dto.id {
                mesoById[id] = block
            }
        }

        // MARK: - Sessions + Items + SetLogs
        for sessionDTO in snapshot.sessions {
            let status = SessionStatus(rawValue: sessionDTO.statusRaw) ?? .planned

            let session = Session(
                id: sessionDTO.id,
                createdAt: sessionDTO.createdAt,
                updatedAt: sessionDTO.updatedAt,
                date: sessionDTO.date,
                status: status,
                readinessStars: sessionDTO.readinessStars,
                sessionNotes: sessionDTO.sessionNotes,
                weekIndex: sessionDTO.weekInMeso ?? 1,
                items: [],
                completedAt: sessionDTO.completedAt,
                programIndex: sessionDTO.programIndex,
                hkWorkoutUUID: sessionDTO.hkWorkoutUUID,
                hkWorkoutStart: sessionDTO.hkWorkoutStart,
                hkWorkoutEnd: sessionDTO.hkWorkoutEnd,
                hkDuration: sessionDTO.hkDuration,
                hkActiveCalories: sessionDTO.hkActiveCalories,
                hkTotalCalories: sessionDTO.hkTotalCalories,
                hkAvgHeartRate: sessionDTO.hkAvgHeartRate,
                hkMaxHeartRate: sessionDTO.hkMaxHeartRate,
                hkZone1Seconds: sessionDTO.hkZone1Seconds,
                hkZone2Seconds: sessionDTO.hkZone2Seconds,
                hkZone3Seconds: sessionDTO.hkZone3Seconds,
                hkZone4Seconds: sessionDTO.hkZone4Seconds,
                hkZone5Seconds: sessionDTO.hkZone5Seconds,
                hkHeartRateSeriesBPM: sessionDTO.hkHeartRateSeriesBPM,
                hkHeartRateSeriesStepSeconds: sessionDTO.hkHeartRateSeriesStepSeconds,
                hkPostWorkoutHeartRateBPM: sessionDTO.hkPostWorkoutHeartRateBPM,
                hkPostWorkoutHeartRateStepSeconds: sessionDTO.hkPostWorkoutHeartRateStepSeconds
            )

            if let mesoBlockId = sessionDTO.mesoBlockId,
               let meso = mesoById[mesoBlockId] {
                session.meso = meso
                meso.sessions.append(session)
            }

            modelContext.insert(session)

            for itemDTO in sessionDTO.items.sorted(by: { $0.order < $1.order }) {
                let logs: [SetLog] = itemDTO.logs.map { logDTO in
                    let log = SetLog(
                        id: logDTO.id,
                        createdAt: logDTO.createdAt,
                        updatedAt: logDTO.updatedAt,
                        setNumber: logDTO.setNumber,
                        targetReps: logDTO.targetReps,
                        targetRIR: logDTO.targetRIR,
                        targetLoad: logDTO.targetLoad,
                        actualReps: logDTO.actualReps,
                        actualRIR: logDTO.actualRIR,
                        actualLoad: logDTO.actualLoad
                    )
                    modelContext.insert(log)
                    return log
                }

                let item = SessionItem(
                    id: itemDTO.id,
                    createdAt: itemDTO.createdAt,
                    updatedAt: itemDTO.updatedAt,
                    order: itemDTO.order,
                    exerciseId: itemDTO.exerciseId,
                    targetReps: itemDTO.targetReps,
                    targetSets: itemDTO.targetSets,
                    targetRIR: itemDTO.targetRIR,
                    suggestedLoad: itemDTO.suggestedLoad,
                    waveRaw: itemDTO.waveRaw,
                    priorityRaw: itemDTO.priorityRaw,
                    setMin: itemDTO.setMin,
                    setMax: itemDTO.setMax,
                    repMin: itemDTO.repMin,
                    repMax: itemDTO.repMax,
                    targetRIRMin: itemDTO.targetRIRMin,
                    targetRIRMax: itemDTO.targetRIRMax,
                    intensifierRaw: itemDTO.intensifierRaw,
                    intensifierNotes: itemDTO.intensifierNotes,
                    prescriptionNotes: itemDTO.prescriptionNotes,
                    plannedRepsBySet: itemDTO.plannedRepsBySet,
                    plannedLoadsBySet: itemDTO.plannedLoadsBySet,
                    plannedRIRsBySet: itemDTO.plannedRIRsBySet,
                    logs: logs,
                    actualReps: itemDTO.actualReps,
                    actualLoads: itemDTO.actualLoads,
                    actualRIRs: itemDTO.actualRIRs,
                    usedRestPauseFlags: itemDTO.usedRestPauseFlags,
                    restPausePatternsBySet: itemDTO.restPausePatternsBySet,
                                        dropSetPatternsBySet: itemDTO.dropSetPatternsBySet,
                    setFeedbackBySet: itemDTO.setFeedbackBySet ?? [],
                                        pumpRatingsBySet: itemDTO.pumpRatingsBySet ?? [],
                    isCompleted: itemDTO.isCompleted,
                    isPR: itemDTO.isPR,
                    coachNote: itemDTO.coachNote,
                    nextSuggestedLoad: itemDTO.nextSuggestedLoad
                )

                modelContext.insert(item)
                session.items.append(item)
            }
        }

        // MARK: - SessionHistory
        for historyDTO in snapshot.sessionHistory {
            let exercises: [SessionHistoryExercise] = historyDTO.exercises.map { exDTO in
                let ex = SessionHistoryExercise(
                    name: exDTO.name,
                    primaryMuscle: exDTO.primaryMuscle,
                    sets: exDTO.sets,
                    reps: exDTO.reps,
                    volume: exDTO.volume
                )
                modelContext.insert(ex)
                return ex
            }

            let history = SessionHistory(
                date: historyDTO.date,
                weekIndex: historyDTO.weekIndex,
                title: historyDTO.title,
                subtitle: historyDTO.subtitle,
                totalExercises: historyDTO.totalExercises,
                totalSets: historyDTO.totalSets,
                totalVolume: historyDTO.totalVolume,
                mesoBlockId: nil,
                mesoBlockNameSnapshot: nil,
                exercises: exercises
            )

            modelContext.insert(history)
        }

        // MARK: - ExerciseNote
        for noteDTO in snapshot.exerciseNotes {
            let note = ExerciseNote(
                id: noteDTO.id,
                createdAt: noteDTO.createdAt,
                updatedAt: noteDTO.updatedAt,
                exerciseId: noteDTO.exerciseId,
                note: noteDTO.note
            )
            modelContext.insert(note)
        }

        // MARK: - CustomExercises
        for dto in snapshot.customExercises ?? [] {
            let custom = CustomExercise(
                id: dto.id,
                name: dto.name,
                primaryMuscleRaw: dto.primaryMuscleRaw,
                isCompound: dto.isCompound,
                createdAt: dto.createdAt
            )
            modelContext.insert(custom)
        }

        try modelContext.save()

        if let restoredAppState = try modelContext.fetch(FetchDescriptor<AppState>()).first {
            AppStateBridge.syncToUserDefaults(from: restoredAppState)
        }

        return BackupSnapshotImportResult(
            mesoBlockCount: snapshot.mesoBlocks.count,
            sessionCount: snapshot.sessions.count,
            sessionHistoryCount: snapshot.sessionHistory.count,
            exerciseNoteCount: snapshot.exerciseNotes.count,
            customExerciseCount: snapshot.customExercises.count
        )
    }

    private static func clearExistingBackupManagedData(in modelContext: ModelContext) throws {
        let appStates = try modelContext.fetch(FetchDescriptor<AppState>())
        let notes = try modelContext.fetch(FetchDescriptor<ExerciseNote>())
        let histories = try modelContext.fetch(FetchDescriptor<SessionHistory>())
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let mesoBlocks = try modelContext.fetch(FetchDescriptor<MesoBlock>())
        let customExercises = try modelContext.fetch(FetchDescriptor<CustomExercise>())

        for object in appStates { modelContext.delete(object) }
        for object in notes { modelContext.delete(object) }
        for object in histories { modelContext.delete(object) }
        for object in sessions { modelContext.delete(object) }
        for object in mesoBlocks { modelContext.delete(object) }
        for object in customExercises { modelContext.delete(object) }

        try modelContext.save()
    }
}
