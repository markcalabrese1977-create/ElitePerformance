import Foundation
import SwiftData

enum ProgramApplicationService {
    enum Strategy {
        case dup10WeekHypertrophy6Day(trainingWeekdays: [Int])
        case catalogGenerated(
            result: OnboardingResult,
            template: CatalogTemplateKind
        )
    }

    enum CatalogTemplateKind: String {
        case defaultPPL
        case upperLower
    }

    static func apply(
        _ result: OnboardingResult,
        context: ModelContext,
        startDate: Date = Date()
    ) {
        let strategy = selectStrategy(for: result)

        execute(strategy, context: context, startDate: startDate)

        // Write UserProfile — persists onboarding answers for use by coaching engine
        writeUserProfile(from: result, context: context)
    }

    // MARK: - UserProfile persistence

    private static func writeUserProfile(from result: OnboardingResult, context: ModelContext) {
        // Fetch or create — only one UserProfile should exist
        let descriptor = FetchDescriptor<UserProfile>()
        let existing = (try? context.fetch(descriptor))?.first

        if let profile = existing {
            // Update existing profile
            profile.experience = result.experience
            profile.primaryGoal = goalToPrimaryGoal(result.goal)
            profile.daysPerWeek = result.daysPerWeek
            profile.sessionLengthMinutes = result.sessionLengthMinutes
            profile.equipmentProfile = result.equipmentProfile
            profile.injuryFlags = result.injuryFlags
            profile.minLoadIncrement = result.minLoadIncrement
            profile.usesKilograms = result.usesKilograms
        } else {
            // Create new profile
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

    // MARK: - Strategy selection

    private static func selectStrategy(for result: OnboardingResult) -> Strategy {
        let weekdays = normalizedWeekdays(from: result)

        if result.goal == .hypertrophy && weekdays.count == 6 {
            return .dup10WeekHypertrophy6Day(trainingWeekdays: weekdays)
        }

        let normalizedResult = OnboardingResult(
            goal: result.goal,
            experience: result.experience,
            daysPerWeek: weekdays.count,
            trainingDaysOfWeek: weekdays,
            equipmentProfile: result.equipmentProfile,
            sessionLengthMinutes: result.sessionLengthMinutes,
            injuryFlags: result.injuryFlags,
            usesKilograms: result.usesKilograms,
            minLoadIncrement: result.minLoadIncrement
        )

        let template = selectCatalogTemplate(for: normalizedResult)

        return .catalogGenerated(result: normalizedResult, template: template)
    }

    private static func selectCatalogTemplate(for result: OnboardingResult) -> CatalogTemplateKind {
        switch (result.goal, result.daysPerWeek) {
        case (.strength, 4):
            return .upperLower
        case (.longevity, 4):
            return .upperLower
        default:
            return .defaultPPL
        }
    }

    private static func execute(
        _ strategy: Strategy,
        context: ModelContext,
        startDate: Date
    ) {
        switch strategy {
        case .dup10WeekHypertrophy6Day(let trainingWeekdays):
            do {
                try DUPProgramReplaceService.replacePlannedProgram(
                    startDate: startDate,
                    trainingWeekdays: trainingWeekdays,
                    context: context
                )
            } catch {
                print("ERROR ProgramApplicationService.execute – DUP replace failed: \(error)")
            }

        case .catalogGenerated(let normalizedResult, let template):
            ProgramCatalog.applyOnboardingResult(
                normalizedResult,
                context: context,
                startDate: startDate,
                template: template
            )
        }
    }

    private static func normalizedWeekdays(from result: OnboardingResult) -> [Int] {
        result.trainingDaysOfWeek
            .map { min(max($0, 1), 7) }
            .sorted()
    }
}
