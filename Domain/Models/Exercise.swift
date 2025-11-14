import Foundation
import SwiftData

@Model
final class Exercise {
    enum Pattern: String, Codable, CaseIterable, Identifiable {
        case benchPress, inclineDB, machinePress
        case squat, legPress, lunge
        case hinge, rdl, hipThrust
        case row, pulldown, pullover
        case curl, triceps, lateralRaise
        var id: String { rawValue }
    }

    var name: String
    var patternRaw: String
    var defaultRepRangeLow: Int
    var defaultRepRangeHigh: Int
    var cues: [String]

    init(name: String, pattern: Pattern, low: Int, high: Int, cues: [String]) {
        self.name = name
        self.patternRaw = pattern.rawValue
        self.defaultRepRangeLow = low
        self.defaultRepRangeHigh = high
        self.cues = cues
    }

    var pattern: Pattern {
        get { Pattern(rawValue: patternRaw) ?? .benchPress }
        set { patternRaw = newValue.rawValue }
    }
}
