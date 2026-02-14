import Foundation

enum AppleHealthLinkStore {
    private static let prefix = "appleHealth.link.v1"

    private static func key(sessionKey: String) -> String {
        "\(prefix).\(sessionKey)"
    }

    /// Session key should be stable. Use persistentModelID string if available; else date+mode fallback.
    static func loadWorkoutUUID(sessionKey: String) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: key(sessionKey: sessionKey)) else { return nil }
        return UUID(uuidString: raw)
    }

    static func saveWorkoutUUID(_ uuid: UUID, sessionKey: String) {
        UserDefaults.standard.set(uuid.uuidString, forKey: key(sessionKey: sessionKey))
    }

    static func clear(sessionKey: String) {
        UserDefaults.standard.removeObject(forKey: key(sessionKey: sessionKey))
    }
}
