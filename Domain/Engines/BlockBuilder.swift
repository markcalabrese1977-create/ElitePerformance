import Foundation

/// Legacy block engine placeholder.
///
/// The original BlockBuilder used a SwiftData-backed CatalogExercise,
/// custom MovementPattern enums, and legacy MuscleGroup variants
/// (e.g. `.arms`, `.hamsGlutes`). That no longer matches the current
/// catalog model.
///
/// For the current build, **all initial programming** is handled by
/// `ProgramGenerator.seedInitialProgram(...)`, which creates Sessions
/// directly from `ExerciseCatalog`.
///
/// This stub exists purely so the project will compile while we
/// refactor the long-term block logic. If other code references
/// BlockBuilder in the future, add minimal shims here.
struct BlockBuilder {

    /// Stub API so any accidental callers compile without doing work.
    /// We don't currently rely on this anywhere.
    static func resetBlocks() {
        // no-op for now
    }
}
