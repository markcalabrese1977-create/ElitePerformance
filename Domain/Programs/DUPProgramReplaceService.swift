import Foundation
import SwiftData

enum DUPProgramReplaceService {
    /// Replaces all non-completed sessions on or after the chosen start date
    /// with a freshly seeded DUP block.
    ///
    /// Keeps completed history intact.
    static func replacePlannedProgram(
        startDate: Date,
        trainingWeekdays: [Int],
        context: ModelContext,
        template: ProgramTemplate = DUP10WeekTemplate.template,
        calendar: Calendar = .current
    ) throws {
        let startDay = calendar.startOfDay(for: startDate)

        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        let allSessions = try context.fetch(descriptor)

        let sessionsToDelete = allSessions.filter { session in
            let sessionDay = calendar.startOfDay(for: session.date)
            return sessionDay >= startDay && session.status != .completed
        }

        for session in sessionsToDelete {
            context.delete(session)
        }

        try context.save()

        try DUPProgramSeeder.seed(
            startDate: startDay,
            trainingWeekdays: trainingWeekdays,
            context: context,
            template: template,
            calendar: calendar
        )
    }
}
