// Domain/Programs/ProgramFitter.swift
import Foundation

/// What the fitter needs to know about a person. A plain value so the fitter stays pure and testable.
struct FitProfile: Equatable {
    var equipment: Set<GearTag>
    var injuries: Set<InjuryFlag>
    var sessionMinutes: Int
    var experience: TrainingExperience

    init(equipment: Set<GearTag>, injuries: Set<InjuryFlag> = [], sessionMinutes: Int = 120,
         experience: TrainingExperience = .intermediate) {
        self.equipment = equipment
        self.injuries = injuries
        self.sessionMinutes = sessionMinutes
        self.experience = experience
    }

    init(_ profile: UserProfile) {
        self.init(equipment: profile.effectiveEquipment, injuries: Set(profile.injuryFlags),
                  sessionMinutes: profile.sessionLengthMinutes, experience: profile.experience)
    }

    /// True when nothing about the profile can rule an exercise out.
    var isUnrestricted: Bool {
        injuries.isEmpty && Set(GearTag.allCases).isSubset(of: equipment)
    }
}

/// One thing the fitter did (or declined to do) and why. `slotIndex` is the slot's position in its day of the
/// ORIGINAL template, so a reason stays addressable after slots are dropped.
struct FitReason: Equatable {
    enum Kind: String {
        case substituted, dropped, droppedForTime, trimmedSets, volume   // changes
        case keptStressed, notEvaluated, unfit, overBudget               // notes: nothing was changed
    }

    let kind: Kind
    let dayNumber: Int?
    let slotIndex: Int?
    let message: String

    var isChange: Bool {
        switch kind {
        case .substituted, .dropped, .droppedForTime, .trimmedSets, .volume: return true
        case .keptStressed, .notEvaluated, .unfit, .overBudget: return false
        }
    }
}

/// How long the fitted program takes, for a preview that offers "choose N min or fewer days".
struct FitAdvice: Equatable {
    struct Day: Equatable {
        let dayNumber: Int
        /// Whole minutes for the day after substitution and experience volume, before any time trimming.
        let untrimmedMinutes: Int
        /// Whole minutes for the day once every trim step has been applied (anchors are never trimmed).
        let minimumMinutes: Int
    }
    let days: [Day]
    /// The longest day, untrimmed.
    var untrimmedMaxDayMinutes: Int { days.map(\.untrimmedMinutes).max() ?? 0 }
    /// The smallest session length at which no day would be over: the longest day after all trims.
    var minimumMinutes: Int { days.map(\.minimumMinutes).max() ?? 0 }
}

struct FitResult {
    let template: ProgramTemplate
    let reasons: [FitReason]
    let advice: FitAdvice
}

/// Adapts a program template to a person's equipment, joints, session length and experience.
///
/// Pure: no persistence, no UserDefaults, built-in catalog only (customs are never chosen). Slots are addressed by
/// (day, slot index), never by exerciseId. Order of work: substitute -> experience volume -> trim for time.
enum ProgramFitter {

    // MARK: - Time model

    /// Calibrated against the Oct 30 backup: 27 completed sessions of the current meso with a HealthKit duration.
    /// With an 8 min warm-up the model ran 2.2 min short on average; at 10 min the mean error is about -0.2 min
    /// (MAE about 4.6 min). Rests are unchanged. Sessions have near-identical set counts, so rest and warm-up cannot be
    /// told apart in that data: the warm-up absorbs the bias and the rests stay at their first-principles values.
    static let warmupSeconds = 10 * 60
    static let workSecondsPerSet = 40
    static let anchorCompoundRest = 180
    static let otherCompoundRest = 120
    static let isolationRest = 75

    // MARK: - Entry point

