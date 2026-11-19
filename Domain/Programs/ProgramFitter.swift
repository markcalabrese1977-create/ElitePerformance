// Domain/Programs/ProgramFitter.swift
import Foundation

/// What the fitter needs to know about a person. A plain value so the fitter stays pure and testable.
struct FitProfile: Equatable {
    var equipment: Set<GearTag>
    var injuries: Set<InjuryFlag>
    /// nil = no limit: the fit skips time trimming and never reports an over-budget day.
    var sessionMinutes: Int?
    var experience: TrainingExperience
    /// Build muscle is the identity: the goal step changes nothing for it.
    var goal: Goal

    init(equipment: Set<GearTag>, injuries: Set<InjuryFlag> = [], sessionMinutes: Int? = 120,
         experience: TrainingExperience = .intermediate, goal: Goal = .hypertrophy) {
        self.equipment = equipment
        self.injuries = injuries
        self.sessionMinutes = sessionMinutes
        self.experience = experience
        self.goal = goal
    }

    init(_ profile: UserProfile) {
        self.init(equipment: profile.effectiveEquipment, injuries: Set(profile.injuryFlags),
                  sessionMinutes: profile.sessionLengthMinutes, experience: profile.experience,
                  goal: Goal(rawValue: profile.primaryGoalRaw) ?? .hypertrophy)
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
        case substituted, dropped, droppedForTime, trimmedSets, volume, goal   // changes
        case keptStressed, jointNote, bodyweightNote, notEvaluated, overBudget   // notes: nothing was changed
    }

    let kind: Kind
    let dayNumber: Int?
    let slotIndex: Int?
    let message: String

    var isChange: Bool {
        switch kind {
        case .substituted, .dropped, .droppedForTime, .trimmedSets, .volume, .goal: return true
        case .keptStressed, .jointNote, .bodyweightNote, .notEvaluated, .overBudget: return false
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

    static func fit(_ original: ProgramTemplate, profile: FitProfile) -> FitResult {
        // The goal first: equipment, joints and time then work on the goal-adjusted numbers. It adds no slots, so every
        // slot index below still means the same slot of the original template.
        let (template, goalNotes) = GoalModifier.apply(original, goal: profile.goal)
        var reasons: [FitReason] = goalNotes
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
            // No limit: no trimming at all, so no trim reasons and no over-budget note.
            if let minutes = profile.sessionMinutes {
                trimForTime(day: day, slots: &slots, template: template, budgetSeconds: minutes * 60, reasons: &reasons)
            }

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
                                     weekRules: template.weekRules, dayTemplates: days, waveless: template.waveless)
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

    /// Which stage of the substitution order produced a replacement. Equipment is a hard rule (a substitute is always
    /// doable on the lifter's gear); joint stress is a soft one: (a) and (b) take a candidate that stresses no flagged
    /// joint above 1 (and, for an available stress-2 original, strictly less), and only when there is none does (c)
    /// take the lowest-stress available option, with a note naming the joint.
    enum SubstitutionStage: Equatable {
        case pattern    // (a) same pattern, max stress on flagged joints <= 1
        case muscle     // (b) same primary muscle, max stress on flagged joints <= 1 (never for a vertical pull)
        case fallback   // (c) nothing passes (a)/(b): the lowest-stress available option, still stressing a flagged joint
    }

    enum SlotOutcome: Equatable {
        case keep
        case notEvaluated
        case replace(exerciseId: String, stage: SubstitutionStage)
        case keptStressed   // gear fine, a flagged joint at stress 2, nothing lower-stress is available: kept, with a note
        case drop           // the gear is missing and nothing doable replaces it (any priority): removed with the equipment note
        case noVerticalPull // a vertical pull with no vertical pull possible on this equipment: dropped, never swapped for another pattern
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
            } else if traits.pattern != .verticalPull, let c = preferred(safe(sameMuscle)) {
                // (never another pattern under a pulldown's slot: a vertical pull skips stage (b))
                found = (c, .muscle)
            } else {
                // (c) joint stress is a soft rule: the lowest-stress option the gear allows, same preference order. For
                // an original that is itself doable, `usable` only lets a strictly lower-stress candidate through.
                let u = usable(candidates.filter {
                    $0.traits.pattern == traits.pattern || (traits.pattern != .verticalPull && $0.exercise.primaryMuscle == current.exercise.primaryMuscle)
                })
                if let m = u.map({ flaggedStress($0.traits, profile.injuries) }).min(),
                   let c = preferred(u.filter { flaggedStress($0.traits, profile.injuries) == m }) {
                    found = (c, .fallback)
                } else {
                    found = nil
                }
            }

            if let (chosen, stage) = found {
                used.insert(chosen.exercise.id)
                plan.append(SlotPlan(originalIndex: index, outcome: .replace(exerciseId: chosen.exercise.id, stage: stage)))
            } else if traits.pattern == .verticalPull && !available
                        && !candidates.contains(where: { $0.traits.pattern == .verticalPull && $0.traits.isAvailable(with: profile.equipment) }) {
                plan.append(SlotPlan(originalIndex: index, outcome: .noVerticalPull))
            } else if available {
                // Doable but stresses a flagged joint and nothing doable is lower: keep it (any priority) and say so.
                plan.append(SlotPlan(originalIndex: index, outcome: .keptStressed))
            } else {
                // Equipment is a hard rule: an exercise the gear cannot support is never kept, anchor or not.
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
                let newName = entry(id)?.exercise.name ?? id
                note(.substituted, "\(name) -> \(newName) (\(why)\(suffix))")
                if stage == .fallback, let t = ExerciseTraits.traits(for: id) {
                    // Nothing doable is gentler: the lowest-stress option still loads the joint, so say which and how to train it.
                    let joints = stressedJoints(t, profile)
                    note(.keptStressed, "\(newName) is the lowest-stress option your equipment allows for your \(jointNames(Set(joints)))." + cueSuffix(joints))
                }
                var replacement = rebuild(original, exerciseId: id, priority: demote ? .standard : nil)
                // A loaded exercise replaced by a bodyweight one: the slot's loaded rep range (10-12) is not a bodyweight
                // range, so the substitute gets its own.
                if let ot = traits, isLoadable(ot), let nt = ExerciseTraits.traits(for: id), !isLoadable(nt),
                   let range = bodyweightRepRange(for: id) {
                    replacement = rebuild(replacement, prescriptions: replacement.prescriptions.map {
                        WavePrescription(wave: $0.wave, setMin: $0.setMin, setMax: $0.setMax, repMin: range.lowerBound, repMax: range.upperBound,
                                         targetRIRMin: $0.targetRIRMin, targetRIRMax: $0.targetRIRMax,
                                         intensifier: $0.intensifier, intensifierNotes: $0.intensifierNotes)
                    })
                    note(.bodyweightNote, "\(newName): \(range.lowerBound)-\(range.upperBound) reps (bodyweight). If you can't reach the range, use band assistance or slow negatives.")
                }
                slots.append(Slot(originalIndex: index, template: replacement))
            case .keptStressed:
                let joints = stressedJoints(traits!, profile)
                note(.keptStressed, "\(name) kept (no lower-stress option for \(jointList(traits!, profile)))." + cueSuffix(joints))
                slots.append(Slot(originalIndex: index, template: original))
            case .drop:
                note(.dropped, "Dropped \(name) (\(cause(traits!, available: false, profile: profile)))")
            case .noVerticalPull:
                note(.dropped, "No vertical pull is possible with your equipment (it needs a pull-up bar, a cable machine or an assisted pull-up machine), so \(name) was removed rather than replaced by a different movement")
            }
            // Knees flagged: every substitute or kept exercise that loads the knees says how to train it.
            if profile.injuries.contains(.knees), let kept = slots.last, kept.originalIndex == index,
               let t = ExerciseTraits.traits(for: kept.template.exerciseId), t.stress(for: .knees) >= 1 {
                note(.jointNote, kneeNote)
            }
        }
        return slots
    }

