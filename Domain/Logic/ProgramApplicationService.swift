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

        // 6-day hypertrophy — DUP is the best-in-class option
        case (.hypertrophy, 6):
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
            profile.usesKilograms = result.usesKilograms
        } else {
            let profile = UserProfile(
                experience: result.experience,
                primaryGoal: goalToPrimaryGoal(result.goal),
                daysPerWeek: result.daysPerWeek,
                sessionLengthMinutes: result.sessionLengthMinutes,
                equipmentProfile: result.equipmentProfile,
                injuryFlags: result.injuryFlags,
                minLoadIncrement: result.minLoadIncrement,
                usesKilograms: result.usesKilograms
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
