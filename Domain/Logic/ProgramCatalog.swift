import Foundation
import SwiftData

/// Central catalog of all built-in training programs that the coach can recommend.
enum ProgramCatalog {

    // MARK: - Public API

    /// All available programs in v1 of the app.
    static let all: [TrainingProgramDefinition] = [
        fullBody3DayHypertrophy,
        upperLower4DayHypertrophy,
        fullBody3DayFatLoss,
        upperLower4DayFatLoss,
        hybrid5DayULPlusPump,
        ppl6DayHypertrophyWarrior
    ]

    /// Fallback if matching ever fails.
    static var defaultProgram: TrainingProgramDefinition {
        upperLower4DayHypertrophy
    }

    /// Lightweight input type for matching.
    ///
    /// We'll later map this from `UserProfile` and onboarding screens.
    struct ProfileInput {
        let goal: Goal
        let daysPerWeek: Int
        let sessionMinutes: Int
        let experience: ProgramExperienceLevel
        let equipment: ProgramEquipmentProfile
        let hasJointIssues: Bool
    }

    /// Result of a recommendation: the chosen program + a coach-style reason.
    struct Recommendation {
        let program: TrainingProgramDefinition
        let reason: String
    }

    static func recommend(for profile: ProfileInput) -> Recommendation {
        // 1) Filter by goal + days + equipment
        let candidates: [TrainingProgramDefinition] = all.filter { program in
            program.goal == profile.goal &&
            profile.daysPerWeek >= program.minDays &&
            profile.daysPerWeek <= program.maxDays &&
            isEquipmentCompatible(program.equipmentProfile, with: profile.equipment)
        }

        // If nothing matches perfectly, fall back slowly.
        let pool = candidates.isEmpty ? all : candidates

        // 2) Score each candidate
        let scored: [(TrainingProgramDefinition, Int)] = pool.map { program in
            var score = 0

            // Match days: exact = best
            if profile.daysPerWeek == program.recommendedDays {
                score += 3
            } else if profile.daysPerWeek >= program.minDays &&
                        profile.daysPerWeek <= program.maxDays {
                score += 1
            }

            // Experience: exact band is best, being slightly under is OK.
            if program.experience == profile.experience {
                score += 3
            } else if program.experience == .intermediate &&
                        profile.experience == .new {
                score += 1
            }

            // Joint-friendly bonus if user flagged issues
            if profile.hasJointIssues && program.jointFriendly {
                score += 2
            }

            // Slight bias for programs that don't overshoot time envelope too hard
            if profile.sessionMinutes <= 45 &&
                program.recommendedDays <= profile.daysPerWeek {
                score += 1
            }

            return (program, score)
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }) else {
            return Recommendation(
                program: defaultProgram,
                reason: "Defaulted to a balanced 4-day upper/lower hypertrophy plan."
            )
        }

