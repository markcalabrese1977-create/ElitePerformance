#if canImport(Testing)
import Testing
import SwiftData
@testable import ElitePerformance

@Suite("ProgramGenerator weekday seeding")
struct ProgramGeneratorWeekdayTests {

    /// Build an in-memory SwiftData container with only the models
    /// required by ProgramGenerator seeding (Session/SessionItem/SetLog).
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Session.self,
            SessionItem.self,
            SetLog.self
        ])

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    @Test("6-day schedule with Thu as rest day")
    func sixDaySchedule_skipsThursday() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let result = OnboardingResult(
            goal: .hypertrophy,
            daysPerWeek: 6,
            weekdays: [1, 2, 3, 4, 6, 7]   // Sun, Mon, Tue, Wed, Fri, Sat (Thu off)
        )

        ProgramGenerator.seedInitialProgram(
            goal: result.goal,
            daysPerWeek: result.daysPerWeek,
            totalWeeks: 4,
            includeDeloadWeek: false,
            weekdays: result.weekdays,
            context: context
        )

        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []

        let week1 = allSessions.filter { $0.weekIndex == 1 }

        let calendar = Calendar.current
        let weekdays = week1.map { calendar.component(.weekday, from: $0.date) }
                            .sorted()

        #expect(weekdays == [1, 2, 3, 4, 6, 7])
        #expect(!weekdays.contains(5)) // 5 = Thursday
    }
}
#endif
