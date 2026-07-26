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
        overrides: PreviewOverrides? = nil
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

    /// Patches `template` with per-exercise overrides and net-new additions.
    ///
    /// The three-step order is non-negotiable:
    ///   1. Filter: remove any exercise whose slot has `isDeleted == true`.
    ///   2. Transform: apply swap (`substituteExerciseId`) and prescription
    ///      overrides to the surviving slots. Deload is never touched.
    ///   3. Append: add net-new exercises from `addedByDay`, ordered after all
    ///      survivors using a stable per-day order index.
    static func applying(
        overrides: PreviewOverrides,
        to template: ProgramTemplate
    ) -> ProgramTemplate {
        let patchedDays = template.dayTemplates.map { day -> ProgramDayTemplate in

            // Step 1: filter deleted slots
            let survivors = day.exerciseTemplates.filter {
                overrides.slotOverrides[$0.exerciseId]?.isDeleted != true
            }

            // Step 2: transform surviving slots (swap + customize)
            let transformed: [ProgramExerciseTemplate] = survivors.map { exercise -> ProgramExerciseTemplate in
                guard let override = overrides.slotOverrides[exercise.exerciseId] else {
                    return exercise
                }

                let effectiveExerciseId = override.substituteExerciseId ?? exercise.exerciseId

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
                    exerciseId: effectiveExerciseId,
                    priority: exercise.priority,
                    notes: exercise.notes,
                    prescriptions: patchedPrescriptions,
                    setsByWeek: patchedSetsByWeek
                )
            }

            // Step 3: append net-new exercises
            let baseOrder = transformed.map(\.order).max() ?? 0
            let additions = (overrides.addedByDay[day.id] ?? []).enumerated().map { idx, added -> ProgramExerciseTemplate in
                ProgramExerciseTemplate(
                    id: added.id,
                    order: baseOrder + 10 * (idx + 1),
                    exerciseId: added.exerciseId,
                    priority: added.priority,
                    notes: nil,
                    prescriptions: buildPrescriptions(from: added),
                    setsByWeek: added.setsByWeek
                )
            }

            return ProgramDayTemplate(
                id: day.id,
                dayNumber: day.dayNumber,
                title: day.title,
                role: day.role,
                exerciseTemplates: transformed + additions
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

    /// Builds [WavePrescription] for a net-new added exercise using the
    /// user's customized wave overrides (or the standard accessory defaults).
    /// Deload is always fixed at the standard accessory defaults.
    private static func buildPrescriptions(from added: AddedExercise) -> [WavePrescription] {
        let editableWaves: [WaveType] = [.a, .b, .c]
        var prescriptions: [WavePrescription] = editableWaves.map { wave -> WavePrescription in
            let override = added.wavePrescriptions[wave]
                ?? AddedExercise.defaultWavePrescriptions[wave]!
            return WavePrescription(
                wave: wave,
                setMin: 3,
                setMax: 3,
                repMin: override.repMin,
                repMax: override.repMax,
                targetRIRMin: override.targetRIR,
                targetRIRMax: override.targetRIR
            )
        }
        prescriptions.append(WavePrescription(
            wave: .deload,
            setMin: 2,
            setMax: 2,
            repMin: 10,
            repMax: 15,
            targetRIRMin: 4,
            targetRIRMax: 4
        ))
        return prescriptions
    }
}
