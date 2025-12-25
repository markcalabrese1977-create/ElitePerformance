import Foundation

enum MesoLabel {

    // MARK: - Persisted anchor
    // We store:
    // - anchorDate (start-of-day)
    // - anchorTrainingDayNumber (1-based across meso; W1D1=1, W2D2=8, etc.)

    private static let anchorDateKey = "meso.anchorDate"
    private static let anchorDayNumberKey = "meso.anchorDayNumber"

    private static var calendar: Calendar { .current }

    private static var anchorDate: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: anchorDateKey)
            return (t == 0) ? nil : Date(timeIntervalSince1970: t)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: anchorDateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: anchorDateKey)
            }
        }
    }

    private static var anchorTrainingDayNumber: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: anchorDayNumberKey)
            return (v == 0) ? nil : v
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: anchorDayNumberKey)
            } else {
                UserDefaults.standard.removeObject(forKey: anchorDayNumberKey)
            }
        }
    }

    // MARK: - Public API

    /// One-time anchor setter:
    /// Example: setAnchor(week: 2, day: 2, on: Date())  // today is W2D2
    static func setAnchor(week: Int, day: Int, on date: Date) {
        let w = max(1, week)
        let d = min(max(1, day), 6)

        let trainingDayNumber = (w - 1) * 6 + d  // W2D2 => 8

        anchorDate = calendar.startOfDay(for: date)
        anchorTrainingDayNumber = trainingDayNumber
    }

    /// Only sets the anchor if it is missing.
    static func ensureAnchor(week: Int, day: Int, on date: Date) {
        guard anchorDate == nil || anchorTrainingDayNumber == nil else { return }
        setAnchor(week: week, day: day, on: date)
    }

    /// Returns (week, day) for any date, based on lift-day counting and Thu rest days.
    static func weekDay(for date: Date) -> (week: Int, day: Int) {
        guard let aDate = anchorDate,
              let aNum = anchorTrainingDayNumber else {
            // Fallback if not anchored yet.
            return (1, 1)
        }

        let target = calendar.startOfDay(for: date)

        // Count lift-days between anchor and target
        let deltaLiftDays = liftDayDelta(from: aDate, to: target)

        let trainingDayNumber = max(1, aNum + deltaLiftDays)
        let week = ((trainingDayNumber - 1) / 6) + 1
        let day = ((trainingDayNumber - 1) % 6) + 1
        return (week, day)
    }

    static func label(for date: Date) -> String {
        let wd = weekDay(for: date)
        return "W\(wd.week)D\(wd.day)"
    }

    // MARK: - Core counting logic (Fri–Wed lift, Thu rest)

    private static func isLiftDay(_ date: Date) -> Bool {
        // Thursday = 5 in Gregorian calendar with Sunday=1
        let weekday = calendar.component(.weekday, from: date)
        return weekday != 5
    }

    /// Returns number of *lift days* between two dates.
    /// If `to` is after `from`, result is positive.
    /// If `to` is before `from`, result is negative.
    private static func liftDayDelta(from: Date, to: Date) -> Int {
        if from == to {
            // If the anchor day itself is a lift day, we consider it "day 0 delta" (same day)
            return 0
        }

        var count = 0

        if to > from {
            var cur = from
            while cur < to {
                cur = calendar.date(byAdding: .day, value: 1, to: cur)!
                if cur <= to, isLiftDay(cur) { count += 1 }
            }
            return count
        } else {
            var cur = from
            while cur > to {
                cur = calendar.date(byAdding: .day, value: -1, to: cur)!
                if cur >= to, isLiftDay(cur) { count -= 1 }
            }
            return count
        }
    }
}
