import Foundation
import SwiftData
import Testing
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
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("6-day schedule skipping Thursday (Sun, Mon, Tue, Wed, Fri, Sat)")
    func sixDaySkipsThursday() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        // Choose the upcoming Sunday (including today if already Sunday)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayWeekday = cal.component(.weekday, from: todayStart)
        let daysUntilSunday = (1 - todayWeekday + 7) % 7
        let startDate = cal.date(byAdding: .day, value: daysUntilSunday, to: todayStart)!

        // Sun(1), Mon(2), Tue(3), Wed(4), Fri(6), Sat(7) — Thursday(5) is OFF
        let selectedWeekdays = [1, 2, 3, 4, 6, 7]

        // Seed a single week to make assertions simple
        ProgramGenerator.seedInitialProgram(
            goal: .hypertrophy,
            daysPerWeek: selectedWeekdays.count,
            totalWeeks: 1,
            includeDeloadWeek: false,
            weekdays: selectedWeekdays,
            startDate: startDate,
            context: context
        )

        // Fetch all sessions and inspect their dates
        let fetch = FetchDescriptor<Session>()
        let sessions = try context.fetch(fetch)

        // Expect exactly 6 sessions created for week 1
        #expect(sessions.count == 6)
        #expect(Set(sessions.map { $0.weekIndex }) == Set([1]))

        // Check the weekdays of the generated sessions
        let generatedWeekdays = Set(sessions.map { cal.component(.weekday, from: $0.date) })
        #expect(generatedWeekdays == Set(selectedWeekdays))
        #expect(!generatedWeekdays.contains(5)) // Ensure Thursday(5) is not present

        // Ensure all sessions are within the first 7-day window starting at our anchor date
        for s in sessions {
            #expect(s.date >= startDate)
            let diff = cal.dateComponents([.day], from: startDate, to: s.date).day ?? -1
            #expect(diff >= 0 && diff < 7)
        }
    }
}
