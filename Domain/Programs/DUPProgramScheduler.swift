import Foundation

struct ScheduledProgramDay: Identifiable {
    let id: String
    let sessionIndex: Int
    let weekNumber: Int
    let dayNumber: Int
    let wave: WaveType
    let date: Date
}

enum ProgramSchedulerError: Error {
    case invalidTrainingDaysPerWeek(Int)
    case invalidWeekday(Int)
    case noWeekRule(Int)
}

enum DUPProgramScheduler {
    /// Input weekdays use Calendar weekday numbering:
    /// 1 = Sunday, 2 = Monday, ... 7 = Saturday
    static func buildSchedule(
        startDate: Date,
        totalWeeks: Int,
        trainingWeekdays: [Int],
        template: ProgramTemplate,
        calendar: Calendar = .current
    ) throws -> [ScheduledProgramDay] {
        let normalizedWeekdays = try normalizeWeekdays(trainingWeekdays)

        guard normalizedWeekdays.count == template.trainingDaysPerWeek else {
            throw ProgramSchedulerError.invalidTrainingDaysPerWeek(normalizedWeekdays.count)
        }

        let startDay = calendar.startOfDay(for: startDate)
        let totalSessions = totalWeeks * normalizedWeekdays.count

        var scheduled: [ScheduledProgramDay] = []
        scheduled.reserveCapacity(totalSessions)

        var current = startDay
        var sessionIndex = 1

        while scheduled.count < totalSessions {
            let weekday = calendar.component(.weekday, from: current)

            if normalizedWeekdays.contains(weekday) {
                let zeroBased = scheduled.count
                let weekNumber = (zeroBased / template.trainingDaysPerWeek) + 1
                let dayNumber = (zeroBased % template.trainingDaysPerWeek) + 1

                guard let weekRule = template.rule(forWeek: weekNumber) else {
                    throw ProgramSchedulerError.noWeekRule(weekNumber)
                }

                let item = ScheduledProgramDay(
                    id: "w\(weekNumber)d\(dayNumber)_\(sessionIndex)",
                    sessionIndex: sessionIndex,
                    weekNumber: weekNumber,
                    dayNumber: dayNumber,
                    wave: weekRule.wave,
                    date: current
                )

                scheduled.append(item)
                sessionIndex += 1
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else {
                break
            }
            current = next
        }

        return scheduled
    }

    private static func normalizeWeekdays(_ weekdays: [Int]) throws -> [Int] {
        let deduped = Array(Set(weekdays)).sorted()

        for value in deduped {
            if !(1...7).contains(value) {
                throw ProgramSchedulerError.invalidWeekday(value)
            }
        }

        return deduped
    }
}
