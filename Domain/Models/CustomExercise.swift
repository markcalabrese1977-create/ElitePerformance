import Foundation
import SwiftData

@Model
final class CustomExercise {
    var id: String
    var name: String
    var primaryMuscleRaw: String
    /// The lifter's decision: a compound lift (RIR is recorded per set and drives progression) or not. nil = not decided yet:
    /// `resolvedIsCompound` then follows the closest built-in (see `MuscleSuggester.suggestedCompound`).
    var isCompound: Bool?
    var createdAt: Date
    var isBodyweight: Bool = false
    /// Analytics only: the fine muscle this exercise primarily trains (`FineMuscle.rawValue`), set by the lifter. nil =
    /// not mapped yet: its sets are listed as "unmapped" in volume reports, never guessed into the totals.
    var fineMuscleRaw: String? = nil
    /// Analytics only: synergist shares (`FineMuscle.rawValue` -> 0.25 / 0.5) beside `fineMuscleRaw` (the primary is 1.0).
    var fineSecondaryShares: [String: Double]? = nil

    init(
        id: String,
        name: String,
        primaryMuscleRaw: String,
        isCompound: Bool?,
        createdAt: Date = Date(),
        isBodyweight: Bool = false
    ) {
        self.id = id
        self.name = name
        self.primaryMuscleRaw = primaryMuscleRaw
        self.isCompound = isCompound
        self.createdAt = createdAt
        self.isBodyweight = isBodyweight
    }

    /// The lifter's fine-muscle shares (primary 1.0 + synergists), or nil when no primary is set.
    var fineShares: [FineMuscle: Double]? {
        guard let raw = fineMuscleRaw, let primary = FineMuscle(rawValue: raw) else { return nil }
        var out: [FineMuscle: Double] = [primary: 1.0]
        for (k, v) in fineSecondaryShares ?? [:] {
            if let m = FineMuscle(rawValue: k), m != primary, v > 0, v <= 0.5 { out[m] = v }
        }
        return out
    }

    /// What the app treats this exercise as: the lifter's value when set, else the suggestion from its closest built-in,
    /// else false (an ambiguous or unknown match is never assumed compound).
    var resolvedIsCompound: Bool {
        isCompound ?? MuscleSuggester.suggestedCompound(name: name, coarse: MuscleGroup(rawValue: primaryMuscleRaw) ?? .chest)
    }

    var asCatalogExercise: CatalogExercise {
        CatalogExercise(
            id: id,
            name: name,
            primaryMuscle: MuscleGroup(rawValue: primaryMuscleRaw) ?? .chest,
            isCompound: resolvedIsCompound,
            isBodyweight: isBodyweight
        )
    }
}
