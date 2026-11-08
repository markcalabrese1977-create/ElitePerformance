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

    // The pre-kg call sites each had their own lb format; these keep each one's lb output EXACTLY, and show a kg lifter
    // the same value trimmed to at most 2 decimals (a 1.25 kg step needs them).

    /// lb: "%.1f" ("132.5", "135.0"). Edit-field text and messages that always showed one decimal.
    func oneDecimal(_ storedLb: Double) -> String {
        unit == .lb ? String(format: "%.1f", storedLb) : Self.trimmed(unit.fromStoredLb(storedLb), maxDecimals: 2)
    }

    /// lb: whole numbers without a decimal, else "%.1f" ("135", "132.5").
    func compact(_ storedLb: Double) -> String {
        guard unit == .lb else { return Self.trimmed(unit.fromStoredLb(storedLb), maxDecimals: 2) }
        return storedLb == storedLb.rounded() ? String(Int(storedLb)) : String(format: "%.1f", storedLb)
    }

    /// lb: "0" for zero, else "%.1f".
    func zeroOrOneDecimal(_ storedLb: Double) -> String {
        if storedLb == 0 { return "0" }
        return oneDecimal(storedLb)
    }

    /// lb: "%.0f" (rounds). Volumes, e1RMs and peaks, which are shown whole.
    func whole(_ storedLb: Double) -> String {
        String(format: "%.0f", unit.fromStoredLb(storedLb))
    }

    /// lb: `String(Int(x))` (truncates). kg: trimmed.
    func truncated(_ storedLb: Double) -> String {
        unit == .lb ? String(Int(storedLb)) : Self.trimmed(unit.fromStoredLb(storedLb), maxDecimals: 2)
    }

    /// lb: `String(Int(v))` of a volume (lb·reps), truncating. kg: the volume converted, truncated.
    func volumeInt(_ storedVolume: Double) -> String { String(Int(unit.fromStoredLb(storedVolume))) }

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
