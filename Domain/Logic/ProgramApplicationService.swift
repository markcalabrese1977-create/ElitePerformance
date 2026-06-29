// Domain/Logic/ProgramApplicationService.swift
import Foundation
import SwiftData

enum ProgramApplicationService {

    static func apply(
        _ result: OnboardingResult,
        context: ModelContext,
        startDate: Date = Date()
    ) {
        let weekdays = normalizedWeekdays(from: result)
        let template = selectTemplate(goal: result.goal, daysPerWeek: weekdays.count)

        do {
            try DUPProgramReplaceService.replacePlannedProgram(
                startDate: startDate,
                trainingWeekdays: weekdays,
                context: context,
                template: template
            )
        } catch {
            print("ERROR ProgramApplicationService.apply – seeding failed: \(error)")
        }

        writeUserProfile(from: result, context: context)
    }

    // MARK: - Template selection

    static func selectTemplate(goal: Goal, daysPerWeek: Int) -> ProgramTemplate {
        switch (goal, daysPerWeek) {

            // 6-day — DUP is the best option regardless of goal
                    case (_, 6):
                        return DUP10WeekTemplate.template

        // 5-day — hybrid upper/lower + pump
        case (_, 5):
            return Hybrid5DayTemplate.template

        // 4-day — upper/lower for all goals
        case (_, 4):
            return UpperLower4DayTemplate.template

        // 3-day — PPL for all goals
        case (_, 3):
            return PPL3WeekTemplate.template

        // 2-day — PPL covers this (only 2 of 3 days used)
        // Fall through to PPL and let the scheduler handle day count
        case (_, 2):
                    return FullBody2DayTemplate.template

        // Fallback — upper/lower is the most broadly applicable
        default:
            return UpperLower4DayTemplate.template
        }
    }
    
    static func recommendationReason(goal: Goal, daysPerWeek: Int) -> String {
            switch (goal, daysPerWeek) {
            case (_, 6):
                        return "Six days a week is serious training. The 10-Week DUP Meso is the best fit — Daily Undulating Periodization rotates strength, hypertrophy, and intensification waves across the week, giving every muscle group multiple quality stimuli while keeping fatigue manageable. This is the most sophisticated program in the app."
            case (_, 5):
                return "Five days a week gives you enough frequency to run a hybrid upper/lower split with a dedicated pump day. The two heavy upper/lower days drive progression on key lifts while the pump day targets weak points and detail work. You get the best of both worlds without grinding yourself down."
            case (_, 4):
                return "Four days a week is the sweet spot for most serious lifters. Upper/lower gives each muscle group two quality exposures per week. Heavy compounds anchor the sessions, higher-rep accessories fill in the detail work. The coach focuses on small, consistent progressions so you build strength and size without joint stress."
            case (_, 3):
                return "Three days a week with Push/Pull/Legs hits every major muscle group with a full dedicated session. Each day has a clear primary stimulus — horizontal push, vertical pull, quad and posterior chain — so nothing gets undertrained. The wave progression keeps intensity building across the 10-week block."
            case (_, 2):
                return "Two days a week means every session has to count. Full-body training is the right call — both days hit every major muscle group so nothing falls behind. Day A is push-biased, Day B is pull-biased, and the wave progression builds across the block. Simple, efficient, and effective."
            default:
                return "Based on your goal and schedule, this program gives you the right balance of frequency, volume, and progressive overload to make consistent progress."
            }
        }

    // MARK: - UserProfile persistence

    static func writeUserProfile(from result: OnboardingResult, context: ModelContext) {
        let descriptor = FetchDescriptor<UserProfile>()
        let existing = (try? context.fetch(descriptor))?.first

        if let profile = existing {
            profile.experience = result.experience
            profile.primaryGoal = goalToPrimaryGoal(result.goal)
            profile.daysPerWeek = result.daysPerWeek
            profile.sessionLengthMinutes = result.sessionLengthMinutes
            profile.equipmentProfile = result.equipmentProfile
            profile.injuryFlags = result.injuryFlags
            profile.minLoadIncrement = result.minLoadIncrement
        } else {
            let profile = UserProfile(
                experience: result.experience,
                primaryGoal: goalToPrimaryGoal(result.goal),
                daysPerWeek: result.daysPerWeek,
                sessionLengthMinutes: result.sessionLengthMinutes,
                equipmentProfile: result.equipmentProfile,
                injuryFlags: result.injuryFlags,
                minLoadIncrement: result.minLoadIncrement
            )
            context.insert(profile)
        }

        try? context.save()
    }

    private static func goalToPrimaryGoal(_ goal: Goal) -> PrimaryGoal {
        switch goal {
        case .hypertrophy: return .hypertrophy
        case .strength:    return .strength
        case .fatLoss:     return .fatLoss
        case .longevity:   return .longevity
        }
    }

    private static func normalizedWeekdays(from result: OnboardingResult) -> [Int] {
        result.trainingDaysOfWeek
            .map { min(max($0, 1), 7) }
            .sorted()
    }
}
