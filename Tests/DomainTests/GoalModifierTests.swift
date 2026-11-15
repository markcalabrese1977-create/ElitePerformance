import XCTest
import SwiftData
@testable import ElitePerformance

/// GoalModifier: Build muscle is the identity, Get stronger shifts anchors' rep ranges, Lose fat and General fitness
/// reshape the set ramp (and RIR for General fitness). Numbers are checked on the 3-day PPL template's bench press
/// (anchor, compound, sets 3-4-4-4-4-5-4-5-5-2) and cable pushdown (isolation, sets 3-3-3-3-4-4-3-4-4-2).
final class GoalModifierTests: XCTestCase {

    private let ppl = PPL3WeekTemplate.template

    private func slot(_ t: ProgramTemplate, _ id: String) -> ProgramExerciseTemplate {
        t.dayTemplates.flatMap(\.exerciseTemplates).first { $0.id == id }!
    }

    private func rx(_ s: ProgramExerciseTemplate, _ wave: WaveType) -> (Int, Int, Int, Int) {
        let p = s.prescription(for: wave)!
        return (p.repMin, p.repMax, p.targetRIRMin, p.targetRIRMax)
    }

    private static func json(_ t: ProgramTemplate) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(data: try! enc.encode(t), encoding: .utf8)!
    }

    private static let templates: [ProgramTemplate] = ExerciseTraitsCoverageTests.templates

    // MARK: Build muscle

    func test_buildMuscle_isByteIdentical_forEveryTemplate() {
        for t in Self.templates {
            let (out, notes) = GoalModifier.apply(t, goal: .hypertrophy)
            XCTAssertEqual(Self.json(out), Self.json(t), t.name)
            XCTAssertTrue(notes.isEmpty)
        }
    }

    // MARK: Get stronger

    func test_strength_shiftsAnchorRepRangesDownOneBand_exactNumbers() {
        let (out, notes) = GoalModifier.apply(ppl, goal: .strength)
        let bench = slot(out, "ppl_push_bench")
        XCTAssertTrue(rx(bench, .a) == (8, 10, 3, 3), "10-12 -> 8-10")
        XCTAssertTrue(rx(bench, .b) == (6, 8, 2, 2), "8-10 -> 6-8")
        XCTAssertTrue(rx(bench, .c) == (4, 6, 1, 2), "6-8 -> 4-6")
        XCTAssertTrue(rx(bench, .deload) == (10, 12, 4, 4), "deload is untouched")
        XCTAssertEqual(bench.setsByWeek, [3, 4, 4, 4, 4, 5, 4, 5, 5, 2], "sets are untouched")
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].message.hasPrefix("Get stronger"))
    }

    func test_strength_changesAnchorsOnly() {
        for t in Self.templates {
            let (out, _) = GoalModifier.apply(t, goal: .strength)
            var anchorsChanged = 0
            for (d, day) in t.dayTemplates.enumerated() {
                for (i, before) in day.exerciseTemplates.enumerated() {
                    let after = out.dayTemplates[d].exerciseTemplates[i]
                    XCTAssertEqual(after.setsByWeek, before.setsByWeek, "\(t.name) \(before.id): sets never change")
                    XCTAssertEqual(after.priority, before.priority)
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.sortedKeys]
                    let same = (try? enc.encode(after.prescriptions)) == (try? enc.encode(before.prescriptions))
                    if before.priority == .anchor { if !same { anchorsChanged += 1 } }
                    else { XCTAssertTrue(same, "\(t.name) \(before.id): an accessory changed") }
                }
            }
            XCTAssertGreaterThan(anchorsChanged, 0, t.name)
        }
    }

    func test_strength_floors_repMinNeverBelowThree_andRangeStaysValid() {
        func wave(_ lo: Int, _ hi: Int) -> WavePrescription {
            WavePrescription(wave: .a, setMin: 3, setMax: 3, repMin: lo, repMax: hi, targetRIRMin: 2, targetRIRMax: 2)
        }
        let a = GoalModifier.shiftedDown(wave(4, 6))
        XCTAssertEqual([a.repMin, a.repMax], [3, 4], "repMin 4-2 would be 2: floored at 3")
        let b = GoalModifier.shiftedDown(wave(3, 5))
        XCTAssertEqual([b.repMin, b.repMax], [3, 3], "already at the floor")
        let c = GoalModifier.shiftedDown(wave(5, 5))
        XCTAssertEqual([c.repMin, c.repMax], [3, 3])
        let d = GoalModifier.shiftedDown(wave(2, 4))
        XCTAssertEqual([d.repMin, d.repMax], [2, 2], "a repMin already below 3 is not raised")
        let skipped = GoalModifier.shiftedDown(wave(0, 0))
        XCTAssertEqual([skipped.repMin, skipped.repMax], [0, 0])
        for t in Self.templates {
            for ex in GoalModifier.apply(t, goal: .strength).0.dayTemplates.flatMap(\.exerciseTemplates) {
                for p in ex.prescriptions where p.repMax > 0 {
                    XCTAssertLessThanOrEqual(p.repMin, p.repMax, "\(ex.id)")
                    XCTAssertGreaterThanOrEqual(p.repMin, min(3, p.repMin))
                }
            }
        }
    }

    // MARK: Lose fat

    func test_fatLoss_holdsSetsSteady_exactArrays() {
        // PPL: bench (anchor) caps at week 1 + 1 = 4; pushdown (isolation) holds at its week-1 count of 3; deload untouched
        let (out, notes) = GoalModifier.apply(ppl, goal: .fatLoss)
        XCTAssertEqual(slot(out, "ppl_push_bench").setsByWeek, [3, 4, 4, 4, 4, 4, 4, 4, 4, 2])
        XCTAssertEqual(slot(out, "ppl_push_pushdown").setsByWeek, [3, 3, 3, 3, 3, 3, 3, 3, 3, 2])
        XCTAssertEqual(slot(out, "ppl_push_lateral").setsByWeek, [3, 3, 3, 3, 3, 3, 3, 3, 3, 2], "isolation")
        XCTAssertEqual(slot(out, "ppl_push_incline_db").setsByWeek, slot(ppl, "ppl_push_incline_db").setsByWeek, "a compound that never exceeds week 1 + 1 is unchanged")
        // 10-week DUP: pushdown 3,3,3,3,3,3,3,4,3,2 -> 3,3,3,3,3,3,3,3,3,2 (week 8's 4 is held at 3)
        let dup = DUP10WeekTemplate.template
        let (dupOut, _) = GoalModifier.apply(dup, goal: .fatLoss)
        XCTAssertEqual(slot(dup, "d1_pushdown").setsByWeek, [3, 3, 3, 3, 3, 3, 3, 4, 3, 2], "the template's own array")
        XCTAssertEqual(slot(dupOut, "d1_pushdown").setsByWeek, [3, 3, 3, 3, 3, 3, 3, 3, 3, 2])
        XCTAssertEqual(slot(dupOut, "d4_pushdown").setsByWeek, [3, 3, 3, 3, 3, 3, 3, 3, 3, 2])
        // DUP bench (compound): capped at week 1 + 1, so a template ramp above that is cut
        let dupBench = slot(dup, "d1_bench")
        XCTAssertEqual(slot(dupOut, "d1_bench").setsByWeek, dupBench.setsByWeek.enumerated().map { i, v in
            i == dupBench.setsByWeek.count - 1 ? v : min(v, dupBench.setsByWeek[0] + 1)
        })
        // reps and RIR untouched
        XCTAssertTrue(rx(slot(out, "ppl_push_bench"), .c) == rx(slot(ppl, "ppl_push_bench"), .c))
        XCTAssertEqual(notes.map(\.message).filter { $0.hasPrefix("Lose fat") }.count, notes.count)
        XCTAssertEqual(notes.count, 2, "one note for the main-lift cap, one for isolation")
        XCTAssertFalse(notes.contains { $0.message.contains("week 5") || $0.message.contains("lose 1 set") }, "the midpoint trim is gone")
    }

    func test_fatLoss_isolationNeverBelowItsStartingCount_andNothingIsRaised_andDeloadUntouched() {
        // an isolation slot that never ramps is unchanged and says nothing
        let flat = syntheticTemplate(sets: [2, 2, 2, 2, 2, 2, 2, 2, 2, 2], exerciseId: "cable_tricep_rope_pushdown")
        let (flatOut, notes) = GoalModifier.apply(flat, goal: .fatLoss)
        XCTAssertEqual(flatOut.dayTemplates[0].exerciseTemplates[0].setsByWeek, [2, 2, 2, 2, 2, 2, 2, 2, 2, 2])
        XCTAssertTrue(notes.isEmpty, "nothing changed, nothing to say")
        // a week below week 1 is left alone (never raised); a skipped week stays skipped
        let dips = syntheticTemplate(sets: [4, 3, 5, 0, 4, 6, 3, 3, 3, 2], exerciseId: "cable_tricep_rope_pushdown")
        XCTAssertEqual(GoalModifier.apply(dips, goal: .fatLoss).0.dayTemplates[0].exerciseTemplates[0].setsByWeek, [4, 3, 4, 0, 4, 4, 3, 3, 3, 2])
        // compounds keep the +1 cap
        let climbing = syntheticTemplate(sets: [3, 4, 5, 6, 3, 3, 3, 3, 3, 2], exerciseId: "bench_press")
        XCTAssertEqual(GoalModifier.apply(climbing, goal: .fatLoss).0.dayTemplates[0].exerciseTemplates[0].setsByWeek, [3, 4, 4, 4, 3, 3, 3, 3, 3, 2])
        // deload weeks are never touched, even above the cap
        let deloadHigh = syntheticTemplate(sets: [3, 3, 3, 3, 3, 3, 3, 3, 3, 5], exerciseId: "cable_tricep_rope_pushdown")
        XCTAssertEqual(GoalModifier.apply(deloadHigh, goal: .fatLoss).0.dayTemplates[0].exerciseTemplates[0].setsByWeek.last, 5)
    }

    // MARK: General fitness

    func test_generalFitness_exactNumbers() {
        let (out, notes) = GoalModifier.apply(ppl, goal: .longevity)
        let bench = slot(out, "ppl_push_bench")
        // cap at 4 first, then -1 above 2; the deload week is untouched
        XCTAssertEqual(bench.setsByWeek, [2, 3, 3, 3, 3, 3, 3, 3, 3, 2])
        XCTAssertEqual(slot(out, "ppl_push_pushdown").setsByWeek, [2, 2, 2, 2, 3, 3, 2, 3, 3, 2])
        // RIR +1, capped at 3: 3 stays 3, 2 -> 3, 1-2 -> 2-3; deload (4) untouched
        XCTAssertTrue(rx(bench, .a) == (10, 12, 3, 3))
        XCTAssertTrue(rx(bench, .b) == (8, 10, 3, 3))
        XCTAssertTrue(rx(bench, .c) == (6, 8, 2, 3))
        XCTAssertTrue(rx(bench, .deload) == (10, 12, 4, 4))
        XCTAssertEqual(notes.count, 3, "ramp cap, fewer sets, more reps in reserve")
        XCTAssertTrue(notes.allSatisfy { $0.message.hasPrefix("General fitness") })
    }

    func test_generalFitness_floors() {
        let t = syntheticTemplate(sets: [3, 3, 3, 3, 3, 3, 3, 3, 3, 2], exerciseId: "bench_press")
        let out = GoalModifier.apply(t, goal: .longevity).0.dayTemplates[0].exerciseTemplates[0]
        XCTAssertEqual(out.setsByWeek, [2, 2, 2, 2, 2, 2, 2, 2, 2, 2], "3 -> 2, never below 2")
        let low = syntheticTemplate(sets: [2, 2, 2, 2, 2, 2, 2, 2, 2, 2], exerciseId: "bench_press")
        XCTAssertEqual(GoalModifier.apply(low, goal: .longevity).0.dayTemplates[0].exerciseTemplates[0].setsByWeek,
                       [2, 2, 2, 2, 2, 2, 2, 2, 2, 2])
        for t in Self.templates {
            for ex in GoalModifier.apply(t, goal: .longevity).0.dayTemplates.flatMap(\.exerciseTemplates) {
                for p in ex.prescriptions where p.wave != .deload {
                    XCTAssertLessThanOrEqual(p.targetRIRMax, max(3, p.targetRIRMax))
                }
            }
        }
    }

    // MARK: Preview and seed agree

    private func syntheticTemplate(sets: [Int], exerciseId: String) -> ProgramTemplate {
        let rules = (1...sets.count).map { w in
            ProgramWeekRule(weekNumber: w, wave: w == sets.count ? .deload : [WaveType.a, .b, .c][(w - 1) % 3], notes: nil)
        }
        let slot = ProgramExerciseTemplate(
            id: "s1", order: 1, exerciseId: exerciseId, priority: .standard,
            prescriptions: [
                .init(wave: .a, setMin: 3, setMax: 3, repMin: 10, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                .init(wave: .b, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2),
                .init(wave: .c, setMin: 3, setMax: 3, repMin: 6, repMax: 8, targetRIRMin: 1, targetRIRMax: 2),
                .init(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 12, targetRIRMin: 4, targetRIRMax: 4)
            ],
            setsByWeek: sets)
        return ProgramTemplate(id: "syn", name: "syn", totalWeeks: sets.count, trainingDaysPerWeek: 1, weekRules: rules,
                               dayTemplates: [ProgramDayTemplate(id: "d1", dayNumber: 1, title: "Day", role: "", exerciseTemplates: [slot])])
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    private func result(goal: Goal, days: Int = 3, preset: EquipmentPreset = .fullGym, minutes: Int = 120) -> OnboardingResult {
        OnboardingResult(goal: goal, experience: .intermediate, daysPerWeek: days,
                         trainingDaysOfWeek: OnboardingDraft.defaultTrainingDays(for: days).sorted(),
                         equipmentProfile: preset.legacyProfile, sessionLengthMinutes: minutes, injuryFlags: [],
                         minLoadIncrement: 2.5, startDate: Date(), equipmentPreset: preset, equipmentChecklist: [])
    }

    /// The preview and the seeder both use `fittedProgram(for:)`: every seeded item matches the fitted template's
    /// resolved prescription for its week and day, for every goal.
    func test_previewAndSeedAgree_forEveryGoal() throws {
        for goal in Goal.allCases {
            for days in [3, 4, 6] {
                let r = result(goal: goal, days: days)
                let fit = ProgramApplicationService.fittedProgram(for: r)
                let context = try makeContext()
                XCTAssertNoThrow(try ProgramApplicationService.apply(r, context: context, startDate: Date()).get())
                var checked = 0
                for session in try context.fetch(FetchDescriptor<Session>()) {
                    let day = try XCTUnwrap(fit.template.dayTemplates.first { $0.title == session.dayLabel })
                    let plans = try ProgramTemplateResolver.resolveDay(template: fit.template, weekNumber: session.weekIndex, dayNumber: day.dayNumber)
                    let expected = plans.sorted { $0.order < $1.order }.map {
                        "\($0.exerciseId)|\($0.defaultSets)|\($0.repMin)|\($0.repMax)|\($0.targetRIRMin)|\($0.targetRIRMax)"
                    }
                    let seeded = session.items.sorted { $0.order < $1.order }.map {
                        "\($0.exerciseId)|\($0.targetSets)|\($0.repMin ?? -1)|\($0.repMax ?? -1)|\($0.targetRIRMin ?? -1)|\($0.targetRIRMax ?? -1)"
                    }
                    XCTAssertEqual(seeded, expected, "\(goal) \(days)d week \(session.weekIndex) \(session.dayLabel ?? "")")
                    checked += 1
                }
                XCTAssertGreaterThan(checked, 0)
            }
        }
    }

    func test_goalChangesTheFittedProgram_andNamesItInTheReasonAndNotes() {
        let build = ProgramApplicationService.fittedProgram(for: result(goal: .hypertrophy))
        XCTAssertFalse(build.reasons.contains { $0.kind == .goal })
        for goal in [Goal.strength, .fatLoss, .longevity] {
            let r = result(goal: goal)
            let fit = ProgramApplicationService.fittedProgram(for: r)
            XCTAssertTrue(fit.reasons.contains { $0.kind == .goal }, "\(goal): a fit note for the change")
            XCTAssertNotEqual(Self.json(fit.template), Self.json(build.template), "\(goal)")
            let text = ProgramApplicationService.recommendationReason(goal: goal, daysPerWeek: 3, injuries: [], fit: fit)
            XCTAssertTrue(text.contains(ProgramApplicationService.goalSentence(goal)), text)
            XCTAssertTrue(text.contains("Goal: "), text)
            XCTAssertFalse(text.lowercased().contains("joint"), "no joint wording without a flag")
        }
    }

    // MARK: Paths that copy a meso

    /// "Start next meso from this one" copies the old block; the goal never enters it.
    func test_startNextMeso_isIdenticalRegardlessOfProfileGoal() throws {
        func summary(goal: Goal?) throws -> [String] {
            let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                                 UserProfile.self, User.self, CustomExercise.self, AppState.self])
            let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            let ctx = ModelContext(c)
            ctx.insert(User(units: .lb, progressionEnabled: true))
            if let goal { ctx.insert(UserProfile(primaryGoal: goal.primaryGoal)) }
            let cal = Calendar(identifier: .gregorian)
            try DUPProgramSeeder.seed(startDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!,
                                      trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
                                      template: DUP10WeekTemplate.template, calendar: cal,
                                      mesoName: "10-Week DUP Meso", mesoStatus: .active)
            let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
            try ctx.save()
            let plan = SessionItemEditService.planNextMeso(meso: block, name: "Next", startDate: nil, endOldMesoNow: true, context: ctx,
                                                           now: cal.date(from: DateComponents(year: 2026, month: 9, day: 20))!)
            XCTAssertTrue(plan.refusals.isEmpty, "\(plan.refusals)")
            return plan.sessions.map { s in
                "\(s.dayLabel ?? "-")|\(s.weekIndex)|\(s.programIndex)|\(s.letter)|" + s.items.map {
                    "\($0.order):\($0.exerciseId):\($0.targetReps):\($0.targetSets):\($0.targetRIR):\($0.prescription):\($0.plannedReps):\($0.plannedRIRs)"
                }.joined(separator: ";")
            }
        }
        let baseline = try summary(goal: nil)
        XCTAssertFalse(baseline.isEmpty)
        for goal in Goal.allCases {
            XCTAssertEqual(try summary(goal: goal), baseline, "profile goal \(goal) must not change a copied meso")
        }
    }
}
