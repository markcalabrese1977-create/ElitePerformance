import Foundation

struct SessionRating: Codable, Equatable {
    // 0–3 each
    var readiness: Int
    var execution: Int
    var performance: Int
    var recoveryCost: Int   // higher = more cost (we’ll show it clearly in UI)

    static let empty = SessionRating(readiness: 0, execution: 0, performance: 0, recoveryCost: 0)

    var total: Int { readiness + execution + performance + recoveryCost } // 0–12
}

enum SessionRatingStore {
    private static let prefix = "session_rating.v1"

    private static func key(sessionId: String) -> String {
        "\(prefix).\(sessionId)"
    }

    static func load(sessionId: String) -> SessionRating {
        guard let data = UserDefaults.standard.data(forKey: key(sessionId: sessionId)),
              let rating = try? JSONDecoder().decode(SessionRating.self, from: data)
        else { return .empty }
        return rating
    }

    static func save(_ rating: SessionRating, sessionId: String) {
        let k = key(sessionId: sessionId)
        if rating == .empty {
            UserDefaults.standard.removeObject(forKey: k)
            return
        }
        if let data = try? JSONEncoder().encode(rating) {
            UserDefaults.standard.set(data, forKey: k)
        }
    }

    static func hasRating(sessionId: String) -> Bool {
        load(sessionId: sessionId) != .empty
    }
}
