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

// MARK: - 10 -> 12 week conversion (DUPMesoLengthConversion)


/// 10 -> 12 week conversion of an active DUP block (see DUPMesoLengthConversion).
/// Seeds a real 6-day DUP10WeekTemplate block, Fri Sep 25 2026, Fri/Sat/Sun/Mon/Tue/Wed.
final class DUPMesoLengthConversionTests: XCTestCase {

    private var container: ModelContainer?

    private func cal() -> Calendar { Calendar(identifier: .gregorian) }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func seededBlock() throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        try DUPProgramSeeder.seed(
            startDate: date(2026, 9, 25),
            trainingWeekdays: [1, 2, 3, 4, 6, 7],
            context: ctx,
            template: DUP10WeekTemplate.template,
            calendar: cal(),
            mesoName: "10-Week DUP Meso",
            mesoStatus: .active
        )
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        return (ctx, block)
    }

    private func sessions(_ ctx: ModelContext) throws -> [Session] {
        try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
    }

    private func week(_ w: Int, _ ctx: ModelContext) throws -> [Session] {
        try sessions(ctx).filter { $0.weekIndex == w }
    }

    /// Gives weeks 7/8/9 real loads (distinct per week and item), week 10 stale deload loads, and makes
    /// one day's first lift a bodyweight pull-up in weeks 7-10 (with a nonzero source load, to prove the
    /// bodyweight rule wins over the copy).
    private func seedLoads(_ ctx: ModelContext) throws {
        let bwDay = try XCTUnwrap(try week(7, ctx).first { $0.dayLabel?.contains("Back") == true }?.dayLabel)
        for w in 7...10 {
            for s in try week(w, ctx) {
                for i in s.items.sorted(by: { $0.order < $1.order }) {
                    if s.dayLabel == bwDay, i.order == s.items.map(\.order).min() { i.exerciseId = "pull_up" }
                    if w == 10 {
                        i.suggestedLoad = 50
                        i.plannedLoadsBySet = Array(repeating: 50.0, count: max(i.plannedLoadsBySet.count, 1))
                    } else {
                        let base = Double(100 + w * 10 + i.order)
                        i.suggestedLoad = base
                        i.plannedLoadsBySet = (0..<max(i.targetSets, 1)).map { base + Double($0) * 2.5 }
                    }
                }
            }
        }
        try ctx.save()
    }

    private func expectedLoads(_ src: SessionItem) -> (suggested: Double, planned: [Double]) {
        let n = max(0, src.targetSets)
        if ExerciseCatalog.isBodyweight(exerciseId: src.exerciseId) { return (0, Array(repeating: 0, count: n)) }
        var planned = Array(src.plannedLoadsBySet.prefix(n))
        if planned.count < n { planned += Array(repeating: planned.last ?? src.suggestedLoad, count: n - planned.count) }
        return (src.suggestedLoad, planned)
    }

    // MARK: Fixture sanity

    func test_fixture_isTheDescribedBlock() throws {
        let (ctx, block) = try seededBlock()
        XCTAssertEqual(block.totalWeeks, 10)
        XCTAssertEqual(try sessions(ctx).count, 60)
        let w7 = try week(7, ctx)
        XCTAssertEqual(cal().startOfDay(for: w7[0].date), date(2026, 11, 6), "week 7 starts Fri Nov 6")
        XCTAssertEqual(Set(try week(10, ctx).flatMap { $0.items.compactMap(\.waveRaw) }), ["deload"])
    }

    // MARK: Dry run

    /// Everything a conversion could touch, as one comparable string.
    private func fingerprint(_ ctx: ModelContext) throws -> String {
        var out: [String] = []
        for b in try ctx.fetch(FetchDescriptor<MesoBlock>()).sorted(by: { $0.name + "\($0.startDate)" < $1.name + "\($1.startDate)" }) {
            out.append("B|\(b.name)|\(b.status.rawValue)|\(b.totalWeeks.map(String.init) ?? "nil")|\(b.isMaintenance)|\(b.notes ?? "")")
        }
        for s in try sessions(ctx) {
            out.append("S|\(s.id?.uuidString ?? "")|\(s.date.timeIntervalSince1970)|\(s.weekIndex)|\(s.programIndex.map(String.init) ?? "nil")|\(s.dayLabel ?? "")|\(s.status.rawValue)|\(s.sessionNotes ?? "")|\(s.meso?.name ?? "")|\(s.items.count)")
            for i in s.items.sorted(by: { $0.order < $1.order }) {
                out.append("I|\(i.id?.uuidString ?? "")|\(i.order)|\(i.exerciseId)|\(i.waveRaw ?? "")|\(i.targetSets)|\(i.targetReps)|\(i.targetRIR)|\(i.suggestedLoad)|\(i.setMin.map(String.init) ?? "")|\(i.setMax.map(String.init) ?? "")|\(i.repMin.map(String.init) ?? "")|\(i.repMax.map(String.init) ?? "")|\(i.targetRIRMin.map(String.init) ?? "")|\(i.targetRIRMax.map(String.init) ?? "")|\(i.intensifierRaw ?? "")|\(i.prescriptionNotes ?? "")|\(i.plannedRepsBySet)|\(i.plannedLoadsBySet)|\(i.plannedRIRsBySet)|\(i.actualReps)|\(i.actualLoads)|\(i.actualRIRs)|\(i.planEdited)|\(i.isCompleted)")
            }
        }
        return out.joined(separator: "\n")
    }

    func test_dryRun_writesNothing_andDescribesEveryWrite() throws {
        let (ctx, block) = try seededBlock()
        try ctx.save()
        let before = try fingerprint(ctx)
        XCTAssertFalse(ctx.hasChanges)

        let report = DUPMesoLengthConversion.dryRun(block: block, context: ctx, calendar: cal())

        XCTAssertTrue(report.blockers.isEmpty, "\(report.blockers)")
        XCTAssertFalse(report.didWrite)
        XCTAssertEqual(try fingerprint(ctx), before, "a dry run must not change a single field")
        XCTAssertFalse(ctx.hasChanges, "a dry run must leave the context clean (nothing inserted, deleted or dirtied)")
        XCTAssertEqual(try sessions(ctx).count, 60)
        XCTAssertEqual(block.totalWeeks, 10)
        XCTAssertEqual(block.name, "10-Week DUP Meso")
        XCTAssertTrue(report.lines.contains { $0.contains("CONVERT week 10") })
        XCTAssertTrue(report.lines.contains { $0.contains("CREATE weeks 11-12 (12 sessions") })
        // Report content: every gate passed, one table row per week-10 item, one chain row per day x letter.
        XCTAssertEqual(report.gates.count, 9)
        XCTAssertTrue(report.gates.allSatisfy { $0.status == .passed }, "\(report.gates)")
        XCTAssertEqual(report.itemTable.count, try week(10, ctx).reduce(0) { $0 + $1.items.count })
        XCTAssertEqual(report.chainTable.count, 6 * 3)
        XCTAssertTrue(report.chainTable.allSatisfy { $0.contains("→nil") })
    }

    /// LOCAL ONLY: runs the dry run against a real backup export (never committed). Enable with
    ///   TEST_RUNNER_EP_BACKUP_FIXTURE=/path/to/ElitePerformance_Backup_v1_….json
    ///   TEST_RUNNER_EP_DRYRUN_REPORT_OUT=/path/to/report.txt   (optional)
    func test_dryRun_againstBackupFixture_writesNothing() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: c)
        let ctx = ModelContext(c)

        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>())
        let active = blocks.filter { $0.status == .active && !$0.isMaintenance }
        var lines = ["blocks in backup: " + blocks.map { "'\($0.name)' \($0.status.rawValue) tw=\($0.totalWeeks.map(String.init) ?? "nil") maint=\($0.isMaintenance)" }.joined(separator: "; ")]
        let block = try XCTUnwrap(active.first, "no active non-maintenance block in the backup")
        XCTAssertEqual(active.count, 1, "expected exactly one active regular block")

        let before = try fingerprint(ctx)
        let report = DUPMesoLengthConversion.dryRun(block: block, context: ctx, calendar: Calendar.current)
        XCTAssertEqual(try fingerprint(ctx), before, "a dry run must not change a single field")
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertFalse(report.didWrite)

        lines.append("sessions in block: \(block.sessions.count)")
        lines.append(report.text)
        let text = lines.joined(separator: "\n")
        if let out = ProcessInfo.processInfo.environment["EP_DRYRUN_REPORT_OUT"], !out.isEmpty {
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Apply

    func test_apply_producesTwelveWeekBlock() throws {
        let (ctx, block) = try seededBlock()
        try seedLoads(ctx)
        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.didWrite, "\(report.blockers)")
        XCTAssertEqual(report.sessionsConverted, 6)
        XCTAssertEqual(report.sessionsCreated, 12)

        XCTAssertEqual(block.totalWeeks, 12)
        XCTAssertEqual(block.name, "12-Week DUP Meso")
        let all = try sessions(ctx)
        XCTAssertEqual(all.count, 72)

        // Six sessions per week, 12 weeks, programIndex 1...72 unique.
        for w in 1...12 { XCTAssertEqual(try week(w, ctx).count, 6, "week \(w)") }
        XCTAssertEqual(Set(all.compactMap(\.programIndex)), Set(1...72))
        for w in 10...12 {
            let idx = try week(w, ctx).compactMap(\.programIndex).sorted()
            XCTAssertEqual(idx, Array(((w - 1) * 6 + 1)...(w * 6)), "week \(w) programIndex")
        }

        // Waves: 10 = a, 11 = b, 12 = c; no deload anywhere.
        XCTAssertEqual(Set(try week(10, ctx).flatMap { $0.items.compactMap(\.waveRaw) }), ["a"])
        XCTAssertEqual(Set(try week(11, ctx).flatMap { $0.items.compactMap(\.waveRaw) }), ["b"])
        XCTAssertEqual(Set(try week(12, ctx).flatMap { $0.items.compactMap(\.waveRaw) }), ["c"])
        XCTAssertFalse(all.contains { $0.items.contains { $0.waveRaw == "deload" } })
        for w in 1...12 { XCTAssertFalse(try week(w, ctx).contains { $0.isDeloadWeek }, "week \(w) must not read as deload") }

        // Dates: wk 10 unchanged (Nov 27 - Dec 2), wk 11 Dec 4-9, wk 12 Dec 11-16; Thursdays empty.
        func span(_ w: Int) throws -> (Date, Date) {
            let ds = try week(w, ctx).map { cal().startOfDay(for: $0.date) }
            return (ds.min()!, ds.max()!)
        }
        XCTAssertEqual(try span(10).0, date(2026, 11, 27)); XCTAssertEqual(try span(10).1, date(2026, 12, 2))
        XCTAssertEqual(try span(11).0, date(2026, 12, 4));  XCTAssertEqual(try span(11).1, date(2026, 12, 9))
        XCTAssertEqual(try span(12).0, date(2026, 12, 11)); XCTAssertEqual(try span(12).1, date(2026, 12, 16))
        XCTAssertFalse(all.contains { cal().component(.weekday, from: $0.date) == 5 }, "Thursday is a rest day")
        XCTAssertEqual(Set(all.map { cal().startOfDay(for: $0.date) }).count, 72, "no date collisions")

        // Converted/created items: prescription matches the source letter, loads zero, nothing logged.
        for s10 in try week(10, ctx) {
            let s7 = try XCTUnwrap(try week(7, ctx).first { $0.dayLabel == s10.dayLabel })
            XCTAssertEqual(s10.sessionNotes, s7.sessionNotes)
            for i10 in s10.items {
                let i7 = try XCTUnwrap(s7.items.first { $0.exerciseId == i10.exerciseId })
                XCTAssertEqual(i10.targetSets, i7.targetSets)
                XCTAssertEqual(i10.repMin, i7.repMin); XCTAssertEqual(i10.repMax, i7.repMax)
                XCTAssertEqual(i10.targetRIRMin, i7.targetRIRMin); XCTAssertEqual(i10.targetRIRMax, i7.targetRIRMax)
                let want = expectedLoads(i7)
                XCTAssertEqual(i10.suggestedLoad, want.suggested, "W10 load copies W7 (bodyweight stays 0)")
                XCTAssertEqual(i10.plannedLoadsBySet, want.planned)
                XCTAssertEqual(i10.plannedRepsBySet.count, i10.targetSets)
                XCTAssertEqual(i10.plannedRIRsBySet.count, i10.targetSets)
                XCTAssertFalse(i10.planEdited)
                XCTAssertTrue(i10.actualReps.isEmpty)
            }
        }
        for s11 in try week(11, ctx) {
            let s8 = try XCTUnwrap(try week(8, ctx).first { $0.dayLabel == s11.dayLabel })
            XCTAssertEqual(s11.items.count, s8.items.count)
            XCTAssertEqual(s11.sessionNotes, s8.sessionNotes)
            XCTAssertEqual(s11.status, .planned)
            XCTAssertTrue(s11.meso === block)
            XCTAssertNotEqual(s11.id, s8.id)
            for i11 in s11.items {
                let i8 = try XCTUnwrap(s8.items.first { $0.order == i11.order })
                let want = expectedLoads(i8)
                XCTAssertEqual(i11.suggestedLoad, want.suggested, "W11 load copies W8")
                XCTAssertEqual(i11.plannedLoadsBySet, want.planned)
            }
        }
        for s12 in try week(12, ctx) {
            let s9 = try XCTUnwrap(try week(9, ctx).first { $0.dayLabel == s12.dayLabel })
            for i12 in s12.items {
                let i9 = try XCTUnwrap(s9.items.first { $0.order == i12.order })
                let want = expectedLoads(i9)
                XCTAssertEqual(i12.suggestedLoad, want.suggested, "W12 load copies W9")
                XCTAssertEqual(i12.plannedLoadsBySet, want.planned)
            }
        }
        // The bodyweight pull-up exists in weeks 10-12 and stayed at 0 despite a nonzero source load.
        for w in 10...12 {
            let bw = try week(w, ctx).flatMap(\.items).filter { $0.exerciseId == "pull_up" }
            XCTAssertEqual(bw.count, 1, "week \(w) has the pull-up")
            XCTAssertEqual(bw.first?.suggestedLoad, 0)
        }
    }

    func test_dryRun_report_showsLoadsBeforeAndAfter() throws {
        let (ctx, block) = try seededBlock()
        try seedLoads(ctx)
        let report = DUPMesoLengthConversion.dryRun(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.blockers.isEmpty, "\(report.blockers)")
        // Every non-bodyweight row shows the stale deload load (50.0) turning into the week-7 load.
        let rows = report.itemTable
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.contains { $0.contains("load 50.0") && $0.contains("->") && !$0.hasSuffix("load 0") }, "\(rows.prefix(3))")
        // The bodyweight pull-up row ends at load 0.
        let bwItem = try XCTUnwrap(try week(10, ctx).flatMap(\.items).first { $0.exerciseId == "pull_up" })
        let bwName = bwItem.exerciseNameSnapshot ?? bwItem.exerciseId
        let bwRows = rows.filter { $0.contains("| \(bwName) :") && $0.contains(String(format: "%.1f", 50.0)) && $0.contains("->") }
        XCTAssertFalse(bwRows.isEmpty, "expected a row for \(bwName)")
        XCTAssertEqual(bwRows.filter { $0.hasSuffix("load 0") }.count, bwRows.count, "bodyweight row ends at load 0")
        XCTAssertTrue(report.lines.contains { $0.contains("bodyweight stays 0") })
    }

    func test_apply_chainsRunOneFourSevenTen_twoFiveEightEleven_threeSixNineTwelve() throws {
        let (ctx, block) = try seededBlock()
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())

        let result = DUPMesoLengthConversion.verifyChains(block: block, context: ctx)
        XCTAssertGreaterThan(result.checked, 0)
        XCTAssertEqual(result.broken, [])

        // Spot-check one lift explicitly: Push-day W7 (A) -> W10 (A); W10 has no target.
        let all = try sessions(ctx)
        let s7 = try XCTUnwrap(try week(7, ctx).first)
        let item7 = try XCTUnwrap(s7.items.first)
        let t = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: item7, after: s7, in: all))
        let s10 = try XCTUnwrap(try week(10, ctx).first { $0.items.contains { $0 === t } })
        XCTAssertEqual(s10.dayLabel, s7.dayLabel)
        XCTAssertEqual(t.waveRaw, "a")
        let s10Item = try XCTUnwrap(s10.items.first)
        XCTAssertNil(PlanMemoryEngine.nextTargetItem(for: s10Item, after: s10, in: all))
    }

    func test_verifyChains_beforeConversion_showsWeek7To9Broken() throws {
        let (ctx, block) = try seededBlock()
        // On the 10-week block week 7 (A) has no later A: this is why the conversion has a deadline.
        let result = DUPMesoLengthConversion.verifyChains(block: block, context: ctx)
        XCTAssertFalse(result.broken.isEmpty)
        XCTAssertTrue(result.broken.contains { $0.hasPrefix("W7 ") }, "W7 has no week-10 A target before conversion")
    }

    func test_apply_isIdempotent() throws {
        let (ctx, block) = try seededBlock()
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        let second = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(second.alreadyConverted)
        XCTAssertFalse(second.didWrite)
        XCTAssertEqual(try sessions(ctx).count, 72)
    }

    // MARK: Blockers (nothing is written)

    private func assertRefusedAndUntouched(_ ctx: ModelContext, _ block: MesoBlock, contains text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let countBefore = try sessions(ctx).count
        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertFalse(report.isSafe, file: file, line: line)
        XCTAssertTrue(report.blockers.contains { $0.contains(text) }, "\(report.blockers)", file: file, line: line)
        XCTAssertFalse(report.didWrite, file: file, line: line)
        XCTAssertEqual(block.totalWeeks, 10, file: file, line: line)
        XCTAssertEqual(try sessions(ctx).count, countBefore, file: file, line: line)
        XCTAssertEqual(Set(try week(10, ctx).flatMap { $0.items.compactMap(\.waveRaw) }), ["deload"], file: file, line: line)
    }

    func test_blocker_loggedWeek10Session() throws {
        let (ctx, block) = try seededBlock()
        let item = try XCTUnwrap(try week(10, ctx).first?.items.first)
        item.actualReps = [8]; item.actualLoads = [50]
        try assertRefusedAndUntouched(ctx, block, contains: "logged data")
    }

    func test_blocker_week10RosterDiffersFromWeek7() throws {
        let (ctx, block) = try seededBlock()
        let s10 = try XCTUnwrap(try week(10, ctx).first)
        ctx.delete(try XCTUnwrap(s10.items.first))
        try ctx.save()
        try assertRefusedAndUntouched(ctx, block, contains: "no week-10 counterpart")
    }

    func test_blocker_dateCollisionWithExistingSession() throws {
        let (ctx, block) = try seededBlock()
        let stray = Session(date: date(2026, 12, 4), status: .planned, weekIndex: 1, items: [])
        ctx.insert(stray)
        try ctx.save()
        try assertRefusedAndUntouched(ctx, block, contains: "collides")
    }

    func test_blocker_wrongTotalWeeks() throws {
        let (ctx, block) = try seededBlock()
        block.totalWeeks = 8
        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.blockers.contains { $0.contains("totalWeeks") })
        XCTAssertFalse(report.didWrite)
        XCTAssertEqual(try sessions(ctx).count, 60)
    }

    func test_blocker_maintenanceBlock() throws {
        let (ctx, block) = try seededBlock()
        block.isMaintenance = true
        let report = DUPMesoLengthConversion.dryRun(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.blockers.contains { $0.contains("maintenance") })
    }

    // MARK: On-device one-shot (TwelveWeekMesoConversionMigration)

    private func clearMigrationFlags() {
        for k in [TwelveWeekMesoConversionMigration.completionKey,
                  TwelveWeekMesoConversionMigration.dryRunLoggedKey,
                  TwelveWeekMesoConversionMigration.reportKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    func test_migration_shipsAsDryRun() {
        XCTAssertTrue(TwelveWeekMesoConversionMigration.dryRun, "applying is a separate, deliberate commit that flips this")
    }

    func test_migration_dryRun_logsOnce_writesNothing_setsOnlyTheLoggedFlag() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, _) = try seededBlock()
        try ctx.save()
        let before = try fingerprint(ctx)

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: true)

        let d = UserDefaults.standard
        XCTAssertTrue(d.bool(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey))
        XCTAssertFalse(d.bool(forKey: TwelveWeekMesoConversionMigration.completionKey), "completion is only ever set after a successful apply")
        let report = try XCTUnwrap(d.string(forKey: TwelveWeekMesoConversionMigration.reportKey))
        XCTAssertTrue(report.contains("== GATES ==") && report.contains("== PROJECTED CHAINS =="))
        XCTAssertEqual(try fingerprint(ctx), before, "dry run must not change any stored field")
        XCTAssertFalse(ctx.hasChanges)

        // Second launch: already logged -> no new report.
        d.set("SENTINEL", forKey: TwelveWeekMesoConversionMigration.reportKey)
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: true)
        XCTAssertEqual(d.string(forKey: TwelveWeekMesoConversionMigration.reportKey), "SENTINEL")
    }

    func test_migration_noEligibleBlock_leavesEveryFlagUnset() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ModelContext(c), dryRun: true)
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ModelContext(c), dryRun: false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
    }

    func test_migration_applyMode_convertsThenSetsCompletionAfterSave_andIsIdempotent() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
        XCTAssertEqual(block.totalWeeks, 12)
        XCTAssertEqual(try sessions(ctx).count, 72)
        XCTAssertEqual(DUPMesoLengthConversion.verifyChains(block: block, context: ctx).broken, [])

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)
        XCTAssertEqual(try sessions(ctx).count, 72, "completed flag makes a second launch a no-op")
    }

    func test_migration_applyMode_unsafeBlock_isRefusedAndFlagStaysUnset() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        let item = try XCTUnwrap(try week(10, ctx).first?.items.first)
        item.actualReps = [8]; item.actualLoads = [50]
        try ctx.save()
        let before = try fingerprint(ctx)

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey), "unset so it retries")
        XCTAssertEqual(block.totalWeeks, 10)
        XCTAssertEqual(try fingerprint(ctx), before)
    }

    // MARK: Same-named archived block (the live store has an April "10-Week DUP Meso")

    private func addArchivedSameNameBlock(_ ctx: ModelContext, totalWeeks: Int?, status: MesoStatus) throws -> (MesoBlock, [Session]) {
        let old = MesoBlock(name: "10-Week DUP Meso", startDate: date(2026, 4, 16), status: status, totalWeeks: totalWeeks)
        ctx.insert(old)
        var made: [Session] = []
        for (w, wave) in [(7, "a"), (8, "b"), (9, "c"), (10, "deload")] {
            let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100, waveRaw: wave)
            let s = Session(date: date(2026, 5, 1 + w), status: .completed, weekIndex: w, dayLabel: "Chest + Triceps", items: [item])
            s.meso = old
            ctx.insert(s)
            made.append(s)
        }
        try ctx.save()
        return (old, made)
    }

    func test_sameNamedArchivedBlock_isNeverTouched_evenWithTotalWeeks10() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, active) = try seededBlock()
        let (old, oldSessions) = try addArchivedSameNameBlock(ctx, totalWeeks: 10, status: .archived)
        let oldBefore = oldSessions.map { "\($0.weekIndex)|\($0.date.timeIntervalSince1970)|\($0.items.map { "\($0.waveRaw ?? "")|\($0.suggestedLoad)" })" }

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)

        XCTAssertEqual(active.totalWeeks, 12)
        XCTAssertEqual(active.name, "12-Week DUP Meso")
        XCTAssertEqual(old.name, "10-Week DUP Meso", "the archived block keeps its name")
        XCTAssertEqual(old.totalWeeks, 10)
        XCTAssertEqual(old.sessions.count, 4)
        XCTAssertEqual(oldSessions.map { "\($0.weekIndex)|\($0.date.timeIntervalSince1970)|\($0.items.map { "\($0.waveRaw ?? "")|\($0.suggestedLoad)" })" }, oldBefore)
        XCTAssertEqual(try sessions(ctx).filter { $0.meso === active }.count, 72)
    }

    func test_twoActiveTenWeekBlocks_isAmbiguous_andNothingIsDone() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, active) = try seededBlock()
        _ = try addArchivedSameNameBlock(ctx, totalWeeks: 10, status: .active)   // pathological: two active blocks
        let before = try fingerprint(ctx)

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)

        XCTAssertEqual(active.totalWeeks, 10)
        XCTAssertEqual(try fingerprint(ctx), before)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
    }
}
