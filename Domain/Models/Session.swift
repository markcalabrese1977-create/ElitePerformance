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

    /// Which week of the block this session belongs to (1-based).
    var weekIndex: Int

    /// Exercises for this session.
    @Relationship(deleteRule: .cascade) var items: [SessionItem]

    init(
        date: Date,
        status: SessionStatus = .planned,
        readinessStars: Int = 0,
        sessionNotes: String? = nil,
        weekIndex: Int,
        items: [SessionItem] = [],
        completedAt: Date? = nil
    ) {
        self.date = date
        self.status = status
        self.readinessStars = readinessStars
        self.sessionNotes = sessionNotes
        self.weekIndex = weekIndex
        self.items = items
        self.completedAt = completedAt
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
    /// Planned reps per set (index 0 = Set 1).
    var plannedRepsBySet: [Int]
    /// Planned load per set (same index as plannedRepsBySet).
    var plannedLoadsBySet: [Double]

    // Simple inline logging (what you’re using now)
    /// Logged reps per set (index 0 = Set 1, etc.).
    var actualReps: [Int]
    /// Logged load per set (same indexing as actualReps).
    var actualLoads: [Double]
    /// Logged RIR per set (same indexing as actualReps).
    var actualRIRs: [Int]
    /// Whether each set used rest-pause / myo-rep (same indexing).
    var usedRestPauseFlags: [Bool]
    /// Rest-pause pattern per set, e.g. "10+4+3" (same indexing as actualReps).
    var restPausePatternsBySet: [String]

    /// Whether this exercise has any logged work.
    var isCompleted: Bool
    /// Whether this exercise hit a new PR in this session.
    var isPR: Bool

    /// Coach note summarizing what to do next time on this exercise.
    var coachNote: String?
    /// Next suggested load for the main working sets (if the coach has a strong opinion).
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

// MARK: - SetLog (for future detailed logging)

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
        case .planned:
            return "Planned"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        }
    }
}
