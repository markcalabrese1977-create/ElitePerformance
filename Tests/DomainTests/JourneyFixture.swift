import Foundation
import SwiftData
@testable import ElitePerformance

// MARK: - Script types (exact field types matching SessionItem)

struct JourneySetLog {
    var load: Double
    var reps: Int
    var rir: Int       // Int, not Double — matches SessionItem.actualRIRs: [Int]
    var feedback: String
    var pump: Int
}

struct JourneyExerciseLog {
    var exerciseId: String
    var sets: [JourneySetLog]
}

struct JourneySessionScript {
    var logs: [JourneyExerciseLog]
}

// MARK: - Fixture

/// Reusable in-memory harness for journey (multi-session) tests.
///
/// Stands up a ModelContext using the identical pattern to every other DomainTest:
///   Schema([Session, SessionItem, MesoBlock, UserProfile, User, CustomExercise])
///   ModelConfiguration(isStoredInMemoryOnly: true)
///
/// Carry-forward traps documented at each guard site:
///   - hasMeaningfulPlan: source suggestedLoad must be > 0 after seedProgram()
///   - isPlanEffectivelyEmpty: target items seeded with load 0 — carry-forward writes to them
///   - Target session found by date order + exerciseId, not programIndex
struct JourneyFixture {

    let context: ModelContext

    // MARK: - Init

    /// Plain synchronous factory — no @MainActor.
    static func make() throws -> JourneyFixture {
        let schema = Schema([
            Session.self, SessionItem.self, MesoBlock.self,
            UserProfile.self, User.self, CustomExercise.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return JourneyFixture(context: ModelContext(container))
    }

    // MARK: - Program Seeding

    /// Seeds the 2-Day Full Body template starting at `startDate`.
    ///
    /// Uses DUPProgramSeeder.seed directly — avoids OnboardingResult dependency.
    /// Weekdays: Monday (2) + Thursday (5) — Calendar weekday numbering.
    ///
    /// After seeding, writes `startingLoad` to every SessionItem's suggestedLoad
    /// and fills plannedLoadsBySet with that value. Required because
    /// DUPSessionMaterializer seeds suggestedLoad = 0 and plannedLoads = [0,...],
    /// which would cause hasMeaningfulPlan() to skip carry-forward for the source item.
    ///
    /// Also inserts a User record with progressionEnabled = true so the
    /// LoadProjectionService path fires during carry-forward.
    @discardableResult
    func seedProgram(startDate: Date, startingLoad: Double = 100.0) throws -> MesoBlock {
        // Insert User so PlanMemoryEngine reads progressionEnabled = true
        let user = User(units: .lb, progressionEnabled: true)
        context.insert(user)

        // Seed via the real DUP seeder — 2-day template, Mon + Thu
        try DUPProgramSeeder.seed(
            startDate: startDate,
            trainingWeekdays: [2, 5],   // Monday=2, Thursday=5 (Calendar weekday numbering)
            context: context,
            template: FullBody2DayTemplate.template,
            mesoName: "JourneyTestMeso",
            mesoStatus: .active
        )

        // Fetch the meso that was just inserted
        let mesoDescriptor = FetchDescriptor<MesoBlock>(
            predicate: #Predicate { $0.name == "JourneyTestMeso" }
        )
        guard let meso = try context.fetch(mesoDescriptor).first else {
            throw JourneyFixtureError.mesoNotFound
        }

        // Write nonzero suggestedLoad + plannedLoadsBySet to every seeded item.
        // This satisfies hasMeaningfulPlan() on the source and gives carry-forward
        // a meaningful load to copy and project from.
        let sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        let sessions = try context.fetch(sessionDescriptor)
        for session in sessions {
            for item in session.items {
                item.suggestedLoad = startingLoad
                item.plannedLoadsBySet = Array(repeating: startingLoad, count: item.targetSets)
            }
        }

        try context.save()
        return meso
    }

    // MARK: - Session Logging

    /// Finds the current planned session (earliest non-completed session by date),
    /// applies the script to it by exerciseId, calls the real carry-forward engine,
    /// then saves.
    ///
    /// Does NOT call SessionScreenViewModel.persist() or persistCompletion().
    /// Drives PlanMemoryEngine(context:).carryForwardPlans(from:) directly.
    func logAndComplete(_ script: JourneySessionScript) throws {
        guard let session = currentPlannedSession() else {
            throw JourneyFixtureError.noPlannedSession
        }

        for exerciseLog in script.logs {
            guard let item = self.item(exerciseLog.exerciseId, in: session) else {
                continue
            }

            let setCount = exerciseLog.sets.count
            item.actualLoads        = exerciseLog.sets.map(\.load)
            item.actualReps         = exerciseLog.sets.map(\.reps)
            item.actualRIRs         = exerciseLog.sets.map(\.rir)
            item.setFeedbackBySet   = exerciseLog.sets.map(\.feedback)
            item.pumpRatingsBySet   = exerciseLog.sets.map(\.pump)
            item.isCompleted        = true

            // Resize planned arrays to match logged set count so array lengths
            // are consistent. suggestedLoad was set by seedProgram — leave it.
            if item.plannedLoadsBySet.count != setCount {
                item.plannedLoadsBySet = Array(repeating: item.suggestedLoad, count: setCount)
            }
            if item.plannedRepsBySet.count != setCount {
                item.plannedRepsBySet = Array(repeating: item.targetReps, count: setCount)
            }
        }

        session.status      = .completed
        session.completedAt = Date()

        // Drive the real production carry-forward engine directly.
        PlanMemoryEngine(context: context).carryForwardPlans(from: session)

        try context.save()
    }

    // MARK: - Read Helpers

    /// Earliest Session where status != .completed.
    /// Fetches all sorted by date and filters in memory — mirrors PlanMemoryEngine's approach.
    func currentPlannedSession() -> Session? {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.status != .completed }
    }

    /// Second earliest Session where status != .completed.
    func nextPlannedSession() -> Session? {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        let incomplete = all.filter { $0.status != .completed }
        return incomplete.count > 1 ? incomplete[1] : nil
    }

    /// First SessionItem in `session` whose exerciseId matches.
    func item(_ exerciseId: String, in session: Session) -> SessionItem? {
        session.items.first { $0.exerciseId == exerciseId }
    }

    // MARK: - Convenience reads off the next session

    /// suggestedLoad on the next planned session's item for `exerciseId`.
    func plannedLoad(exerciseId: String) -> Double {
        guard let session = nextPlannedSession(),
              let item = self.item(exerciseId, in: session) else { return 0 }
        return item.suggestedLoad
    }

    /// plannedLoadsBySet on the next planned session's item for `exerciseId`.
    func plannedLoadsBySet(exerciseId: String) -> [Double] {
        guard let session = nextPlannedSession(),
              let item = self.item(exerciseId, in: session) else { return [] }
        return item.plannedLoadsBySet
    }
}

// MARK: - Errors

enum JourneyFixtureError: Error {
    case mesoNotFound
    case noPlannedSession
}