        let program = best.0
        let reason = buildReason(for: program, profile: profile)
        return Recommendation(program: program, reason: reason)
    }

    // MARK: - Internal helpers

    private static func isEquipmentCompatible(
        _ programEquipment: ProgramEquipmentProfile,
        with userEquipment: ProgramEquipmentProfile
    ) -> Bool {
        // Simple v1 rules: commercial gym can run everything.
        if userEquipment == .commercialGym { return true }

        switch programEquipment {
        case .commercialGym:
            // Some commercial-only templates may not feel right at home.
            return userEquipment == .commercialGym
        case .homeGymRack:
            return userEquipment == .homeGymRack || userEquipment == .commercialGym
        case .dumbbellsAndCables:
            return userEquipment == .dumbbellsAndCables ||
                   userEquipment == .commercialGym ||
                   userEquipment == .homeGymRack
        case .minimal:
            return true
        }
    }

    private static func buildReason(
        for program: TrainingProgramDefinition,
        profile: ProfileInput
    ) -> String {
        var lines: [String] = []

        lines.append("You chose **\(prettyGoal(profile.goal))** as your main goal.")
        lines.append("You told me you can train **\(profile.daysPerWeek)x/week** for about **\(profile.sessionMinutes) minutes** per session.")
        lines.append("Your experience looks **\(prettyExperience(profile.experience))** with **\(prettyEquipment(profile.equipment))** access.")

        if profile.hasJointIssues && program.jointFriendly {
            lines.append("You also flagged some joint limitations, so I preferred a joint-friendly template.")
        }

        lines.append("")
        lines.append("**Why this program:** \(program.whyItWorks)")

        return lines.joined(separator: "\n")
    }

    private static func prettyGoal(_ goal: Goal) -> String {
        // Adjust to your real Goal enum; this `default` keeps us compiling
        switch goal {
        case .hypertrophy:
            return "building muscle"
        case .fatLoss:
            return "losing fat while keeping muscle"
        case .strength:
            return "getting stronger"
        @unknown default:
            return "training better"
        }
    }

    private static func prettyExperience(_ xp: ProgramExperienceLevel) -> String {
        switch xp {
        case .new:          return "new or getting back into lifting"
        case .intermediate: return "intermediate"
        case .advanced:     return "advanced"
        }
    }

    private static func prettyEquipment(_ equipment: ProgramEquipmentProfile) -> String {
        switch equipment {
        case .commercialGym:      return "a commercial gym"
        case .homeGymRack:        return "a home rack + barbell setup"
        case .dumbbellsAndCables: return "dumbbells and cables"
        case .minimal:            return "minimal equipment"
        }
    }

    // MARK: - Program Definitions

    /// 3-day full-body hypertrophy (joint-friendly)
    static let fullBody3DayHypertrophy = TrainingProgramDefinition(
        id: "fullbody_3d_hypertrophy",
        name: "3-Day Full-Body Hypertrophy (Joint-Friendly)",
        goal: .hypertrophy,
        minDays: 3,
        maxDays: 3,
        recommendedDays: 3,
        experience: .new,
        equipmentProfile: .commercialGym,
        jointFriendly: true,
        description: "Three full-body sessions per week built around big, joint-friendly movements.",
        whyItWorks: "Full-body 3x/week keeps things simple and efficient. We hit each muscle several times per week without burying you in volume. Most movements are machine or dumbbell-based, so you can focus on good reps and slow progression instead of worrying about technical complexity."
    )

    /// 4-day upper/lower hypertrophy (your default style)
    static let upperLower4DayHypertrophy = TrainingProgramDefinition(
        id: "ul_4d_hypertrophy",
        name: "4-Day Upper/Lower Hypertrophy",
        goal: .hypertrophy,
        minDays: 4,
        maxDays: 4,
        recommendedDays: 4,
        experience: .intermediate,
        equipmentProfile: .commercialGym,
        jointFriendly: true,
        description: "Classic 4-day upper/lower split focused on muscle growth and joint-friendly loading.",
        whyItWorks: "Upper/lower 4x/week gives each muscle group two quality exposures per week without demanding a 6-day schedule. We use compounds as the spine and higher-rep accessories for detail work. The coach focuses on 1–3 RIR and small, frequent progressions so you build strength and size without cooking your joints."
    )

    /// 3-day full-body fat-loss strength (Angela baseline)
    static let fullBody3DayFatLoss = TrainingProgramDefinition(
        id: "fullbody_3d_fatloss",
        name: "3-Day Fat-Loss Strength",
        goal: .fatLoss,
        minDays: 3,
        maxDays: 3,
        recommendedDays: 3,
        experience: .new,
        equipmentProfile: .commercialGym,
        jointFriendly: true,
        description: "Three strength-focused full-body sessions designed to protect muscle while you lean out.",
        whyItWorks: "In a fat-loss phase, strength training’s job is to protect muscle, not crush you. Three full-body sessions let you push the big lifts, then recover. Volume stays reasonable so you still have energy for daily life, steps, and nutrition. The coach will prioritize stable performance over constant load increases."
    )

    /// 4-day upper/lower fat-loss strength
    static let upperLower4DayFatLoss = TrainingProgramDefinition(
        id: "ul_4d_fatloss",
        name: "4-Day Upper/Lower Fat-Loss Strength",
        goal: .fatLoss,
        minDays: 4,
        maxDays: 4,
        recommendedDays: 4,
        experience: .intermediate,
        equipmentProfile: .commercialGym,
        jointFriendly: true,
        description: "Four-day upper/lower split tuned for strength and muscle retention during fat loss.",
        whyItWorks: "When you’re dieting, 4x/week upper/lower gives enough frequency to keep your main lifts moving without overwhelming recovery. We trim junk volume and focus on key compounds plus a small set of accessories. The coach will push progression on good days and encourage load holds when fatigue or RIR slip."
    )

    /// 5-day hybrid upper/lower + pump/weak-point day
    static let hybrid5DayULPlusPump = TrainingProgramDefinition(
        id: "hybrid_5d_ul_pump",
        name: "5-Day Hybrid Upper/Lower + Pump",
        goal: .hypertrophy,
        minDays: 5,
        maxDays: 5,
        recommendedDays: 5,
        experience: .intermediate,
        equipmentProfile: .commercialGym,
        jointFriendly: true,
        description: "Five-day split mixing heavier upper/lower sessions with pump/weak-point work.",
        whyItWorks: "This plan is for people who like being in the gym often, but don’t want every day to be a max-effort grind. Heavy upper/lower days drive progression on key lifts, while higher-rep pump and weak-point work rounds out the week. The coach will help you avoid overcooking volume so you can string together multiple strong weeks."
    )

    /// 6-day PPL hypertrophy – the 'warrior' template
    static let ppl6DayHypertrophyWarrior = TrainingProgramDefinition(
        id: "ppl_6d_hypertrophy",
        name: "6-Day PPL Hypertrophy (Warrior)",
        goal: .hypertrophy,
        minDays: 6,
        maxDays: 6,
        recommendedDays: 6,
        experience: .advanced,
        equipmentProfile: .commercialGym,
        jointFriendly: false, // higher commitment, tighter fatigue management
        description: "High-frequency 6-day Push/Pull/Legs split for experienced lifters.",
        whyItWorks: "Six training days a week lets you hit each muscle group often with smaller, higher-quality doses. This template assumes you understand RIR and recovery. The coach will nudge load up when you’re clearly over-performing and pull back or hold when rep quality and RIR show fatigue building, so you can train like a warrior without digging yourself into a hole."
    )
}
// MARK: - Applying onboarding result to the current program

