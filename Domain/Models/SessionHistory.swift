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
        exercises: [SessionHistoryExercise]
    ) {
        self.date = date
        self.weekIndex = weekIndex
        self.title = title
        self.subtitle = subtitle
        self.totalExercises = totalExercises
        self.totalSets = totalSets
        self.totalVolume = totalVolume
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
