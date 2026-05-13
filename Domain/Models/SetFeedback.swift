import Foundation

/// Per-set feedback taxonomy.
/// Stored as raw strings in SessionItem.setFeedbackBySet.
enum SetFeedback: String, Codable {
    case none = ""
    case pain = "pain"               // joint/structural — stop signal
    case soreness = "soreness"       // muscular — informational
    case disruption = "disruption"   // general fatigue/strength loss
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

