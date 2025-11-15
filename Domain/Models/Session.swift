import Foundation
import SwiftData

enum SessionStatus: String, Codable, CaseIterable { case planned, inProgress, completed }

@Model
final class Session {
    var date: Date
    var status: SessionStatus
    var readinessStars: Int
    @Relationship(deleteRule: .cascade) var items: [SessionItem]

    init(date: Date,
         status: SessionStatus = .planned,
         readinessStars: Int = 0,
         items: [SessionItem] = []) {
        self.date = date
        self.status = status
        self.readinessStars = readinessStars
        self.items = items
    }
}

@Model
final class SessionItem {
    var order: Int

    /// ID of the exercise in `ExerciseCatalog` / `CatalogExercise`.
    var exerciseId: String

    // Planned targets (aggregate)
    var targetReps: Int
    var targetSets: Int
    var targetRIR: Int
    var suggestedLoad: Double

    @Relationship(deleteRule: .cascade) var logs: [SetLog]

    // Planned pattern per set (v1)
    /// Planned reps per set (index 0 = Set 1).
    var plannedRepsBySet: [Int]
    /// Planned load per set (same index as plannedRepsBySet).
    var plannedLoadsBySet: [Double]

    // Simple inline logging for v1
    /// Logged reps per set (index 0 = Set 1, etc.).
    var actualReps: [Int]
    /// Logged load per set (same indexing as actualReps).
    var actualLoads: [Double]
    /// Whether this exercise has any logged work.
    var isCompleted: Bool
    /// Whether this session hit a new PR for this exercise.
    var isPR: Bool
    
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
        isCompleted: Bool = false,
        isPR: Bool = false
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
        self.isCompleted = isCompleted
        self.isPR = isPR
    }
}
@Model
final class SetLog {
    var setNumber: Int
    var targetReps: Int
    var targetRIR: Int
    var targetLoad: Double
    var actualReps: Int
    var actualRIR: Int
    var actualLoad: Double

    init(setNumber: Int,
         targetReps: Int,
         targetRIR: Int,
         targetLoad: Double,
         actualReps: Int,
         actualRIR: Int,
         actualLoad: Double) {
        self.setNumber = setNumber
        self.targetReps = targetReps
        self.targetRIR = targetRIR
        self.targetLoad = targetLoad
        self.actualReps = actualReps
        self.actualRIR = actualRIR
        self.actualLoad = actualLoad
    }
}
