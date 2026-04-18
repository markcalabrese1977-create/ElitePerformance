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

        print(
            "DEBUG ProgramApplicationService.apply – goal=\(result.goal), " +
            "daysPerWeek=\(result.daysPerWeek), " +
            "weekdays=\(result.trainingDaysOfWeek), " +
            "strategy=\(debugLabel(for: strategy))"
        )

        execute(
            strategy,
            context: context,
            startDate: startDate
        )
    }

    private static func selectStrategy(for result: OnboardingResult) -> Strategy {
        let weekdays = normalizedWeekdays(from: result)

        if result.goal == .hypertrophy && weekdays.count == 6 {
            return .dup10WeekHypertrophy6Day(trainingWeekdays: weekdays)
        }

        let normalizedResult = OnboardingResult(
            goal: result.goal,
            experience: result.experience,
            daysPerWeek: weekdays.count,
            trainingDaysOfWeek: weekdays
        )

        let template = selectCatalogTemplate(for: normalizedResult)

        return .catalogGenerated(
            result: normalizedResult,
            template: template
        )
    }

    private static func selectCatalogTemplate(for result: OnboardingResult) -> CatalogTemplateKind {
        switch (result.goal, result.daysPerWeek) {
        case (.strength, 4):
            return .upperLower
        case (.maintenance, 4):
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
                print("DEBUG ProgramApplicationService.execute – completed DUP replace flow")
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
            print("DEBUG ProgramApplicationService.execute – completed catalog apply flow for template=\(template.rawValue)")
        }
    }

    private static func normalizedWeekdays(from result: OnboardingResult) -> [Int] {
        result.trainingDaysOfWeek
            .map { min(max($0, 1), 7) }
            .sorted()
    }

    private static func debugLabel(for strategy: Strategy) -> String {
        switch strategy {
        case .dup10WeekHypertrophy6Day:
            return "dup10WeekHypertrophy6Day"
        case .catalogGenerated(_, let template):
            return "catalogGenerated.\(template.rawValue)"
        }
    }
}
