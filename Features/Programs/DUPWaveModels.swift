import Foundation

// MARK: - Core Enums

enum WaveType: String, Codable, CaseIterable, Identifiable {
    case a
    case b
    case c
    case deload

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .deload: return "Deload"
        }
    }
}

enum IntensifierType: String, Codable, CaseIterable, Identifiable {
    case none
    case dropSetLast
    case restPauseLast
    case squeezePauseLast
    case customNoteOnly

    var id: String { rawValue }
}

enum ExercisePriority: String, Codable, CaseIterable, Identifiable {
    case anchor
    case standard
    case optional
    case firstCut

    var id: String { rawValue }
}

// MARK: - Program Template

struct ProgramTemplate: Identifiable, Codable {
    let id: String
    let name: String
    let totalWeeks: Int
    let trainingDaysPerWeek: Int
    let weekRules: [ProgramWeekRule]
    let dayTemplates: [ProgramDayTemplate]

    init(
        id: String,
        name: String,
        totalWeeks: Int,
        trainingDaysPerWeek: Int,
        weekRules: [ProgramWeekRule],
        dayTemplates: [ProgramDayTemplate]
    ) {
        self.id = id
        self.name = name
        self.totalWeeks = totalWeeks
        self.trainingDaysPerWeek = trainingDaysPerWeek
        self.weekRules = weekRules.sorted { $0.weekNumber < $1.weekNumber }
        self.dayTemplates = dayTemplates.sorted { $0.dayNumber < $1.dayNumber }
    }

    func rule(forWeek weekNumber: Int) -> ProgramWeekRule? {
        weekRules.first { $0.weekNumber == weekNumber }
    }

    func dayTemplate(forDay dayNumber: Int) -> ProgramDayTemplate? {
        dayTemplates.first { $0.dayNumber == dayNumber }
    }
}

struct ProgramWeekRule: Codable, Identifiable {
    var id: String { "week-\(weekNumber)" }

    let weekNumber: Int
    let wave: WaveType
    let notes: String?

    var isDeload: Bool {
        wave == .deload
    }
}

struct ProgramDayTemplate: Identifiable, Codable {
    let id: String
    let dayNumber: Int
    let title: String
    let role: String
    let exerciseTemplates: [ProgramExerciseTemplate]

    init(
        id: String,
        dayNumber: Int,
        title: String,
        role: String,
        exerciseTemplates: [ProgramExerciseTemplate]
    ) {
        self.id = id
        self.dayNumber = dayNumber
        self.title = title
        self.role = role
        self.exerciseTemplates = exerciseTemplates.sorted { $0.order < $1.order }
    }
}

struct ProgramExerciseTemplate: Identifiable, Codable {
    let id: String
    let order: Int
    let exerciseId: String
    let priority: ExercisePriority
    let notes: String?
    let prescriptions: [WavePrescription]

    /// Per-week set counts for this exercise. Index 0 = week 1.
    /// Empty means use WavePrescription.defaultSetCount for all weeks.
    var setsByWeek: [Int]

    init(
        id: String,
        order: Int,
        exerciseId: String,
        priority: ExercisePriority,
        notes: String? = nil,
        prescriptions: [WavePrescription],
        setsByWeek: [Int] = []
    ) {
        self.id = id
        self.order = order
        self.exerciseId = exerciseId
        self.priority = priority
        self.notes = notes
        self.prescriptions = prescriptions
        self.setsByWeek = setsByWeek
    }

    enum CodingKeys: String, CodingKey {
        case id, order, exerciseId, priority, notes, prescriptions, setsByWeek
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
        exerciseId = try container.decode(String.self, forKey: .exerciseId)
        priority = try container.decode(ExercisePriority.self, forKey: .priority)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        prescriptions = try container.decode([WavePrescription].self, forKey: .prescriptions)
        setsByWeek = (try? container.decode([Int].self, forKey: .setsByWeek)) ?? []
    }

