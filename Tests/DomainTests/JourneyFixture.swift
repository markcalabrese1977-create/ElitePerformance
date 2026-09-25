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
    /// After seeding, writes `startingLoad` to only the FIRST scheduled occurrence
    /// of EACH LETTER CHAIN — (exerciseId, dayLabel, wave) — via suggestedLoad +
    /// plannedLoadsBySet. Every later occurrence in a chain that's already been
    /// seeded once is left exactly as DUPSessionMaterializer produced it —
    /// suggestedLoad = 0, plannedLoadsBySet = [0,...] — so carry-forward has real
    /// empty targets to write into.
    ///
    /// The chain key was originally exerciseId alone. That predates per-letter
    /// anchoring: PlanMemoryEngine.nextTargetItem now carries week 1's A result into
    /// week 4's A on the same day slot, so an exerciseId-keyed baseline would leave
    /// every B- and C-wave occurrence permanently at zero with nothing targeting
    /// them. See the seeding loop below for the full rationale.
    ///
    /// This is deliberate, not an oversight: PlanMemoryEngine.carryForwardPlans
    /// only ever writes into a target item when isPlanEffectivelyEmpty(target) is
    /// true (plannedLoadsBySet all zero AND suggestedLoad == 0). If every future
    /// session were pre-seeded with a nonzero suggestedLoad too, that guard would
    /// be false everywhere downstream and the engine's load-writing branch would
    /// never fire — the journey would silently test nothing beyond the seeded
    /// baseline. (Verified empirically: with every session pre-seeded, session 2's
    /// suggestedLoad after carry-forward was exactly the seeded 100.0, not an
    /// engine-produced value.) Only the source item needs a nonzero starting point
    /// — hasMeaningfulPlan(source) is satisfied by plannedRepsBySet alone, which
    /// the materializer already fills with nonzero target reps, but a zero
    /// suggestedLoad on the source would zero out the carry-forward's 2x cap
    /// (min(projection, source.suggestedLoad * 2.0)).
    ///
    /// "First scheduled session only" is not enough for a multi-day template: a
    /// Day B exercise doesn't appear until the program's SECOND session, so seeding
    /// only session[0] left every Day B exercise's suggestedLoad at 0 forever — the
    /// 2x cap against that zero baseline silently zeroes any later projection too.
    /// (Verified empirically via Scenario 2: every Day B item's suggestedLoad
    /// stayed exactly 0.0 across the whole journey.) Seeding the first occurrence
    /// of every exerciseId, not just session index 0, fixes this while preserving
    /// the isPlanEffectivelyEmpty behavior above for every subsequent occurrence.
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

        // Write nonzero suggestedLoad + plannedLoadsBySet to the first scheduled
        // occurrence of each LETTER CHAIN — see doc comment above.
        //
        // A chain is (exerciseId, dayLabel, wave): PlanMemoryEngine.nextTargetItem
        // anchors per letter, so week 1's A-wave result targets week 4's A-wave
        // session on the SAME day slot, not the next session that happens to contain
        // the exercise. Keying this set by exerciseId alone (the original rule, which
        // predates per-letter anchoring) baselines only the first A-wave occurrence
        // and leaves every B- and C-wave occurrence at the materializer's zeros
        // forever — nothing ever targets them, so the scenarios would log 0 lb
        // sessions and the invariant checker would report a ZEROED storm that is a
        // fixture artifact, not engine behavior.
        //
        // Per-chain keying preserves this helper's actual intent unchanged — the
        // FIRST occurrence in each chain gets a baseline, every LATER occurrence
        // stays empty so carry-forward has a real empty target to write into — and
        // it matches production, where ProgramGenerator.anchorLoadsForNewMeso
        // anchors every item in the block at seed time.
        //
        // The seeded VALUE is prescription-aware, mirroring the production anchor
        // (ProgramGenerator.anchorLoadsForNewMeso): a notional per-exercise e1RM is
        // derived once from `startingLoad` against that exercise's FIRST prescription
        // (week 1, wave A), then every chain's baseline is projected back out of that
        // e1RM at its OWN targetReps/targetRIR via E1RMCalculator — the same inverse-
        // Epley + RIR formula production uses.
        //
        // A flat `startingLoad` on every chain (the earlier rule) made the deload
        // week's baseline identical to wave A's, which is not what production does:
        // deload prescriptions carry a higher RIR and so anchor LOWER. Since
        // carry-forward no longer writes into deload items at all (nothing precedes
        // them in their own letter chain), seed-time anchoring is now the only thing
        // that sets a deload load, and the fixture has to model it to test it.
        //
        // Wave A's week-1 baseline round-trips back to exactly `startingLoad`, so
        // this is a no-op for the wave-A chain every existing expectation is written
        // against; only the B / C / deload chains change.
        let sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        let sessions = try context.fetch(sessionDescriptor)

        // Pass 1 — notional e1RM per exercise, inverted from `startingLoad` at that
        // exercise's first-seen prescription. Sessions are date-ordered, so that is
        // week 1 == wave A.
        var notionalE1RMByExercise: [String: Double] = [:]
        for session in sessions {
            for item in session.items where notionalE1RMByExercise[item.exerciseId] == nil {
                let reps = item.targetReps > 0 ? item.targetReps : 10
                let rirFactor = 1.0 - (Double(item.targetRIR) * 0.025)
                guard rirFactor > 0 else { continue }
                notionalE1RMByExercise[item.exerciseId] =
                    startingLoad * (1.0 + Double(reps) / 30.0) / rirFactor
            }
        }

        // Pass 2 — baseline the first occurrence of each chain at its own prescription.
        var seededChains: Set<String> = []
        for session in sessions {
            for item in session.items {
                let chainKey = [
                    item.exerciseId,
                    session.dayLabel ?? "",
                    item.waveRaw?.lowercased() ?? ""
                ].joined(separator: "|")
                guard !seededChains.contains(chainKey) else { continue }
                seededChains.insert(chainKey)

                let anchored: Double = {
                    guard let e1rm = notionalE1RMByExercise[item.exerciseId], e1rm > 0 else {
                        return startingLoad
                    }
                    let raw = E1RMCalculator.load(
                        for: e1rm,
                        reps: item.targetReps > 0 ? item.targetReps : 10,
                        targetRIR: item.targetRIR
                    )
                    let rounded = E1RMCalculator.rounded(raw, increment: 2.5)
                    return rounded > 0 ? rounded : startingLoad
                }()

                item.suggestedLoad = anchored
                item.plannedLoadsBySet = Array(repeating: anchored, count: item.targetSets)
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
        try logAndComplete(script, session: session)
    }

    /// Same as `logAndComplete(_:)` but completes a caller-specified session
    /// instead of the earliest non-completed one. Lets a test "skip" a session
    /// (leave it `.planned`, never logged) and complete a later one directly —
    /// there is no SessionStatus.skipped case, so a skip is simulated by simply
    /// not calling this for that session.
    func logAndComplete(_ script: JourneySessionScript, session: Session) throws {
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

    // MARK: - Cross-Block Transitions

    /// Seeds a maintenance block from `sourceMeso` via the real Path A entry point
    /// (MaintenanceProgramSeeder.seed) — clones sourceMeso's day/exercise structure,
    /// applies the maintenance prescription, and anchors loads from full session
    /// history via the real ProgramGenerator.anchorLoadsForNewMeso, exactly as
    /// production does. Archives sourceMeso (and any other active meso) and deletes
    /// its non-completed future sessions, mirroring the real function's behavior.
    @discardableResult
    func seedMaintenanceFromMeso(
        sourceMeso: MesoBlock,
        trainingWeekdays: [Int] = [2, 5],
        totalWeeks: Int = 4,
        startDate: Date
    ) throws -> MesoBlock {
        try MaintenanceProgramSeeder.seed(
            from: sourceMeso,
            trainingWeekdays: trainingWeekdays,
            totalWeeks: totalWeeks,
            startDate: startDate,
            context: context
        )
        return try mostRecentActiveMeso()
    }

    /// Seeds a maintenance block from a fresh ProgramTemplate via the real Path B
    /// entry point (MaintenanceProgramSeeder.seedFromNewProgram) — does NOT clone
    /// the prior meso's roster. Anchors loads from full session history via the
    /// real (private to that file) anchorLoadsFromFullHistory.
    @discardableResult
    func seedMaintenanceFromTemplate(
        template: ProgramTemplate,
        totalWeeks: Int = 4,
        startDate: Date
    ) throws -> MesoBlock {
        try MaintenanceProgramSeeder.seedFromNewProgram(
            template: template,
            totalWeeks: totalWeeks,
            startDate: startDate,
            context: context
        )
        return try mostRecentActiveMeso()
    }

    /// Seeds a fresh regular meso via the real DUPProgramReplaceService.replacePlannedProgram
    /// entry point — confirmed via recon to be the real, single shared entry point for
    /// seeding any regular meso in production (App/ContentView.swift and
    /// Features/Home/HomeView.swift's handleOnboardingDismiss both route through
    /// ProgramApplicationService.apply -> replacePlannedProgram -> DUPProgramSeeder.seed).
    /// Archives the currently active meso and deletes any of ITS non-completed sessions
    /// dated on/after `startDate` (mirrors the real "start a new meso" transition), then
    /// seeds fresh.
    ///
    /// FIXED (previously a recon finding): replacePlannedProgram now calls
    /// ProgramGenerator.anchorLoadsForNewMeso itself, as its final step, mirroring
    /// MaintenanceProgramSeeder.seed's own placement — so this method anchors loads
    /// automatically, through production code, exactly as a real meso transition would.
    /// No separate anchoring call is needed (or should be made) by callers of this method.
    @discardableResult
    func seedFreshMeso(
        startDate: Date,
        trainingWeekdays: [Int] = [2, 5],
        template: ProgramTemplate = FullBody2DayTemplate.template
    ) throws -> MesoBlock {
        try DUPProgramReplaceService.replacePlannedProgram(
            startDate: startDate,
            trainingWeekdays: trainingWeekdays,
            context: context,
            template: template
        )
        return try mostRecentActiveMeso()
    }

    /// Most recently created MesoBlock with status == .active. Used to find the
    /// block MaintenanceProgramSeeder just created — it always names the block
    /// literally "Maintenance Block", so name-based lookup isn't unique across
    /// two maintenance transitions in the same fixture.
    private func mostRecentActiveMeso() throws -> MesoBlock {
        let descriptor = FetchDescriptor<MesoBlock>(
            sortBy: [SortDescriptor(\MesoBlock.startDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        guard let meso = all.first(where: { $0.status == .active }) else {
            throw JourneyFixtureError.mesoNotFound
        }
        return meso
    }

    // MARK: - Read Helpers

    /// All sessions in the meso, chronological order, regardless of status.
    func allSessionsSorted() -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.date, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

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
