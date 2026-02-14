import Foundation

enum ExtrasPlanEngine {

    /// Zone 2 targets for the current plan:
    /// - This week (W8): 2 sessions
    /// - Weeks 9+ : 3 sessions
    ///
    /// Note: We key off the MesoLabel week number so it stays aligned with
    /// your Fri–Wed lift / Thu rest calendar.
    static func zone2WeeklyTarget(for date: Date = Date()) -> Int {
        let wd = MesoLabel.weekDay(for: date)
        return wd.week <= 8 ? 2 : 3
    }

    /// Recommended slots based on your rule:
    /// - Thu (normal rest day)
    /// - after D2
    /// - after D4
    /// For a 2-session week, D4 becomes optional.
    static func recommendedZone2Slots(for date: Date = Date()) -> [String] {
        let target = zone2WeeklyTarget(for: date)
        if target <= 2 {
            return ["After D2", "Thu (Rest Day)"]
        } else {
            return ["After D2", "After D4", "Thu (Rest Day)"]
        }
    }

    /// A simple default prescription that keeps interference low.
    static func zone2PrescriptionText() -> String {
        "25–40 min @ steady conversational pace (true Zone 2).\nNasal breathing if possible.\nKeep it easy: you should finish feeling better, not wrecked."
    }

    static func corePrescriptionText() -> String {
        "8–12 min, 2–3x/week.\nPick 1–2 carries + 1 bracing drill.\nExample: Farmer carry 3x45s + Suitcase carry 3x30s/side + Pallof press 2x12/side."
    }
}
