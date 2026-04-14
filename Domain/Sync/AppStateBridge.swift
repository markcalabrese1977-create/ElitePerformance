import Foundation
import SwiftData

enum AppStateBridge {
    private static let activeStartEpochKey = "meso.activeStartDateEpoch"
    private static let scheduledStartEpochKey = "meso.scheduledStartDateEpoch"
    private static let promptSnoozeEpochKey = "meso.promptSnoozeEpoch"
    private static let anchorDateKey = "meso.anchorDate"
    private static let anchorDayNumberKey = "meso.anchorDayNumber"
    private static let appModeKey = AppStorageKeys.appMode

    static func shared(in context: ModelContext) -> AppState {
        let descriptor = FetchDescriptor<AppState>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let created = AppState()
        context.insert(created)
        try? context.save()
        return created
    }

    static func importFromUserDefaultsIfNeeded(in context: ModelContext) {
        let state = shared(in: context)
        var changed = false
        let now = Date()

        if state.activeMesoStartDate == nil {
            let t = UserDefaults.standard.double(forKey: activeStartEpochKey)
            if t > 0 {
                state.activeMesoStartDate = Date(timeIntervalSince1970: t)
                changed = true
            }
        }

        if state.scheduledNextMesoStartDate == nil {
            let t = UserDefaults.standard.double(forKey: scheduledStartEpochKey)
            if t > 0 {
                state.scheduledNextMesoStartDate = Date(timeIntervalSince1970: t)
                changed = true
            }
        }

        if state.mesoPromptSnoozeUntil == nil {
            let t = UserDefaults.standard.double(forKey: promptSnoozeEpochKey)
            if t > 0 {
                state.mesoPromptSnoozeUntil = Date(timeIntervalSince1970: t)
                changed = true
            }
        }

        if state.mesoAnchorDate == nil {
            let t = UserDefaults.standard.double(forKey: anchorDateKey)
            if t > 0 {
                state.mesoAnchorDate = Date(timeIntervalSince1970: t)
                changed = true
            }
        }

        if state.mesoAnchorDayNumber == nil {
            let v = UserDefaults.standard.integer(forKey: anchorDayNumberKey)
            if v > 0 {
                state.mesoAnchorDayNumber = v
                changed = true
            }
        }

        if state.appModeRaw == nil {
            let raw = UserDefaults.standard.string(forKey: appModeKey)
            if let raw, !raw.isEmpty {
                state.appModeRaw = raw
                changed = true
            }
        }

        if state.id == nil {
            state.id = UUID()
            changed = true
        }
        if state.createdAt == nil {
            state.createdAt = now
            changed = true
        }
        if changed {
            state.updatedAt = now
            try? context.save()
            print("✅ AppState imported from UserDefaults.")
        } else {
            print("ℹ️ AppState import not needed.")
        }
    }

    static func syncToUserDefaults(from state: AppState) {
        if let d = state.activeMesoStartDate {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: activeStartEpochKey)
        }

        if let d = state.scheduledNextMesoStartDate {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: scheduledStartEpochKey)
        } else {
            UserDefaults.standard.removeObject(forKey: scheduledStartEpochKey)
        }

        if let d = state.mesoPromptSnoozeUntil {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: promptSnoozeEpochKey)
        } else {
            UserDefaults.standard.removeObject(forKey: promptSnoozeEpochKey)
        }

        if let d = state.mesoAnchorDate {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: anchorDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: anchorDateKey)
        }

        if let v = state.mesoAnchorDayNumber, v > 0 {
            UserDefaults.standard.set(v, forKey: anchorDayNumberKey)
        } else {
            UserDefaults.standard.removeObject(forKey: anchorDayNumberKey)
        }

        if let raw = state.appModeRaw, !raw.isEmpty {
            UserDefaults.standard.set(raw, forKey: appModeKey)
        }
    }

    static func setAppMode(_ raw: String, in context: ModelContext) {
        let state = shared(in: context)
        state.appModeRaw = raw
        state.updatedAt = Date()
        try? context.save()
        syncToUserDefaults(from: state)
    }

    static func setScheduledNextMesoStartDate(_ date: Date?, in context: ModelContext) {
        let state = shared(in: context)
        state.scheduledNextMesoStartDate = date.map { Calendar.current.startOfDay(for: $0) }
        state.updatedAt = Date()
        try? context.save()
        syncToUserDefaults(from: state)
    }

    static func setActiveMesoStartDate(_ date: Date?, in context: ModelContext) {
        let state = shared(in: context)
        state.activeMesoStartDate = date.map { Calendar.current.startOfDay(for: $0) }
        state.updatedAt = Date()
        try? context.save()
        syncToUserDefaults(from: state)
    }

    static func setMesoPromptSnoozeUntil(_ date: Date?, in context: ModelContext) {
        let state = shared(in: context)
        state.mesoPromptSnoozeUntil = date.map { Calendar.current.startOfDay(for: $0) }
        state.updatedAt = Date()
        try? context.save()
        syncToUserDefaults(from: state)
    }

    static func setMesoAnchor(date: Date?, dayNumber: Int?, in context: ModelContext) {
        let state = shared(in: context)
        state.mesoAnchorDate = date.map { Calendar.current.startOfDay(for: $0) }
        state.mesoAnchorDayNumber = dayNumber
        state.updatedAt = Date()
        try? context.save()
        syncToUserDefaults(from: state)
    }
}
