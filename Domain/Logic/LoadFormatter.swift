import Foundation

/// The one place load text is formatted, so a unit change (see BACKLOG: kg support) is made once.
/// Today every load is pounds: `User.units` exists but nothing reads it.
enum LoadFormatter {

    /// Unit suffix shown next to a load or an increment.
    static var unitLabel: String { "lb" }

    /// "132", "132.5" — no trailing ".0".
    static func number(_ load: Double) -> String {
        load == load.rounded() ? String(Int(load)) : String(format: "%g", load)
    }

    /// "132 lb", "132.5 lb".
    static func text(_ load: Double) -> String {
        "\(number(load)) \(unitLabel)"
    }
}
