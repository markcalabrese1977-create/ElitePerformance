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

    // Session screen: warm-up card hidden. A user preference; the UI reads/writes it through UserDefaults
    // (@AppStorage), this is the backed-up copy. nil = never set (card shown).
    var warmupHidden: Bool? = nil

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),
        activeMesoStartDate: Date? = nil,
        scheduledNextMesoStartDate: Date? = nil,
        mesoPromptSnoozeUntil: Date? = nil,
        mesoAnchorDate: Date? = nil,
        mesoAnchorDayNumber: Int? = nil,
        warmupHidden: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activeMesoStartDate = activeMesoStartDate
        self.scheduledNextMesoStartDate = scheduledNextMesoStartDate
        self.mesoPromptSnoozeUntil = mesoPromptSnoozeUntil
        self.mesoAnchorDate = mesoAnchorDate
        self.mesoAnchorDayNumber = mesoAnchorDayNumber
        self.warmupHidden = warmupHidden
    }
}
