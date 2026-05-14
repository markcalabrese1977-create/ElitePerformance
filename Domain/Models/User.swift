import Foundation
import SwiftData

@Model
final class User {
    enum Units: String, Codable, CaseIterable, Identifiable {
        case lb, kg
        var id: String { rawValue }
    }

    var createdAt: Date
    var unitsRaw: String
    var coachVoiceRaw: String          // retained for schema compatibility — unused
    var progressionEnabled: Bool

    init(units: Units, progressionEnabled: Bool) {
        self.createdAt = Date()
        self.unitsRaw = units.rawValue
        self.coachVoiceRaw = "casual"  // inert default
        self.progressionEnabled = progressionEnabled
    }

    var units: Units {
        get { Units(rawValue: unitsRaw) ?? .lb }
        set { unitsRaw = newValue.rawValue }
    }
}
