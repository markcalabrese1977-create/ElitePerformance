import Foundation

/// Compatibility shim for older onboarding code that referenced `TrainingGoal`.
/// New code primarily uses `Goal`, but we keep this to avoid breaking references.
enum TrainingGoal: String, CaseIterable, Identifiable, Codable {
    case hypertrophy
    case strength
    case fatLoss
    case maintenance // maps to `Goal.longevity` in current domain

    var id: String { rawValue }

    /// Bridge to the current `Goal` enum used by the program catalog.
    var goal: Goal {
        switch self {
        case .hypertrophy: return .hypertrophy
        case .strength:    return .strength
        case .fatLoss:     return .fatLoss
        case .maintenance: return .longevity
        }
    }

    /// Short tag for UI chips, if needed by onboarding views.
    var shortTag: String {
        switch self {
        case .hypertrophy: return "Build muscle"
        case .strength:    return "Strength"
        case .fatLoss:     return "Fat loss"
        case .maintenance: return "Maintenance"
        }
    }
}
