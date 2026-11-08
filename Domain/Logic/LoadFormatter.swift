import Foundation

/// The one place load text is formatted. Takes a STORED (lb) load, shows it in `unit`.
struct LoadFormatter {
    let unit: LoadUnit

    init(unit: LoadUnit = .lb) { self.unit = unit }

    var unitLabel: String { unit.label }

    /// "132", "132.5"; kg trims trailing zeros and shows at most 2 decimals ("46.49", "45").
    func number(_ storedLb: Double) -> String {
        switch unit {
        case .lb: return Self.lbNumber(storedLb)
        case .kg: return Self.trimmed(unit.fromStoredLb(storedLb), maxDecimals: 2)
        }
    }

    /// "132 lb", "46.5 kg".
    func text(_ storedLb: Double) -> String { "\(number(storedLb)) \(unitLabel)" }

    /// An amount that is already in this unit (an increment), without conversion.
    func numberInUnit(_ amount: Double) -> String {
        unit == .lb ? Self.lbNumber(amount) : Self.trimmed(amount, maxDecimals: 2)
    }

    func textInUnit(_ amount: Double) -> String { "\(numberInUnit(amount)) \(unitLabel)" }

    // Static lb shorthands: the pre-kg API, kept so existing call sites compile unchanged until the UI cut.
    static var unitLabel: String { "lb" }
    static func number(_ load: Double) -> String { lbNumber(load) }
    static func text(_ load: Double) -> String { "\(lbNumber(load)) lb" }

    private static func lbNumber(_ load: Double) -> String {
        load == load.rounded() ? String(Int(load)) : String(format: "%g", load)
    }

    static func trimmed(_ value: Double, maxDecimals: Int) -> String {
        var s = String(format: "%.\(maxDecimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}
