import Foundation

/// The unit a lifter sees and types loads in. Stored loads are ALWAYS lb (`UserProfile.loadUnit` only picks the
/// presentation unit and the unit `minLoadIncrement` is in). Conversion happens at three choke points only:
/// `LoadFormatter` (display), `LoadInput` (entry) and `UnitAwareRounding` (computed loads).
enum LoadUnit: String, Codable, CaseIterable, Identifiable {
    case lb, kg

    var id: String { rawValue }

    /// Exact: 1 lb = 0.45359237 kg (international avoirdupois pound).
    static let kgPerLb = 0.45359237

    var label: String { rawValue }

    /// A stored (lb) load expressed in this unit. lb is the identity, never a multiply, so lb results stay bit-identical.
    func fromStoredLb(_ lb: Double) -> Double {
        self == .lb ? lb : lb * Self.kgPerLb
    }

    /// An amount in this unit expressed as a stored (lb) load.
    func toStoredLb(_ amount: Double) -> Double {
        self == .lb ? amount : amount / Self.kgPerLb
    }
}

// MARK: - Entry

/// Parses typed load text (in the lifter's unit) to a STORED lb load.
enum LoadInput {

    /// The number in `text`, or nil when it is empty, unparseable or negative. Accepts "," as the decimal mark.
    static func number(from text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let v = Double(cleaned), v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// What typing `text` means for a stored load.
    enum Edit: Equatable {
        /// A real edit: write this stored (lb) load.
        case set(Double)
        /// The field was emptied.
        case clear
        /// The text shows the current value as it already displays: write nothing.
        case unchanged
        /// Not a number.
        case invalid
    }

    static func edit(_ text: String, unit: LoadUnit, current: Double?) -> Edit {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .clear }
        guard number(from: text) != nil else { return .invalid }
        guard let stored = storedLb(from: text, unit: unit, currentStoredLb: current) else { return .unchanged }
        return .set(stored)
    }

    /// The Program tab's per-set load: the stored load to write, or nil for no write. Empty or unreadable text writes 0
    /// (as it always did); text that shows the stored load as it is writes nothing, so planEdited stays as it was.
    static func plannedLoadWrite(_ text: String, unit: LoadUnit, current: Double?) -> Double? {
        switch edit(text, unit: unit, current: current) {
        case .set(let v): return v
        case .clear, .invalid: return 0
        case .unchanged: return nil
        }
    }

    /// The Max load field: set, clear, or leave alone.
    enum MaxWrite: Equatable { case set(Double), clear, none }
    static func maxLoadWrite(_ text: String, unit: LoadUnit, current: Double?) -> MaxWrite {
        switch edit(text, unit: unit, current: current) {
        case .set(let v): return .set(v)
        case .clear, .invalid: return .clear
        case .unchanged: return .none
        }
    }

    /// The stored lb load for `text` typed in `unit`, or nil when nothing should be written: the text is empty or
    /// invalid, or it shows the same value `currentStoredLb` already displays as. The second rule is what stops
    /// edit -> save from rewriting a stored 102.5 lb as the 46.49 kg it displays as (drift).
    static func storedLb(from text: String, unit: LoadUnit, currentStoredLb: Double? = nil) -> Double? {
        guard let typed = number(from: text) else { return nil }
        if let current = currentStoredLb {
            let shown = LoadFormatter(unit: unit).number(current)
            if let shownValue = Double(shown), abs(shownValue - typed) < 1e-9 { return nil }
        }
        return unit.toStoredLb(typed)
    }
}

// MARK: - Computed loads

/// Rounding of every load the app computes, done in the lifter's unit: stored lb -> unit -> round to the lifter's
/// increment -> back to lb. A kg lifter's loads therefore land on 1.25 / 2.5 kg steps, not on 102.5 lb. lb is the
/// identity path, so lb results are bit-identical to the pre-kg arithmetic.
///
/// `increment` is ALWAYS in `unit` (that is how `UserProfile.minLoadIncrement` is stored).
enum UnitAwareRounding {