    static func fit(_ template: ProgramTemplate, profile: FitProfile) -> FitResult {
        var reasons: [FitReason] = []
        var beginnerChanged = false
        var days: [ProgramDayTemplate] = []
        var adviceDays: [FitAdvice.Day] = []

        for day in template.dayTemplates {
            var slots = substitute(day, profile: profile, reasons: &reasons)
            if profile.experience == .new {
                for i in slots.indices {
                    let reduced = reduceForBeginner(slots[i].template, rules: template)
                    if reduced.setsByWeek != slots[i].template.setsByWeek { beginnerChanged = true }
                    slots[i].template = reduced
                }
            }
            let untrimmed = estimatedSeconds(slots.map(\.template), template: template)
            var floorSlots = slots
            var scratch: [FitReason] = []
            trimForTime(day: day, slots: &floorSlots, template: template, budgetSeconds: 0, reasons: &scratch)
            adviceDays.append(FitAdvice.Day(dayNumber: day.dayNumber,
                                            untrimmedMinutes: (untrimmed + 59) / 60,
                                            minimumMinutes: (estimatedSeconds(floorSlots.map(\.template), template: template) + 59) / 60))
            trimForTime(day: day, slots: &slots, template: template, budgetSeconds: profile.sessionMinutes * 60, reasons: &reasons)

            var exercises = slots.map(\.template)
            if exercises.count != day.exerciseTemplates.count {
                exercises = exercises.enumerated().map { rebuild($1, order: $0 + 1) }
            }
            days.append(ProgramDayTemplate(id: day.id, dayNumber: day.dayNumber, title: day.title,
                                           role: day.role, exerciseTemplates: exercises))
        }
        if beginnerChanged {
            reasons.append(FitReason(kind: .volume, dayNumber: nil, slotIndex: nil,
                                     message: "Starting volume -1 set (beginner)"))
        }

        let fitted = ProgramTemplate(id: template.id, name: template.name, totalWeeks: template.totalWeeks,
                                     trainingDaysPerWeek: template.trainingDaysPerWeek,
                                     weekRules: template.weekRules, dayTemplates: days)
        return FitResult(template: fitted, reasons: reasons, advice: FitAdvice(days: adviceDays))
    }

    // MARK: - Estimate

    /// Seconds for a day at its heaviest non-deload week.
    static func estimatedSeconds(_ exercises: [ProgramExerciseTemplate], template: ProgramTemplate) -> Int {
        var heaviest = 0
        for week in 1...max(1, template.totalWeeks) {
            let rule = template.rule(forWeek: week)
            if rule?.isDeload == true { continue }
            let wave = rule?.wave ?? .a
            let total = exercises.reduce(0) { sum, ex in
                sum + ex.sets(forWeek: week, wave: wave) * (workSecondsPerSet + restSeconds(ex))
            }
            heaviest = max(heaviest, total)
        }
        return heaviest + warmupSeconds
    }

    private static func restSeconds(_ ex: ProgramExerciseTemplate) -> Int {
        let compound = entry(ex.exerciseId)?.exercise.isCompound ?? true
        if !compound { return isolationRest }
        return ex.priority == .anchor ? anchorCompoundRest : otherCompoundRest
    }

    // MARK: - Substitution

    private struct Slot {
        let originalIndex: Int
        var template: ProgramExerciseTemplate
    }

    private static let catalog: [CatalogExercise] = ExerciseCatalog.builtIn

