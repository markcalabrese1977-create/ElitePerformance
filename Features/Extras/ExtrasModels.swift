import Foundation

// MARK: - Extras Log Models (UserDefaults-backed; no SwiftData migration risk)

struct ExtrasEntry: Identifiable, Codable, Equatable {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case zone2
        case core

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zone2:
                return "Zone 2"
            case .core:
                return "Core"
            }
        }

        var systemImage: String {
            switch self {
            case .zone2:
                return "heart.circle"
            case .core:
                return "figure.strengthtraining.traditional"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var date: Date

    /// Minutes, if the activity is time-based (Zone 2; carries as time too).
    var durationMinutes: Int?

    /// Free text details (e.g., "Farmer carry 3x45s + Suitcase 3x30s/side" or Zone 2 notes)
    var notes: String

    init(
        id: UUID = UUID(),
        kind: Kind,
        date: Date,
        durationMinutes: Int? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.durationMinutes = durationMinutes
        self.notes = notes
    }
}

