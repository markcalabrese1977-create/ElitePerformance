import Foundation

enum SessionNotesStore {
    private static let prefix = "session_note.v1"

    private static func key(sessionId: String) -> String {
        "\(prefix).\(sessionId)"
    }

    static func load(sessionId: String) -> String {
        UserDefaults.standard.string(forKey: key(sessionId: sessionId)) ?? ""
    }

    static func save(_ note: String, sessionId: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key(sessionId: sessionId)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: k) }
        else { UserDefaults.standard.set(trimmed, forKey: k) }
    }

    static func hasNote(sessionId: String) -> Bool {
        !load(sessionId: sessionId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
