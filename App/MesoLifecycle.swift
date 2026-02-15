import Foundation

enum MesoLifecycle {

    // MARK: - UserDefaults keys
    private static let activeStartEpochKey = "meso.activeStartDateEpoch"
    private static let scheduledStartEpochKey = "meso.scheduledStartDateEpoch"
    private static let promptSnoozeEpochKey = "meso.promptSnoozeEpoch" // optional: "not now" snooze

    private static var calendar: Calendar { .current }

    // MARK: - Active meso start (metrics cutoff)
    static var activeStartDate: Date {
        let t = UserDefaults.standard.double(forKey: activeStartEpochKey)
        if t > 0 { return Date(timeIntervalSince1970: t) }
        // Default: today if never set
        let today = calendar.startOfDay(for: Date())
        UserDefaults.standard.set(today.timeIntervalSince1970, forKey: activeStartEpochKey)
        return today
    }

    static func setActiveStartDate(_ date: Date) {
        let d0 = calendar.startOfDay(for: date)
        UserDefaults.standard.set(d0.timeIntervalSince1970, forKey: activeStartEpochKey)
    }

    // MARK: - Scheduling
    static var scheduledStartDate: Date? {
        let t = UserDefaults.standard.double(forKey: scheduledStartEpochKey)
        return (t > 0) ? Date(timeIntervalSince1970: t) : nil
    }

    static func scheduleNextMeso(on date: Date) {
        let d0 = calendar.startOfDay(for: date)
        UserDefaults.standard.set(d0.timeIntervalSince1970, forKey: scheduledStartEpochKey)
        // clear snooze when rescheduled
        UserDefaults.standard.removeObject(forKey: promptSnoozeEpochKey)
    }

    static func clearScheduledNextMeso() {
        UserDefaults.standard.removeObject(forKey: scheduledStartEpochKey)
        UserDefaults.standard.removeObject(forKey: promptSnoozeEpochKey)
    }

    // MARK: - Due logic (confirmation guard)
    static func isRolloverDue(today: Date = Date()) -> Bool {
        guard let scheduled = scheduledStartDate else { return false }

        let today0 = calendar.startOfDay(for: today)
        let scheduled0 = calendar.startOfDay(for: scheduled)

        // if "Not now" snooze is set beyond today, don't prompt
        let snoozeT = UserDefaults.standard.double(forKey: promptSnoozeEpochKey)
        if snoozeT > 0 {
            let snoozeDate = Date(timeIntervalSince1970: snoozeT)
            let snooze0 = calendar.startOfDay(for: snoozeDate)
            if snooze0 > today0 { return false }
        }

        return today0 >= scheduled0
    }

    /// Performs the rollover: sets the labeling anchor + updates active start date + clears the scheduled date.
    static func confirmStartNewMeso(on date: Date = Date()) {
        let d0 = calendar.startOfDay(for: date)
        MesoLabel.startNewMeso(on: d0)
        setActiveStartDate(d0)
        clearScheduledNextMeso()
    }

    static func delayScheduledStart(byDays days: Int = 1) {
        guard let scheduled = scheduledStartDate else { return }
        let scheduled0 = calendar.startOfDay(for: scheduled)
        let newDate = calendar.date(byAdding: .day, value: max(1, days), to: scheduled0) ?? scheduled0
        scheduleNextMeso(on: newDate)
    }

    /// Optional: "Not now" for today only (prompt again tomorrow)
    static func snoozePromptUntilTomorrow() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        UserDefaults.standard.set(tomorrow.timeIntervalSince1970, forKey: promptSnoozeEpochKey)
    }
}
