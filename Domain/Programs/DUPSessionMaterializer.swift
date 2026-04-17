import Foundation

struct MaterializedProgramDay {
    let templateId: String
    let weekNumber: Int
    let wave: WaveType
    let dayNumber: Int
    let title: String
    let role: String
    let exercises: [ResolvedExercisePlan]
}

enum ProgramMaterializerError: Error {
    case missingWeekRule(Int)
    case missingDayTemplate(Int)
}

enum DUPSessionMaterializer {
    static func materializeDay(
        template: ProgramTemplate,
        weekNumber: Int,
        dayNumber: Int
    ) throws -> MaterializedProgramDay {
        guard let weekRule = template.rule(forWeek: weekNumber) else {
            throw ProgramMaterializerError.missingWeekRule(weekNumber)
        }

        guard let dayTemplate = template.dayTemplate(forDay: dayNumber) else {
            throw ProgramMaterializerError.missingDayTemplate(dayNumber)
        }

        let resolved = try ProgramTemplateResolver.resolveDay(
            template: template,
            weekNumber: weekNumber,
            dayNumber: dayNumber
        )

        return MaterializedProgramDay(
            templateId: template.id,
            weekNumber: weekNumber,
            wave: weekRule.wave,
            dayNumber: dayNumber,
            title: dayTemplate.title,
            role: dayTemplate.role,
            exercises: resolved
        )
    }

    static func makeSessionItems(
        from materializedDay: MaterializedProgramDay
    ) -> [SessionItem] {
        materializedDay.exercises.map { exercise in
            let defaultSets = max(0, exercise.defaultSets)

            let plannedReps: [Int]
            let plannedLoads: [Double]
            let plannedRIRs: [Int]

            if defaultSets == 0 {
                plannedReps = []
                plannedLoads = []
                plannedRIRs = []
            } else {
                plannedReps = Array(repeating: exercise.defaultTargetReps, count: defaultSets)
                plannedLoads = Array(repeating: 0.0, count: defaultSets)
                plannedRIRs = Array(repeating: exercise.defaultTargetRIR, count: defaultSets)
            }

            return SessionItem(
                order: exercise.order,
                exerciseId: exercise.exerciseId,
                exerciseNameSnapshot: ExerciseCatalog.displayName(for: exercise.exerciseId),
                targetReps: exercise.defaultTargetReps,
                targetSets: defaultSets,
                targetRIR: exercise.defaultTargetRIR,
                suggestedLoad: 0.0,

                waveRaw: materializedDay.wave.rawValue,
                priorityRaw: exercise.priority.rawValue,
                setMin: exercise.setMin,
                setMax: exercise.setMax,
                repMin: exercise.repMin,
                repMax: exercise.repMax,
                targetRIRMin: exercise.targetRIRMin,
                targetRIRMax: exercise.targetRIRMax,
                intensifierRaw: exercise.intensifier.rawValue,
                intensifierNotes: exercise.intensifierNotes,
                prescriptionNotes: exercise.notes,

                plannedRepsBySet: plannedReps,
                plannedLoadsBySet: plannedLoads,
                plannedRIRsBySet: plannedRIRs
            )
        }
    }

    static func makeSession(
        template: ProgramTemplate,
        weekNumber: Int,
        dayNumber: Int,
        date: Date
    ) throws -> Session {
        let materializedDay = try materializeDay(
            template: template,
            weekNumber: weekNumber,
            dayNumber: dayNumber
        )

        let items = makeSessionItems(from: materializedDay)

        return Session(
            date: date,
            status: .planned,
            readinessStars: 0,
            sessionNotes: "\(materializedDay.title) · \(materializedDay.wave.displayName) wave",
            weekIndex: weekNumber,
            items: items
        )
    }
}
