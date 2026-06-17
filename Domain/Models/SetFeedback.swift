import Foundation

/// Per-set feedback taxonomy.
/// Stored as raw strings in SessionItem.setFeedbackBySet.
enum SetFeedback: String, Codable {
    case none = ""
    case pain = "pain"               // joint/structural — stop signal
    case soreness = "soreness"       // muscular — informational
    case disruption = "disruption"   // general fatigue/strength loss
    case fatigue = "fatigue"         // systemic fatigue/tired — distinct from disruption
}

/// Pump quality on completed sets.
/// Stored as Int in SessionItem.pumpRatingsBySet.
/// 0 = not rated, 1 = poor, 2 = moderate, 3 = good, 4 = excellent
enum PumpRating: Int, Codable, CaseIterable {
    case none = 0
    case poor = 1
    case moderate = 2
    case good = 3
    case excellent = 4

    var label: String {
        switch self {
        case .none: return "—"
        case .poor: return "Poor"
        case .moderate: return "Moderate"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }

    var color: String {
        switch self {
        case .none: return "secondary"
        case .poor: return "orange"
        case .moderate: return "yellow"
        case .good: return "blue"
        case .excellent: return "green"
        }
    }
}


// MARK: - Volume Regulation

enum VolumeRegulationAction {
    case hold
    case reduce
}

// MARK: - Load Override Reason

enum LoadOverrideReason: String, Codable, CaseIterable {
    case jointTenderness
    case generalFatigue
    case equipmentConstraint
    case deliberateDeload

    var displayName: String {
        switch self {
        case .jointTenderness:     return "Joint tenderness"
        case .generalFatigue:      return "General fatigue"
        case .equipmentConstraint: return "Equipment constraint"
        case .deliberateDeload:    return "Deliberate deload"
        }
    }

    var coachNote: String {
        switch self {
        case .jointTenderness:
            return "⚠️ Joint tenderness was flagged last session. Reassess load before pushing."
        case .generalFatigue:
            return "ℹ️ General fatigue caused a load reduction last session. Monitor before increasing."
        case .equipmentConstraint, .deliberateDeload:
            return ""
        }
    }
}

struct VolumeRegulationSignal {
    let action: VolumeRegulationAction
    let reason: String?
    let setDelta: Int  // 0 or -1

    static let neutral = VolumeRegulationSignal(action: .hold, reason: nil, setDelta: 0)
}
