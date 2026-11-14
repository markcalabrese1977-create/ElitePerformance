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
            reasons.append("The file's last completed session is earlier than the one on this device.")
        }
        return reasons.isEmpty ? .normalConfirm : .requireTypedReplace(reasons: reasons)
    }

    static func accepts(typed: String) -> Bool { typed.trimmingCharacters(in: .whitespaces) == confirmationWord }
}

