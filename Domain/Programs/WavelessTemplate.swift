// Domain/Programs/WavelessTemplate.swift
import Foundation

/// A program the lifter writes themselves: days, exercises, ONE prescription per exercise, no A/B/C undulation. The sessions it
/// makes carry no wave letter; the coach chains the weeks by block + day name (see `PlanMemoryEngine.nextTargetItem`).
struct WavelessSlot: Equatable {
    var exerciseId: String
    var sets: Int
    var repMin: Int
    var repMax: Int
    var rirMin: Int
    var rirMax: Int
    var isCompound: Bool = false

    /// The defaults: a compound is 3 x 6-10 at RIR 2, an isolation 3 x 10-15 at RIR 1-2.
    static func defaults(exerciseId: String, isCompound: Bool) -> WavelessSlot {
        isCompound
            ? WavelessSlot(exerciseId: exerciseId, sets: 3, repMin: 6, repMax: 10, rirMin: 2, rirMax: 2, isCompound: true)
            : WavelessSlot(exerciseId: exerciseId, sets: 3, repMin: 10, repMax: 15, rirMin: 1, rirMax: 2, isCompound: false)
    }
}

struct WavelessDay: Equatable {
    var title: String
    var slots: [WavelessSlot]
}

extension ProgramTemplate {

    /// A block is 4 to 12 weeks.
    static let wavelessWeeks = 4...12
    static let wavelessDefaultWeeks = 8

    /// A template with no waves from the lifter's days. `deloadFinalWeek` makes the last week a deload (half the sets, two more
    /// reps in reserve); otherwise every week is a working week. The week count is clamped to 4-12.
    static func waveless(id: String = "own_program", name: String, totalWeeks: Int = wavelessDefaultWeeks,
                         deloadFinalWeek: Bool = false, days: [WavelessDay]) -> ProgramTemplate {
        let weeks = min(max(totalWeeks, wavelessWeeks.lowerBound), wavelessWeeks.upperBound)
        let rules = (1...weeks).map { week in
            ProgramWeekRule(weekNumber: week, wave: deloadFinalWeek && week == weeks ? .deload : .a, notes: nil)
        }
        let dayTemplates = days.enumerated().map { dayIndex, day in
            ProgramDayTemplate(
                id: "d\(dayIndex + 1)", dayNumber: dayIndex + 1, title: day.title, role: "Your program",
                exerciseTemplates: day.slots.enumerated().map { slotIndex, slot in
                    ProgramExerciseTemplate(
                        id: "d\(dayIndex + 1)_s\(slotIndex + 1)", order: slotIndex + 1, exerciseId: slot.exerciseId,
                        priority: .standard, notes: nil,
                        prescriptions: [
                            WavePrescription(wave: .a, setMin: slot.sets, setMax: slot.sets, repMin: slot.repMin, repMax: slot.repMax,
                                             targetRIRMin: slot.rirMin, targetRIRMax: slot.rirMax),
                            WavePrescription(wave: .deload, setMin: max(1, (slot.sets + 1) / 2), setMax: max(1, (slot.sets + 1) / 2),
                                             repMin: slot.repMin, repMax: slot.repMax,
                                             targetRIRMin: min(slot.rirMin + 2, 4), targetRIRMax: min(slot.rirMax + 2, 4)),
                        ])
                })
        }
        return ProgramTemplate(id: id, name: name, totalWeeks: weeks, trainingDaysPerWeek: days.count, weekRules: rules,
                               dayTemplates: dayTemplates, waveless: true)
    }
}
