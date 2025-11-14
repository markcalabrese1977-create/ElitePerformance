import Foundation
import SwiftData

enum Goal: String, CaseIterable, Identifiable { case strength, hypertrophy, fatLoss; var id: String { rawValue } }

enum Units: String { case lb, kg }

struct ProgramGenerator {
    static func seedInitialProgram(goal: Goal, daysPerWeek: Int, context: ModelContext) {
        // Minimal library
        let bench = Exercise(name: "Barbell Bench Press", pattern: .benchPress, low: 6, high: 10, cues: ["Shoulders packed", "Bar path: lower chest", "Drive feet"])
        let row = Exercise(name: "Seated Cable Row", pattern: .row, low: 8, high: 12, cues: ["Neutral spine", "Elbows back", "Squeeze lats"])
        let squat = Exercise(name: "Hack Squat", pattern: .squat, low: 8, high: 12, cues: ["Knees track", "Full depth controlled", "Drive through midfoot"])
        context.insert(bench); context.insert(row); context.insert(squat)

        // Simple first session
        let s = Session(date: Date(), status: .planned, readinessStars: 0, items: [])
        context.insert(s)

        let items: [SessionItem] = [
            SessionItem(order: 1, exercise: bench, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 135),
            SessionItem(order: 2, exercise: row, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 100),
            SessionItem(order: 3, exercise: squat, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 180)
        ]
        s.items.append(contentsOf: items)
    }
}
