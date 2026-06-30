import Foundation
import SwiftData

enum MesoStatus: String, Codable, CaseIterable {
    case draft
    case active
    case archived
}

@Model
final class MesoBlock {
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    var name: String
    var startDate: Date
    var status: MesoStatus

    /// Optional notes like “Cut block” / “Deload week 6” etc.
    var notes: String?
    
    /// Total number of weeks in this meso (hard weeks + deload if included).
    /// Used by CoachingEngine for phase detection.
    var totalWeeks: Int?

    /// True for a maintenance block (seeded by MaintenanceProgramSeeder), false for a
    /// regular meso. Distinguishes a maintenance block from a regular meso's own
    /// deload week — the two previously shared no block-level marker; the only
    /// existing signal was a fragile name match (`name.lowercased().contains("maintenance")`).
    /// Defaults to false for migration safety — existing regular mesos and any not
    /// explicitly marked maintenance are correctly treated as non-maintenance.
    var isMaintenance: Bool = false

    /// Sessions that belong to this meso
    @Relationship(deleteRule: .cascade) var sessions: [Session] = []

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),
        name: String,
        startDate: Date,
        status: MesoStatus = .draft,
        notes: String? = nil,
        totalWeeks: Int? = nil,
        isMaintenance: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.name = name
        self.startDate = startDate
        self.status = status
        self.notes = notes
        self.totalWeeks = totalWeeks
        self.isMaintenance = isMaintenance
    }
}
