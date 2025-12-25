import Foundation

/// Experience band used for program matching.
///
/// This is deliberately separate from any other "experience" enums you may have
/// so we don't collide with existing models.
enum ProgramExperienceLevel: String, CaseIterable {
    case new          // brand new or long break
    case intermediate
    case advanced
}

/// Coarse equipment profile for matching program templates to what the user has.
///
/// Named `ProgramEquipmentProfile` on purpose to avoid clashing with any
/// existing `EquipmentProfile` types in the project.
enum ProgramEquipmentProfile: String, CaseIterable {
    case commercialGym
    case homeGymRack       // rack + barbell + DBs
    case dumbbellsAndCables
    case minimal           // bands, bodyweight, light DBs
}

/// Definition of a training program template that the coach can recommend.
///
/// This is *not* one user's specific block; it's the blueprint the
/// ProgramGenerator will turn into concrete weeks and sessions.
struct TrainingProgramDefinition: Identifiable {
    let id: String
    let name: String

    /// Primary goal this program serves (reuse your existing `Goal` model).
    let goal: Goal

    /// Minimum and maximum days per week this program supports.
    let minDays: Int
    let maxDays: Int

    /// The day count this program is really designed around.
    let recommendedDays: Int

    /// Intended lifter experience band for this program.
    let experience: ProgramExperienceLevel

    /// What equipment environment this program assumes.
    let equipmentProfile: ProgramEquipmentProfile

    /// Whether the exercise selection and loading pattern are joint-friendly by design.
    let jointFriendly: Bool

    /// Short description for the user (shown in UI).
    let description: String

    /// Coach-style explanation of *why* this program is a good fit.
    let whyItWorks: String
}
