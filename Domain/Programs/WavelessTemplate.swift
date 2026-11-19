// Domain/Programs/WavelessTemplate.swift
import Foundation

/// A program the lifter writes themselves: days, exercises, ONE prescription per exercise, no A/B/C undulation. The sessions it
/// makes carry no wave letter; the coach chains the weeks by block + day name (see `PlanMemoryEngine.nextTargetItem`).
struct WavelessSlot: Equatable, Codable {
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

struct WavelessDay: Equatable, Codable {
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


/// What the "Use my own program" flow collects, and what travels in `OnboardingResult.ownProgram`: the lifter's days (names and
/// exercises with one prescription each), the block length and whether the last week is a deload.
struct OwnProgramSpec: Codable, Equatable {
    var name: String = "My program"
    var days: [WavelessDay]
    var totalWeeks: Int = ProgramTemplate.wavelessDefaultWeeks
    var deloadFinalWeek: Bool = false

    var template: ProgramTemplate {
        .waveless(name: name, totalWeeks: totalWeeks, deloadFinalWeek: deloadFinalWeek, days: days)
    }

    /// Every day has a name and at least one exercise; 2-6 days.
    var isValid: Bool {
        (2...6).contains(days.count)
            && days.allSatisfy { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && !$0.slots.isEmpty }
    }
}

/// The pure editing operations of the own-program flow.
enum OwnProgramBuilder {

    /// The prescription a compound or an isolation starts with.
    static let compoundDefault = WavelessSlot.defaults(exerciseId: "", isCompound: true)
    static let isolationDefault = WavelessSlot.defaults(exerciseId: "", isCompound: false)

    /// A new slot for `exercise` with the default prescription for its kind.
    static func newSlot(for exercise: CatalogExercise) -> WavelessSlot {
        .defaults(exerciseId: exercise.id, isCompound: RIREntry.isCompound(exercise.id) || exercise.isCompound)
    }

    static func blankDays(count: Int, names: [String]? = nil) -> [WavelessDay] {
        (0..<max(0, count)).map { WavelessDay(title: names?[safe: $0] ?? "Day \($0 + 1)", slots: []) }
    }

    /// Resizes the day list: new days are blank and named "Day n", removed days drop off the end. Existing names and exercises stay.
    static func resized(_ days: [WavelessDay], to count: Int) -> [WavelessDay] {
        if days.count >= count { return Array(days.prefix(count)) }
        return days + blankDays(count: count, names: nil).dropFirst(days.count)
    }

    /// "Copy day": `target`'s exercises become copies of `source`'s (the same exercises and prescriptions), independent of it.
    static func copyDay(_ days: [WavelessDay], from source: Int, to target: Int) -> [WavelessDay] {
        guard days.indices.contains(source), days.indices.contains(target), source != target else { return days }
        var out = days
        out[target].slots = days[source].slots
        return out
    }

    /// Chosen names with repeats numbered: Upper, Lower, Upper, Lower, Upper -> Upper A, Lower A, Upper B, Lower B, Upper C.
    /// A name used once stays as it is; names the lifter already made distinct ("Upper A") are never touched.
    static func numberedNames(_ names: [String]) -> [String] {
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespaces) }
        let counts = Dictionary(trimmed.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        let letters = Array("ABCDEFGH")
        return trimmed.map { name in
            guard !name.isEmpty, (counts[name.lowercased()] ?? 0) > 1 else { return name }
            let n = seen[name.lowercased(), default: 0]
            seen[name.lowercased()] = n + 1
            return "\(name) \(letters[min(n, letters.count - 1)])"
        }
    }

    /// Sets every compound (or isolation) slot to `slot`'s sets, reps and RIR.
    static func applyPrescription(_ slot: WavelessSlot, toCompounds compounds: Bool, in days: [WavelessDay]) -> [WavelessDay] {
        days.map { day in
            var d = day
            d.slots = day.slots.map { existing in
                guard existing.isCompound == compounds else { return existing }
                var s = existing
                s.sets = slot.sets; s.repMin = slot.repMin; s.repMax = max(slot.repMin, slot.repMax)
                s.rirMin = slot.rirMin; s.rirMax = max(slot.rirMin, slot.rirMax)
                return s
            }
            return d
        }
    }

    /// The suggested day names for a day count (the lifter edits them).
    static func suggestedNames(count: Int) -> [String] {
        switch count {
        case 2: return ["Full body", "Full body"]
        case 3: return ["Push", "Pull", "Legs"]
        case 4: return ["Upper", "Lower", "Upper", "Lower"]
        case 5: return ["Upper", "Lower", "Upper", "Lower", "Upper"]
        case 6: return ["Push", "Pull", "Legs", "Push", "Pull", "Legs"]
        default: return (1...max(1, count)).map { "Day \($0)" }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
