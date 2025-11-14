import Foundation
import SwiftData

@Model
final class User {
    enum Units: String, Codable, CaseIterable, Identifiable {
        case lb, kg
        var id: String { rawValue }
    }
    enum CoachVoice: String, Codable, CaseIterable, Identifiable {
        case casual, strict
        var id: String { rawValue }
    }

    var createdAt: Date
    var unitsRaw: String
    var coachVoiceRaw: String
    var progressionEnabled: Bool

    init(units: Units, coachVoice: CoachVoice, progressionEnabled: Bool) {
        self.createdAt = Date()
        self.unitsRaw = units.rawValue
        self.coachVoiceRaw = coachVoice.rawValue
        self.progressionEnabled = progressionEnabled
    }

    var units: Units {
        get { Units(rawValue: unitsRaw) ?? .lb }
        set { unitsRaw = newValue.rawValue }
    }

    var coachVoice: CoachVoice {
        get { CoachVoice(rawValue: coachVoiceRaw) ?? .casual }
        set { coachVoiceRaw = newValue.rawValue }
    }
}
