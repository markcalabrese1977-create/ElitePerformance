import XCTest
@testable import ElitePerformance

/// K1: LoadUnit conversion, LoadFormatter(unit), LoadInput, UnitAwareRounding, UserProfile.loadUnit.
final class LoadUnitTests: XCTestCase {

    // MARK: Conversion

    func test_exactConversionFactor() {
        XCTAssertEqual(LoadUnit.kgPerLb, 0.45359237)
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(1), 0.45359237, accuracy: 1e-12)
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(100), 45.359237, accuracy: 1e-9)
        XCTAssertEqual(LoadUnit.kg.toStoredLb(0.45359237), 1, accuracy: 1e-12)
    }

    func test_lbIsTheIdentity() {
        for v in [0.0, 2.5, 102.5, 135, 317.3333333] {
            XCTAssertEqual(LoadUnit.lb.fromStoredLb(v), v)
            XCTAssertEqual(LoadUnit.lb.toStoredLb(v), v)
        }
    }

    func test_kgRoundTrip() {
        for kg in [1.25, 20, 46.5, 100, 142.5] {
            XCTAssertEqual(LoadUnit.kg.fromStoredLb(LoadUnit.kg.toStoredLb(kg)), kg, accuracy: 1e-9)
        }
    }

    // MARK: Formatter

    func test_lbFormatterMatchesThePreKgOutput() {
        let f = LoadFormatter(unit: .lb)
        XCTAssertEqual(f.number(135), "135")
        XCTAssertEqual(f.number(132.5), "132.5")
        XCTAssertEqual(f.text(135), "135 lb")
        XCTAssertEqual(f.unitLabel, "lb")
        XCTAssertEqual(LoadFormatter.text(2.5), f.text(2.5))
        XCTAssertEqual(LoadFormatter.number(132.5), f.number(132.5))
    }

    func test_kgFormatterTrimsZerosAndCapsAtTwoDecimals() {
        let f = LoadFormatter(unit: .kg)
        XCTAssertEqual(f.number(LoadUnit.kg.toStoredLb(45)), "45")
        XCTAssertEqual(f.number(LoadUnit.kg.toStoredLb(46.5)), "46.5")
        XCTAssertEqual(f.number(LoadUnit.kg.toStoredLb(46.25)), "46.25")
        XCTAssertEqual(f.number(102.5), "46.49")          // 102.5 lb = 46.4939 kg
        XCTAssertEqual(f.text(100), "45.36 kg")
        XCTAssertEqual(f.number(0), "0")
        XCTAssertEqual(f.textInUnit(1.25), "1.25 kg")
        XCTAssertEqual(f.textInUnit(2.5), "2.5 kg")
        XCTAssertEqual(LoadFormatter(unit: .lb).textInUnit(5), "5 lb")
    }

    // MARK: LoadInput

    func test_inputConvertsTypedTextToStoredLb() throws {
        XCTAssertEqual(try XCTUnwrap(LoadInput.storedLb(from: "135", unit: .lb)), 135)
        XCTAssertEqual(try XCTUnwrap(LoadInput.storedLb(from: "46,5", unit: .kg)), 46.5 / LoadUnit.kgPerLb, accuracy: 1e-9)
        XCTAssertNil(LoadInput.storedLb(from: "", unit: .kg))
        XCTAssertNil(LoadInput.storedLb(from: "abc", unit: .lb))
        XCTAssertNil(LoadInput.storedLb(from: "-5", unit: .lb))
    }

    func test_inputIsANoOpWhenTheTextIsTheCurrentDisplayedValue() {
        // 102.5 lb displays as "46.49" kg. Re-saving that text must not rewrite the stored 102.5 lb.
        XCTAssertNil(LoadInput.storedLb(from: "46.49", unit: .kg, currentStoredLb: 102.5))
        XCTAssertNil(LoadInput.storedLb(from: " 46.490 ", unit: .kg, currentStoredLb: 102.5))
        XCTAssertNil(LoadInput.storedLb(from: "135", unit: .lb, currentStoredLb: 135))
        XCTAssertNil(LoadInput.storedLb(from: "135.0", unit: .lb, currentStoredLb: 135))
        // A real change writes.
        XCTAssertNotNil(LoadInput.storedLb(from: "46.5", unit: .kg, currentStoredLb: 102.5))
        XCTAssertNotNil(LoadInput.storedLb(from: "140", unit: .lb, currentStoredLb: 135))
    }

    // MARK: Rounding

    func test_lbRoundingIsBitIdenticalToTheOldArithmetic() {
        for load in [0.0, 17.3, 99.99999999, 102.5, 133.3333, 319.2, 318.5, 500.1] {
            for inc in [1.25, 2.5, 5.0] {
                XCTAssertEqual(UnitAwareRounding.round(load, increment: inc, unit: .lb),
                               (load / inc).rounded() * inc)
                XCTAssertEqual(UnitAwareRounding.round(load, increment: inc, unit: .lb, mode: .nearMissDown),
                               oldRoundedDown(load, inc))
            }
        }
        XCTAssertEqual(UnitAwareRounding.round(123.4, increment: 0, unit: .lb), 123.4)
    }

    func test_kgRoundingLandsOnExactKgStepsAfterTheRoundTrip() {
        for storedLb in [100.0, 102.5, 133.3, 185.0, 225.0, 317.9, 61.0] {
            for (inc, mode) in [(1.25, UnitAwareRounding.Mode.nearest), (2.5, .nearest), (2.5, .down), (1.25, .nearMissDown)] {
                let r = UnitAwareRounding.round(storedLb, increment: inc, unit: .kg, mode: mode)
                let kg = LoadUnit.kg.fromStoredLb(r)
                let steps = kg / inc
                XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9, "\(storedLb) lb @ \(inc) kg \(mode) -> \(kg) kg")
            }
        }
        // 102.5 lb is 46.49 kg: nearest 2.5 kg step is 47.5 kg, nearest 1.25 is 46.25.
        XCTAssertEqual(LoadFormatter(unit: .kg).number(UnitAwareRounding.round(102.5, increment: 2.5, unit: .kg)), "47.5")
        XCTAssertEqual(LoadFormatter(unit: .kg).number(UnitAwareRounding.round(102.5, increment: 1.25, unit: .kg)), "46.25")
    }

    func test_downNeverExceedsTheInputAndToleratesFloatNoise() {
        let kg100 = LoadUnit.kg.toStoredLb(100)
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(UnitAwareRounding.round(kg100, increment: 2.5, unit: .kg, mode: .down)), 100, accuracy: 1e-9)
        let r = UnitAwareRounding.round(LoadUnit.kg.toStoredLb(101.9), increment: 2.5, unit: .kg, mode: .down)
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(r), 100, accuracy: 1e-9)
    }

    /// The near-miss window is a share of the step, so a load at the same fraction of a step behaves the same in both units.
    func test_nearMissRuleIsIdenticalInBothUnits() {
        let cases: [(LoadUnit, Double)] = [(.lb, 5.0), (.kg, 2.5)]
        for (unit, inc) in cases {
            func rounded(_ stepsAbove: Double) -> Double {
                // `stepsAbove` steps above 40 whole steps, in the unit.
                let x = 40 * inc + stepsAbove * inc
                let r = UnitAwareRounding.round(unit.toStoredLb(x), increment: inc, unit: unit, mode: .nearMissDown)
                return (unit.fromStoredLb(r) / inc).rounded()
            }
            XCTAssertEqual(rounded(0.84), 41, "\(unit): 0.16 of a step short takes the next step")
            XCTAssertEqual(rounded(0.81), 41, "\(unit)")
            XCTAssertEqual(rounded(0.79), 40, "\(unit): 0.21 short stays down")
            XCTAssertEqual(rounded(0.5), 40, "\(unit)")
            XCTAssertEqual(rounded(0.0), 40, "\(unit)")
            XCTAssertEqual(rounded(1.0), 41, "\(unit): a whole step stays")
        }
        // The documented lb examples.
        XCTAssertEqual(UnitAwareRounding.round(319.2, increment: 5, unit: .lb, mode: .nearMissDown), 320)
        XCTAssertEqual(UnitAwareRounding.round(318.5, increment: 5, unit: .lb, mode: .nearMissDown), 315)
        XCTAssertEqual(UnitAwareRounding.round(104, increment: 5, unit: .lb, mode: .nearMissDown), 100)
    }

    func test_defaultAndFallbackIncrementsPerUnit() {
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .lb), 2.5)
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .lb, coarse: true), 5)
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .kg), 1.25)
        XCTAssertEqual(UnitAwareRounding.defaultIncrement(unit: .kg, coarse: true), 2.5)
        // lb: exactly the old bands.
        XCTAssertEqual(UnitAwareRounding.fallbackIncrement(forBaseLb: 250, unit: .lb), 5)
        XCTAssertEqual(UnitAwareRounding.fallbackIncrement(forBaseLb: 150, unit: .lb), 2.5)
        XCTAssertEqual(UnitAwareRounding.fallbackIncrement(forBaseLb: 50, unit: .lb), 2)
        XCTAssertEqual(UnitAwareRounding.bumpFallbackIncrement(forBaseLb: 250, unit: .lb), 5)
        XCTAssertEqual(UnitAwareRounding.bumpFallbackIncrement(forBaseLb: 50, unit: .lb), 2.5)
        // kg: the same bands at 90 / 45 kg.
        XCTAssertEqual(UnitAwareRounding.fallbackIncrement(forBaseLb: LoadUnit.kg.toStoredLb(100), unit: .kg), 2.5)
        XCTAssertEqual(UnitAwareRounding.fallbackIncrement(forBaseLb: LoadUnit.kg.toStoredLb(60), unit: .kg), 1.25)
        XCTAssertEqual(UnitAwareRounding.fallbackIncrement(forBaseLb: LoadUnit.kg.toStoredLb(20), unit: .kg), 1)
        XCTAssertEqual(UnitAwareRounding.bumpFallbackIncrement(forBaseLb: LoadUnit.kg.toStoredLb(100), unit: .kg), 2.5)
        XCTAssertEqual(UnitAwareRounding.bumpFallbackIncrement(forBaseLb: LoadUnit.kg.toStoredLb(20), unit: .kg), 1.25)
    }

    func test_warmupRamp_lbMatchesTheOldArithmeticAndKgUsesKgSteps() {
        for v in [0.0, 47.3, 112.6, 183.9, 301.2] {
            XCTAssertEqual(UnitAwareRounding.warmupRamp(v, coarse: true, unit: .lb), (v / 5.0).rounded() * 5.0)
            XCTAssertEqual(UnitAwareRounding.warmupRamp(v, coarse: false, unit: .lb), (v / 2.5).rounded() * 2.5)
        }
        for kg in [37.3, 61.1, 83.4, 118.9] {
            let lb = LoadUnit.kg.toStoredLb(kg)
            let barbell = LoadUnit.kg.fromStoredLb(UnitAwareRounding.warmupRamp(lb, coarse: true, unit: .kg)) / 2.5
            let light = LoadUnit.kg.fromStoredLb(UnitAwareRounding.warmupRamp(lb, coarse: false, unit: .kg)) / 1.25
            XCTAssertEqual(barbell, barbell.rounded(), accuracy: 1e-9)
            XCTAssertEqual(light, light.rounded(), accuracy: 1e-9)
        }
        // 33.9 kg: nearest 2.5 kg barbell step is 35, nearest 1.25 kg step is 33.75.
        let lb33 = LoadUnit.kg.toStoredLb(33.9)
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(UnitAwareRounding.warmupRamp(lb33, coarse: true, unit: .kg)), 35, accuracy: 1e-9)
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(UnitAwareRounding.warmupRamp(lb33, coarse: false, unit: .kg)), 33.75, accuracy: 1e-9)
    }

    func test_catalogLbIncrementsMapToKgSteps() {
        for lbStep in [10.0, 5.0, 2.5, 1.0, 0.0] {
            XCTAssertEqual(UnitAwareRounding.increment(fromLb: lbStep, unit: .lb), lbStep)
        }
        XCTAssertEqual(UnitAwareRounding.increment(fromLb: 10, unit: .kg), 5)
        XCTAssertEqual(UnitAwareRounding.increment(fromLb: 5, unit: .kg), 2.5)
        XCTAssertEqual(UnitAwareRounding.increment(fromLb: 2.5, unit: .kg), 1.25)
        XCTAssertEqual(UnitAwareRounding.increment(fromLb: 1, unit: .kg), 1.25)
        XCTAssertEqual(UnitAwareRounding.increment(fromLb: 0, unit: .kg), 0)
    }

    func test_stepLbConvertsAnIncrementForAddingToAStoredLoad() {
        XCTAssertEqual(UnitAwareRounding.stepLb(5, unit: .lb), 5)
        XCTAssertEqual(UnitAwareRounding.stepLb(2.5, unit: .kg), 2.5 / LoadUnit.kgPerLb, accuracy: 1e-12)
    }

    // MARK: Profile accessor

    func test_profileUnitDefaultsToLbAndStoresNilForLb() {
        let p = UserProfile()
        XCTAssertNil(p.unitRaw)
        XCTAssertEqual(p.loadUnit, .lb)
        p.loadUnit = .kg
        XCTAssertEqual(p.unitRaw, "kg")
        XCTAssertEqual(p.loadUnit, .kg)
        p.loadUnit = .lb
        XCTAssertNil(p.unitRaw)
        p.unitRaw = "garbage"
        XCTAssertEqual(p.loadUnit, .lb)
        XCTAssertEqual(UserProfile(unit: .kg).loadUnit, .kg)
    }

    private func oldRoundedDown(_ load: Double, _ increment: Double) -> Double {
        let floored = ((load / increment) + 1e-9).rounded(.down) * increment
        let next = floored + increment
        if next - load < 0.2 * increment - 1e-9 { return next }
        return floored
    }
}

