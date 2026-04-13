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
    /// - Use it only when you intentionally want to create a fresh DUP block.
    static func seed(
        startDate: Date,
        trainingWeekdays: [Int],
        context: ModelContext,
        template: ProgramTemplate = DUP10WeekTemplate.template,
        calendar: Calendar = .current
    ) throws {
        let normalizedWeekdays = Array(Set(trainingWeekdays)).sorted()

        guard normalizedWeekdays.count == template.trainingDaysPerWeek else {
            throw DUPProgramSeederError.invalidWeekdayCount(
                expected: template.trainingDaysPerWeek,
                got: normalizedWeekdays.count
            )
        }

        let scheduledDays = try DUPProgramScheduler.buildSchedule(
            startDate: startDate,
            totalWeeks: template.totalWeeks,
            trainingWeekdays: normalizedWeekdays,
            template: template,
            calendar: calendar
        )

        var createdCount = 0

        for scheduled in scheduledDays {
            let session = try DUPSessionMaterializer.makeSession(
                template: template,
                weekNumber: scheduled.weekNumber,
                dayNumber: scheduled.dayNumber,
                date: scheduled.date
            )

            session.programIndex = scheduled.sessionIndex
            context.insert(session)
            createdCount += 1
        }

        try context.save()
        print("✅ DUPProgramSeeder created \(createdCount) planned sessions.")
    }
}
