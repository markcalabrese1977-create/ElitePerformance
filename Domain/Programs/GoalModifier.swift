// Domain/Programs/GoalModifier.swift
import Foundation

/// A note the fit shows in the preview's "Adjusted for you" list.
typealias FitNote = FitReason

/// Adapts a program template to the lifter's goal. Pure: a template in, a template and notes out. It runs first inside
/// `ProgramFitter.fit`, before the equipment, joint and time fitting, so those steps see the goal-adjusted numbers.
///
/// Only template-generated paths go through the fitter (onboarding, "New program from template", maintenance Path B).
/// Paths that copy an existing meso ("Start next meso from this one", maintenance Path A) never call it, so their output
/// does not depend on the goal.
///
/// - Build muscle: unchanged (the same value back, no notes).
/// - Get stronger: anchor slots shift each working wave's rep range down one band (repMin and repMax -2, repMin never
///   below 3). Accessories are untouched.
/// - Lose fat: weekly sets stop ramping. Compound and anchor slots are capped at week 1 + 1, isolation slots at their
///   week-1 count, in every non-deload week. Reps and RIR are untouched; no slot is ever raised.
/// - General fitness (`Goal.longevity`): the same ramp cap, then -1 set on every slot every week (never below 2), and
///   target RIR +1 (capped at 3; a value already at or above 3 is left alone).
///
/// Deload weeks and deload prescriptions are never touched, and zero-set entries ("skip this week") stay zero.
enum GoalModifier {

    static func apply(_ template: ProgramTemplate, goal: Goal) -> (ProgramTemplate, [FitNote]) {
        switch goal {
        case .hypertrophy:
            return (template, [])
        case .strength:
            return strength(template)
        case .fatLoss:
            return fatLoss(template)
        case .longevity:
            return generalFitness(template)
        }
    }

    // MARK: - Get stronger

    /// The one-band shift: -2 on both ends, repMin floored at 3 (a repMin already below 3 is left alone), repMax never
    /// below the new repMin. A 0-0 entry (skipped wave) is untouched.
    static func shiftedDown(_ p: WavePrescription) -> WavePrescription {
        guard p.wave != .deload, p.repMax > 0 else { return p }
        let newMin = p.repMin < 3 ? p.repMin : max(3, p.repMin - 2)
        let newMax = max(newMin, p.repMax - 2)
        return replacing(p, repMin: newMin, repMax: newMax)
    }

    private static func strength(_ template: ProgramTemplate) -> (ProgramTemplate, [FitNote]) {
        var changed = false
        let out = mapSlots(template) { _, slot in
            guard slot.priority == .anchor else { return slot }
            let shifted = slot.prescriptions.map(shiftedDown)
            let different = zip(shifted, slot.prescriptions).contains { $0.repMin != $1.repMin || $0.repMax != $1.repMax }
            guard different else { return slot }
            changed = true
            return rebuilt(slot, prescriptions: shifted)
        }
        guard changed else { return (template, []) }
        return (out, [note("Get stronger: main lifts use lower-rep ranges (min and max reps -2, never below 3). Accessories are unchanged.")])
    }

    // MARK: - Lose fat

    private static func fatLoss(_ template: ProgramTemplate) -> (ProgramTemplate, [FitNote]) {
        var cappedMain = false, heldIsolation = false
        let out = mapSlots(template) { template, slot in
            guard let first = slot.setsByWeek.first else { return slot }
            // Isolation holds at its week-1 count; compounds and anchors may ramp by one over week 1.
            let cap = isCompound(slot.exerciseId) ? first + 1 : first
            var sets = slot.setsByWeek
            for i in sets.indices where !isDeload(template, week: i + 1) && sets[i] > cap {
                sets[i] = cap
                if isCompound(slot.exerciseId) { cappedMain = true } else { heldIsolation = true }
            }
            return sets == slot.setsByWeek ? slot : rebuilt(slot, setsByWeek: sets)
        }
        var notes: [FitNote] = []
        if cappedMain { notes.append(note("Lose fat: main-lift sets ramp up by at most 1 over week 1.")) }
        if heldIsolation { notes.append(note("Lose fat: isolation exercises hold at their week-1 set count instead of ramping up.")) }
        return (notes.isEmpty ? template : out, notes)
    }

    // MARK: - General fitness

