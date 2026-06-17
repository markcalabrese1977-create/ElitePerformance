import Foundation
import SwiftData

struct BackupSnapshotExportResult {
    let url: URL
    let mesoBlockCount: Int
    let sessionCount: Int
    let sessionHistoryCount: Int
    let exerciseNoteCount: Int
    let customExerciseCount: Int
}

enum BackupSnapshotExporter {
    static func exportFullBackupJSON(modelContext: ModelContext) throws -> BackupSnapshotExportResult {
        let appState = try modelContext.fetch(FetchDescriptor<AppState>()).first

        let mesoBlocks = try modelContext.fetch(
            FetchDescriptor<MesoBlock>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        )

        let sessions = try modelContext.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )

        let sessionHistory = try modelContext.fetch(
            FetchDescriptor<SessionHistory>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )

        let exerciseNotes = try modelContext.fetch(
            FetchDescriptor<ExerciseNote>(sortBy: [SortDescriptor(\.exerciseId, order: .forward)])
        )

        let customExercises = try modelContext.fetch(
            FetchDescriptor<CustomExercise>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )

        let userProfile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first

        let snapshot = BackupSnapshotV1(
            version: 1,
            exportedAt: Date(),
            appState: appState.map {
                AppStateBackupDTO(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    activeMesoStartDate: $0.activeMesoStartDate,
                    scheduledNextMesoStartDate: $0.scheduledNextMesoStartDate,
                    mesoPromptSnoozeUntil: $0.mesoPromptSnoozeUntil,
                    mesoAnchorDate: $0.mesoAnchorDate,
                    mesoAnchorDayNumber: $0.mesoAnchorDayNumber,
                    appModeRaw: $0.appModeRaw
                )
            },
            userProfile: userProfile.map {
                UserProfileBackupDTO(
                    profileId: $0.profileId,
                    createdAt: $0.createdAt,
                    experienceRaw: $0.experienceRaw,
                    primaryGoalRaw: $0.primaryGoalRaw,
                    daysPerWeek: $0.daysPerWeek,
                    sessionLengthMinutes: $0.sessionLengthMinutes,
                    equipmentProfileRaw: $0.equipmentProfileRaw,
                    injuryFlagRaws: $0.injuryFlagRaws,
                    minLoadIncrement: $0.minLoadIncrement,
                    unitPreferenceRaw: $0.unitPreferenceRaw,
                    bodyWeight: $0.bodyWeight
                )
            },
            mesoBlocks: mesoBlocks.map { block in
                MesoBlockBackupDTO(
                    id: block.id,
                    createdAt: block.createdAt,
                    updatedAt: block.updatedAt,
                    name: block.name,
                    startDate: block.startDate,
                    statusRaw: block.status.rawValue,
                    notes: block.notes
                )
            },
            sessions: sessions.map { session in
                SessionBackupDTO(
                    id: session.id,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    mesoBlockId: session.meso?.id,
                    date: session.date,
                    statusRaw: session.status.rawValue,
                    completedAt: session.completedAt,
                    readinessStars: session.readinessStars,
                    sessionNotes: session.sessionNotes,
                    weekInMeso: session.weekInMeso,
                    dayLabel: session.dayLabel, programIndex: session.programIndex,
                    hkWorkoutUUID: session.hkWorkoutUUID,
                    hkWorkoutStart: session.hkWorkoutStart,
                    hkWorkoutEnd: session.hkWorkoutEnd,
                    hkDuration: session.hkDuration,
                    hkActiveCalories: session.hkActiveCalories,
                    hkTotalCalories: session.hkTotalCalories,
                    hkAvgHeartRate: session.hkAvgHeartRate,
                    hkMaxHeartRate: session.hkMaxHeartRate,
                    hkZone1Seconds: session.hkZone1Seconds,
                    hkZone2Seconds: session.hkZone2Seconds,
                    hkZone3Seconds: session.hkZone3Seconds,
                    hkZone4Seconds: session.hkZone4Seconds,
                    hkZone5Seconds: session.hkZone5Seconds,
                    hkHeartRateSeriesBPM: session.hkHeartRateSeriesBPM,
                    hkHeartRateSeriesStepSeconds: session.hkHeartRateSeriesStepSeconds,
                    hkPostWorkoutHeartRateBPM: session.hkPostWorkoutHeartRateBPM,
                    hkPostWorkoutHeartRateStepSeconds: session.hkPostWorkoutHeartRateStepSeconds,
                    items: session.items
                        .sorted { $0.order < $1.order }
                        .map { item in
                            SessionItemBackupDTO(
                                id: item.id,
                                createdAt: item.createdAt,
                                updatedAt: item.updatedAt,
                                order: item.order,
                                exerciseId: item.exerciseId,
                                targetReps: item.targetReps,
                                targetSets: item.targetSets,
                                targetRIR: item.targetRIR,
                                suggestedLoad: item.suggestedLoad,
                                waveRaw: item.waveRaw,
                                priorityRaw: item.priorityRaw,
                                setMin: item.setMin,
                                setMax: item.setMax,
                                repMin: item.repMin,
                                repMax: item.repMax,
                                targetRIRMin: item.targetRIRMin,
                                targetRIRMax: item.targetRIRMax,
                                intensifierRaw: item.intensifierRaw,
                                intensifierNotes: item.intensifierNotes,
                                prescriptionNotes: item.prescriptionNotes,
                                plannedRepsBySet: item.plannedRepsBySet,
                                plannedLoadsBySet: item.plannedLoadsBySet,
                                plannedRIRsBySet: item.plannedRIRsBySet,
                                actualReps: item.actualReps,
                                actualLoads: item.actualLoads,
                                actualRIRs: item.actualRIRs,
                                usedRestPauseFlags: item.usedRestPauseFlags,
                                restPausePatternsBySet: item.restPausePatternsBySet,
                                                                dropSetPatternsBySet: item.dropSetPatternsBySet,
                                                                setFeedbackBySet: item.setFeedbackBySet,
                                                                pumpRatingsBySet: item.pumpRatingsBySet,
                                isCompleted: item.isCompleted,
                                isPR: item.isPR,
                                coachNote: item.coachNote,
                                loadOverrideReasonRaw: item.loadOverrideReasonRaw,
                                nextSuggestedLoad: item.nextSuggestedLoad,
                                logs: item.logs.map { log in
                                    SetLogBackupDTO(
                                        id: log.id,
                                        createdAt: log.createdAt,
                                        updatedAt: log.updatedAt,
                                        setNumber: log.setNumber,
                                        targetReps: log.targetReps,
                                        targetRIR: log.targetRIR,
                                        targetLoad: log.targetLoad,
                                        actualReps: log.actualReps,
                                        actualRIR: log.actualRIR,
                                        actualLoad: log.actualLoad
                                    )
                                }
                            )
                        }
                )
            },
            sessionHistory: sessionHistory.map { history in
                SessionHistoryBackupDTO(
                    date: history.date,
                    weekIndex: history.weekIndex,
                    title: history.title,
                    subtitle: history.subtitle,
                    totalExercises: history.totalExercises,
                    totalSets: history.totalSets,
                    totalVolume: history.totalVolume,
                    exercises: history.exercises.map { exercise in
                        SessionHistoryExerciseBackupDTO(
                            name: exercise.name,
                            primaryMuscle: exercise.primaryMuscle,
                            sets: exercise.sets,
                            reps: exercise.reps,
                            volume: exercise.volume
                        )
                    }
                )
            },
            exerciseNotes: exerciseNotes.map { note in
                ExerciseNoteBackupDTO(
                    id: note.id,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    exerciseId: note.exerciseId,
                    note: note.note
                )
            },
            customExercises: customExercises.map { ex in
                CustomExerciseBackupDTO(
                    id: ex.id,
                    name: ex.name,
                    primaryMuscleRaw: ex.primaryMuscleRaw,
                    isCompound: ex.isCompound,
                    createdAt: ex.createdAt
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(snapshot)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let filename = "ElitePerformance_Backup_v1_\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try data.write(to: url, options: .atomic)

        return BackupSnapshotExportResult(
            url: url,
            mesoBlockCount: mesoBlocks.count,
            sessionCount: sessions.count,
            sessionHistoryCount: sessionHistory.count,
            exerciseNoteCount: exerciseNotes.count,
            customExerciseCount: customExercises.count
        )
    }
}