    private static let catalogIndex: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, ex) in catalog.enumerated() where map[ex.id] == nil { map[ex.id] = i }
        return map
    }()

    /// A substitution candidate. Internal so tests can inject a synthetic pool.
    struct Candidate {
        let index: Int
        let exercise: CatalogExercise
        let traits: ExerciseTraits
    }

    /// Tagged built-ins in catalog order. Untagged built-ins and customs are not here, so they are never chosen.
    static let candidates: [Candidate] = catalog.enumerated().compactMap { i, ex in
        ExerciseTraits.traits(for: ex.id).map { Candidate(index: i, exercise: ex, traits: $0) }
    }

    private static func entry(_ id: String) -> (index: Int, exercise: CatalogExercise)? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        return catalogIndex[canonical].map { ($0, catalog[$0]) }
    }

    private static func flaggedStress(_ traits: ExerciseTraits, _ joints: Set<InjuryFlag>) -> Int {
        joints.reduce(0) { $0 + traits.stress(for: $1) }
    }

    /// Which stage of the substitution order produced a replacement. A substitute never stresses a flagged joint above
    /// 1, and for a stress-2 original it is strictly lower; when no candidate passes there is no replacement at all.
    enum SubstitutionStage: Equatable {
        case pattern    // (a) same pattern, max stress on flagged joints <= 1
        case muscle     // (b) same primary muscle, max stress on flagged joints <= 1 
    }

    enum SlotOutcome: Equatable {
        case keep
        case notEvaluated
        case replace(exerciseId: String, stage: SubstitutionStage)
        case keptStressed   // anchor: gear fine, a flagged joint at stress 2, nothing lower-stress exists; kept
        case unfit          // anchor with no available substitute: kept
        case drop           // no substitute and the slot is not an anchor
    }

    struct SlotPlan: Equatable {
        let originalIndex: Int
        let outcome: SlotOutcome
    }

    /// Stage (a) accepts a candidate only if no flagged joint is stressed above this.
    static let patternStageMaxStress = 1

    /// Gear that holds added load. Bench, rack, pull-up bar and dip station alone do not make an exercise loadable.
    static let loadBearingGear: Set<GearTag> = [.barbell, .dumbbell, .ezBar, .cable, .machine, .smith]

    /// Loadable = the traits list load-bearing gear (not the catalog isBodyweight flag, which marks logging behaviour).
    static func isLoadable(_ traits: ExerciseTraits) -> Bool {
        !traits.equipment.isDisjoint(with: loadBearingGear)
    }

    private static func maxStress(_ traits: ExerciseTraits, _ joints: Set<InjuryFlag>) -> Int {
        joints.map { traits.stress(for: $0) }.max() ?? 0
    }

    /// The substitution decision for every slot of a day, in order. `used` starts as every exercise in the original day
    /// and grows with each replacement, so a swap never duplicates an exercise. Internal so tests can check each stage.
    static func substitutionPlan(_ day: ProgramDayTemplate, profile: FitProfile, pool: [Candidate]? = nil) -> [SlotPlan] {
        let candidates = pool ?? Self.candidates
        var used = Set(day.exerciseTemplates.map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        var plan: [SlotPlan] = []

        // Higher-priority slots choose first (anchor, standard, optional/firstCut; ties by slot index), so they win
        // contested substitutes under the no-duplicate rule. The plan is returned in slot order.
        func rank(_ p: ExercisePriority) -> Int {
            switch p {
            case .anchor: return 0
            case .standard: return 1
            case .optional, .firstCut: return 2
            }
        }
        let order = day.exerciseTemplates.indices.sorted {
            (rank(day.exerciseTemplates[$0].priority), $0) < (rank(day.exerciseTemplates[$1].priority), $1)
        }

        for index in order {
            let original = day.exerciseTemplates[index]
            guard let traits = ExerciseTraits.traits(for: original.exerciseId), let current = entry(original.exerciseId) else {
                plan.append(SlotPlan(originalIndex: index, outcome: .notEvaluated))
                continue
            }
            let available = traits.isAvailable(with: profile.equipment)
            let ownStress = flaggedStress(traits, profile.injuries)
            // Keep rule: available gear and no flagged joint above stress 1. Joint-driven swaps are for stress-2 originals only.
            if available && maxStress(traits, profile.injuries) <= patternStageMaxStress {
                plan.append(SlotPlan(originalIndex: index, outcome: .keep))
                continue
            }

            // Usable: available gear, not already in the day, and (when the original is usable) strictly lower-stress.
            func usable(_ pool: [Candidate]) -> [Candidate] {
                pool.filter { c in
                    !used.contains(c.exercise.id)
                        && c.traits.isAvailable(with: profile.equipment)
                        && (!available || flaggedStress(c.traits, profile.injuries) < ownStress)
                }
            }
            // Every stage orders its candidates the same way: loadable (when the original was loaded), then same
            // isCompound, then lower summed flagged stress, then catalog order.
            let originalLoaded = isLoadable(traits)
            func preferred(_ safe: [Candidate]) -> Candidate? {
                func key(_ c: Candidate) -> (Int, Int, Int, Int) {
                    (originalLoaded && !isLoadable(c.traits) ? 1 : 0,
                     c.exercise.isCompound != current.exercise.isCompound ? 1 : 0,
                     flaggedStress(c.traits, profile.injuries), c.index)
                }
                return safe.min { key($0) < key($1) }
            }
            func safe(_ pool: [Candidate]) -> [Candidate] {
                usable(pool).filter { maxStress($0.traits, profile.injuries) <= patternStageMaxStress }
            }
            let samePattern = candidates.filter { $0.traits.pattern == traits.pattern }
            let sameMuscle = candidates.filter { $0.exercise.primaryMuscle == current.exercise.primaryMuscle }

            let found: (Candidate, SubstitutionStage)?
            if let c = preferred(safe(samePattern)) {
                found = (c, .pattern)
            } else if let c = preferred(safe(sameMuscle)) {
                found = (c, .muscle)
            } else {
                // No candidate is strictly safer than the original: there is no replacement.
                found = nil
            }

            if let (chosen, stage) = found {
                used.insert(chosen.exercise.id)
                plan.append(SlotPlan(originalIndex: index, outcome: .replace(exerciseId: chosen.exercise.id, stage: stage)))
            } else if available {
                plan.append(SlotPlan(originalIndex: index, outcome: original.priority == .anchor ? .keptStressed : .drop))
            } else if original.priority == .anchor {
                plan.append(SlotPlan(originalIndex: index, outcome: .unfit))
            } else {
                plan.append(SlotPlan(originalIndex: index, outcome: .drop))
            }
        }
        return plan.sorted { $0.originalIndex < $1.originalIndex }
    }

    private static func substitute(_ day: ProgramDayTemplate, profile: FitProfile,
                                   reasons: inout [FitReason]) -> [Slot] {
        var slots: [Slot] = []
        for step in substitutionPlan(day, profile: profile) {
            let index = step.originalIndex
            let original = day.exerciseTemplates[index]
            func note(_ kind: FitReason.Kind, _ message: String) {
                reasons.append(FitReason(kind: kind, dayNumber: day.dayNumber, slotIndex: index, message: message))
            }
            let name = entry(original.exerciseId)?.exercise.name ?? original.exerciseId
            let traits = ExerciseTraits.traits(for: original.exerciseId)
            let available = traits?.isAvailable(with: profile.equipment) ?? true

            switch step.outcome {
            case .keep:
                slots.append(Slot(originalIndex: index, template: original))
            case .notEvaluated:
                if !profile.isUnrestricted { note(.notEvaluated, "\(name) not evaluated for your equipment or joints") }
                slots.append(Slot(originalIndex: index, template: original))
            case .replace(let id, let stage):
                let why = cause(traits!, available: available, profile: profile)
                // An anchor replaced by an isolation exercise is no longer an anchor: it takes isolation rest and can be trimmed.
                let demote = original.priority == .anchor && !(entry(id)?.exercise.isCompound ?? true)
                let suffix = demote ? "; no longer an anchor" : ""
                note(.substituted, "\(name) -> \(entry(id)?.exercise.name ?? id) (\(why)\(suffix))")
                slots.append(Slot(originalIndex: index, template: rebuild(original, exerciseId: id, priority: demote ? .standard : nil)))
            case .keptStressed:
                note(.keptStressed, "\(name) kept (no lower-stress option for \(jointList(traits!, profile)))")
                slots.append(Slot(originalIndex: index, template: original))
            case .unfit:
                note(.unfit, "\(name) kept (no substitute for \(cause(traits!, available: false, profile: profile)))")
                slots.append(Slot(originalIndex: index, template: original))
            case .drop:
                // Gear-driven drops name the gear; a stress-2 original with nothing safer to swap to names the joint.
                note(.dropped, "Dropped \(name) (\(cause(traits!, available: available, profile: profile))" + (available ? "; no lower-stress option)" : ")"))
            }
        }
        return slots
    }

    private static func cause(_ traits: ExerciseTraits, available: Bool, profile: FitProfile) -> String {
        if !available, let gear = GearTag.allCases.first(where: { traits.equipment.contains($0) && !profile.equipment.contains($0) }) {
            return gearPhrase(gear)
        }
        return jointList(traits, profile)
    }

    private static func gearPhrase(_ gear: GearTag) -> String {
        switch gear {
        case .barbell:    return "no barbell"
        case .ezBar:      return "no EZ bar"
        case .dumbbell:   return "no dumbbells"
        case .bench:      return "no bench"
        case .rack:       return "no rack"
        case .cable:      return "no cable machine"
        case .machine:    return "no machine"
        case .smith:      return "no smith machine"
        case .pullUpBar:  return "no pull-up bar"
        case .dipStation: return "no dip station"
        }
    }

    private static let jointOrder: [InjuryFlag] = [.lowBack, .knees, .shoulders, .elbows, .wrists, .hips]

    static func jointLabel(_ joint: InjuryFlag) -> String {
        switch joint {
        case .lowBack:   return "lower back"
        case .knees:     return "knees"
        case .shoulders: return "shoulders"
        case .elbows:    return "elbows"
        case .wrists:    return "wrists"
        case .hips:      return "hips"
        }
    }

    /// "knees", "knees and lower back", "knees, lower back and hips": the flagged joints in the order the fitter uses.
    static func jointNames(_ joints: Set<InjuryFlag>) -> String {
        let names = jointOrder.filter { joints.contains($0) }.map(jointLabel)
        switch names.count {
        case 0, 1: return names.first ?? ""
        default:   return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    private static func jointList(_ traits: ExerciseTraits, _ profile: FitProfile) -> String {
        jointOrder.filter { profile.injuries.contains($0) && traits.stress(for: $0) > 0 }
            .map(jointLabel).joined(separator: ", ")
    }

    // MARK: - Experience

    private static func reduceForBeginner(_ ex: ProgramExerciseTemplate, rules template: ProgramTemplate) -> ProgramExerciseTemplate {
        let sets = ex.setsByWeek.enumerated().map { i, s in
            template.rule(forWeek: i + 1)?.isDeload == true || s <= 2 ? s : s - 1
        }
        return rebuild(ex, setsByWeek: sets)
    }

    // MARK: - Time

    private static func trimForTime(day: ProgramDayTemplate, slots: inout [Slot], template: ProgramTemplate,
                                    budgetSeconds budget: Int, reasons: inout [FitReason]) {
        func over() -> Bool { estimatedSeconds(slots.map(\.template), template: template) > budget }
        func isolation(_ s: Slot) -> Bool { !(entry(s.template.exerciseId)?.exercise.isCompound ?? true) }
        func name(_ s: Slot) -> String { entry(s.template.exerciseId)?.exercise.name ?? s.template.exerciseId }
        func drop(at position: Int) {
            let slot = slots.remove(at: position)
            reasons.removeAll { $0.dayNumber == day.dayNumber && $0.slotIndex == slot.originalIndex && ($0.kind == .trimmedSets || $0.kind == .substituted) }
            reasons.append(FitReason(kind: .droppedForTime, dayNumber: day.dayNumber, slotIndex: slot.originalIndex,
                                     message: "Dropped \(name(slot)) (session length)"))
        }

        // (i) optional / firstCut slots, last first
        while over(), let p = slots.lastIndex(where: { $0.template.priority == .optional || $0.template.priority == .firstCut }) {
            drop(at: p)
        }
        // (ii) one set off each non-anchor isolation slot (floor 2), non-deload weeks only, last first
        for p in slots.indices.reversed() where over() && slots[p].template.priority != .anchor && isolation(slots[p]) {
            let before = slots[p].template.setsByWeek
            let after = before.enumerated().map { i, s in
                template.rule(forWeek: i + 1)?.isDeload == true || s <= 2 ? s : s - 1
            }
            guard after != before else { continue }
            slots[p].template = rebuild(slots[p].template, setsByWeek: after)
            reasons.append(FitReason(kind: .trimmedSets, dayNumber: day.dayNumber, slotIndex: slots[p].originalIndex,
                                     message: "\(name(slots[p])): -1 set (session length)"))
        }
        // (iii) non-anchor isolation slots, last first
        while over(), let p = slots.lastIndex(where: { $0.template.priority != .anchor && isolation($0) }) {
            drop(at: p)
        }
        // (iv) one set off each non-anchor compound slot (floor 2), non-deload weeks only, last first
        for p in slots.indices.reversed() where over() && slots[p].template.priority != .anchor && !isolation(slots[p]) {
            let before = slots[p].template.setsByWeek
            let after = before.enumerated().map { i, s in
                template.rule(forWeek: i + 1)?.isDeload == true || s <= 2 ? s : s - 1
            }
            guard after != before else { continue }
            slots[p].template = rebuild(slots[p].template, setsByWeek: after)
            reasons.append(FitReason(kind: .trimmedSets, dayNumber: day.dayNumber, slotIndex: slots[p].originalIndex,
                                     message: "\(name(slots[p])): -1 set (session length)"))
        }
        if over() {
            let seconds = estimatedSeconds(slots.map(\.template), template: template) - budget
            let minutes = (seconds + 59) / 60
            reasons.append(FitReason(kind: .overBudget, dayNumber: day.dayNumber, slotIndex: nil,
                                     message: "\(day.title): estimated \(minutes) min over the \(budget / 60) min session"))
        }
    }

    // MARK: - Rebuild

    private static func rebuild(_ ex: ProgramExerciseTemplate, exerciseId: String? = nil, order: Int? = nil,
                                setsByWeek: [Int]? = nil, priority: ExercisePriority? = nil) -> ProgramExerciseTemplate {
        ProgramExerciseTemplate(id: ex.id, order: order ?? ex.order, exerciseId: exerciseId ?? ex.exerciseId,
                                priority: priority ?? ex.priority, notes: ex.notes, prescriptions: ex.prescriptions,
                                setsByWeek: setsByWeek ?? ex.setsByWeek)
    }
}
