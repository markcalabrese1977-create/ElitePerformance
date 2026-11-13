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
    static func importFullBackupJSON(from url: URL, modelContainer: ModelContainer) throws -> BackupSnapshotImportResult {
        let modelContext = ModelContext(modelContainer)
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(BackupSnapshotV1.self, from: data)

        try clearExistingBackupManagedData(in: modelContext)

        // MARK: - UserProfile
        if let dto = snapshot.userProfile {
            let profile = UserProfile(
                id: dto.profileId ?? UUID(),
                createdAt: dto.createdAt ?? Date(),
                experience: TrainingExperience(rawValue: dto.experienceRaw ?? "") ?? .intermediate,
                primaryGoal: PrimaryGoal(rawValue: dto.primaryGoalRaw ?? "") ?? .hypertrophy,
                daysPerWeek: dto.daysPerWeek ?? 4,
                sessionLengthMinutes: dto.sessionLengthMinutes ?? 60,
                equipmentProfile: EquipmentProfile(rawValue: dto.equipmentProfileRaw ?? "") ?? .commercial,
                injuryFlags: (dto.injuryFlagRaws ?? []).compactMap { InjuryFlag(rawValue: $0) },
                minLoadIncrement: dto.minLoadIncrement ?? 2.5,
                // Q18 cleanup: usesKilograms removed — dto.unitPreferenceRaw
                // is decoded (for old backups that still have it) and
                // intentionally dropped here, never written anywhere.
                // The load unit is restored from dto.unitRaw below.
                bodyWeight: dto.bodyWeight
            )
            // Fixed-load exemptions. An old backup without the key decodes to nil and
            // restores to the default (empty), so assign explicitly.
            profile.exemptExerciseIds = dto.exemptExerciseIds ?? UserProfile.defaultExemptExerciseIds
            // Per-exercise max loads. nil (an old backup, or no caps ever set) stays nil.
            profile.maxLoadByExerciseStored = dto.maxLoadByExercise
            profile.muscleSetRangesStored = dto.muscleSetRanges
            profile.birthDateOverride = dto.birthDateOverride
            profile.equipmentPresetRaw = dto.equipmentPresetRaw
            profile.equipmentChecklistRaws = dto.equipmentChecklistRaws
            // nil (old backup, or a lb lifter) stays nil = lb.
            profile.unitRaw = dto.unitRaw
            profile.savedIncrementLb = dto.savedIncrementLb
            profile.savedIncrementKg = dto.savedIncrementKg
            profile.roundOfferPending = dto.roundOfferPending
            modelContext.insert(profile)
        }

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
                warmupHidden: dto.warmupHidden
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
                notes: dto.notes,
                // Restored from backup. Old backups predate these keys → dto values
                // are nil: totalWeeks stays nil (the model's own default), and
                // isMaintenance falls back to false (the model's default).
                totalWeeks: dto.totalWeeks,
                isMaintenance: dto.isMaintenance ?? false
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
                dayLabel: sessionDTO.dayLabel, items: [],
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

            // Restored from backup. Session has no readiness init param, so set it
            // directly. Old backups predate this key → nil falls back to "normal"
            // (the model's own default for readinessRaw).
            session.readinessRaw = sessionDTO.readinessRaw ?? "normal"
            // Old backups predate this key → nil (not an inserted deload).
            session.insertedDeload = sessionDTO.insertedDeload
            // Old backups predate this key → nil (unknown planned day). Overrides the init default (= date).
            session.plannedDate = sessionDTO.plannedDate
            session.plannedDateExact = sessionDTO.plannedDateExact

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
                    exerciseNameSnapshot: itemDTO.exerciseNameSnapshot,
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
                    nextSuggestedLoad: itemDTO.nextSuggestedLoad,
                    loadOverrideReasonRaw: itemDTO.loadOverrideReasonRaw
                )
                // SessionItem's init has no planEdited param; set it directly.
                // Old backups predate the key → nil falls back to false (the
                // model default), keeping restored auto plans bump-eligible.
                item.planEdited = itemDTO.planEdited ?? false
                // Top-set fields: absent in old backups -> nil -> an ordinary item.
                item.setRolesBySet = itemDTO.setRolesBySet
                item.topRepMin = itemDTO.topRepMin
                item.topRepMax = itemDTO.topRepMax
                item.topRIR = itemDTO.topRIR
                // nil for a backup from before the key existed (the init default would invent a value).
                item.prescribedSets = itemDTO.prescribedSets

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
                sessionId: historyDTO.sessionId,
                dayLabelSnapshot: historyDTO.dayLabelSnapshot,
                mechanicalLoad: historyDTO.mechanicalLoad,
                mesoBlockId: historyDTO.mesoBlockId,
                mesoBlockNameSnapshot: historyDTO.mesoBlockNameSnapshot,
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
                createdAt: dto.createdAt,
                isBodyweight: dto.isBodyweight ?? false
            )
            modelContext.insert(custom)
        }

        // MARK: - User
        // User is deliberately NOT part of the wipe-first step
        // (clearExistingBackupManagedData does not delete User). We overwrite it
        // in place only when the backup actually carries a user record. Old
        // backups (missing the `user` key → dto == nil) leave the existing or
        // default User untouched, so we never blank out progressionEnabled/units.
        if let userDTO = snapshot.user {
            let existingUser = try modelContext.fetch(FetchDescriptor<User>()).first
            let targetUser: User
            if let existingUser {
                targetUser = existingUser
            } else {
                targetUser = User(units: .lb, progressionEnabled: true)
                modelContext.insert(targetUser)
            }
            if let createdAt = userDTO.createdAt { targetUser.createdAt = createdAt }
            if let unitsRaw = userDTO.unitsRaw { targetUser.unitsRaw = unitsRaw }
            if let coachVoiceRaw = userDTO.coachVoiceRaw { targetUser.coachVoiceRaw = coachVoiceRaw }
            if let progressionEnabled = userDTO.progressionEnabled { targetUser.progressionEnabled = progressionEnabled }
        }

        try modelContext.save()

        // PRIndex is derived from the sessions just restored (it is not in the backup): replace whatever was
        // there instead of keeping a stale index or starting empty.
        try PRRebuildService.rebuild(in: modelContext)

        if let restoredAppState = try modelContext.fetch(FetchDescriptor<AppState>()).first {
            AppStateBridge.syncToUserDefaults(from: restoredAppState)
        }

        // The App Group mechanicalLoad.* day totals are a projection of SessionHistory, which was just restored:
        // rebuild them (this also clears totals left behind by the data that was replaced).
        MechanicalLoadProjector.projectAll(in: modelContext)

        // Rebuild the UserDefaults mirror of the custom exercises from the restored rows so
        // ExerciseCatalog.all can resolve their names (and isBodyweight) without a ModelContext.
        // Always rewritten, an empty list included: a backup with no customs must clear a stale mirror.
        ExerciseCatalog.rebuildCustomMirror(from: modelContext)

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
        let userProfiles = try modelContext.fetch(FetchDescriptor<UserProfile>())

        for object in appStates { modelContext.delete(object) }
        for object in notes { modelContext.delete(object) }
        for object in histories { modelContext.delete(object) }
        for object in sessions { modelContext.delete(object) }
        for object in mesoBlocks { modelContext.delete(object) }
        for object in customExercises { modelContext.delete(object) }
        for object in userProfiles { modelContext.delete(object) }

        try modelContext.save()
    }
}
