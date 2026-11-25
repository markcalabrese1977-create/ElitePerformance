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

    // Every LOAD (a weight on the bar, as entered or planned) is shown exactly as entered through `number`: 145 is "145", 22.5 is "22.5",
    // 22.25 is "22.25"; never rounded and never with a trailing ".0". The names below are kept so every call site reads the same as before;
    // they all delegate to `number`. COMPUTED values (e1RM, averages, volume) use `whole`, `wholeGrouped` or one decimal instead.

    /// A load as entered (was "%.1f" in lb: "145.0", and 22.25 became "22.3").
    func oneDecimal(_ storedLb: Double) -> String { number(storedLb) }

    /// A load as entered (was "%.1f" for non-whole lb loads, which rounded 22.25 to "22.3").
    func compact(_ storedLb: Double) -> String { number(storedLb) }

    /// "0" for zero, else the load as entered.
    func zeroOrOneDecimal(_ storedLb: Double) -> String {
        if storedLb == 0 { return "0" }
        return number(storedLb)
    }

    /// lb: "%.0f" (rounds). Volumes, e1RMs and peaks, which are shown whole.
    func whole(_ storedLb: Double) -> String {
        String(format: "%.0f", unit.fromStoredLb(storedLb))
    }

    /// A volume (lb·reps) in thousands, in this unit, rounded: 24,000 lb·reps is 11 in kg.
    func volumeK(_ storedVolume: Double) -> Int { Int((unit.fromStoredLb(storedVolume) / 1000.0).rounded()) }

    /// "11k kg" / "11k lb".
    func volumeKText(_ k: Int) -> String { "\(k)k \(unit.label)" }

    /// A logged set's load in a list: as entered (it used to round lb to a whole number, so a logged 22.5 read "22").
    func setLoad(_ storedLb: Double) -> String { number(storedLb) }

    /// A load as entered (it used to truncate lb, so 22.5 read "22").
    func truncated(_ storedLb: Double) -> String { number(storedLb) }

    /// lb: `String(Int(v))` of a volume (lb·reps), truncating. kg: the volume converted, truncated.
    func volumeInt(_ storedVolume: Double) -> String { String(Int(unit.fromStoredLb(storedVolume))) }

    // MARK: Large numbers with grouping separators ("1,028", "905,432")

    /// A count or an amount that is already a plain number, grouped by the locale ("10,572").
    static func grouped(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    static func grouped(_ value: Int) -> String { grouped(Double(value)) }

    /// `volumeInt` (truncating) with grouping separators: the History tab's session volumes.
    func volumeIntGrouped(_ storedVolume: Double) -> String { Self.grouped(Double(Int(unit.fromStoredLb(storedVolume)))) }

    /// `whole` with grouping separators: e1RMs, peaks.
    func wholeGrouped(_ storedLb: Double) -> String { Self.grouped(unit.fromStoredLb(storedLb)) }

    /// A volume (lb·reps) in this unit, whole, with grouping separators ("905,432").
    func volumeGrouped(_ storedVolume: Double) -> String { Self.grouped(unit.fromStoredLb(storedVolume)) }

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
