import Foundation
import SwiftData

enum DUPProgramSeederError: Error {
    case invalidWeekdayCount(expected: Int, got: Int)
}

enum DUPProgramSeeder {
    /// Seeds planned sessions from the new DUP template system.
    ///
    /// Important:
    /// - This does NOT delete existing sessions.
    /// - This does NOT replace the old generator yet.
    /// - It now creates a MesoBlock and attaches each seeded session to it.
    static func seed(
        startDate: Date,
        trainingWeekdays: [Int],
        context: ModelContext,
        template: ProgramTemplate = DUP10WeekTemplate.template,
        calendar: Calendar = .current,
        mesoName: String? = nil,
        mesoStatus: MesoStatus = .draft,
        mesoNotes: String? = nil,
        overrides: ExerciseOverrideMap? = nil
    ) throws {
        let normalizedWeekdays = Array(Set(trainingWeekdays)).sorted()

        guard normalizedWeekdays.count == template.trainingDaysPerWeek else {
                    throw DUPProgramSeederError.invalidWeekdayCount(
                        expected: template.trainingDaysPerWeek,
                        got: normalizedWeekdays.count
                    )
                }
                // Note: for 2-day users on a 3-day template, the scheduler
                // will only schedule sessions on the provided weekdays.
                // This guard intentionally stays strict — callers must pass
                // the correct weekday count for the selected template.

        let startDay = calendar.startOfDay(for: startDate)

        let scheduledDays = try DUPProgramScheduler.buildSchedule(
            startDate: startDay,
            totalWeeks: template.totalWeeks,
            trainingWeekdays: normalizedWeekdays,
            template: template,
            calendar: calendar
        )

        let effectiveTemplate = overrides.map { applying(overrides: $0, to: template) } ?? template

        let blockName = mesoName ?? template.name
        let mesoBlock = MesoBlock(
            name: blockName,
            startDate: startDay,
            status: mesoStatus,
            notes: mesoNotes,
            totalWeeks: template.totalWeeks
        )
        context.insert(mesoBlock)

        var createdCount = 0

        for scheduled in scheduledDays {
            let session = try DUPSessionMaterializer.makeSession(
                template: effectiveTemplate,
                weekNumber: scheduled.weekNumber,
                dayNumber: scheduled.dayNumber,
                date: scheduled.date
            )

            session.programIndex = scheduled.sessionIndex
            session.meso = mesoBlock

            context.insert(session)
            createdCount += 1
        }

        try context.save()

    }

    /// Patches `template` with per-exercise, per-wave overrides. WaveType.deload is
    /// never touched, regardless of what an override supplies for it — deload always
    /// stays at the template's own default.
    static func applying(
        overrides: ExerciseOverrideMap,
        to template: ProgramTemplate
    ) -> ProgramTemplate {
        let patchedDays = template.dayTemplates.map { day -> ProgramDayTemplate in
            let patchedExercises = day.exerciseTemplates.map { exercise -> ProgramExerciseTemplate in
                guard let override = overrides[exercise.exerciseId] else {
                    return exercise
                }

                var patchedPrescriptions = exercise.prescriptions
                if let waveOverrides = override.wavePrescriptions {
                    patchedPrescriptions = exercise.prescriptions.map { prescription -> WavePrescription in
                        guard prescription.wave != .deload,
                              let waveOverride = waveOverrides[prescription.wave] else {
                            return prescription
                        }

                        return WavePrescription(
                            wave: prescription.wave,
                            setMin: prescription.setMin,
                            setMax: prescription.setMax,
                            repMin: waveOverride.repMin,
                            repMax: waveOverride.repMax,
                            targetRIRMin: waveOverride.targetRIR,
                            targetRIRMax: waveOverride.targetRIR,
                            intensifier: prescription.intensifier,
                            intensifierNotes: prescription.intensifierNotes
                        )
                    }
                }

                let patchedSetsByWeek = override.setsByWeek ?? exercise.setsByWeek

                return ProgramExerciseTemplate(
                    id: exercise.id,
                    order: exercise.order,
                    exerciseId: exercise.exerciseId,
                    priority: exercise.priority,
                    notes: exercise.notes,
                    prescriptions: patchedPrescriptions,
                    setsByWeek: patchedSetsByWeek
                )
            }

            return ProgramDayTemplate(
                id: day.id,
                dayNumber: day.dayNumber,
                title: day.title,
                role: day.role,
                exerciseTemplates: patchedExercises
            )
        }

        return ProgramTemplate(
            id: template.id,
            name: template.name,
            totalWeeks: template.totalWeeks,
            trainingDaysPerWeek: template.trainingDaysPerWeek,
            weekRules: template.weekRules,
            dayTemplates: patchedDays
        )
    }
}
