import Foundation

struct CatalogProgramPolicy {
    let totalWeeks: Int
    let includeDeloadWeek: Bool

    static func `default`(
        for result: OnboardingResult,
        template: ProgramApplicationService.CatalogTemplateKind
    ) -> CatalogProgramPolicy {
        switch template {
        case .defaultPPL:
            return CatalogProgramPolicy(
                totalWeeks: 10,
                includeDeloadWeek: true
            )
        }
    }
}
