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

            let inDay = Set(finalIds).union(origDay.exerciseTemplates.map { Self.canon($0.exerciseId) })
            let reasonsForDay = result.reasons.filter { $0.dayNumber == day.dayNumber }

            // anchors never dropped
            for slot in origDay.exerciseTemplates where slot.priority == .anchor {
                if !day.exerciseTemplates.contains(where: { $0.id == slot.id }) { fail("\(day.title): anchor \(slot.id) dropped") }
            }

            for ex in day.exerciseTemplates {
                guard let traits = ExerciseTraits.traits(for: ex.exerciseId) else { continue }
                // gear
                if !traits.isAvailable(with: p.equipment) {
                    let slotIndex = originalSlots[ex.id]?.index
                    let flagged = reasonsForDay.contains { $0.kind == .unfit && $0.slotIndex == slotIndex }
                    fail("\(day.title): \(ex.exerciseId) needs unavailable gear" + (flagged ? " (unfit reason present)" : ""))
                }
                // joint stress: nothing stressed remains when a lower-stress option existed
                let own = p.injuries.reduce(0) { $0 + traits.stress(for: $1) }
                // Substituted slots are judged by the spec's stage order (same pattern first, even at non-zero stress),
                // so only the pattern pool is checked for them; a kept slot is checked against pattern then muscle.
                let wasSwapped = reasonsForDay.contains { $0.kind == .substituted && $0.slotIndex == originalSlots[ex.id]?.index }
                if own > 0, let current = catalogByName[Self.canon(ex.exerciseId)] {
                    func lower(_ pool: [CatalogExercise]) -> [CatalogExercise] {
                        pool.filter { c in
                            guard let t = ExerciseTraits.traits(for: c.id), !inDay.contains(c.id) else { return false }
                            return t.isAvailable(with: p.equipment) && p.injuries.reduce(0, { $0 + t.stress(for: $1) }) < own
                        }
                    }
                    let samePattern = ExerciseCatalog.builtIn.filter { ExerciseTraits.traits(for: $0.id)?.pattern == traits.pattern }
                    let sameMuscle = ExerciseCatalog.builtIn.filter { $0.primaryMuscle == current.primaryMuscle }
                    if !lower(samePattern).isEmpty || (!wasSwapped && !lower(sameMuscle).isEmpty) {
                        fail("\(day.title): \(ex.exerciseId) stressed (\(own)) but a lower-stress option existed")
                    }
                }
            }

            // duration or an over note
            let seconds = ProgramFitter.estimatedSeconds(day.exerciseTemplates, template: fitted)
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
                if ex.priority != orig.priority || ex.prescriptions.count != orig.prescriptions.count { fail("\(ex.id): priority/prescriptions changed") }
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
