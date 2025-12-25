//
//  LoggedSet.swift
//  ElitePerformance
//

import Foundation
import SwiftData

@Model
final class LoggedSet {
    @Attribute(.unique) var id: UUID

    // Session metadata
    var sessionDate: Date
    var weekIndex: Int
    var programDayLabel: String?   // e.g. "Week 1 · Tuesday"

    // Exercise metadata
    var exerciseId: String
    var exerciseName: String

    // Set index (1-based within that exercise)
    var setIndex: Int

    // Plan vs actual
    var plannedLoad: Double
    var plannedReps: Int
    var plannedRIR: Int?

    var actualLoad: Double
    var actualReps: Int

    // Aggregate helpers
    var volume: Double   // actualLoad * Double(actualReps)

    // For sorting / debugging
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sessionDate: Date,
        weekIndex: Int,
        programDayLabel: String?,
        exerciseId: String,
        exerciseName: String,
        setIndex: Int,
        plannedLoad: Double,
        plannedReps: Int,
        plannedRIR: Int?,
        actualLoad: Double,
        actualReps: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionDate = sessionDate
        self.weekIndex = weekIndex
        self.programDayLabel = programDayLabel
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.setIndex = setIndex
        self.plannedLoad = plannedLoad
        self.plannedReps = plannedReps
        self.plannedRIR = plannedRIR
        self.actualLoad = actualLoad
        self.actualReps = actualReps
        self.volume = actualLoad * Double(actualReps)
        self.createdAt = createdAt
    }
}
