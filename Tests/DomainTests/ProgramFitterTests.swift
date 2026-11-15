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
            for step in ProgramFitter.substitutionPlan(origDay, profile: p) {
                guard case .replace = step.outcome, let t = ExerciseTraits.traits(for: origDay.exerciseTemplates[step.originalIndex].exerciseId),
                      t.isAvailable(with: p.equipment) else { continue }
                if (p.injuries.map { t.stress(for: $0) }.max() ?? 0) <= 1 {
                    fail("\(day.title): slot \(step.originalIndex) has gear and stress <= 1 but was swapped")
                }
            }
            // equipment is a hard rule: an unavailable anchor is removed (or replaced), never kept
            var noPull = Set<String>()
            for step in ProgramFitter.substitutionPlan(origDay, profile: p) where step.outcome == .noVerticalPull || step.outcome == .drop {
                noPull.insert(origDay.exerciseTemplates[step.originalIndex].id)
            }
            for slot in origDay.exerciseTemplates where slot.priority == .anchor && !demoted.contains(slot.id) && !noPull.contains(slot.id) {
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
                    _ = originalSlots[ex.id]?.index
                    fail("\(day.title): \(ex.exerciseId) needs gear the profile does not have")
                }
                // joint stress: only a stress-2 original is ever swapped for joints, so a kept stress-2 exercise means nothing lower-stress existed
                let own = p.injuries.reduce(0) { $0 + traits.stress(for: $1) }
                let peak = p.injuries.map { traits.stress(for: $0) }.max() ?? 0
                let wasSwapped = originalSlots[ex.id].map { slot in
                    Self.canon(slot.ex.exerciseId) != Self.canon(ex.exerciseId)
                } ?? false
                if peak >= 2, !wasSwapped, let current = catalogByName[Self.canon(ex.exerciseId)] {
                    let pool = ExerciseCatalog.builtIn.filter {
                        ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern || $0.primaryMuscle == current.primaryMuscle
                    }
                    let lower = pool.filter { c in
                        guard let t = ExerciseTraits.traits(for: c.id), !inDay.contains(c.id) else { return false }
                        return t.isAvailable(with: p.equipment)
                            && p.injuries.reduce(0, { $0 + t.stress(for: $1) }) < own
                            && (traits.pattern != .verticalPull || t.pattern == .verticalPull)
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
                if over && adv.minimumMinutes <= (p.sessionMinutes ?? 0) { fail("\(day.title): over note but minimum \(adv.minimumMinutes) <= budget") }
                if !over && adv.minimumMinutes > (p.sessionMinutes ?? 0) { fail("\(day.title): within budget but minimum \(adv.minimumMinutes) > budget") }
            } else { fail("\(day.title): no advice entry") }
            if seconds > (p.sessionMinutes ?? 0) * 60 && !reasonsForDay.contains(where: { $0.kind == .overBudget }) {
                fail("\(day.title): \(seconds / 60) min over \((p.sessionMinutes ?? 0)) with no over reason")
            }
            if seconds <= (p.sessionMinutes ?? 0) * 60 && reasonsForDay.contains(where: { $0.kind == .overBudget }) {
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
    /// stage that had any candidate: stages (a) same pattern and (b) same muscle keep only candidates whose max flagged
    /// stress is <= 1, ordered loadable (if the original was loaded) > same isCompound > lower summed stress > catalog
    /// order; stage (c) runs only when neither passes and takes the lowest stress. Also: a loaded original never gets a
    /// bodyweight-only substitute when any safe loadable candidate exists in that stage, regardless of compound-ness.
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
                        for step in ProgramFitter.substitutionPlan(day, profile: prof).sorted(by: { Self.pickOrder($0.originalIndex, day) < Self.pickOrder($1.originalIndex, day) }) {
                            let orig = day.exerciseTemplates[step.originalIndex]
                            guard let traits = ExerciseTraits.traits(for: orig.exerciseId),
                                  let current = builtIn.first(where: { $0.id == Self.canon(orig.exerciseId) }) else {
                                if case .replace = step.outcome { failures.append("\(template.name) \(day.title): replace without traits") }
                                continue
                            }
                            switch step.outcome { case .keep, .notEvaluated: continue; default: break }
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
                            func key(_ e: (CatalogExercise, ExerciseTraits, Int)) -> (Int, Int, Int, Int) {
                                (ProgramFitter.isLoadable(traits) && !ProgramFitter.isLoadable(e.1) ? 1 : 0, e.0.isCompound != current.isCompound ? 1 : 0, sum(e.1), e.2)
                            }
                            func best(_ safe: [(CatalogExercise, ExerciseTraits, Int)]) -> CatalogExercise? { safe.min { key($0) < key($1) }?.0 }
                            func lowest(_ u: [(CatalogExercise, ExerciseTraits, Int)]) -> [(CatalogExercise, ExerciseTraits, Int)] {
                                guard let m = u.map({ sum($0.1) }).min() else { return [] }
                                return u.filter { sum($0.1) == m }
                            }

                            let samePattern = builtIn.filter { ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern }
                            let sameMuscle = builtIn.filter { $0.primaryMuscle == current.primaryMuscle }
                            let safeA = usable(samePattern).filter { peak($0.1) <= 1 }
                            // a vertical pull never falls back to another pattern
                            let safeB = traits.pattern == .verticalPull ? [] : usable(sameMuscle).filter { peak($0.1) <= 1 }
                            let union = builtIn.filter { ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern
                                || (traits.pattern != .verticalPull && $0.primaryMuscle == current.primaryMuscle) }
                            let safeC = lowest(usable(union))
                            let expected: (CatalogExercise?, ProgramFitter.SubstitutionStage, [(CatalogExercise, ExerciseTraits, Int)])
                            if !safeA.isEmpty { expected = (best(safeA), .pattern, safeA) }
                            else if !safeB.isEmpty { expected = (best(safeB), .muscle, safeB) }
                            else if !safeC.isEmpty { expected = (best(safeC), .fallback, safeC) }
                            else { expected = (nil, .pattern, []) }
                            guard case .replace(let chosenId, let stage) = step.outcome else {
                                if let e = expected.0 { failures.append("\(tag): \(step.outcome) although \(e.id) was a safe substitute") }
                                continue
                            }
                            if expected.0?.id != chosenId || expected.1 != stage {
                                failures.append("\(tag): chose \(chosenId) via \(stage), expected \(expected.0?.id ?? "nil") via \(expected.1)")
                            }
                            switch stage { case .pattern: staged[0] += 1; case .muscle: staged[1] += 1; case .fallback: staged[2] += 1 }
                            // stages (a)/(b) never stress a flagged joint above 1; an available stress-2 original only ever gets a strictly lower sum
                            if let ct = ExerciseTraits.traits(for: chosenId) {
                                if stage != .fallback, peak(ct) > 1 { failures.append("\(tag): stage \(stage) chose peak stress \(peak(ct))") }
                                if available, sum(ct) >= own { failures.append("\(tag): \(chosenId) is not lower-stress than the doable original") }
                            }
                            // a loaded original never gets a bodyweight-only substitute while any safe loadable candidate exists
                            if let chosenTraits = ExerciseTraits.traits(for: chosenId), ProgramFitter.isLoadable(traits), !ProgramFitter.isLoadable(chosenTraits),
                               expected.2.contains(where: { ProgramFitter.isLoadable($0.1) }) {
                                failures.append("\(tag): loaded slot got bodyweight-only \(chosenId) although a safe loadable candidate existed")
                                passedOverLoadable += 1
                            }
                            used.insert(chosenId)
                        }
                    }
                }
            }
        }
        print("FITTER_STAGES pattern=\(staged[0]) muscle=\(staged[1]) fallback=\(staged[2]) bodyweightOverSafeLoadable=\(passedOverLoadable) failures=\(failures.count)")
        XCTAssertTrue(failures.isEmpty, failures.prefix(15).joined(separator: "\n"))
    }

    /// Slots choose in priority order (anchor, standard, optional/firstCut), ties by slot index.
    static func pickOrder(_ index: Int, _ day: ProgramDayTemplate) -> (Int, Int) {
        switch day.exerciseTemplates[index].priority {
        case .anchor: return (0, index)
        case .standard: return (1, index)
        case .optional, .firstCut: return (2, index)
        }
    }

    // MARK: - Priority order and the keep rule

    /// A contested substitute goes to the higher-priority slot even when a lower-priority slot comes earlier.
    func test_higherPrioritySlotPicksFirst_underTheNoDuplicateRule() {
        let prof = FitProfile(equipment: [.dumbbell], injuries: [], sessionMinutes: 120)
        let day = ProgramDayTemplate(id: "d", dayNumber: 1, title: "Day", role: "", exerciseTemplates: [
            slot("s1", 1, "hack_squat", .optional), slot("s2", 2, "leg_press", .anchor)
        ])
        let one = fake("only", 1, muscle: .quads, compound: true, traits: ExerciseTraits(equipment: [.dumbbell], pattern: .squat))
        let plan = ProgramFitter.substitutionPlan(day, profile: prof, pool: [one])
        XCTAssertEqual(plan.map(\.originalIndex), [0, 1], "plan stays in slot order")
        XCTAssertEqual(plan[0].outcome, .drop)
        guard case .replace(let id, _) = plan[1].outcome else { return XCTFail("anchor should get the only candidate") }
        XCTAssertEqual(id, "only")
    }

    /// Lower B (4-day, homeBarbell, lowBack + shoulders): the anchor machine hip thrust picks first and, with loadable
    /// meaning load-bearing gear in the traits, takes the barbell hip thrust over the bodyweight glute bridge.
    func test_lowerB_anchorHipThrustSlot_getsBarbellHipThrust() {
        let prof = profile(.homeBarbell, [.lowBack, .shoulders], 75)
        let day = UpperLower4DayTemplate.template.dayTemplates.first { $0.title == "Lower B" }!
        let plan = ProgramFitter.substitutionPlan(day, profile: prof)
        let anchor = day.exerciseTemplates.firstIndex { $0.id == "ul_lb_hip_thrust" }!
        XCTAssertEqual(plan[anchor].outcome, .replace(exerciseId: "barbell_hip_thrust", stage: .pattern))
    }

    /// Classification is by traits: bench, rack, pull-up bar and dip station alone are not load-bearing.
    func test_loadable_isDefinedByLoadBearingGear() {
        XCTAssertTrue(ProgramFitter.isLoadable(ExerciseTraits.table["barbell_hip_thrust"]!))
        XCTAssertFalse(ProgramFitter.isLoadable(ExerciseTraits.table["glute_bridge"]!))
        XCTAssertFalse(ProgramFitter.isLoadable(ExerciseTraits(equipment: [.bench, .rack, .pullUpBar, .dipStation], pattern: .squat)))
    }

    /// Keep rule: gear available and max flagged stress <= 1 stays; only stress-2 originals are swapped for joints.
    func test_keepRule_stressOneIsKept_stressTwoIsSwapped() {
        let prof = FitProfile(equipment: [.dumbbell], injuries: [.knees], sessionMinutes: 120)
        for template in Self.templates {
            for day in template.dayTemplates {
                for step in ProgramFitter.substitutionPlan(day, profile: prof) {
                    guard let t = ExerciseTraits.traits(for: day.exerciseTemplates[step.originalIndex].exerciseId), t.isAvailable(with: prof.equipment) else { continue }
                    let peak = t.stress(for: .knees)
                    if peak <= 1 { XCTAssertEqual(step.outcome, .keep, "\(template.name) \(day.title) slot \(step.originalIndex)") }
                    else if case .keep = step.outcome { XCTFail("stress-2 original kept silently") }
                }
            }
        }
    }

    // MARK: - No fallback stage, synthetic

    private func fake(_ id: String, _ index: Int, muscle: MuscleGroup, compound: Bool, traits: ExerciseTraits) -> ProgramFitter.Candidate {
        ProgramFitter.Candidate(index: index, exercise: CatalogExercise(id: id, name: id, primaryMuscle: muscle, isCompound: compound), traits: traits)
    }

    private func hackSquatDay(_ priority: ExercisePriority = .standard) -> ProgramDayTemplate {
        ProgramDayTemplate(id: "d", dayNumber: 1, title: "Day", role: "", exerciseTemplates: [slot("s1", 1, "hack_squat", priority)])
    }

    /// Joint stress is soft: with no candidate under the stress filter the lowest-stress doable option is taken (c),
    /// and a doable original that nothing beats is kept. Equipment is hard: an original the gear cannot do is never kept.
    func test_softJointRule_fallbackToLowestDoable_keepOriginal_andHardEquipmentRule() {
        let prof = FitProfile(equipment: [.dumbbell, .machine], injuries: [.knees, .hips], sessionMinutes: 120)
        let heavy = fake("heavy", 1, muscle: .quads, compound: true, traits: ExerciseTraits(equipment: [.dumbbell], pattern: .squat, stress: [.knees: 2, .hips: 1]))
        let lighter = fake("lighter", 2, muscle: .quads, compound: true, traits: ExerciseTraits(equipment: [.dumbbell], pattern: .squat, stress: [.knees: 2]))
        let unavailable = fake("unavailable", 3, muscle: .quads, compound: true, traits: ExerciseTraits(equipment: [.smith], pattern: .squat))
        // hack squat (knees 2, hips 1) is doable; "lighter" is the lowest doable option and strictly lower: taken as (c)
        XCTAssertEqual(ProgramFitter.substitutionPlan(hackSquatDay(.standard), profile: prof, pool: [heavy, lighter, unavailable]).map(\.outcome),
                       [.replace(exerciseId: "lighter", stage: .fallback)])
        // nothing doable is lower: the original stays, anchor or not
        for priority in [ExercisePriority.standard, .anchor] {
            XCTAssertEqual(ProgramFitter.substitutionPlan(hackSquatDay(priority), profile: prof, pool: [heavy, unavailable]).map(\.outcome), [.keptStressed])
        }
        // a safe candidate wins over any (c) option
        let safe = fake("safe", 4, muscle: .quads, compound: true, traits: ExerciseTraits(equipment: [.dumbbell], pattern: .squat, stress: [.knees: 1, .hips: 1]))
        XCTAssertEqual(ProgramFitter.substitutionPlan(hackSquatDay(), profile: prof, pool: [heavy, lighter, unavailable, safe]).map(\.outcome),
                       [.replace(exerciseId: "safe", stage: .pattern)])
        // stage (b): same muscle, different pattern, passes the filter
        let sibling = fake("sibling", 5, muscle: .quads, compound: false, traits: ExerciseTraits(equipment: [.dumbbell], pattern: .kneeExtension, stress: [.knees: 1]))
        XCTAssertEqual(ProgramFitter.substitutionPlan(hackSquatDay(), profile: prof, pool: [heavy, lighter, sibling]).map(\.outcome),
                       [.replace(exerciseId: "sibling", stage: .muscle)])

        // the gear cannot do the original (no machine) and nothing doable exists: removed, even an anchor
        let noMachine = FitProfile(equipment: [.dumbbell], injuries: [.knees, .hips], sessionMinutes: 120)
        for priority in [ExercisePriority.standard, .anchor] {
            XCTAssertEqual(ProgramFitter.substitutionPlan(hackSquatDay(priority), profile: noMachine, pool: [unavailable]).map(\.outcome), [.drop])
        }
        // ...but the lowest-stress doable option is taken even when it stresses the joint
        XCTAssertEqual(ProgramFitter.substitutionPlan(hackSquatDay(.anchor), profile: noMachine, pool: [heavy, lighter]).map(\.outcome),
                       [.replace(exerciseId: "lighter", stage: .fallback)])
    }

    /// Loaded original: any safe loadable candidate beats a bodyweight-only one, even when the bodyweight one matches
    /// compound-ness and has lower stress.
    func test_loadedOriginal_prefersSafeLoadableOverBodyweightOnly_regardlessOfCompoundness() {
        let prof = FitProfile(equipment: [.dumbbell], injuries: [], sessionMinutes: 120)
        let day = hackSquatDay()
        var bw = fake("bw", 1, muscle: .quads, compound: true, traits: ExerciseTraits(equipment: [], pattern: .squat))
        bw = ProgramFitter.Candidate(index: 1, exercise: CatalogExercise(id: "bw", name: "bw", primaryMuscle: .quads, isCompound: true, isBodyweight: true), traits: bw.traits)
        let loaded = fake("loaded", 2, muscle: .quads, compound: false, traits: ExerciseTraits(equipment: [.dumbbell], pattern: .squat, stress: [:]))
        let plan = ProgramFitter.substitutionPlan(day, profile: prof, pool: [bw, loaded])
        XCTAssertEqual(plan.map(\.outcome), [.replace(exerciseId: "loaded", stage: .pattern)])
        // with no loadable candidate the bodyweight option is still taken
        XCTAssertEqual(ProgramFitter.substitutionPlan(day, profile: prof, pool: [bw]).map(\.outcome), [.replace(exerciseId: "bw", stage: .pattern)])
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

    // MARK: - Joint swaps lower stress

    /// With a knee flag, no replacement stresses the knees at 2 (knee-dominant), and a replacement for a stress-2 knee
    /// exercise is strictly lower. Holds for every template, preset and joint combination that includes knees.
    func test_kneeFlag_neverProducesKneeDominantSubstitute() {
        var checked = 0
        for template in Self.templates {
            for preset in Self.presets {
                for joints in Self.jointCombos where joints.contains(.knees) {
                    let p = profile(preset, joints)
                    for day in template.dayTemplates {
                        for step in ProgramFitter.substitutionPlan(day, profile: p) {
                            guard case .replace(let id, let stage) = step.outcome,
                                  let new = ExerciseTraits.traits(for: id),
                                  let old = ExerciseTraits.traits(for: day.exerciseTemplates[step.originalIndex].exerciseId) else { continue }
                            // (c) is the explicit exception: nothing doable is gentler, so the lowest option is taken (and noted)
                            if stage != .fallback {
                                XCTAssertLessThan(new.stress(for: .knees), 2, "\(template.name) \(day.title): \(id) is knee-dominant")
                            }
                            if old.stress(for: .knees) >= 2, stage != .fallback {
                                XCTAssertLessThan(new.stress(for: .knees), old.stress(for: .knees), "\(id) not lower than the original")
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    /// Every squat-pattern exercise the catalog tags loads the knees; none may read as zero.
    func test_squatAndKneeExtensionPatterns_carryKneeStress() {
        for (id, t) in ExerciseTraits.table where t.pattern == .squat || t.pattern == .kneeExtension {
            XCTAssertGreaterThanOrEqual(t.stress(for: .knees), 1, "\(id) is a knee-loading pattern with no knee stress")
        }
    }

    func test_kneeFlag_fullGym_swapsNameTheJoint_andKeptNotesCarryTheCue() {
        let p = profile(.fullGym, [.knees])
        for template in Self.templates {
            let r = ProgramFitter.fit(template, profile: p)
            for reason in r.reasons where reason.kind == .substituted {
                XCTAssertTrue(reason.message.contains("knees") || reason.message.contains("no "), reason.message)
            }
            for reason in r.reasons where reason.kind == .keptStressed {
                XCTAssertTrue(reason.message.contains("flagged:"), "a kept/lowest-stress note names the joint and the cue: \(reason.message)")
            }
        }
    }

    // MARK: - Equipment is hard, joint stress is soft

    /// Home gym (barbell, rack, dumbbells, bench, pull-up bar; no cable) with elbows flagged: the pulldown slots become
    /// pull-ups (the only vertical pull the gear allows, though it stresses the elbows) with an elbow note. Never a pulldown.
    func test_elbowsFlag_homeGym_givesPullUpsWithTheNote_neverPulldown() {
        let p = profile(.homeBarbell, [.elbows])
        var sawPullUp = false
        for template in Self.templates {
            let r = ProgramFitter.fit(template, profile: p)
            for day in r.template.dayTemplates {
                for ex in day.exerciseTemplates {
                    let id = Self.canon(ex.exerciseId)
                    XCTAssertFalse(id.contains("pulldown"), "\(template.name) \(day.title): \(id) needs a cable machine")
                    if id == "pull_up" || id == "chin_up" { sawPullUp = true }
                }
            }
            for (di, day) in template.dayTemplates.enumerated() {
                for (si, slot) in day.exerciseTemplates.enumerated()
                where ExerciseTraits.traits(for: slot.exerciseId)?.pattern == .verticalPull
                    && !(ExerciseTraits.traits(for: slot.exerciseId)?.isAvailable(with: p.equipment) ?? true) {
                    let notes = r.reasons.filter { $0.dayNumber == day.dayNumber && $0.slotIndex == si && $0.kind == .keptStressed }
                    XCTAssertTrue(notes.contains { $0.message.contains("Elbows flagged: neutral grip, stop short of pain.") },
                                  "\(template.name) \(day.title) slot \(si) (\(slot.exerciseId)): no elbow note")
                    _ = di
                    let final = r.template.dayTemplates[di].exerciseTemplates.map { Self.canon($0.exerciseId) }
                    XCTAssertTrue(final.contains("pull_up") || final.contains("chin_up"), "\(template.name) \(day.title): expected a pull-up")
                }
            }
        }
        XCTAssertTrue(sawPullUp)
    }

    /// Whatever the flag, preset, session length and experience, no exercise the equipment cannot support is ever kept.
    private func assertNoUnavailableExerciseKept(flag: InjuryFlag, file: StaticString = #filePath, line: UInt = #line) {
        var checked = 0
        for template in Self.templates {
            for preset in Self.presets {
                for minutes in [45, 120] {
                    let p = profile(preset, [flag], minutes)
                    let fitted = ProgramFitter.fit(template, profile: p).template
                    for day in fitted.dayTemplates {
                        for ex in day.exerciseTemplates {
                            guard let t = ExerciseTraits.traits(for: ex.exerciseId) else { continue }
                            XCTAssertTrue(t.isAvailable(with: p.equipment),
                                          "\(flag) \(preset) \(template.name) \(day.title): \(ex.exerciseId) cannot be done with this gear", file: file, line: line)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 500, file: file, line: line)
    }

    func test_lowBackFlag_neverKeepsAnUnavailableExercise() { assertNoUnavailableExerciseKept(flag: .lowBack) }
    func test_kneesFlag_neverKeepsAnUnavailableExercise() { assertNoUnavailableExerciseKept(flag: .knees) }
    func test_shouldersFlag_neverKeepsAnUnavailableExercise() { assertNoUnavailableExerciseKept(flag: .shoulders) }
    func test_elbowsFlag_neverKeepsAnUnavailableExercise() { assertNoUnavailableExerciseKept(flag: .elbows) }
    func test_wristsFlag_neverKeepsAnUnavailableExercise() { assertNoUnavailableExerciseKept(flag: .wrists) }
    func test_hipsFlag_neverKeepsAnUnavailableExercise() { assertNoUnavailableExerciseKept(flag: .hips) }

    // MARK: - Equipment rules

    func test_nordic_needsSomethingToAnchorTheFeet() {
        let nordic = ExerciseTraits.table["nordic_curl"]!
        XCTAssertFalse(nordic.isAvailable(with: [.dumbbell, .bench]))
        XCTAssertFalse(nordic.isAvailable(with: [.dumbbell, .bench, .cable]))
        XCTAssertTrue(nordic.isAvailable(with: [.barbell, .rack]))
        XCTAssertTrue(nordic.isAvailable(with: [.machine]))
        XCTAssertTrue(nordic.isAvailable(with: [.smith]))
    }

    func test_nordic_isNeverChosenWithoutAnAnchor() {
        var anchorlessChecked = 0
        for template in Self.templates {
            for equipment in [Set<GearTag>([.dumbbell, .bench]), [.dumbbell, .bench, .cable], [.dumbbell], [.cable]] as [Set<GearTag>] {
                for joints in Self.jointCombos {
                    let p = FitProfile(equipment: equipment, injuries: joints, sessionMinutes: 120)
                    let fitted = ProgramFitter.fit(template, profile: p).template
                    for day in fitted.dayTemplates {
                        XCTAssertFalse(day.exerciseTemplates.contains { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == "nordic_curl" },
                                       "\(template.name) \(day.title) \(equipment)")
                        anchorlessChecked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(anchorlessChecked, 0)
    }

    /// Dumbbells + bench with a pulldown slot: no vertical pull is possible, so the slot is removed with a note, never
    /// filled with a pullover or a row.
    func test_noVerticalPullPossible_noteInsteadOfOtherPattern() {
        let p = profile(.dumbbellsBench)
        var sawNote = false
        for template in Self.templates {
            let r = ProgramFitter.fit(template, profile: p)
            let notes = r.reasons.filter { $0.message.hasPrefix("No vertical pull is possible") }
            sawNote = sawNote || !notes.isEmpty
            for n in notes {
                let day = template.dayTemplates.first { $0.dayNumber == n.dayNumber }!
                let original = day.exerciseTemplates[n.slotIndex!]
                XCTAssertEqual(ExerciseTraits.traits(for: original.exerciseId)?.pattern, .verticalPull)
            }
            for day in r.template.dayTemplates {
                for ex in day.exerciseTemplates {
                    XCTAssertNotEqual(ExerciseTraits.traits(for: ex.exerciseId)?.pattern, .verticalPull,
                                      "\(template.name): a vertical pull appeared on equipment that cannot do one")
                }
            }
            // pullovers are a different pattern and never fill a pulldown slot
            for step in day0Steps(template, p) { if case .replace(let id, _) = step, id.contains("pullover") { XCTFail("pullover chosen under a pulldown") } }
        }
        XCTAssertTrue(sawNote)
    }

    private func day0Steps(_ template: ProgramTemplate, _ p: FitProfile) -> [ProgramFitter.SlotOutcome] {
        template.dayTemplates.flatMap { day in
            ProgramFitter.substitutionPlan(day, profile: p).enumerated().compactMap { i, step in
                ExerciseTraits.traits(for: day.exerciseTemplates[i].exerciseId)?.pattern == .verticalPull ? step.outcome : nil
            }
        }
    }

    func test_pullUpBarMakesAVerticalPullPossible() {
        let p = FitProfile(equipment: [.pullUpBar, .dumbbell, .bench], injuries: [], sessionMinutes: 120)
        for template in Self.templates {
            let r = ProgramFitter.fit(template, profile: p)
            XCTAssertFalse(r.reasons.contains { $0.message.hasPrefix("No vertical pull is possible") }, template.name)
        }
    }

    // MARK: - Knee cue

    /// Knees flagged: every exercise left in the program that loads the knees (substitutes and kept originals alike)
    /// carries "Knees flagged: use a pain-free depth." on its own slot. Stress ratings are not touched by this.
    func test_kneeFlag_everyKneeLoadingExerciseCarriesTheCue() {
        var cued = 0
        for template in Self.templates {
            for preset in Self.presets {
                for minutes in [45, 120] {
                    let p = profile(preset, [.knees], minutes)
                    let r = ProgramFitter.fit(template, profile: p)
                    for (di, day) in r.template.dayTemplates.enumerated() {
                        let origDay = template.dayTemplates[di]
                        for ex in day.exerciseTemplates {
                            let slot = origDay.exerciseTemplates.firstIndex { $0.id == ex.id }!
                            let loadsKnees = (ExerciseTraits.traits(for: ex.exerciseId)?.stress(for: .knees) ?? 0) >= 1
                            let noted = r.reasons.contains { $0.dayNumber == day.dayNumber && $0.slotIndex == slot
                                && $0.kind == .jointNote && $0.message == "Knees flagged: use a pain-free depth." }
                            XCTAssertEqual(noted, loadsKnees, "\(template.name) \(preset) \(day.title): \(ex.exerciseId)")
                            if noted { cued += 1 }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(cued, 100)
    }

    func test_noKneeFlag_noKneeNotes() {
        for template in Self.templates {
            for preset in Self.presets {
                let r = ProgramFitter.fit(template, profile: profile(preset, [.lowBack, .elbows], 60))
                XCTAssertFalse(r.reasons.contains { $0.message.contains("Knees flagged") || $0.kind == .jointNote }, template.name)
            }
        }
    }

    func test_kneeStressRatings_areUnchanged() {
        XCTAssertEqual(ExerciseTraits.table["leg_press"]?.stress(for: .knees), 1)
        XCTAssertEqual(ExerciseTraits.table["smith_machine_squat"]?.stress(for: .knees), 1)
        XCTAssertEqual(ExerciseTraits.table["hack_squat"]?.stress(for: .knees), 2)
        XCTAssertEqual(ExerciseTraits.table["leg_extension"]?.stress(for: .knees), 2)
    }

    // MARK: - Bodyweight substitutes

    /// Home gym (no cable machine): the pulldown slots become pull-ups with a bodyweight range in every wave, never the
    /// pulldown's 10-12, and the slot says what to do when the range is out of reach.
    func test_homeGym_pulldownBecomesPullUp_withABodyweightRange_neverTenToTwelve() {
        var checked = 0
        for template in Self.templates {
            let p = profile(.homeBarbell)
            let r = ProgramFitter.fit(template, profile: p)
            for (di, day) in r.template.dayTemplates.enumerated() {
                for (si, ex) in template.dayTemplates[di].exerciseTemplates.enumerated() where Self.canon(ex.exerciseId).contains("pulldown") {
                    let fitted = r.template.dayTemplates[di].exerciseTemplates.first { $0.id == ex.id }
                    guard let fitted else { continue }   // trimmed away by time: nothing to check
                    XCTAssertEqual(Self.canon(fitted.exerciseId), "pull_up", "\(template.name) \(day.title)")
                    for pr in fitted.prescriptions {
                        XCTAssertEqual([pr.repMin, pr.repMax], [5, 8], "\(template.name) \(day.title) wave \(pr.wave)")
                        XCTAssertFalse(pr.repMin == 10 && pr.repMax == 12)
                        XCTAssertEqual([pr.targetRIRMin, pr.targetRIRMax], [ex.prescriptions.first { $0.wave == pr.wave }!.targetRIRMin,
                                                                           ex.prescriptions.first { $0.wave == pr.wave }!.targetRIRMax], "RIR is the slot's")
                    }
                    XCTAssertTrue(r.reasons.contains { $0.dayNumber == day.dayNumber && $0.slotIndex == si && $0.kind == .bodyweightNote
                        && $0.message.contains("If you can't reach the range, use band assistance or slow negatives.") },
                                  "\(template.name) \(day.title): no bodyweight note")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// Whichever bodyweight exercise replaces a loaded one, pull-ups and chin-ups get 5-8 and dips and push-ups 8-12;
    /// a loaded substitute keeps the slot's range.
    func test_bodyweightRanges_followTheExercise() {
        XCTAssertEqual(ProgramFitter.bodyweightRepRange(for: "pull_up"), 5...8)
        XCTAssertEqual(ProgramFitter.bodyweightRepRange(for: "chin_up"), 5...8)
        XCTAssertEqual(ProgramFitter.bodyweightRepRange(for: "dip"), 8...12)
        XCTAssertEqual(ProgramFitter.bodyweightRepRange(for: "push_up"), 8...12)
        XCTAssertNil(ProgramFitter.bodyweightRepRange(for: "dumbbell_pullover"))
        for template in Self.templates {
            for preset in Self.presets {
                let r = ProgramFitter.fit(template, profile: profile(preset))
                for (di, day) in template.dayTemplates.enumerated() {
                    for ex in day.exerciseTemplates {
                        guard let fitted = r.template.dayTemplates[di].exerciseTemplates.first(where: { $0.id == ex.id }),
                              Self.canon(fitted.exerciseId) != Self.canon(ex.exerciseId),
                              let range = ProgramFitter.bodyweightRepRange(for: fitted.exerciseId),
                              let ot = ExerciseTraits.traits(for: ex.exerciseId), ProgramFitter.isLoadable(ot) else {
                            // an unchanged or loaded-for-loaded slot keeps its prescriptions exactly
                            if let fitted = r.template.dayTemplates[di].exerciseTemplates.first(where: { $0.id == ex.id }),
                               Self.canon(fitted.exerciseId) == Self.canon(ex.exerciseId) || ProgramFitter.bodyweightRepRange(for: fitted.exerciseId) == nil {
                                XCTAssertEqual(fitted.prescriptions.map { [$0.repMin, $0.repMax] }, ex.prescriptions.map { [$0.repMin, $0.repMax] },
                                               "\(template.name) \(preset) \(ex.id)")
                            }
                            continue
                        }
                        XCTAssertTrue(fitted.prescriptions.allSatisfy { $0.repMin == range.lowerBound && $0.repMax == range.upperBound })
                    }
                }
            }
        }
    }
}
