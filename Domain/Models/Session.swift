import Foundation
import SwiftData

@Model
final class Session {
    enum Status: String, Codable, CaseIterable, Identifiable { case planned, inProgress, completed; var id: String { rawValue } }
    var date: Date
    var statusRaw: String
    var readinessStars: Int
    @Relationship(deleteRule: .cascade) var items: [SessionItem]

    init(date: Date = Date(), status: Status = .planned, readinessStars: Int = 0, items: [SessionItem] = []) {
        self.date = date
        self.statusRaw = status.rawValue
        self.readinessStars = readinessStars
        self.items = items
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class SessionItem {
    var order: Int
    @Relationship var exercise: Exercise?
    var targetReps: Int
    var targetSets: Int
    var targetRIR: Int
    var suggestedLoad: Double
    @Relationship(deleteRule: .cascade) var logs: [SetLog]

    init(order: Int, exercise: Exercise?, targetReps: Int, targetSets: Int, targetRIR: Int, suggestedLoad: Double, logs: [SetLog] = []) {
        self.order = order
        self.exercise = exercise
        self.targetReps = targetReps
        self.targetSets = targetSets
        self.targetRIR = targetRIR
        self.suggestedLoad = suggestedLoad
        self.logs = logs
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
    var notes: String
    var isPR: Bool

    init(setNumber: Int, targetReps: Int, targetRIR: Int, targetLoad: Double,
         actualReps: Int = 0, actualRIR: Int = 3, actualLoad: Double = 0,
         notes: String = "", isPR: Bool = false) {
        self.setNumber = setNumber
        self.targetReps = targetReps
        self.targetRIR = targetRIR
        self.targetLoad = targetLoad
        self.actualReps = actualReps
        self.actualRIR = actualRIR
        self.actualLoad = actualLoad
        self.notes = notes
        self.isPR = isPR
    }
}

@Model
final class PRIndex {
    var exerciseName: String
    var bestReps: Int
    var bestE1RM: Double

    init(exerciseName: String, bestReps: Int = 0, bestE1RM: Double = 0) {
        self.exerciseName = exerciseName
        self.bestReps = bestReps
        self.bestE1RM = bestE1RM
    }
}
