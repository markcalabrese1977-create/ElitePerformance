//
//  PlannedBlock.swift
//  ElitePerformance
//
//  Created by Mark Calabrese on 11/14/25.
//

// Domain/Models/PlannedBlock.swift

import Foundation

enum SessionFocus: String, Codable {
    case push
    case pull
    case legs
    case upper
    case lower
    case fullBody
    case off
}

struct PlannedSetTemplate: Codable {
    let setIndex: Int
    let isTopSet: Bool
    let targetRepsLower: Int
    let targetRepsUpper: Int
    let notes: String?
}

struct PlannedExercise: Codable, Identifiable {
    let id: UUID
    let exerciseId: String      // link to Exercise catalog (string key for now)
    let primaryMuscle: MuscleGroup
    let isPriorityMuscle: Bool
    let order: Int
    let plannedSets: [PlannedSetTemplate]
}

struct PlannedSession: Codable, Identifiable {
    let id: UUID
    let dayIndex: Int           // 1...7
    let isTrainingDay: Bool
    let focus: SessionFocus
    let label: String
    let plannedExercises: [PlannedExercise]
}

struct PlannedBlock: Codable {
    let weeks: Int              // v1 = 1
    let sessions: [PlannedSession]  // 7 sessions for week 1
}
