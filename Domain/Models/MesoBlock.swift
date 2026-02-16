import Foundation
import SwiftData

enum MesoStatus: String, Codable, CaseIterable {
    case draft
    case active
    case archived
}

@Model
final class MesoBlock {
    var name: String
    var startDate: Date
    var status: MesoStatus

    /// Optional notes like “Cut block” / “Deload week 6” etc.
    var notes: String?

    /// Sessions that belong to this meso
    @Relationship(deleteRule: .cascade) var sessions: [Session] = []

    init(name: String, startDate: Date, status: MesoStatus = .draft, notes: String? = nil) {
        self.name = name
        self.startDate = startDate
        self.status = status
        self.notes = notes
    }
}