    enum Mode {
        /// Nearest increment.
        case nearest
        /// Floor to the increment (float-noise tolerant).
        case down
        /// Floor, but a load within `nearMissFraction` of the next increment takes it (HistorySeedLoad's rule).
        case nearMissDown
    }

    /// Share of one increment (not of the load) that counts as "a near miss" for `.nearMissDown`.
    static let nearMissFraction = 0.2

    static func round(_ storedLb: Double, increment: Double, unit: LoadUnit, mode: Mode = .nearest) -> Double {
        guard increment > 0 else { return storedLb }
        let x = unit.fromStoredLb(storedLb)
        let r: Double
        switch mode {
        case .nearest:
            r = (x / increment).rounded() * increment
        case .down:
            r = ((x / increment) + 1e-9).rounded(.down) * increment
        case .nearMissDown:
            let floored = ((x / increment) + 1e-9).rounded(.down) * increment
            let next = floored + increment
            r = next - x < nearMissFraction * increment - 1e-9 ? next : floored
        }
        return unit.toStoredLb(r)
    }

    /// A warm-up ramp load: barbell ramps step by the coarse default (lb 5, kg 2.5), dumbbell / machine / cable by the
    /// fine one (lb 2.5, kg 1.25). The ramp is a fixed convention, not the lifter's `minLoadIncrement`.
    static func warmupRamp(_ storedLb: Double, coarse: Bool, unit: LoadUnit) -> Double {
        round(storedLb, increment: defaultIncrement(unit: unit, coarse: coarse), unit: unit)
    }

    /// One step, as a stored-lb amount, for adding to or subtracting from a stored load.
    static func stepLb(_ increment: Double, unit: LoadUnit) -> Double {
        unit.toStoredLb(increment)
    }

    // MARK: Default increments (in `unit`)

    /// The two chip values onboarding offers beyond the plate-pair step: lb 2.5 / 5, kg 1.25 / 2.5.
    static func defaultIncrement(unit: LoadUnit, coarse: Bool = false) -> Double {
        switch unit {
        case .lb: return coarse ? 5.0 : 2.5
        case .kg: return coarse ? 2.5 : 1.25
        }
    }

    /// Onboarding chip values, in `unit`.
    static func incrementChoices(unit: LoadUnit) -> [Double] {
        unit == .lb ? [1.25, 2.5, 5.0] : [0.5, 1.25, 2.5]
    }

    /// Base-scaled fallback when the lifter has no increment on file (in `unit`). lb: >=200 -> 5, >=100 -> 2.5, else 2.
    /// kg: the same bands at 90 / 45 kg -> 2.5 / 1.25 / 1.
    static func fallbackIncrement(forBaseLb baseLb: Double, unit: LoadUnit) -> Double {
        switch unit {
        case .lb: return baseLb >= 200 ? 5.0 : (baseLb >= 100 ? 2.5 : 2.0)
        case .kg:
            let kg = unit.fromStoredLb(baseLb)
            return kg >= 90 ? 2.5 : (kg >= 45 ? 1.25 : 1.0)
        }
    }

    /// Fallback that never returns less than the smallest sensible step (the earned-bump increment).
    /// lb: >=200 -> 5, else 2.5. kg: >=90 -> 2.5, else 1.25.
    static func bumpFallbackIncrement(forBaseLb baseLb: Double, unit: LoadUnit) -> Double {
        switch unit {
        case .lb: return baseLb >= 200 ? 5.0 : 2.5
        case .kg: return unit.fromStoredLb(baseLb) >= 90 ? 2.5 : 1.25
        }
    }

    /// A catalog increment written in lb (cluster configs: 10 / 5 / 2.5 / 1) expressed as a step in `unit`.
    /// lb unchanged; kg is the nearest multiple of 1.25 (at least 1.25 for any positive input). 0 stays 0.
    static func increment(fromLb lbStep: Double, unit: LoadUnit) -> Double {
        guard unit == .kg, lbStep > 0 else { return lbStep }
        return max(1.25, ((lbStep * LoadUnit.kgPerLb) / 1.25).rounded() * 1.25)
    }
}