extension ProgramCatalog {

    /// Apply the onboarding answers to the user's plan:
    /// - Pick a Goal from the TrainingGoal enum used in onboarding.
    /// - Delete only *planned* sessions (no logged work).
    /// - Seed a new block starting from today using ProgramGenerator.
    static func applyOnboardingResult(
        _ result: OnboardingResult,
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let weekdays = result.trainingDaysOfWeek.map { min(max($0, 1), 7) }.sorted()

        print("DEBUG ProgramCatalog.applyOnboardingResult – goal=\(result.goal), daysPerWeek=\(result.daysPerWeek), weekdays=\(result.trainingDaysOfWeek)")

        // 1) Map onboarding TrainingGoal -> domain Goal
        let goal = mapGoal(from: result.goal)

        // 2) Clamp days/week to a sane range (1–7 for now) based on weekdays count
        let daysPerWeek = max(1, min(weekdays.count, 7))

        print("DEBUG ProgramCatalog.applyOnboardingResult – mapped goal=\(goal), derived daysPerWeek from weekdays=\(daysPerWeek), weekdays=\(weekdays)")

        // 3) For v1, assume a 6-week block, no explicit deload week.
        //    You can later branch this on experience or ProgramOption.
        let totalWeeks = 6
        let includeDeloadWeek = false

        // 4) Delete only *planned* sessions (no logged data).
        //    Any session with logged sets should already be .inProgress or .completed
        //    because SessionView flips .planned → .inProgress on first save.
        let fetch = FetchDescriptor<Session>()
        if let sessions = try? context.fetch(fetch) {
            print("DEBUG ProgramCatalog.applyOnboardingResult – existing sessions before delete: \(sessions.count)")
            for session in sessions where session.status == .planned {
                context.delete(session)
            }
        }

        // 5) Seed a new block starting from today with the new parameters.
        print("DEBUG ProgramCatalog.applyOnboardingResult – seeding program now")
        ProgramGenerator.seedInitialProgram(
            goal: goal,
            daysPerWeek: daysPerWeek,
            totalWeeks: totalWeeks,
            includeDeloadWeek: includeDeloadWeek,
            weekdays: weekdays,
            startDate: today,
            context: context
        )
        print("DEBUG ProgramCatalog.applyOnboardingResult – finished seeding")
    }

    /// Helper: connect onboarding's TrainingGoal to the existing Goal enum.
    private static func mapGoal(from trainingGoal: TrainingGoal) -> Goal {
        switch trainingGoal {
        case .hypertrophy:
            return .hypertrophy
        case .strength:
            return .strength
        case .fatLoss:
            return .fatLoss
        case .maintenance:
            // Treat maintenance as a "longevity / feel better" style goal
            return .longevity
        }
    }
}
