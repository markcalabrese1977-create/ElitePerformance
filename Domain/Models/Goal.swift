import Foundation

/// High-level training goal selected during onboarding.
/// Names here are aligned with the existing OnboardingView usage.
enum Goal: String, CaseIterable, Identifiable, Codable {
    case hypertrophy
    case strength
    case fatLoss
    case longevity

    /// Old typo support: if you see `.strenght` anywhere,
    /// change it to `.strength` there. We do NOT keep a second case.
    var id: String { rawValue }

    /// Map to our PrimaryGoal domain type.
    var primaryGoal: PrimaryGoal {
        switch self {
        case .hypertrophy: return .hypertrophy
        case .strength:    return .strength
        case .fatLoss:     return .fatLoss
        case .longevity:   return .longevity
        }
    }

    /// Nice label for UI if you ever want it.
    var displayName: String {
        switch self {
        case .hypertrophy: return "Build Muscle (Hypertrophy)"
        case .strength:    return "Get Stronger"
        case .fatLoss:     return "Lose Fat"
        case .longevity:   return "Longevity / Feel Better"
        }
    }
}
