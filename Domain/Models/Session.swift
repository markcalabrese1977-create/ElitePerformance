import Foundation
import SwiftData

// MARK: - Session Status

enum SessionStatus: String, Codable, CaseIterable {
    case planned
    case inProgress
    case completed
}

// MARK: - Session Readiness

enum SessionReadiness: String, Codable {
    case fresh        // better than normal — aggressive increase threshold
    case normal       // baseline — standard evaluation
    case fatigued     // tired but trainable — hold load, no increases
    case compromised  // joint/injury issue — reduce load, shift reps up
}

// MARK: - Session

@Model
final class Session {
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    // Core
    var date: Date
    var status: SessionStatus
    var completedAt: Date?

    /// 0 = not set yet, 1–5 = readiness rating for this session.
    var readinessStars: Int
    
    /// Structured readiness for coaching engine use. Default normal.
    var readinessRaw: String = "normal"

    var readiness: SessionReadiness {
        get { SessionReadiness(rawValue: readinessRaw) ?? .normal }
        set { readinessRaw = newValue.rawValue }
    }

    /// Optional text recap / notes for this session (end-of-workout recap writes here).
    var sessionNotes: String?

    /// Stored property kept for migration compatibility.
    var weekInMeso: Int?

    var meso: MesoBlock?

    /// Stable order within a mesocycle: 1...N
    /// Optional for migration safety with existing stores.
    var programIndex: Int?

    var dayLabel: String?
    
    /// Alias used throughout the app.
    var weekIndex: Int {
        get { weekInMeso ?? 1 }
        set { weekInMeso = newValue }
    }

    /// Exercises for this session.
    @Relationship(deleteRule: .cascade) var items: [SessionItem] = []

    // MARK: - HealthKit / Apple Workout Summary

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

    // MARK: - HealthKit HR UI series

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
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),

        date: Date,
        status: SessionStatus = .planned,
        readinessStars: Int = 0,
        sessionNotes: String? = nil,
        weekIndex: Int = 1,
        dayLabel: String? = nil,
        items: [SessionItem] = [],
        completedAt: Date? = nil,
        programIndex: Int? = nil,

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
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.date = date
        self.status = status
        self.completedAt = completedAt

        self.readinessStars = readinessStars
        self.sessionNotes = sessionNotes
        self.weekInMeso = weekIndex
        self.dayLabel = dayLabel
        self.items = items
        self.programIndex = programIndex

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
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    /// Display order within the session (1-based).
    var order: Int

    /// ID of the exercise in `ExerciseCatalog` / `CatalogExercise`.
    var exerciseId: String

    /// Durable display-name snapshot for history / recap portability.
    var exerciseNameSnapshot: String?

    // Planned targets (flattened execution defaults)
    var targetReps: Int
    var targetSets: Int
    var targetRIR: Int
    var suggestedLoad: Double

    // Resolved DUP prescription metadata (optional for migration safety)
    var waveRaw: String?
    var priorityRaw: String?

    var setMin: Int?
    var setMax: Int?

    var repMin: Int?
    var repMax: Int?

    var targetRIRMin: Int?
    var targetRIRMax: Int?

    var intensifierRaw: String?
    var intensifierNotes: String?
    var prescriptionNotes: String?

    /// Optional per-set logs (for future richer analytics).
    @Relationship(deleteRule: .cascade) var logs: [SetLog] = []

    // Planned pattern per set (v1)
    var plannedRepsBySet: [Int] = []
    var plannedLoadsBySet: [Double] = []
    var plannedRIRsBySet: [Int] = []

    // Simple inline logging (what you’re using now)
    var actualReps: [Int] = []
    var actualLoads: [Double] = []
    var actualRIRs: [Int] = []
    var usedRestPauseFlags: [Bool] = []
    var restPausePatternsBySet: [String] = []
    var dropSetPatternsBySet: [String] = []
    var setFeedbackBySet: [String] = []
    var pumpRatingsBySet: [Int] = []

    var isCompleted: Bool
    var isPR: Bool

    var coachNote: String?
    var loadOverrideReasonRaw: String? = nil

    var loadOverrideReason: LoadOverrideReason? {
        get {
            guard let raw = loadOverrideReasonRaw else { return nil }
            return LoadOverrideReason(rawValue: raw)
        }
        set { loadOverrideReasonRaw = newValue?.rawValue }
    }
    var nextSuggestedLoad: Double?

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),

        order: Int,
        exerciseId: String,
        exerciseNameSnapshot: String? = nil,
        targetReps: Int,
        targetSets: Int,
        targetRIR: Int,
        suggestedLoad: Double,

        waveRaw: String? = nil,
        priorityRaw: String? = nil,
        setMin: Int? = nil,
        setMax: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        targetRIRMin: Int? = nil,
        targetRIRMax: Int? = nil,
        intensifierRaw: String? = nil,
        intensifierNotes: String? = nil,
        prescriptionNotes: String? = nil,

        plannedRepsBySet: [Int] = [],
        plannedLoadsBySet: [Double] = [],
        plannedRIRsBySet: [Int] = [],
        logs: [SetLog] = [],
        actualReps: [Int] = [],
        actualLoads: [Double] = [],
        actualRIRs: [Int] = [],
        usedRestPauseFlags: [Bool] = [],
        restPausePatternsBySet: [String] = [],
        dropSetPatternsBySet: [String] = [],
        setFeedbackBySet: [String] = [],
        pumpRatingsBySet: [Int] = [],
        isCompleted: Bool = false,
        isPR: Bool = false,
        coachNote: String? = nil,
        nextSuggestedLoad: Double? = nil,
        loadOverrideReasonRaw: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.order = order
        self.exerciseId = exerciseId
        self.exerciseNameSnapshot = exerciseNameSnapshot

        self.targetReps = targetReps
        self.targetSets = targetSets
        self.targetRIR = targetRIR
        self.suggestedLoad = suggestedLoad

        self.waveRaw = waveRaw
        self.priorityRaw = priorityRaw
        self.setMin = setMin
        self.setMax = setMax
        self.repMin = repMin
        self.repMax = repMax
        self.targetRIRMin = targetRIRMin
        self.targetRIRMax = targetRIRMax
        self.intensifierRaw = intensifierRaw
        self.intensifierNotes = intensifierNotes
        self.prescriptionNotes = prescriptionNotes

        self.plannedRepsBySet = plannedRepsBySet
        self.plannedLoadsBySet = plannedLoadsBySet
        self.plannedRIRsBySet = plannedRIRsBySet
        self.logs = logs

        self.actualReps = actualReps
        self.actualLoads = actualLoads
        self.actualRIRs = actualRIRs
        self.usedRestPauseFlags = usedRestPauseFlags
        self.restPausePatternsBySet = restPausePatternsBySet
        self.dropSetPatternsBySet = dropSetPatternsBySet
        self.setFeedbackBySet = setFeedbackBySet
        self.pumpRatingsBySet = pumpRatingsBySet

        self.isCompleted = isCompleted
        self.isPR = isPR

        self.coachNote = coachNote
        self.nextSuggestedLoad = nextSuggestedLoad
        self.loadOverrideReasonRaw = loadOverrideReasonRaw
    }
}

