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

struct FitResult {
    let template: ProgramTemplate
    let reasons: [FitReason]
}

/// Adapts a program template to a person's equipment, joints, session length and experience.
///
/// Pure: no persistence, no UserDefaults, built-in catalog only (customs are never chosen). Slots are addressed by
/// (day, slot index), never by exerciseId. Order of work: substitute -> experience volume -> trim for time.
enum ProgramFitter {

    // MARK: - Time model

    static let warmupSeconds = 8 * 60
    static let workSecondsPerSet = 40
    static let anchorCompoundRest = 180
    static let otherCompoundRest = 120
    static let isolationRest = 75

    // MARK: - Entry point

    static func fit(_ template: ProgramTemplate, profile: FitProfile) -> FitResult {
        var reasons: [FitReason] = []
        var beginnerChanged = false
        var days: [ProgramDayTemplate] = []

        for day in template.dayTemplates {
            var slots = substitute(day, profile: profile, reasons: &reasons)
            if profile.experience == .new {
                for i in slots.indices {
                    let reduced = reduceForBeginner(slots[i].template, rules: template)
                    if reduced.setsByWeek != slots[i].template.setsByWeek { beginnerChanged = true }
                    slots[i].template = reduced
                }
            }
            trimForTime(day: day, slots: &slots, template: template, profile: profile, reasons: &reasons)

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
        return FitResult(template: fitted, reasons: reasons)
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

    private struct Candidate {
        let index: Int
        let exercise: CatalogExercise
        let traits: ExerciseTraits
    }

    /// Tagged built-ins in catalog order. Untagged built-ins and customs are not here, so they are never chosen.
    private static let candidates: [Candidate] = catalog.enumerated().compactMap { i, ex in
        ExerciseTraits.traits(for: ex.id).map { Candidate(index: i, exercise: ex, traits: $0) }
    }

    private static func entry(_ id: String) -> (index: Int, exercise: CatalogExercise)? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        return catalogIndex[canonical].map { ($0, catalog[$0]) }
    }

    private static func flaggedStress(_ traits: ExerciseTraits, _ joints: Set<InjuryFlag>) -> Int {
        joints.reduce(0) { $0 + traits.stress(for: $1) }
    }

    private static func substitute(_ day: ProgramDayTemplate, profile: FitProfile,
                                   reasons: inout [FitReason]) -> [Slot] {
        var used = Set(day.exerciseTemplates.map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        var slots: [Slot] = []

        for (index, original) in day.exerciseTemplates.enumerated() {
            func note(_ kind: FitReason.Kind, _ message: String) {
                reasons.append(FitReason(kind: kind, dayNumber: day.dayNumber, slotIndex: index, message: message))
            }
            let name = entry(original.exerciseId)?.exercise.name ?? original.exerciseId

            guard let traits = ExerciseTraits.traits(for: original.exerciseId), let current = entry(original.exerciseId) else {
                if !profile.isUnrestricted { note(.notEvaluated, "\(name) not evaluated for your equipment or joints") }
                slots.append(Slot(originalIndex: index, template: original))
                continue
            }

            let available = traits.isAvailable(with: profile.equipment)
            let ownStress = flaggedStress(traits, profile.injuries)
            if available && ownStress == 0 {
                slots.append(Slot(originalIndex: index, template: original))
                continue
            }

            func best(_ pool: [Candidate]) -> Candidate? {
                pool.filter { c in
                    !used.contains(c.exercise.id)
                        && c.traits.isAvailable(with: profile.equipment)
                        && (!available || flaggedStress(c.traits, profile.injuries) < ownStress)
                }.min { a, b in
                    let ka = (flaggedStress(a.traits, profile.injuries), a.exercise.isCompound != current.exercise.isCompound ? 1 : 0, a.index)
                    let kb = (flaggedStress(b.traits, profile.injuries), b.exercise.isCompound != current.exercise.isCompound ? 1 : 0, b.index)
                    return ka < kb
                }
            }

            let chosen = best(candidates.filter { $0.traits.pattern == traits.pattern })
                ?? best(candidates.filter { $0.exercise.primaryMuscle == current.exercise.primaryMuscle })

            if let chosen {
                used.insert(chosen.exercise.id)
                note(.substituted, "\(current.exercise.name) -> \(chosen.exercise.name) (\(cause(traits, available: available, profile: profile)))")
                slots.append(Slot(originalIndex: index, template: rebuild(original, exerciseId: chosen.exercise.id)))
            } else if available {
                note(.keptStressed, "\(current.exercise.name) kept (no lower-stress option for \(jointList(traits, profile)))")
                slots.append(Slot(originalIndex: index, template: original))
            } else if original.priority == .anchor {
                note(.unfit, "\(current.exercise.name) kept (no substitute for \(cause(traits, available: false, profile: profile)))")
                slots.append(Slot(originalIndex: index, template: original))
            } else {
                note(.dropped, "Dropped \(current.exercise.name) (\(cause(traits, available: false, profile: profile)))")
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

    private static func jointLabel(_ joint: InjuryFlag) -> String {
        switch joint {
        case .lowBack:   return "lower back"
        case .knees:     return "knees"
        case .shoulders: return "shoulders"
        case .elbows:    return "elbows"
        case .wrists:    return "wrists"
        case .hips:      return "hips"
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
                                    profile: FitProfile, reasons: inout [FitReason]) {
        let budget = profile.sessionMinutes * 60
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
        if over() {
            let seconds = estimatedSeconds(slots.map(\.template), template: template) - budget
            let minutes = (seconds + 59) / 60
            reasons.append(FitReason(kind: .overBudget, dayNumber: day.dayNumber, slotIndex: nil,
                                     message: "\(day.title): estimated \(minutes) min over the \(profile.sessionMinutes) min session"))
        }
    }

    // MARK: - Rebuild

    private static func rebuild(_ ex: ProgramExerciseTemplate, exerciseId: String? = nil, order: Int? = nil,
                                setsByWeek: [Int]? = nil) -> ProgramExerciseTemplate {
        ProgramExerciseTemplate(id: ex.id, order: order ?? ex.order, exerciseId: exerciseId ?? ex.exerciseId,
                                priority: ex.priority, notes: ex.notes, prescriptions: ex.prescriptions,
                                setsByWeek: setsByWeek ?? ex.setsByWeek)
    }
}