    private static func cause(_ traits: ExerciseTraits, available: Bool, profile: FitProfile) -> String {
        if !available, let gear = GearTag.allCases.first(where: { traits.equipment.contains($0) && !profile.equipment.contains($0) }) {
            return gearPhrase(gear)
        }
        if !available, !traits.anchorOneOf.isEmpty { return "nothing to hook your feet under" }
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

    /// What to do on an exercise that still loads a flagged joint.
    static func painCue(_ joint: InjuryFlag) -> String {
        switch joint {
        case .knees:     return "use a pain-free depth"
        case .elbows:    return "neutral grip, stop short of pain"
        case .wrists:    return "neutral grip, stop short of pain"
        case .shoulders: return "pain-free range, stop short of pain"
        case .lowBack:   return "neutral spine, pain-free range, stop short of pain"
        case .hips:      return "pain-free range, stop short of pain"
        }
    }

    /// The flagged joints an exercise loads at all, in the fitter's order.
    private static func stressedJoints(_ traits: ExerciseTraits, _ profile: FitProfile) -> [InjuryFlag] {
        jointOrder.filter { profile.injuries.contains($0) && traits.stress(for: $0) >= 1 }
    }

    /// "Elbows flagged: neutral grip, stop short of pain." for each joint. Knees are left out: every exercise that loads
    /// them already carries the separate knee note.
    private static func cueSentences(_ joints: [InjuryFlag]) -> String {
        joints.filter { $0 != .knees }.map { joint in
            let label = jointLabel(joint)
            return "\(label.prefix(1).uppercased() + label.dropFirst()) flagged: \(painCue(joint))."
        }.joined(separator: " ")
    }

    private static func cueSuffix(_ joints: [InjuryFlag]) -> String {
        let cues = cueSentences(joints)
        return cues.isEmpty ? "" : " " + cues
    }

    static let kneeNote = "Knees flagged: use a pain-free depth."

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
            reasons.removeAll { $0.dayNumber == day.dayNumber && $0.slotIndex == slot.originalIndex
                && ($0.kind == .trimmedSets || $0.kind == .substituted || $0.kind == .keptStressed || $0.kind == .jointNote
                    || $0.kind == .bodyweightNote) }
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
                                setsByWeek: [Int]? = nil, priority: ExercisePriority? = nil,
                                prescriptions: [WavePrescription]? = nil) -> ProgramExerciseTemplate {
        ProgramExerciseTemplate(id: ex.id, order: order ?? ex.order, exerciseId: exerciseId ?? ex.exerciseId,
                                priority: priority ?? ex.priority, notes: ex.notes, prescriptions: prescriptions ?? ex.prescriptions,
                                setsByWeek: setsByWeek ?? ex.setsByWeek)
    }

    /// Rep range for a bodyweight exercise that replaced a loaded one. The catalog carries no per-exercise bodyweight
    /// default, so these are the fitter's own: 5-8 for pull-ups and chin-ups, 8-12 for dips and push-ups. Other
    /// bodyweight substitutes (glute bridge, lunges, ...) keep the slot's range.
    static func bodyweightRepRange(for exerciseId: String) -> ClosedRange<Int>? {
        switch ExerciseCatalog.canonicalExerciseId(for: exerciseId) {
        case "pull_up", "chin_up": return 5...8
        case "dip", "push_up":     return 8...12
        default:                   return nil
        }
    }
}