// MARK: - Loads show exactly as entered (one test per formatter); computed values show at most one decimal

final class LoadDisplayExactTests: XCTestCase {
    private let lb = LoadFormatter(unit: .lb)
    private let kg = LoadFormatter(unit: .kg)
    /// Loads a lifter can type: whole, half, a 1.25-lb step, a quarter, a 2.5-kg step in lb.
    private let entered: [(Double, String)] = [(145, "145"), (22.5, "22.5"), (22.25, "22.25"), (1.25, "1.25"), (100.5, "100.5"), (0, "0"), (315, "315"), (7.5, "7.5")]

    func test_number_isExact() {
        for (v, text) in entered { XCTAssertEqual(lb.number(v), text, "\(v)") }
        XCTAssertEqual(LoadFormatter.number(22.25), "22.25")
        XCTAssertEqual(kg.number(LoadUnit.kg.toStoredLb(22.5)), "22.5")
        XCTAssertEqual(kg.number(LoadUnit.kg.toStoredLb(45)), "45")
        XCTAssertEqual(kg.number(LoadUnit.kg.toStoredLb(1.25)), "1.25")
    }
    func test_oneDecimal_isExact_noTrailingZero_neverRounded() {
        for (v, text) in entered { XCTAssertEqual(lb.oneDecimal(v), text, "\(v)") }
        XCTAssertEqual(kg.oneDecimal(LoadUnit.kg.toStoredLb(22.5)), "22.5")
    }
    func test_compact_isExact_neverRounded() {
        for (v, text) in entered { XCTAssertEqual(lb.compact(v), text, "\(v)") }
        XCTAssertEqual(kg.compact(LoadUnit.kg.toStoredLb(62.5)), "62.5")
    }
    func test_zeroOrOneDecimal_isExact() {
        for (v, text) in entered { XCTAssertEqual(lb.zeroOrOneDecimal(v), text, "\(v)") }
    }
    func test_setLoad_isExact_aLoggedTwentyTwoPointFiveIsNotTwentyTwo() {
        for (v, text) in entered { XCTAssertEqual(lb.setLoad(v), text, "\(v)") }
        XCTAssertEqual(kg.setLoad(LoadUnit.kg.toStoredLb(22.5)), "22.5")
    }
    func test_truncated_isExact_neverTruncates() {
        for (v, text) in entered { XCTAssertEqual(lb.truncated(v), text, "\(v)") }
    }
    func test_text_and_numberInUnit_areExact() {
        XCTAssertEqual(lb.text(22.5), "22.5 lb")
        XCTAssertEqual(lb.text(145), "145 lb")
        XCTAssertEqual(lb.numberInUnit(2.5), "2.5")
        XCTAssertEqual(lb.numberInUnit(5), "5")
    }
    func test_computedValues_showAtMostOneDecimal() {
        XCTAssertEqual(lb.whole(216.43), "216", "an e1RM is whole")
        XCTAssertEqual(lb.wholeGrouped(1234.56), "1,235")
        XCTAssertEqual(lb.volumeGrouped(905_432.2), "905,432")
        XCTAssertEqual(String(format: "%.1f", 14.0 / 3.0), "4.7", "averages use one decimal")
    }
    func test_planLine_and_coachLines_showTheLoadAsEntered() {
        EffortTracking.mode = .detailed
        defer { EffortTracking.clearMirror() }
        let it = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 140, repMin: 8, repMax: 10)
        it.actualReps = [10, 10, 10]; it.actualLoads = [140, 140, 140]; it.actualRIRs = [2, 2, 2]
        it.plannedRepsBySet = [10, 10, 10]
        let msg = CoachingEngine.recommend(for: it, policy: .shipped, minLoadIncrement: 5)?.message ?? ""
        XCTAssertFalse(msg.contains(".0"), msg)
        XCTAssertTrue(msg.contains("145"), msg)
        let half = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 22.5, repMin: 8, repMax: 10)
        half.actualReps = [10, 10, 10]; half.actualLoads = [22.5, 22.5, 22.5]; half.actualRIRs = [2, 2, 2]
        half.plannedRepsBySet = [10, 10, 10]
        let m2 = CoachingEngine.recommend(for: half, policy: .shipped, minLoadIncrement: 2.5)?.message ?? ""
        XCTAssertTrue(m2.contains("25"), m2)
        XCTAssertFalse(m2.contains("25.0"), m2)
    }
}