    private static func generalFitness(_ template: ProgramTemplate) -> (ProgramTemplate, [FitNote]) {
        var capped = false, lighter = false, easier = false
        let out = mapSlots(template) { template, slot in
            var sets = slot.setsByWeek
            if let first = sets.first {
                for i in sets.indices where !isDeload(template, week: i + 1) && sets[i] > 0 {
                    let before = sets[i]
                    sets[i] = min(sets[i], first + 1)        // the ramp cap first, on the template's own numbers
                    if sets[i] != before { capped = true }
                    if sets[i] > 2 { sets[i] -= 1; lighter = true }   // then -1 set, never below 2
                }
            }
            let prescriptions = slot.prescriptions.map { p -> WavePrescription in
                guard p.wave != .deload else { return p }
                let lo = p.targetRIRMin >= 3 ? p.targetRIRMin : p.targetRIRMin + 1
                let hi = p.targetRIRMax >= 3 ? p.targetRIRMax : p.targetRIRMax + 1
                if lo != p.targetRIRMin || hi != p.targetRIRMax { easier = true }
                return replacing(p, targetRIRMin: lo, targetRIRMax: hi)
            }
            return rebuilt(slot, prescriptions: prescriptions, setsByWeek: sets)
        }
        var notes: [FitNote] = []
        if capped { notes.append(note("General fitness: weekly sets ramp up by at most 1 over week 1.")) }
        if lighter { notes.append(note("General fitness: 1 fewer set on every exercise (never below 2).")) }
        if easier { notes.append(note("General fitness: 1 more rep in reserve on working sets (target RIR +1, up to 3).")) }
        return (notes.isEmpty ? template : out, notes)
    }

    // MARK: - Helpers

    private static func note(_ message: String) -> FitNote {
        FitReason(kind: .goal, dayNumber: nil, slotIndex: nil, message: message)
    }

    private static func isDeload(_ template: ProgramTemplate, week: Int) -> Bool {
        template.rule(forWeek: week)?.isDeload == true
    }

    private static let catalogById: [String: CatalogExercise] = {
        var map: [String: CatalogExercise] = [:]
        for ex in ExerciseCatalog.builtIn where map[ex.id] == nil { map[ex.id] = ex }
        return map
    }()

    /// Unknown ids count as compound, like the fitter does.
    private static func isCompound(_ exerciseId: String) -> Bool {
        catalogById[ExerciseCatalog.canonicalExerciseId(for: exerciseId)]?.isCompound ?? true
    }

    private static func mapSlots(_ template: ProgramTemplate,
                                 _ transform: (ProgramTemplate, ProgramExerciseTemplate) -> ProgramExerciseTemplate) -> ProgramTemplate {
        let days = template.dayTemplates.map { day in
            ProgramDayTemplate(id: day.id, dayNumber: day.dayNumber, title: day.title, role: day.role,
                               exerciseTemplates: day.exerciseTemplates.map { transform(template, $0) })
        }
        return ProgramTemplate(id: template.id, name: template.name, totalWeeks: template.totalWeeks,
                               trainingDaysPerWeek: template.trainingDaysPerWeek,
                               weekRules: template.weekRules, dayTemplates: days, waveless: template.waveless)
    }

    private static func rebuilt(_ ex: ProgramExerciseTemplate, prescriptions: [WavePrescription]? = nil,
                                setsByWeek: [Int]? = nil) -> ProgramExerciseTemplate {
        ProgramExerciseTemplate(id: ex.id, order: ex.order, exerciseId: ex.exerciseId, priority: ex.priority, notes: ex.notes,
                                prescriptions: prescriptions ?? ex.prescriptions, setsByWeek: setsByWeek ?? ex.setsByWeek)
    }

    private static func replacing(_ p: WavePrescription, repMin: Int? = nil, repMax: Int? = nil,
                                  targetRIRMin: Int? = nil, targetRIRMax: Int? = nil) -> WavePrescription {
        WavePrescription(wave: p.wave, setMin: p.setMin, setMax: p.setMax,
                         repMin: repMin ?? p.repMin, repMax: repMax ?? p.repMax,
                         targetRIRMin: targetRIRMin ?? p.targetRIRMin, targetRIRMax: targetRIRMax ?? p.targetRIRMax,
                         intensifier: p.intensifier, intensifierNotes: p.intensifierNotes)
    }
}
