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
        mesoNotes: String? = nil
    ) throws {
        let normalizedWeekdays = Array(Set(trainingWeekdays)).sorted()

        guard normalizedWeekdays.count == template.trainingDaysPerWeek else {
            throw DUPProgramSeederError.invalidWeekdayCount(
                expected: template.trainingDaysPerWeek,
                got: normalizedWeekdays.count
            )
        }

        let startDay = calendar.startOfDay(for: startDate)

        let scheduledDays = try DUPProgramScheduler.buildSchedule(
            startDate: startDay,
            totalWeeks: template.totalWeeks,
            trainingWeekdays: normalizedWeekdays,
            template: template,
            calendar: calendar
        )

        let blockName = mesoName ?? template.name
        let mesoBlock = MesoBlock(
            name: blockName,
            startDate: startDay,
            status: mesoStatus,
            notes: mesoNotes
        )
        context.insert(mesoBlock)

        var createdCount = 0

        for scheduled in scheduledDays {
            let session = try DUPSessionMaterializer.makeSession(
                template: template,
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
        print("✅ DUPProgramSeeder created \(createdCount) planned sessions in meso block '\(blockName)'.")
    }
}
