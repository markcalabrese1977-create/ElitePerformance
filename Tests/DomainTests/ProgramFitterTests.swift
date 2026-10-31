import XCTest
@testable import ElitePerformance

/// ProgramFitter: identity for an unrestricted profile, then a property matrix over every template, equipment
/// preset, joint combination, session length and experience level.
final class ProgramFitterTests: XCTestCase {

    static let templates = ExerciseTraitsCoverageTests.templates
    static let presets = ExerciseTraitsCoverageTests.presets
    static let minutes = [45, 60, 90, 120]
    static let experiences: [TrainingExperience] = [.new, .intermediate, .advanced]

    static let jointCombos: [Set<InjuryFlag>] = [
        [], [.lowBack], [.knees], [.shoulders], [.elbows], [.wrists], [.hips],
        [.lowBack, .shoulders], [.knees, .hips], [.knees, .lowBack, .hips],
        [.lowBack, .knees, .shoulders, .elbows, .wrists, .hips]
    ]

    private static func fingerprint(_ t: ProgramTemplate) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? String(data: enc.encode(t), encoding: .utf8)) ?? "unencodable"
    }

    private static func canon(_ id: String) -> String { ExerciseCatalog.canonicalExerciseId(for: id) }

    private func profile(_ preset: EquipmentPreset, _ joints: Set<InjuryFlag> = [], _ minutes: Int = 120,
                         _ exp: TrainingExperience = .intermediate) -> FitProfile {
        FitProfile(equipment: preset.defaultEquipment, injuries: joints, sessionMinutes: minutes, experience: exp)
    }

    // MARK: - Identity

    func test_fullGym_noFlags_120min_isIdentity_forEveryTemplate() {
        for template in Self.templates {
            for exp in [TrainingExperience.intermediate, .advanced] {
                let result = ProgramFitter.fit(template, profile: profile(.fullGym, [], 120, exp))
                XCTAssertEqual(Self.fingerprint(result.template), Self.fingerprint(template), "\(template.name) \(exp)")
                XCTAssertEqual(result.reasons, [], "\(template.name) \(exp) must produce no reasons")
            }
        }
    }

    // MARK: - Matrix

    func test_matrix_properties() {
        var failures: [String] = []
        var runs = 0
        var swaps = 0, drops = 0, trims = 0, overs = 0

        for template in Self.templates {
            let originalSlots = Dictionary(uniqueKeysWithValues: template.dayTemplates.flatMap { day in
                day.exerciseTemplates.enumerated().map { ($1.id, (day: day.dayNumber, index: $0, ex: $1)) }
            })

            for preset in Self.presets {
                for joints in Self.jointCombos {
                    for minutes in Self.minutes {
                        for exp in Self.experiences {
                            let p = profile(preset, joints, minutes, exp)
                            let tag = "\(template.name) | \(preset.rawValue) | \(joints.map(\.rawValue).sorted()) | \(minutes)m | \(exp.rawValue)"
                            let result = ProgramFitter.fit(template, profile: p)
                            runs += 1
                            check(template, result, p, originalSlots, tag, &failures)
                            swaps += result.reasons.filter { $0.kind == .substituted }.count
                            drops += result.reasons.filter { $0.kind == .dropped || $0.kind == .droppedForTime }.count
                            trims += result.reasons.filter { $0.kind == .trimmedSets }.count
                            overs += result.reasons.filter { $0.kind == .overBudget }.count
                        }
                    }
                }
            }
        }
        print("FITTER_MATRIX runs=\(runs) swaps=\(swaps) drops=\(drops) trimmedSlots=\(trims) overBudgetNotes=\(overs) failures=\(failures.count)")
        var byKind: [String: Int] = [:]
        for f in failures {
            let detail = f.components(separatedBy: ": ").dropFirst(2).joined(separator: ": ")
            let key = detail.split(separator: " ").filter { !$0.contains("_") && !$0.allSatisfy { $0.isNumber || $0 == "-" || $0 == ">" } }.joined(separator: " ")
            byKind[key, default: 0] += 1
        }
        let summary = byKind.sorted { $0.value > $1.value }.map { "\($0.value)x \($0.key)" }.joined(separator: "\n")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) violations by kind:\n\(summary)\nfirst:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    private func check(_ template: ProgramTemplate, _ result: FitResult, _ p: FitProfile,
                       _ originalSlots: [String: (day: Int, index: Int, ex: ProgramExerciseTemplate)],
                       _ tag: String, _ failures: inout [String]) {
        func fail(_ s: String) { failures.append("\(tag): \(s)") }
        let fitted = result.template

        // determinism
        let again = ProgramFitter.fit(template, profile: p)
        if Self.fingerprint(again.template) != Self.fingerprint(fitted) || again.reasons != result.reasons { fail("not deterministic") }

        // structure
        if fitted.dayTemplates.map(\.id) != template.dayTemplates.map(\.id) { fail("days changed") }
        if fitted.totalWeeks != template.totalWeeks { fail("totalWeeks changed") }

        let catalogByName = Dictionary(ExerciseCatalog.builtIn.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for (di, day) in fitted.dayTemplates.enumerated() {
            let origDay = template.dayTemplates[di]
            let finalIds = day.exerciseTemplates.map { Self.canon($0.exerciseId) }
            if Set(finalIds).count != finalIds.count { fail("\(day.title): duplicate exercise") }

            // exercises the fitter could not reuse: the original day plus every replacement chosen, even ones trimmed away later
            var inDay = Set(finalIds).union(origDay.exerciseTemplates.map { Self.canon($0.exerciseId) })
            for step in ProgramFitter.substitutionPlan(origDay, profile: p) { if case .replace(let id, _) = step.outcome { inDay.insert(id) } }
            let reasonsForDay = result.reasons.filter { $0.dayNumber == day.dayNumber }

            // An anchor replaced by an isolation exercise is demoted to standard; every other anchor must survive.
            var demoted = Set<String>()
            for step in ProgramFitter.substitutionPlan(origDay, profile: p) {
                if case .replace(let id, _) = step.outcome, origDay.exerciseTemplates[step.originalIndex].priority == .anchor,
                   catalogByName[id]?.isCompound == false { demoted.insert(origDay.exerciseTemplates[step.originalIndex].id) }
            }
            for slot in origDay.exerciseTemplates where slot.priority == .anchor && !demoted.contains(slot.id) {
                if !day.exerciseTemplates.contains(where: { $0.id == slot.id }) { fail("\(day.title): anchor \(slot.id) dropped") }
            }
            for slot in day.exerciseTemplates where demoted.contains(slot.id) && slot.priority != .standard {
                fail("\(day.title): \(slot.id) replaced by isolation but still \(slot.priority)")
            }

            for ex in day.exerciseTemplates {
                guard let traits = ExerciseTraits.traits(for: ex.exerciseId) else { continue }
                // gear
                if !traits.isAvailable(with: p.equipment) {
                    let slotIndex = originalSlots[ex.id]?.index
                    let flagged = reasonsForDay.contains { $0.kind == .unfit && $0.slotIndex == slotIndex }
                    fail("\(day.title): \(ex.exerciseId) needs unavailable gear" + (flagged ? " (unfit reason present)" : ""))
                }
                // joint stress: a kept (not swapped) exercise with stressed flagged joints means nothing lower-stress existed
                let own = p.injuries.reduce(0) { $0 + traits.stress(for: $1) }
                let wasSwapped = originalSlots[ex.id].map { slot in
                    Self.canon(slot.ex.exerciseId) != Self.canon(ex.exerciseId)
                } ?? false
                if own > 0, !wasSwapped, let current = catalogByName[Self.canon(ex.exerciseId)] {
                    let pool = ExerciseCatalog.builtIn.filter {
                        ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern || $0.primaryMuscle == current.primaryMuscle
                    }
                    let lower = pool.filter { c in
                        guard let t = ExerciseTraits.traits(for: c.id), !inDay.contains(c.id) else { return false }
                        return t.isAvailable(with: p.equipment) && p.injuries.reduce(0, { $0 + t.stress(for: $1) }) < own
                    }
                    if !lower.isEmpty { fail("\(day.title): \(ex.exerciseId) kept at stress \(own) but a lower-stress option existed") }
                }
            }

            // duration or an over note
            let seconds = ProgramFitter.estimatedSeconds(day.exerciseTemplates, template: fitted)
            // budget advice: untrimmed >= fitted >= minimum; minimum fits the budget exactly when there is no over note
            if let adv = result.advice.days.first(where: { $0.dayNumber == day.dayNumber }) {
                let fittedMinutes = (seconds + 59) / 60
                if adv.untrimmedMinutes < fittedMinutes { fail("\(day.title): advice untrimmed \(adv.untrimmedMinutes) < fitted \(fittedMinutes)") }
                if adv.minimumMinutes > fittedMinutes { fail("\(day.title): advice minimum \(adv.minimumMinutes) > fitted \(fittedMinutes)") }
                let over = reasonsForDay.contains { $0.kind == .overBudget }
                if over && adv.minimumMinutes <= p.sessionMinutes { fail("\(day.title): over note but minimum \(adv.minimumMinutes) <= budget") }
                if !over && adv.minimumMinutes > p.sessionMinutes { fail("\(day.title): within budget but minimum \(adv.minimumMinutes) > budget") }
            } else { fail("\(day.title): no advice entry") }
            if seconds > p.sessionMinutes * 60 && !reasonsForDay.contains(where: { $0.kind == .overBudget }) {
                fail("\(day.title): \(seconds / 60) min over \(p.sessionMinutes) with no over reason")
            }
            if seconds <= p.sessionMinutes * 60 && reasonsForDay.contains(where: { $0.kind == .overBudget }) {
                fail("\(day.title): over reason although within budget")
            }

            // sets shape, deload, zero entries
            for ex in day.exerciseTemplates {
                guard let orig = originalSlots[ex.id]?.ex else { fail("\(ex.id) is not an original slot"); continue }
                if ex.setsByWeek.count != orig.setsByWeek.count { fail("\(ex.id): setsByWeek shape changed"); continue }
                for (i, s) in ex.setsByWeek.enumerated() {
                    let o = orig.setsByWeek[i]
                    let deload = template.rule(forWeek: i + 1)?.isDeload == true
                    if (deload || o == 0) && s != o { fail("\(ex.id) week \(i + 1): deload/zero entry changed \(o)->\(s)") }
                    if s > o { fail("\(ex.id) week \(i + 1): sets increased \(o)->\(s)") }
                    if s < min(o, 2) { fail("\(ex.id) week \(i + 1): below floor \(o)->\(s)") }
                }
                let priorityOK = ex.priority == orig.priority || (demoted.contains(ex.id) && ex.priority == .standard)
                if !priorityOK || ex.prescriptions.count != orig.prescriptions.count { fail("\(ex.id): priority/prescriptions changed") }
                // trim steps never touch an anchor: only the beginner step may change its sets
                if ex.priority == .anchor {
                    let beginner = p.experience == .new
                    let expected = orig.setsByWeek.enumerated().map { i, s in
                        (!beginner || template.rule(forWeek: i + 1)?.isDeload == true || s <= 2) ? s : s - 1
                    }
                    if ex.setsByWeek != expected { fail("\(ex.id): anchor sets trimmed \(expected)->\(ex.setsByWeek)") }
                }
            }
        }

        // reasons: exactly one slot-level reason per exercise change, trims only where sets moved beyond the beginner step
        let slotChangeKinds: Set<FitReason.Kind> = [.substituted, .dropped, .droppedForTime]
        for (id, slot) in originalSlots {
            let mine = result.reasons.filter { $0.dayNumber == slot.day && $0.slotIndex == slot.index }
            let finalEx = fitted.dayTemplates.first { $0.dayNumber == slot.day }?.exerciseTemplates.first { $0.id == id }
            let exerciseChanged = finalEx == nil || Self.canon(finalEx!.exerciseId) != Self.canon(slot.ex.exerciseId)
            let slotLevel = mine.filter { slotChangeKinds.contains($0.kind) }.count
            if slotLevel != (exerciseChanged ? 1 : 0) { fail("\(id): \(slotLevel) change reasons, expected \(exerciseChanged ? 1 : 0)") }
            if let finalEx {
                let beginner = p.experience == .new
                let expected = slot.ex.setsByWeek.enumerated().map { i, s in
                    (!beginner || template.rule(forWeek: i + 1)?.isDeload == true || s <= 2) ? s : s - 1
                }
                let trims = mine.filter { $0.kind == .trimmedSets }.count
                if trims != (finalEx.setsByWeek != expected ? 1 : 0) { fail("\(id): \(trims) trim reasons for sets \(expected)->\(finalEx.setsByWeek)") }
            }
        }
        if result.reasons.filter({ $0.kind == .volume }).count > 1 { fail("more than one volume reason") }
        if p.experience != .new && result.reasons.contains(where: { $0.kind == .volume }) { fail("volume reason for non-beginner") }
        for r in result.reasons where r.message.isEmpty { fail("empty reason message") }
    }

    // MARK: - Stage-local optimality

    /// Re-derives each swap from the documented stage order and checks the fitter chose the optimum of the first
    /// stage that had any candidate: stage (a) filters to max flagged stress <= 1, stages (b) and (c) to the lowest
    /// available stress; then the preference is same isCompound, loadable if the original was loaded, lower flagged
    /// stress, catalog order. Also: never a stress-2 choice on a flagged joint when a later stage offered lower, and
    /// a loaded slot never gets a bodyweight-only substitute when a loadable safe option of the same kind existed.
    func test_substitutionStages_areLocallyOptimal() {
        var failures: [String] = []
        var staged = [0, 0, 0]
        var passedOverLoadable = 0
        let builtIn = ExerciseCatalog.builtIn
        for template in Self.templates {
            for preset in Self.presets {
                for joints in Self.jointCombos {
                    let prof = profile(preset, joints)
                    for day in template.dayTemplates {
                        var used = Set(day.exerciseTemplates.map { Self.canon($0.exerciseId) })
                        for step in ProgramFitter.substitutionPlan(day, profile: prof) {
                            let orig = day.exerciseTemplates[step.originalIndex]
                            guard case .replace(let chosenId, let stage) = step.outcome,
                                  let traits = ExerciseTraits.traits(for: orig.exerciseId),
                                  let current = builtIn.first(where: { $0.id == Self.canon(orig.exerciseId) }) else {
                                if case .replace = step.outcome { failures.append("\(template.name) \(day.title): replace without traits") }
                                continue
                            }
                            let tag = "\(template.name) | \(preset.rawValue) | \(joints.map(\.rawValue).sorted()) | \(day.title) slot \(step.originalIndex)"
                            let available = traits.isAvailable(with: prof.equipment)
                            let own = prof.injuries.reduce(0) { $0 + traits.stress(for: $1) }
                            func sum(_ t: ExerciseTraits) -> Int { prof.injuries.reduce(0) { $0 + t.stress(for: $1) } }
                            func peak(_ t: ExerciseTraits) -> Int { prof.injuries.map { t.stress(for: $0) }.max() ?? 0 }
                            func usable(_ pool: [CatalogExercise]) -> [(CatalogExercise, ExerciseTraits, Int)] {
                                pool.enumerated().compactMap { _, c in
                                    guard let t = ExerciseTraits.traits(for: c.id), !used.contains(c.id), t.isAvailable(with: prof.equipment),
                                          !available || sum(t) < own, let idx = builtIn.firstIndex(where: { $0.id == c.id }) else { return nil }
                                    return (c, t, idx)
                                }
                            }
                            func lowest(_ u: [(CatalogExercise, ExerciseTraits, Int)]) -> [(CatalogExercise, ExerciseTraits, Int)] {
                                guard let m = u.map({ sum($0.1) }).min() else { return [] }
                                return u.filter { sum($0.1) == m }
                            }
                            func key(_ e: (CatalogExercise, ExerciseTraits, Int)) -> (Int, Int, Int, Int) {
                                (e.0.isCompound != current.isCompound ? 1 : 0, !current.isBodyweight && e.0.isBodyweight ? 1 : 0, sum(e.1), e.2)
                            }
                            func best(_ safe: [(CatalogExercise, ExerciseTraits, Int)]) -> CatalogExercise? { safe.min { key($0) < key($1) }?.0 }

                            let samePattern = builtIn.filter { ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern }
                            let sameMuscle = builtIn.filter { $0.primaryMuscle == current.primaryMuscle }
                            let union = builtIn.filter { ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern || $0.primaryMuscle == current.primaryMuscle }
                            let safeA = usable(samePattern).filter { peak($0.1) <= 1 }
                            let safeB = lowest(usable(sameMuscle))
                            let safeC = lowest(usable(union))
                            let expected: (CatalogExercise?, ProgramFitter.SubstitutionStage, [(CatalogExercise, ExerciseTraits, Int)])
                            if !safeA.isEmpty { expected = (best(safeA), .pattern, safeA) }
                            else if !safeB.isEmpty { expected = (best(safeB), .muscle, safeB) }
                            else { expected = (best(safeC), .fallback, safeC) }
                            if expected.0?.id != chosenId || expected.1 != stage {
                                failures.append("\(tag): chose \(chosenId) via \(stage), expected \(expected.0?.id ?? "nil") via \(expected.1)")
                            }
                            switch stage { case .pattern: staged[0] += 1; case .muscle: staged[1] += 1; case .fallback: staged[2] += 1 }
                            if let ct = ExerciseTraits.traits(for: chosenId), peak(ct) >= 2 {
                                let laterLowest = [best(safeB), best(safeC)].compactMap { $0 }.compactMap { ExerciseTraits.traits(for: $0.id) }.map(sum).min()
                                if let l = laterLowest, l < sum(ct) { failures.append("\(tag): stress-2 choice \(chosenId) but a later stage had stress \(l)") }
                            }
                            if stage == .pattern, let ct = ExerciseTraits.traits(for: chosenId), peak(ct) > 1 {
                                failures.append("\(tag): stage (a) chose peak stress \(peak(ct))")
                            }
                            // loaded slot, bodyweight-only substitute, loadable safe option of the same kind existed
                            if let chosen = builtIn.first(where: { $0.id == chosenId }), !current.isBodyweight, chosen.isBodyweight {
                                if expected.2.contains(where: { !$0.0.isBodyweight && $0.0.isCompound == chosen.isCompound }) {
                                    failures.append("\(tag): loaded slot got bodyweight-only \(chosenId) although a loadable safe option existed")
                                }
                                if expected.2.contains(where: { !$0.0.isBodyweight }) { passedOverLoadable += 1 }
                            }
                            used.insert(chosenId)
                        }
                    }
                }
            }
        }
        print("FITTER_STAGES pattern=\(staged[0]) muscle=\(staged[1]) fallback=\(staged[2]) bodyweightOverLoadableOfOtherKind=\(passedOverLoadable) failures=\(failures.count)")
        XCTAssertTrue(failures.isEmpty, failures.prefix(15).joined(separator: "\n"))
    }

    // MARK: - Targeted behaviour

    func test_untaggedExercise_isKept_withNotEvaluatedReason_whenProfileIsRestricted() {
        let day = ProgramDayTemplate(id: "d", dayNumber: 1, title: "Day", role: "", exerciseTemplates: [
            slot("s1", 1, "bench_back_extension", .standard)
        ])
        let t = ProgramTemplate(id: "t", name: "T", totalWeeks: 2, trainingDaysPerWeek: 1,
                                weekRules: [.init(weekNumber: 1, wave: .a, notes: nil), .init(weekNumber: 2, wave: .deload, notes: nil)],
                                dayTemplates: [day])
        let restricted = ProgramFitter.fit(t, profile: profile(.machinesOnly, [.lowBack]))
        XCTAssertEqual(restricted.template.dayTemplates[0].exerciseTemplates.map(\.exerciseId), ["bench_back_extension"])
        XCTAssertEqual(restricted.reasons.map(\.kind), [.notEvaluated])
        XCTAssertEqual(ProgramFitter.fit(t, profile: profile(.fullGym)).reasons, [])
    }

    func test_untaggedAndCustomExercises_areNeverChosenAsSubstitutes() {
        for template in Self.templates {
            for preset in Self.presets {
                let result = ProgramFitter.fit(template, profile: profile(preset, [.lowBack, .knees, .shoulders, .elbows, .wrists, .hips], 45))
                for day in result.template.dayTemplates {
                    for ex in day.exerciseTemplates where !template.dayTemplates.flatMap(\.exerciseTemplates).contains(where: { $0.id == ex.id && $0.exerciseId == ex.exerciseId }) {
                        XCTAssertNotNil(ExerciseTraits.traits(for: ex.exerciseId), "\(ex.exerciseId) was chosen without traits")
                    }
                }
            }
        }
    }

    func test_reasonText_namesBothExercisesAndTheCause() {
        let r = ProgramFitter.fit(PPL6DayTemplate.template, profile: profile(.dumbbellsBench, [.knees]))
        let swaps = r.reasons.filter { $0.kind == .substituted }.map(\.message)
        XCTAssertFalse(swaps.isEmpty)
        for m in swaps {
            XCTAssertTrue(m.contains(" -> ") && m.hasSuffix(")"), m)
        }
    }

    private func twoWeekTemplate(_ exercises: [ProgramExerciseTemplate]) -> ProgramTemplate {
        ProgramTemplate(id: "t", name: "T", totalWeeks: 2, trainingDaysPerWeek: 1,
                        weekRules: [.init(weekNumber: 1, wave: .a, notes: nil), .init(weekNumber: 2, wave: .deload, notes: nil)],
                        dayTemplates: [ProgramDayTemplate(id: "d", dayNumber: 1, title: "Day", role: "", exerciseTemplates: exercises)])
    }

    func test_anchorReplacedByIsolation_isDemotedToStandard() {
        let t = twoWeekTemplate([slot("a1", 1, "pec_deck", .anchor), slot("s2", 2, "bench_press", .standard)])
        let r = ProgramFitter.fit(t, profile: profile(.dumbbellsBench))
        let ex = r.template.dayTemplates[0].exerciseTemplates[0]
        XCTAssertEqual(ex.exerciseId, "dumbbell_fly")
        XCTAssertEqual(ex.priority, .standard)
        XCTAssertTrue(r.reasons.first { $0.kind == .substituted }?.message.contains("no longer an anchor") == true)
    }

    func test_trimStepIV_trimsNonAnchorCompoundsOnly_neverAnchors() {
        let anchor = ProgramExerciseTemplate(id: "a1", order: 1, exerciseId: "bench_press", priority: .anchor, notes: nil,
                                             prescriptions: slot("x", 1, "bench_press", .anchor).prescriptions, setsByWeek: [5, 2])
        let std = ProgramExerciseTemplate(id: "s2", order: 2, exerciseId: "incline_dumbbell_press", priority: .standard, notes: nil,
                                          prescriptions: slot("x", 1, "bench_press", .anchor).prescriptions, setsByWeek: [4, 2])
        let r = ProgramFitter.fit(twoWeekTemplate([anchor, std]), profile: profile(.fullGym, [], 20))
        let out = r.template.dayTemplates[0].exerciseTemplates
        XCTAssertEqual(out[0].setsByWeek, [5, 2], "anchor untouched")
        XCTAssertEqual(out[1].setsByWeek, [3, 2], "non-anchor compound -1 set in the non-deload week, deload untouched")
        XCTAssertEqual(r.reasons.filter { $0.kind == .trimmedSets }.count, 1)
        XCTAssertTrue(r.reasons.contains { $0.kind == .overBudget })
    }

    func test_budgetAdvice_matchesUntrimmedAndFloor() {
        for t in Self.templates {
            let r = ProgramFitter.fit(t, profile: profile(.fullGym, [], 120))
            let expectedMax = t.dayTemplates.map { (ProgramFitter.estimatedSeconds($0.exerciseTemplates, template: t) + 59) / 60 }.max()
            XCTAssertEqual(r.advice.untrimmedMaxDayMinutes, expectedMax, t.name)
            XCTAssertLessThanOrEqual(r.advice.minimumMinutes, r.advice.untrimmedMaxDayMinutes, t.name)
            XCTAssertGreaterThan(r.advice.minimumMinutes, 0, t.name)
        }
        // a tight budget cannot go below the advised minimum; a budget at the minimum has no over note
        let t = PPL6DayTemplate.template
        let tight = ProgramFitter.fit(t, profile: profile(.fullGym, [], 45))
        XCTAssertTrue(tight.reasons.contains { $0.kind == .overBudget })
        let atMinimum = ProgramFitter.fit(t, profile: profile(.fullGym, [], tight.advice.minimumMinutes))
        XCTAssertFalse(atMinimum.reasons.contains { $0.kind == .overBudget }, "advised minimum must be achievable")
    }

    // MARK: - Goldens (printed for the report)

    func test_goldenCases_printed() {
        let cases: [(String, ProgramTemplate, FitProfile)] = [
            ("6-day + dumbbellsBench + knees + 60 min", PPL6DayTemplate.template, profile(.dumbbellsBench, [.knees], 60)),
            ("4-day + homeBarbell + lowBack + shoulders + 75 min", UpperLower4DayTemplate.template, profile(.homeBarbell, [.lowBack, .shoulders], 75)),
            ("3-day + machinesOnly + hips + beginner + 45 min", PPL3WeekTemplate.template, profile(.machinesOnly, [.hips], 45, .new))
        ]
        for (title, template, p) in cases {
            let result = ProgramFitter.fit(template, profile: p)
            var lines = ["FITTER_GOLDEN \(title) [\(template.name)]"]
            for day in result.template.dayTemplates {
                let secs = ProgramFitter.estimatedSeconds(day.exerciseTemplates, template: result.template)
                let names = day.exerciseTemplates.map { ex in ExerciseCatalog.builtIn.first(where: { $0.id == ex.exerciseId })?.name ?? ex.exerciseId }
                lines.append("  \(day.title) (~\(secs / 60) min): " + names.joined(separator: ", "))
            }
            lines += result.reasons.map { "  - [\($0.dayNumber.map { "D\($0)" } ?? "all")] \($0.message)" }
            print(lines.joined(separator: "\n"))
            XCTAssertFalse(result.reasons.isEmpty, title)
        }
    }

    private func slot(_ id: String, _ order: Int, _ exerciseId: String, _ priority: ExercisePriority) -> ProgramExerciseTemplate {
        ProgramExerciseTemplate(id: id, order: order, exerciseId: exerciseId, priority: priority, notes: nil,
                                prescriptions: [.init(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 3),
                                                .init(wave: .deload, setMin: 2, setMax: 2, repMin: 8, repMax: 10, targetRIRMin: 4, targetRIRMax: 4)],
                                setsByWeek: [3, 2])
    }
}
