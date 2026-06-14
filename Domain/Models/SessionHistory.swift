import Foundation
import SwiftData

@Model
final class SessionHistory {
    var date: Date
    var weekIndex: Int
    var title: String
    var subtitle: String
    var totalExercises: Int
    var totalSets: Int
    var totalVolume: Double

    // Durable session/day identity
    var sessionId: UUID?
    var dayLabelSnapshot: String?

    // Computed session metrics snapshot
    var mechanicalLoad: Double?

    // Durable block identity
    var mesoBlockId: UUID?
    var mesoBlockNameSnapshot: String?

    @Relationship(deleteRule: .cascade)
    var exercises: [SessionHistoryExercise]

    init(
        date: Date,
        weekIndex: Int,
        title: String,
        subtitle: String,
        totalExercises: Int,
        totalSets: Int,
        totalVolume: Double,
        sessionId: UUID? = nil,
        dayLabelSnapshot: String? = nil,
        mechanicalLoad: Double? = nil,
        mesoBlockId: UUID? = nil,
        mesoBlockNameSnapshot: String? = nil,
        exercises: [SessionHistoryExercise]
    ) {
        self.date = date
        self.weekIndex = weekIndex
        self.title = title
        self.subtitle = subtitle
        self.totalExercises = totalExercises
        self.totalSets = totalSets
        self.totalVolume = totalVolume
        self.sessionId = sessionId
        self.dayLabelSnapshot = dayLabelSnapshot
        self.mechanicalLoad = mechanicalLoad
        self.mesoBlockId = mesoBlockId
        self.mesoBlockNameSnapshot = mesoBlockNameSnapshot
        self.exercises = exercises
    }
}

@Model
final class SessionHistoryExercise {
    var name: String
    var primaryMuscle: String?
    var sets: Int
    var reps: Int
    var volume: Double

    init(
        name: String,
        primaryMuscle: String?,
        sets: Int,
        reps: Int,
        volume: Double
    ) {
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.sets = sets
        self.reps = reps
        self.volume = volume
    }
}
