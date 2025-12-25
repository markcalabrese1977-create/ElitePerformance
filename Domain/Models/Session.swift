import Foundation
import SwiftData

// MARK: - Session Status

enum SessionStatus: String, Codable, CaseIterable {
    case planned
    case inProgress
    case completed
}

// MARK: - Session

@Model
final class Session {
    var date: Date
    var status: SessionStatus
    var completedAt: Date?

    /// 0 = not set yet, 1–5 = readiness rating for this session.
    var readinessStars: Int

    /// Optional text recap / notes for this session (end-of-workout recap writes here).
    var sessionNotes: String?

    /// ✅ STORED property (keep this name to match the existing on-device SwiftData store)
    var weekInMeso: Int

    /// ✅ Alias used throughout the app (does NOT change the stored schema)
    var weekIndex: Int {
        get { weekInMeso }
        set { weekInMeso = newValue }
    }

    /// Exercises for this session.
    @Relationship(deleteRule: .cascade) var items: [SessionItem]

    // MARK: - HealthKit / Apple Workout Summary (stored on Session)

    /// Linked HealthKit workout UUID (string form). Used as our “already synced” flag.
    var hkWorkoutUUID: String?

    var hkWorkoutStart: Date?
    var hkWorkoutEnd: Date?

    /// Workout duration in seconds.
    var hkDuration: Double

    /// Calories (kcal)
    var hkActiveCalories: Double
    var hkTotalCalories: Double

    /// Heart Rate (bpm)
    var hkAvgHeartRate: Double
    var hkMaxHeartRate: Double

    // MARK: - HealthKit HR UI series (optional)

    /// Zone durations in seconds
    var hkZone1Seconds: Double
    var hkZone2Seconds: Double
    var hkZone3Seconds: Double
    var hkZone4Seconds: Double
    var hkZone5Seconds: Double

    /// Downsampled HR series for sparkline (bpm)
    var hkHeartRateSeriesBPM: [Double]
    var hkHeartRateSeriesStepSeconds: Double

    /// Post-workout HR mini chart (bpm)
    var hkPostWorkoutHeartRateBPM: [Double]
    var hkPostWorkoutHeartRateStepSeconds: Double

    init(
        date: Date,
        status: SessionStatus = .planned,
        readinessStars: Int = 0,
        sessionNotes: String? = nil,
        weekIndex: Int,
        items: [SessionItem] = [],
        completedAt: Date? = nil,

        // HK defaults
        hkWorkoutUUID: String? = nil,
        hkWorkoutStart: Date? = nil,
        hkWorkoutEnd: Date? = nil,
        hkDuration: Double = 0,
        hkActiveCalories: Double = 0,
        hkTotalCalories: Double = 0,
        hkAvgHeartRate: Double = 0,
        hkMaxHeartRate: Double = 0,

        hkZone1Seconds: Double = 0,
        hkZone2Seconds: Double = 0,
        hkZone3Seconds: Double = 0,
        hkZone4Seconds: Double = 0,
        hkZone5Seconds: Double = 0,

        hkHeartRateSeriesBPM: [Double] = [],
        hkHeartRateSeriesStepSeconds: Double = 0,

        hkPostWorkoutHeartRateBPM: [Double] = [],
        hkPostWorkoutHeartRateStepSeconds: Double = 0
    ) {
        self.date = date
        self.status = status
        self.completedAt = completedAt

        self.readinessStars = readinessStars
        self.sessionNotes = sessionNotes

        // store into the legacy schema field
        self.weekInMeso = weekIndex

        self.items = items

        self.hkWorkoutUUID = hkWorkoutUUID
        self.hkWorkoutStart = hkWorkoutStart
        self.hkWorkoutEnd = hkWorkoutEnd
        self.hkDuration = hkDuration
        self.hkActiveCalories = hkActiveCalories
        self.hkTotalCalories = hkTotalCalories
        self.hkAvgHeartRate = hkAvgHeartRate
        self.hkMaxHeartRate = hkMaxHeartRate

        self.hkZone1Seconds = hkZone1Seconds
        self.hkZone2Seconds = hkZone2Seconds
        self.hkZone3Seconds = hkZone3Seconds
        self.hkZone4Seconds = hkZone4Seconds
        self.hkZone5Seconds = hkZone5Seconds

        self.hkHeartRateSeriesBPM = hkHeartRateSeriesBPM
        self.hkHeartRateSeriesStepSeconds = hkHeartRateSeriesStepSeconds

        self.hkPostWorkoutHeartRateBPM = hkPostWorkoutHeartRateBPM
        self.hkPostWorkoutHeartRateStepSeconds = hkPostWorkoutHeartRateStepSeconds
    }
}

