import SwiftUI

/// The one card shape every recap screen uses: full width, contents aligned leading, so every card starts at the same
/// left edge whatever its content (a narrow card used to sit centred in the scroll view).
extension View {
    func recapCardFrame() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The single Duration a recap shows. Apple Health's workout duration when a workout is linked; otherwise the app's own
/// (first logged set to completion), and nothing at all when that is missing or under five minutes (a number that short
/// is a misleading one).
enum RecapDuration {
    static let minimumAppSeconds: Double = 5 * 60

    struct Line: Equatable {
        let label: String
        let seconds: Double
    }

    static func line(healthLinked: Bool, healthSeconds: Double, appSeconds: Double?) -> Line? {
        if healthLinked, healthSeconds > 0 { return Line(label: "Duration (Apple Health)", seconds: healthSeconds) }
        if let app = appSeconds, app >= minimumAppSeconds { return Line(label: "Duration (from first set)", seconds: app) }
        return nil
    }

    /// m:ss, or h:mm:ss from an hour up.
    static func text(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