// MARK: - Planned effort reads as an aim, never as a logged tap

final class PlannedEffortLabelTests: XCTestCase {
    override func tearDown() { EffortTracking.clearMirror(); super.tearDown() }

    func test_aimText_followsTheMode() {
        XCTAssertEqual(EffortTracking.aimText(0, mode: .detailed), "aim: 0 RIR")
        XCTAssertEqual(EffortTracking.aimText(0, mode: .simple), "aim: All out")
        XCTAssertEqual(EffortTracking.aimText(2, mode: .simple), "aim: Solid")
        XCTAssertNil(EffortTracking.aimText(2, mode: .off))
        XCTAssertEqual(EffortTracking.aimRangeText(1, 2, mode: .detailed), "aim: 1–2 RIR")
        XCTAssertEqual(EffortTracking.aimRangeText(0, 1, mode: .simple), "aim: Hard–All out")
        XCTAssertNil(EffortTracking.aimRangeText(1, 2, mode: .off))
    }
    func test_plannedSuffix_isAnAim_andLoggedSuffixIsNot() {
        XCTAssertEqual(EffortTracking.plannedSuffix(0, mode: .detailed), " · aim: 0 RIR")
        XCTAssertEqual(EffortTracking.plannedSuffix(0, mode: .simple), " · aim: All out")
        XCTAssertEqual(EffortTracking.plannedSuffix(0, mode: .off), "")
        XCTAssertEqual(EffortTracking.loggedSuffix(0, mode: .detailed), " @ 0 RIR")
        XCTAssertEqual(EffortTracking.loggedSuffix(0, mode: .simple), " · All out")
        XCTAssertFalse(EffortTracking.plannedSuffix(0, mode: .detailed).contains("@"), "a plan never uses the logged form")
    }
    func test_extraSetAndPlanLines_carryTheAim() {
        EffortTracking.mode = .detailed
        XCTAssertEqual(UISessionSet.extraSetLabel(repRange: RepRange(min: 6, max: 8), rir: 0), "OPTIONAL EXTRA SET  6-8 reps · aim: 0 RIR")
        EffortTracking.mode = .simple
        XCTAssertEqual(UISessionSet.extraSetLabel(repRange: RepRange(min: 6, max: 8), rir: 0), "OPTIONAL EXTRA SET  6-8 reps · aim: All out")
    }
    func test_styledText_marksOnlyTheAim() {
        // The aim chunk is the italic part: it starts at "aim:" and the text before it is untouched.
        let line = "Week 9 · Chest · 4 sets · 8–10 reps · aim: 0 RIR"
        let r = line.range(of: "aim:")
        XCTAssertNotNil(r)
        XCTAssertEqual(String(line[line.startIndex..<r!.lowerBound]), "Week 9 · Chest · 4 sets · 8–10 reps · ")
        XCTAssertEqual(String(line[r!.lowerBound...]), "aim: 0 RIR")
    }
}
