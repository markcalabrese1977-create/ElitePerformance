import Foundation
import SwiftData

@Model
final class CustomExercise {
    var id: String
    var name: String
    var primaryMuscleRaw: String
    var isCompound: Bool
    var createdAt: Date

    init(
        id: String,
        name: String,
        primaryMuscleRaw: String,
        isCompound: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.primaryMuscleRaw = primaryMuscleRaw
        self.isCompound = isCompound
        self.createdAt = createdAt
    }

    var asCatalogExercise: CatalogExercise {
        CatalogExercise(
            id: id,
            name: name,
            primaryMuscle: MuscleGroup(rawValue: primaryMuscleRaw) ?? .chest,
            isCompound: isCompound
        )
    }
}
