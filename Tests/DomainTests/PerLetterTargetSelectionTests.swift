import XCTest
import SwiftData
@testable import ElitePerformance

/// Per-letter carry-forward target selection — `PlanMemoryEngine.nextTargetItem`.
///
/// A wave letter is a WEEK property (DUPSessionMaterializer stamps every item in a
/// session with the week rule's wave), so "same wave" alone does not identify a day
/// slot: every day of an A week carries "a". Per-letter anchoring therefore requires
/// same block + same dayLabel + same wave, which lands three weeks out in a 3-wave
/// rotation. These tests pin that, and pin the absence of a chronological fallback.
///
/// Seeded through the REAL DUPProgramSeeder + DUP10WeekTemplate so dayLabel, waveRaw
/// and the meso relationship come from production code, not hand-built fixtures.
/// That template's day 1 ("Chest + Triceps") and day 4 ("Chest + Biceps + Triceps")
/// both carry `cable_tricep_rope_pushdown` — the real cross-day pair this guards.
final class PerLetterTargetSelectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Session.self, SessionItem.self, MesoBlock.self,
            UserProfile.self, User.self, CustomExercise.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    /// A fixed Monday, so the six training weekdays (Mon–Sat) map onto day numbers
    /// 1...6 in schedule order with no week-boundary ambiguity.
    private var mondayStart: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 5   // Monday
        let d = Calendar.current.date(from: c)!
        XCTAssertEqual(Calendar.current.component(.weekday, from: d), 2, "fixture start must be a Monday")
        return d
    }

    /// Seeds the real 10-week DUP block (6 days/week, waves A,B,C,A,B,C,A,B,C,deload)
    /// and returns its sessions in date order.
    private func seedDUPBlock(_ context: ModelContext) throws -> [Session] {
        context.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(
            startDate: mondayStart,
            trainingWeekdays: [2, 3, 4, 5, 6, 7],   // Mon–Sat
            context: context,
            template: DUP10WeekTemplate.template,
            mesoName: "PerLetterTestMeso",
            mesoStatus: .active
        )
        try context.save()
        return try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])
        )
    }

    /// 1-based week and day-within-week, in schedule order.
    private func session(_ sessions: [Session], week: Int, day: Int) -> Session {
        sessions[(week - 1) * 6 + (day - 1)]
    }

    private func item(_ session: Session, _ exerciseId: String) throws -> SessionItem {
        let match = session.items.first {
            ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId)
                == ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        }
        return try XCTUnwrap(match, "\(exerciseId) missing from \(session.dayLabel ?? "?")")
    }

    // MARK: - Fixture sanity

    /// If this fails, every expectation below is meaningless — the template or the
    /// scheduler changed shape, not the engine.
    func test_fixtureShape_wavesAndDayLabelsAreAsAssumed() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        XCTAssertEqual(sessions.count, 60, "10 weeks x 6 training days")

        let w1d1 = session(sessions, week: 1, day: 1)
        let w4d1 = session(sessions, week: 4, day: 1)
        let w1d4 = session(sessions, week: 1, day: 4)

        XCTAssertEqual(w1d1.items.first?.waveRaw?.lowercased(), "a", "week 1 is the first A")
        XCTAssertEqual(session(sessions, week: 2, day: 1).items.first?.waveRaw?.lowercased(), "b")
        XCTAssertEqual(session(sessions, week: 3, day: 1).items.first?.waveRaw?.lowercased(), "c")
        XCTAssertEqual(w4d1.items.first?.waveRaw?.lowercased(), "a", "week 4 is the second A")

        XCTAssertEqual(w1d1.dayLabel, w4d1.dayLabel, "week 1 and week 4 share the day-1 slot")
        XCTAssertNotEqual(w1d1.dayLabel, w1d4.dayLabel, "day 1 and day 4 are different slots")

        // The whole point of the cross-day case: same exercise, two days, same week,
        // and (because wave is a week property) the same wave letter.
        XCTAssertNoThrow(try item(w1d1, ExerciseCatalog.cableTricepRopePushdown.id))
        XCTAssertNoThrow(try item(w1d4, ExerciseCatalog.cableTricepRopePushdown.id))
        XCTAssertEqual(
            w1d1.items.first?.waveRaw?.lowercased(),
            w1d4.items.first?.waveRaw?.lowercased(),
            "both days of week 1 carry the same wave letter"
        )
    }

    // MARK: - 1. Week-1 A anchors week-4 A, skipping B and C

    func test_weekOneA_targetsWeekFourA_notWeekTwoBOrWeekThreeC() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        let w1d1 = session(sessions, week: 1, day: 1)
        let benchW1 = try item(w1d1, ExerciseCatalog.benchPress.id)

        let target = PlanMemoryEngine.nextTargetItem(for: benchW1, after: w1d1, in: sessions)
        let resolved = try XCTUnwrap(target, "week 1 A must anchor a later A")

        let w4Bench = try item(session(sessions, week: 4, day: 1), ExerciseCatalog.benchPress.id)
        let w2Bench = try item(session(sessions, week: 2, day: 1), ExerciseCatalog.benchPress.id)
        let w3Bench = try item(session(sessions, week: 3, day: 1), ExerciseCatalog.benchPress.id)

        XCTAssertEqual(
            resolved.persistentModelID, w4Bench.persistentModelID,
            "bench in week 1 A must target week 4 A (the next same-letter, same-day session)"
        )
        XCTAssertNotEqual(resolved.persistentModelID, w2Bench.persistentModelID, "week 2 is wave B")
        XCTAssertNotEqual(resolved.persistentModelID, w3Bench.persistentModelID, "week 3 is wave C")
        XCTAssertEqual(resolved.waveRaw?.lowercased(), "a")
    }

    /// The write itself, end to end, must leave the intervening B and C weeks alone.
    func test_carryForward_writesOnlyTheSameLetterSession() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        let w1d1 = session(sessions, week: 1, day: 1)
        let benchW1 = try item(w1d1, ExerciseCatalog.benchPress.id)
        let w2Bench = try item(session(sessions, week: 2, day: 1), ExerciseCatalog.benchPress.id)
        let w3Bench = try item(session(sessions, week: 3, day: 1), ExerciseCatalog.benchPress.id)
        let w4Bench = try item(session(sessions, week: 4, day: 1), ExerciseCatalog.benchPress.id)

        // Give the source a real, clean, top-of-range performance so a bump is earned.
        let setCount = max(1, benchW1.targetSets)
        let repMax = benchW1.repMax ?? benchW1.targetReps
        benchW1.suggestedLoad     = 200
        benchW1.plannedLoadsBySet = Array(repeating: 200, count: setCount)
        benchW1.actualLoads       = Array(repeating: 200, count: setCount)
        benchW1.actualReps        = Array(repeating: repMax, count: setCount)
        benchW1.actualRIRs        = Array(repeating: benchW1.targetRIR, count: setCount)
        benchW1.setFeedbackBySet  = Array(repeating: "", count: setCount)
        benchW1.isCompleted       = true
        w1d1.status = .completed

        let w2Before = w2Bench.suggestedLoad
        let w3Before = w3Bench.suggestedLoad
        let w4Before = w4Bench.suggestedLoad

        PlanMemoryEngine(context: context).carryForwardPlans(from: w1d1)
        try context.save()

        XCTAssertEqual(w2Bench.suggestedLoad, w2Before, accuracy: 0.001, "week 2 (B) must not receive an A-wave load")
        XCTAssertEqual(w3Bench.suggestedLoad, w3Before, accuracy: 0.001, "week 3 (C) must not receive an A-wave load")
        XCTAssertNotEqual(w4Bench.suggestedLoad, w4Before, "week 4 (A) is the anchor target and must move")
        XCTAssertGreaterThan(w4Bench.suggestedLoad, 200, "a clean top-of-range session earns an increase")
    }

    // MARK: - 2. Cross-day pair in the same week

    func test_crossDayPair_fridayDoesNotWriteSunday_targetsItsOwnDaySlotThreeWeeksOut() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        let pushdownId = ExerciseCatalog.cableTricepRopePushdown.id
        let w1d1 = session(sessions, week: 1, day: 1)
        let sourcePushdown = try item(w1d1, pushdownId)

        let sameWeekOtherDay = try item(session(sessions, week: 1, day: 4), pushdownId)
        let w4SameDay        = try item(session(sessions, week: 4, day: 1), pushdownId)

        let resolved = try XCTUnwrap(
            PlanMemoryEngine.nextTargetItem(for: sourcePushdown, after: w1d1, in: sessions)
        )

        XCTAssertNotEqual(
            resolved.persistentModelID, sameWeekOtherDay.persistentModelID,
            "day 1's result must NOT hop into day 4's instance — different day slot, even though the wave letter matches"
        )
        XCTAssertEqual(
            resolved.persistentModelID, w4SameDay.persistentModelID,
            "day 1's result anchors day 1 of the next A week"
        )
    }

    /// The other half of the pair keeps its own independent chain.
    func test_crossDayPair_eachDaySlotAnchorsItself() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        let pushdownId = ExerciseCatalog.cableTricepRopePushdown.id
        let w1d4 = session(sessions, week: 1, day: 4)

        let resolved = try XCTUnwrap(
            PlanMemoryEngine.nextTargetItem(for: try item(w1d4, pushdownId), after: w1d4, in: sessions)
        )
        let w4d4Pushdown = try item(session(sessions, week: 4, day: 4), pushdownId)

        XCTAssertEqual(resolved.persistentModelID, w4d4Pushdown.persistentModelID)
    }

    // MARK: - 3. End of a letter's chain — no fallback

    func test_lastAWeek_hasNoLaterSameLetterSession_soThereIsNoTarget() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        // Weeks 1,4,7 are A; week 10 is deload. Week 7 is the LAST A week, so its
        // chain ends there. A chronological fallback would wrongly pick week 8 (B).
        let w7d1 = session(sessions, week: 7, day: 1)
        XCTAssertEqual(w7d1.items.first?.waveRaw?.lowercased(), "a", "week 7 is the third and last A")
        XCTAssertEqual(session(sessions, week: 8, day: 1).items.first?.waveRaw?.lowercased(), "b")

        let target = PlanMemoryEngine.nextTargetItem(
            for: try item(w7d1, ExerciseCatalog.benchPress.id),
            after: w7d1,
            in: sessions
        )

        XCTAssertNil(target, "no later A week exists — must return nil, never fall through to week 8's B")
    }

    func test_lastAWeek_carryForwardWritesNothingAnywhere() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        let w7d1 = session(sessions, week: 7, day: 1)
        let benchW7 = try item(w7d1, ExerciseCatalog.benchPress.id)

        let setCount = max(1, benchW7.targetSets)
        let repMax = benchW7.repMax ?? benchW7.targetReps
        benchW7.suggestedLoad     = 200
        benchW7.plannedLoadsBySet = Array(repeating: 200, count: setCount)
        benchW7.actualLoads       = Array(repeating: 200, count: setCount)
        benchW7.actualReps        = Array(repeating: repMax, count: setCount)
        benchW7.actualRIRs        = Array(repeating: benchW7.targetRIR, count: setCount)
        benchW7.setFeedbackBySet  = Array(repeating: "", count: setCount)
        benchW7.isCompleted       = true
        w7d1.status = .completed

        let laterBenchItems = sessions
            .filter { $0.date > w7d1.date }
            .compactMap { s in s.items.first { $0.exerciseId == benchW7.exerciseId } }
        let before = laterBenchItems.map(\.suggestedLoad)
        XCTAssertFalse(laterBenchItems.isEmpty, "weeks 8-10 still contain bench — the no-write must be a choice, not an empty set")

        PlanMemoryEngine(context: context).carryForwardPlans(from: w7d1)
        try context.save()

        XCTAssertEqual(laterBenchItems.map(\.suggestedLoad), before, "the last A week must not write into any later session")
    }

    // MARK: - 4. waveRaw nil — legacy chronological behavior preserved

    func test_nilWave_keepsChronologicalNextOccurrence() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let day0 = cal.date(byAdding: .day, value: -1, to: Date())!
        let day1 = cal.date(byAdding: .day, value: 1, to: Date())!
        let day2 = cal.date(byAdding: .day, value: 8, to: Date())!

        func makeItem(_ load: Double) -> SessionItem {
            SessionItem(order: 1, exerciseId: "bench", targetReps: 10, targetSets: 3,
                        targetRIR: 2, suggestedLoad: load, waveRaw: nil)
        }

        // No wave, no dayLabel, no meso — the shape legacy/hand-built sessions have.
        let source = makeItem(100)
        let sourceSession = Session(date: day0, status: .completed, weekIndex: 1, items: [source])
        let nearItem = makeItem(0)
        let nearSession = Session(date: day1, status: .planned, weekIndex: 1, items: [nearItem])
        let farItem = makeItem(0)
        let farSession = Session(date: day2, status: .planned, weekIndex: 2, items: [farItem])

        [sourceSession, nearSession, farSession].forEach(context.insert)
        try context.save()

        let sessions = try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])
        )
        let resolved = try XCTUnwrap(
            PlanMemoryEngine.nextTargetItem(for: source, after: sourceSession, in: sessions)
        )

        XCTAssertEqual(
            resolved.persistentModelID, nearItem.persistentModelID,
            "a wave-less source keeps the original chronological-next-occurrence target"
        )
    }

    /// An empty-string wave is an unset wave, not a letter — same legacy path.
    func test_emptyStringWave_isTreatedAsNoWave() throws {
        let context = try makeContext()
        let cal = Calendar.current

        func makeItem(_ load: Double) -> SessionItem {
            SessionItem(order: 1, exerciseId: "bench", targetReps: 10, targetSets: 3,
                        targetRIR: 2, suggestedLoad: load, waveRaw: "")
        }

        let source = makeItem(100)
        let sourceSession = Session(
            date: cal.date(byAdding: .day, value: -1, to: Date())!,
            status: .completed, weekIndex: 1, items: [source]
        )
        let nextItem = makeItem(0)
        let nextSession = Session(
            date: cal.date(byAdding: .day, value: 1, to: Date())!,
            status: .planned, weekIndex: 1, items: [nextItem]
        )

        [sourceSession, nextSession].forEach(context.insert)
        try context.save()

        let sessions = try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])
        )
        let resolved = try XCTUnwrap(
            PlanMemoryEngine.nextTargetItem(for: source, after: sourceSession, in: sessions)
        )
        XCTAssertEqual(resolved.persistentModelID, nextItem.persistentModelID)
    }

    // MARK: - Block scoping

    /// A later block's session is never an anchor target, even when its day label and
    /// wave letter coincide — letters restart with each block.
    func test_targetNeverCrossesIntoAnotherBlock() throws {
        let context = try makeContext()
        let sessions = try seedDUPBlock(context)

        // Week 7 day 1 (the last A) with a same-label, same-wave session in a
        // DIFFERENT block placed after the whole seeded meso.
        let w7d1 = session(sessions, week: 7, day: 1)
        let lastDate = sessions.last!.date

        let otherBlock = MesoBlock(name: "NextBlock", startDate: lastDate, status: .draft)
        let strayItem = SessionItem(
            order: 1, exerciseId: ExerciseCatalog.benchPress.id, targetReps: 5,
            targetSets: 4, targetRIR: 2, suggestedLoad: 0, waveRaw: "a"
        )
        let strayDate = Calendar.current.date(byAdding: .day, value: 7, to: lastDate)!
        let stray = Session(date: strayDate, status: .planned, weekIndex: 1,
                            dayLabel: w7d1.dayLabel, items: [strayItem])
        stray.meso = otherBlock
        context.insert(otherBlock)
        context.insert(stray)
        try context.save()

        let all = try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])
        )
        let target = PlanMemoryEngine.nextTargetItem(
            for: try item(w7d1, ExerciseCatalog.benchPress.id),
            after: w7d1,
            in: all
        )

        XCTAssertNil(target, "a different block's A week must not be anchored from this block")
    }
}
