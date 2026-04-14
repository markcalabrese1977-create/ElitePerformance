import Foundation
import SwiftData

@Model
final class AppState {
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    // Meso lifecycle
    var activeMesoStartDate: Date?
    var scheduledNextMesoStartDate: Date?
    var mesoPromptSnoozeUntil: Date?

    // Meso label anchor
    var mesoAnchorDate: Date?
    var mesoAnchorDayNumber: Int?

    // App-level user mode
    var appModeRaw: String?

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),
        activeMesoStartDate: Date? = nil,
        scheduledNextMesoStartDate: Date? = nil,
        mesoPromptSnoozeUntil: Date? = nil,
        mesoAnchorDate: Date? = nil,
        mesoAnchorDayNumber: Int? = nil,
        appModeRaw: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activeMesoStartDate = activeMesoStartDate
        self.scheduledNextMesoStartDate = scheduledNextMesoStartDate
        self.mesoPromptSnoozeUntil = mesoPromptSnoozeUntil
        self.mesoAnchorDate = mesoAnchorDate
        self.mesoAnchorDayNumber = mesoAnchorDayNumber
        self.appModeRaw = appModeRaw
    }
}