// MARK: - SetLog

@Model
final class SetLog {
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    var setNumber: Int
    var targetReps: Int
    var targetRIR: Int
    var targetLoad: Double
    var actualReps: Int
    var actualRIR: Int
    var actualLoad: Double

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),

        setNumber: Int,
        targetReps: Int,
        targetRIR: Int,
        targetLoad: Double,
        actualReps: Int,
        actualRIR: Int,
        actualLoad: Double
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

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
extension Session {
    /// Day number within the training week (1–6), derived from programIndex.
    var dayNumberInWeek: Int {
        guard let pi = programIndex, pi > 0 else { return 1 }
        return ((pi - 1) % 6) + 1
    }
    
    var weekDayLabel: String {
        let week = weekIndex

        let dayText: String = {
            if let programIndex {
                let day = ((programIndex - 1) % 6) + 1
                return "D\(day)"
            }

            let weekdayName = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .none)
            _ = weekdayName // keep compiler quiet if you later change this logic

            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: date)

            switch weekday {
            case 1: return "D1" // Sunday
            case 2: return "D2" // Monday
            case 3: return "D3" // Tuesday
            case 4: return "D4" // Wednesday
            case 6: return "D5" // Friday
            case 7: return "D6" // Saturday
            case 5: return "Rest"
            default: return "D?"
            }
        }()
        return "W\(week)\(dayText)"
    }
}
extension Session {
    /// True when this session falls in the deload phase of its meso.
    /// Derived from `mesoPhase` (the single source of truth for phase-band
    /// math) so the two can never contradict each other — previously this
    /// compared weekIndex to totalWeeks directly (exact-last-week-only),
    /// which disagreed with mesoPhase's 90%-of-block percentage band for
    /// every meso where the deload band spans more than one week (e.g.
    /// totalWeeks == 10: mesoPhase already says .deload at week 9, but the
    /// old isDeloadWeek required week 10 exactly). See OPEN Q6 in
    /// Tests/DomainTests/TestOpenQuestions.swift.
    var isDeloadWeek: Bool {
        mesoPhase == .deload
    }
}

extension Session {
    /// Meso phase derived from position within the block.
    /// Uses percentage bands so it works for any meso length.
    var mesoPhase: MesoPhase {
        guard let total = meso?.totalWeeks, total > 0 else {
            return .early
        }
        let pct = Double(weekIndex) / Double(total)
        switch pct {
        case ..<0.30: return .early
        case ..<0.70: return .mid
        case ..<0.90: return .late
        default:      return .deload
        }
    }
}
