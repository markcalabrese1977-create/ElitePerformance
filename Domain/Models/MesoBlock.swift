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

    /// Sessions that belong to this meso
    @Relationship(deleteRule: .cascade) var sessions: [Session] = []

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),
        name: String,
        startDate: Date,
        status: MesoStatus = .draft,
        notes: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.name = name
        self.startDate = startDate
        self.status = status
        self.notes = notes
    }
}
