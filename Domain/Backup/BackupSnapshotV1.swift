import Foundation

struct BackupSnapshotV1: Codable {
    let version: Int
    let exportedAt: Date

    let appState: AppStateBackupDTO?
    let userProfile: UserProfileBackupDTO?
    let mesoBlocks: [MesoBlockBackupDTO]
    let sessions: [SessionBackupDTO]
    let sessionHistory: [SessionHistoryBackupDTO]
    let exerciseNotes: [ExerciseNoteBackupDTO]
    let customExercises: [CustomExerciseBackupDTO]

    // Added (backup-completeness fix). Optional so OLD backup files that predate
    // this key still decode: synthesized Codable maps an absent key to nil.
    let user: UserBackupDTO?
}

// MARK: - User

struct UserBackupDTO: Codable {
    let createdAt: Date?
    let unitsRaw: String?
    let coachVoiceRaw: String?
    let progressionEnabled: Bool?
}

// MARK: - UserProfile

struct UserProfileBackupDTO: Codable {
    let profileId: UUID?
    let createdAt: Date?
    let experienceRaw: String?
    let primaryGoalRaw: String?
    let daysPerWeek: Int?
    let sessionLengthMinutes: Int?
    let equipmentProfileRaw: String?
    let injuryFlagRaws: [String]?
    let minLoadIncrement: Double?
    // Q18 cleanup: usesKilograms/unitPreferenceRaw removed from UserProfile.
    // Kept here, still Optional, purely so old backups that have this key
    // still decode without error — BackupSnapshotImporter now ignores the
    // decoded value entirely, and BackupSnapshotExporter always writes nil.
    let unitPreferenceRaw: String?
    let bodyWeight: Double?
}

// MARK: - AppState

struct AppStateBackupDTO: Codable {
    let id: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    let activeMesoStartDate: Date?
    let scheduledNextMesoStartDate: Date?
    let mesoPromptSnoozeUntil: Date?

    let mesoAnchorDate: Date?
    let mesoAnchorDayNumber: Int?

    let appModeRaw: String?
}

// MARK: - MesoBlock

struct MesoBlockBackupDTO: Codable {
    let id: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    let name: String
    let startDate: Date
    let statusRaw: String
    let notes: String?

    // Added (backup-completeness fix). Optional so OLD backups decode with nil.
    let totalWeeks: Int?
    let isMaintenance: Bool?
}

// MARK: - Session

struct SessionBackupDTO: Codable {
    let id: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    let mesoBlockId: UUID?

    let date: Date
    let statusRaw: String
    let completedAt: Date?

    let readinessStars: Int
    // Added (backup-completeness fix). Optional so OLD backups decode with nil.
    let readinessRaw: String?
    let sessionNotes: String?

    let weekInMeso: Int?
    let dayLabel: String?
    let programIndex: Int?

    let hkWorkoutUUID: String?
    let hkWorkoutStart: Date?
    let hkWorkoutEnd: Date?
    let hkDuration: Double
    let hkActiveCalories: Double
    let hkTotalCalories: Double
    let hkAvgHeartRate: Double
    let hkMaxHeartRate: Double

    let hkZone1Seconds: Double
    let hkZone2Seconds: Double
    let hkZone3Seconds: Double
    let hkZone4Seconds: Double
    let hkZone5Seconds: Double

    let hkHeartRateSeriesBPM: [Double]
    let hkHeartRateSeriesStepSeconds: Double

    let hkPostWorkoutHeartRateBPM: [Double]
    let hkPostWorkoutHeartRateStepSeconds: Double

    let items: [SessionItemBackupDTO]
}

// MARK: - SessionItem

struct SessionItemBackupDTO: Codable {
    let id: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    let order: Int
    let exerciseId: String
    // Added (backup-completeness fix). Optional so OLD backups decode with nil.
    let exerciseNameSnapshot: String?

    let targetReps: Int
    let targetSets: Int
    let targetRIR: Int
    let suggestedLoad: Double

    let waveRaw: String?
    let priorityRaw: String?

    let setMin: Int?
    let setMax: Int?

    let repMin: Int?
    let repMax: Int?

    let targetRIRMin: Int?
    let targetRIRMax: Int?

    let intensifierRaw: String?
    let intensifierNotes: String?
    let prescriptionNotes: String?

    let plannedRepsBySet: [Int]
    let plannedLoadsBySet: [Double]
    let plannedRIRsBySet: [Int]

    let actualReps: [Int]
    let actualLoads: [Double]
    let actualRIRs: [Int]
    let usedRestPauseFlags: [Bool]
    let restPausePatternsBySet: [String]
        let dropSetPatternsBySet: [String]
    let setFeedbackBySet: [String]?
        let pumpRatingsBySet: [Int]?

    let isCompleted: Bool
    let isPR: Bool

    let coachNote: String?
    let loadOverrideReasonRaw: String?
    let nextSuggestedLoad: Double?

    let logs: [SetLogBackupDTO]
}

// MARK: - SetLog

struct SetLogBackupDTO: Codable {
    let id: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    let setNumber: Int
    let targetReps: Int
    let targetRIR: Int
    let targetLoad: Double
    let actualReps: Int
    let actualRIR: Int
    let actualLoad: Double
}

// MARK: - SessionHistory

struct SessionHistoryBackupDTO: Codable {
    let date: Date
    let weekIndex: Int
    let title: String
    let subtitle: String
    let totalExercises: Int
    let totalSets: Int
    let totalVolume: Double
    let exercises: [SessionHistoryExerciseBackupDTO]

    // Added: previously dropped on round-trip.
    let mechanicalLoad: Double?
    let sessionId: UUID?
    let dayLabelSnapshot: String?
    let mesoBlockId: UUID?
    let mesoBlockNameSnapshot: String?
}

struct SessionHistoryExerciseBackupDTO: Codable {
    let name: String
    let primaryMuscle: String?
    let sets: Int
    let reps: Int
    let volume: Double
}

// MARK: - ExerciseNote

struct ExerciseNoteBackupDTO: Codable {
    let id: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    let exerciseId: String
    let note: String
}

// MARK: - CustomExercise

struct CustomExerciseBackupDTO: Codable {
    let id: String
    let name: String
    let primaryMuscleRaw: String
    let isCompound: Bool
    let createdAt: Date
    let isBodyweight: Bool?
}
