import Foundation
import SwiftData

@Model
final class ExerciseNote {
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    var exerciseId: String
    var note: String

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),
        exerciseId: String,
        note: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.exerciseId = exerciseId
        self.note = note
    }
}