// MARK: - Session Item (per-exercise)

@Model
final class SessionItem {
    /// Display order within the session (1-based).
    var order: Int

    /// ID of the exercise in `ExerciseCatalog` / `CatalogExercise`.
    var exerciseId: String

    // Planned targets (aggregate)
    var targetReps: Int
    var targetSets: Int
    var targetRIR: Int
    var suggestedLoad: Double

    /// Optional per-set logs (for future richer analytics).
    @Relationship(deleteRule: .cascade) var logs: [SetLog]

    // Planned pattern per set (v1)
    var plannedRepsBySet: [Int]
    var plannedLoadsBySet: [Double]

    // Simple inline logging (what you’re using now)
    var actualReps: [Int]
    var actualLoads: [Double]
    var actualRIRs: [Int]
    var usedRestPauseFlags: [Bool]
    var restPausePatternsBySet: [String]

    var isCompleted: Bool
    var isPR: Bool

    var coachNote: String?
    var nextSuggestedLoad: Double?

    init(
        order: Int,
        exerciseId: String,
        targetReps: Int,
        targetSets: Int,
        targetRIR: Int,
        suggestedLoad: Double,
        plannedRepsBySet: [Int] = [],
        plannedLoadsBySet: [Double] = [],
        logs: [SetLog] = [],
        actualReps: [Int] = [],
        actualLoads: [Double] = [],
        actualRIRs: [Int] = [],
        usedRestPauseFlags: [Bool] = [],
        restPausePatternsBySet: [String] = [],
        isCompleted: Bool = false,
        isPR: Bool = false,
        coachNote: String? = nil,
        nextSuggestedLoad: Double? = nil
    ) {
        self.order = order
        self.exerciseId = exerciseId
        self.targetReps = targetReps
        self.targetSets = targetSets
        self.targetRIR = targetRIR
        self.suggestedLoad = suggestedLoad

        self.plannedRepsBySet = plannedRepsBySet
        self.plannedLoadsBySet = plannedLoadsBySet
        self.logs = logs

        self.actualReps = actualReps
        self.actualLoads = actualLoads
        self.actualRIRs = actualRIRs
        self.usedRestPauseFlags = usedRestPauseFlags
        self.restPausePatternsBySet = restPausePatternsBySet

        self.isCompleted = isCompleted
        self.isPR = isPR
        self.coachNote = coachNote
        self.nextSuggestedLoad = nextSuggestedLoad
    }
}

// MARK: - SetLog

@Model
final class SetLog {
    var setNumber: Int
    var targetReps: Int
    var targetRIR: Int
    var targetLoad: Double
    var actualReps: Int
    var actualRIR: Int
    var actualLoad: Double

    init(
        setNumber: Int,
        targetReps: Int,
        targetRIR: Int,
        targetLoad: Double,
        actualReps: Int,
        actualRIR: Int,
        actualLoad: Double
    ) {
        self.setNumber = setNumber
        self.targetReps = targetReps
        self.targetRIR = targetRIR
        self.targetLoad = targetLoad
        self.actualReps = actualReps
        self.actualRIR = actualRIR
        self.actualLoad = actualLoad
    }
}

// MARK: - SessionStatus display helper

extension SessionStatus {
    var displayTitle: String {
        switch self {
        case .planned:     return "Planned"
        case .inProgress:  return "In Progress"
        case .completed:   return "Completed"
        }
    }
}