    func prescription(for wave: WaveType) -> WavePrescription? {
        prescriptions.first { $0.wave == wave }
    }

    /// Set count for a specific week (1-indexed). Falls back to prescription default.
    func sets(forWeek weekNumber: Int, wave: WaveType) -> Int {
        let idx = weekNumber - 1
        if idx >= 0 && idx < setsByWeek.count {
            return setsByWeek[idx]
        }
        return prescription(for: wave)?.defaultSetCount ?? 3
    }
}

struct WavePrescription: Codable {
    let wave: WaveType
    let setMin: Int
    let setMax: Int
    let repMin: Int
    let repMax: Int
    let targetRIRMin: Int
    let targetRIRMax: Int
    let intensifier: IntensifierType
    let intensifierNotes: String?

    init(
        wave: WaveType,
        setMin: Int,
        setMax: Int,
        repMin: Int,
        repMax: Int,
        targetRIRMin: Int,
        targetRIRMax: Int,
        intensifier: IntensifierType = .none,
        intensifierNotes: String? = nil
    ) {
        self.wave = wave
        self.setMin = setMin
        self.setMax = setMax
        self.repMin = repMin
        self.repMax = repMax
        self.targetRIRMin = targetRIRMin
        self.targetRIRMax = targetRIRMax
        self.intensifier = intensifier
        self.intensifierNotes = intensifierNotes
    }

    var defaultSetCount: Int { setMin }

    var defaultTargetReps: Int {
        if repMin == repMax { return repMin }
        return repMin
    }

    var defaultTargetRIR: Int {
        if targetRIRMin == targetRIRMax { return targetRIRMin }
        return targetRIRMax
    }
}

struct ResolvedExercisePlan {
    let order: Int
    let exerciseId: String
    let priority: ExercisePriority
    let notes: String?
    let wave: WaveType
    let setMin: Int
    let setMax: Int
    let repMin: Int
    let repMax: Int
    let targetRIRMin: Int
    let targetRIRMax: Int
    let intensifier: IntensifierType
    let intensifierNotes: String?
    let defaultSets: Int
    let defaultTargetReps: Int
    let defaultTargetRIR: Int
}

enum ProgramResolutionError: Error {
    case missingWeekRule(Int)
    case missingDayTemplate(Int)
    case missingPrescription(day: Int, exerciseId: String, wave: WaveType)
}

struct ProgramTemplateResolver {
    static func resolveDay(
        template: ProgramTemplate,
        weekNumber: Int,
        dayNumber: Int
    ) throws -> [ResolvedExercisePlan] {
        guard let weekRule = template.rule(forWeek: weekNumber) else {
            throw ProgramResolutionError.missingWeekRule(weekNumber)
        }

        guard let dayTemplate = template.dayTemplate(forDay: dayNumber) else {
            throw ProgramResolutionError.missingDayTemplate(dayNumber)
        }

        return try dayTemplate.exerciseTemplates.map { exercise in
            guard let prescription = exercise.prescription(for: weekRule.wave) else {
                throw ProgramResolutionError.missingPrescription(
                    day: dayNumber,
                    exerciseId: exercise.exerciseId,
                    wave: weekRule.wave
                )
            }

            return ResolvedExercisePlan(
                order: exercise.order,
                exerciseId: exercise.exerciseId,
                priority: exercise.priority,
                notes: exercise.notes,
                wave: weekRule.wave,
                setMin: prescription.setMin,
                setMax: prescription.setMax,
                repMin: prescription.repMin,
                repMax: prescription.repMax,
                targetRIRMin: prescription.targetRIRMin,
                targetRIRMax: prescription.targetRIRMax,
                intensifier: prescription.intensifier,
                intensifierNotes: prescription.intensifierNotes,
                defaultSets: exercise.sets(forWeek: weekNumber, wave: weekRule.wave),
                defaultTargetReps: prescription.defaultTargetReps,
                defaultTargetRIR: prescription.defaultTargetRIR
            )
        }
    }
}
