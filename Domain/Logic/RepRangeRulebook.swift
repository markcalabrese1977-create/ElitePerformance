import Foundation

/// UI/logic-only rep range rules.
///
/// ✅ No SwiftData model changes.
/// We keep storing a single planned/target rep count in the model,
/// and compute the allowed range at runtime for display + progression.
struct RepRange: Equatable {
    let min: Int
    let max: Int
}

enum LiftPattern: String {
    case compoundPress
    case pull
    case squatPattern
    case hingeSpineSensitive
    case hamCurlLegExt
    case lateralRearDelt
    case biceps
    case triceps
    case calves
    case abs
    case unknown
}

enum RepRangeRulebook {

    // MARK: - Public API

    /// Main entry point for the app: compute a rep range from an exercise id/name.
    static func range(forExerciseId id: String, exerciseName: String? = nil, spineSensitive: Bool = false) -> RepRange {
        let pattern = inferPattern(exerciseId: id, exerciseName: exerciseName)
        return range(for: pattern, spineSensitive: spineSensitive)
    }

    /// Human-friendly string: `10 (8–12)`.
    static func display(targetReps: Int, range: RepRange) -> String {
        "\(targetReps) (\(range.min)–\(range.max))"
    }

    // MARK: - Pattern → Range (v1 blueprint)

    static func range(for pattern: LiftPattern, spineSensitive: Bool = false) -> RepRange {
        switch pattern {
        case .compoundPress:
            return RepRange(min: 8, max: 12)
        case .pull:
            return RepRange(min: 10, max: 15)
        case .squatPattern:
            return RepRange(min: 8, max: 12)
        case .hingeSpineSensitive:
            // When the back is “fussy”, hinge category collapses to fixed 10.
            return spineSensitive ? RepRange(min: 10, max: 10) : RepRange(min: 8, max: 12)
        case .hamCurlLegExt:
            return RepRange(min: 10, max: 15)
        case .lateralRearDelt:
            return RepRange(min: 15, max: 25)
        case .biceps:
            return RepRange(min: 10, max: 15)
        case .triceps:
            return RepRange(min: 10, max: 15)
        case .calves:
            return RepRange(min: 10, max: 20)
        case .abs:
            return RepRange(min: 12, max: 20)
        case .unknown:
            return RepRange(min: 8, max: 12)
        }
    }

    // MARK: - Inference

    /// Infers a lift pattern from known ids / name keywords.
    /// This is intentionally simple and safe: if unknown, we fall back to compound-friendly defaults.
    static func inferPattern(exerciseId: String, exerciseName: String? = nil) -> LiftPattern {
        let id = exerciseId.lowercased()
        let name = (exerciseName ?? "").lowercased()

        // Squat / press / pull are easier to infer by ID.
        if id.contains("hack") || id.contains("leg_press") || id.contains("squat") {
            return .squatPattern
        }

        // Hinge / spine sensitive
        if id.contains("rdl") || id.contains("deadlift") || id.contains("pull_through") || id.contains("hinge") {
            return .hingeSpineSensitive
        }

        // Pulls
        if id.contains("pulldown") || id.contains("pull_down") || id.contains("row") || id.contains("chin") || id.contains("pullup") || id.contains("pull_up") {
            return .pull
        }

        // Pressing
        if id.contains("bench") || id.contains("press") || id.contains("dip") {
            return .compoundPress
        }

        // Ham curls / leg extension
        if id.contains("leg_curl") || id.contains("ham") || id.contains("leg_extension") {
            return .hamCurlLegExt
        }

        // Lateral / rear delts
        if id.contains("lateral") || id.contains("rear_delt") || id.contains("reverse_fly") || id.contains("rear_fly") {
            return .lateralRearDelt
        }

        // Biceps / triceps
        if id.contains("curl") {
            return .biceps
        }
        if id.contains("tricep") || id.contains("pressdown") || id.contains("pushdown") || id.contains("overhead") {
            return .triceps
        }

        // Calves / abs
        if id.contains("calf") {
            return .calves
        }
        if id.contains("crunch") || id.contains("hanging") || id.contains("ab") {
            return .abs
        }

        // Name-based fallback (covers edge cases)
        if name.contains("pulldown") || name.contains("row") { return .pull }
        if name.contains("press") || name.contains("bench") { return .compoundPress }
        if name.contains("hack") || name.contains("leg press") || name.contains("squat") { return .squatPattern }
        if name.contains("rdl") || name.contains("deadlift") { return .hingeSpineSensitive }
        if name.contains("curl") { return .biceps }
        if name.contains("tricep") || name.contains("pushdown") { return .triceps }
        if name.contains("calf") { return .calves }
        if name.contains("crunch") || name.contains("hanging") { return .abs }

        return .unknown
    }
}

