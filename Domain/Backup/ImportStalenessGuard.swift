import Foundation

/// The staleness guard: an incoming file that would move the store backwards needs a typed "REPLACE".
enum ImportStalenessGuard {
    static let confirmationWord = "REPLACE"

    enum Verdict: Equatable {
        case normalConfirm
        case requireTypedReplace(reasons: [String])
        var requiresTypedWord: Bool { if case .requireTypedReplace = self { return true } else { return false } }
    }

    static func assess(incoming: BackupContentSummary, current: BackupContentSummary) -> Verdict {
        var reasons: [String] = []
        if incoming.completedSessions < current.completedSessions {
            reasons.append("The file has fewer completed sessions (\(incoming.completedSessions)) than this device (\(current.completedSessions)).")
        }
        if let cur = current.lastCompletedDate, (incoming.lastCompletedDate ?? .distantPast) < cur {
            // A file written moments ago from this very device is not stale. Two ways to see that: the file holds this
            // device's latest completed session (by id), or the dates agree at the precision the export writes (whole seconds;
            // the store keeps fractions of a second, the file does not).
            let containsLatest = current.lastCompletedSessionId.map { incoming.completedSessionIds.contains($0) } ?? false
            let incomingSeconds = (incoming.lastCompletedDate ?? .distantPast).timeIntervalSince1970.rounded(.down)
            let currentSeconds = cur.timeIntervalSince1970.rounded(.down)
            if !containsLatest && incomingSeconds < currentSeconds {
                reasons.append("The file's last completed session is earlier than the one on this device.")
            }
        }
        return reasons.isEmpty ? .normalConfirm : .requireTypedReplace(reasons: reasons)
    }

    static func accepts(typed: String) -> Bool { typed.trimmingCharacters(in: .whitespaces) == confirmationWord }
}

