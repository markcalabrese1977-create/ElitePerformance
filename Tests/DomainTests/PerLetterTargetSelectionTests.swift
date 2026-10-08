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
        // The swap runs in weeks 1-10 so the per-letter chains stay consistent (apply verifies them).
        for w in 1...6 {
            for s in try week(w, ctx) where s.dayLabel == bwDay {
                if let first = s.items.min(by: { $0.order < $1.order }) { first.exerciseId = "pull_up" }
            }
        }
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

    /// LOCAL ONLY. The 2026-10-07 backup carries a planned, hand-swapped [Hotel] Pull B session in week 2 that has
    /// no week-5 counterpart. The conversion verifies only the links it creates (7/8/9 -> 10/11/12), so it must
    /// convert this store as it is and name the legacy dead ends as [INFO], never as failures.
    func test_fixture_convertsWithTheSwappedOct7PullBSession_andListsDeadEndsAsInfo() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        print("CONVERSION FIXTURE|\(URL(fileURLWithPath: path).lastPathComponent)")
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: c)
        let ctx = ModelContext(c)
        ctx.autosaveEnabled = false
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first { $0.status == .active && !$0.isMaintenance })

        let sessions = try self.sessions(ctx).filter { $0.meso?.persistentModelID == block.persistentModelID }
        let swapped = try XCTUnwrap(sessions.first { $0.weekIndex == 2 && $0.dayLabel == "Pull B" })
        XCTAssertEqual(swapped.status, .planned)
        let w5 = try XCTUnwrap(sessions.first { $0.weekIndex == 5 && $0.dayLabel == "Pull B" })
        let w5Ids = Set(w5.items.map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        XCTAssertTrue(swapped.items.contains { !w5Ids.contains(ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId)) },
                      "precondition: the Oct 7 session carries lifts with no week-5 counterpart")

        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx)
        print("CONVERSION FIXTURE VERIFICATION|\n" + report.verification.joined(separator: "\n"))

        XCTAssertTrue(report.didWrite)
        XCTAssertEqual(block.totalWeeks, 12)
        assertVerificationLinesAreKnown(report.verification)
        XCTAssertTrue(report.verification.contains { $0.hasPrefix("[PASS] created links") })
        let info = try XCTUnwrap(report.verification.first { $0.hasPrefix("[INFO]") && $0.contains("legacy dead ends") }, "\(report.verification)")
        XCTAssertTrue(info.contains("W2 Pull B"), info)
        XCTAssertEqual(report.postWriteChainTable.count, 18)
    }

    /// A break in a link the conversion creates (week 8 -> 11: a week-11 lift whose canonical id differs) fails
    /// verification and restores the store.
    func test_apply_forcedBreakInA8To11Link_failsAndRestoresTheStore() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        try ctx.save()
        let before = try fingerprint(ctx)
        let hooks = DUPMesoLengthConversion.ApplyHooks(beforeVerify: { c in
            let w11 = ((try? c.fetch(FetchDescriptor<Session>())) ?? []).first { $0.weekIndex == 11 }!
            w11.items.sorted { $0.order < $1.order }[0].exerciseId = "tricep_kickback"
        })
        XCTAssertThrowsError(try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal(), hooks: hooks)) { err in
            guard case DUPMesoLengthConversion.ApplyError.verificationFailed(let f) = err else { return XCTFail("\(err)") }
            XCTAssertTrue(f.contains { $0.hasPrefix("created links") && $0.contains("W8") }, "\(f)")
        }
        try assertAppliedNothing(ctx, block, before: before)
    }

    /// Weeks 1-6 are not verified: a legacy dead end there is listed as [INFO] and the conversion still applies.
    func test_apply_legacyDeadEndInWeek2_isInfoNotFailure() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        let w2 = try XCTUnwrap(try week(2, ctx).first)
        w2.items.sorted { $0.order < $1.order }[0].exerciseId = "tricep_kickback"      // no week-5 counterpart
        try ctx.save()
        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.didWrite)
        assertVerificationLinesAreKnown(report.verification)
        XCTAssertTrue(report.verification.contains { $0.hasPrefix("[INFO] 1 week 1-6 item(s)") && $0.contains("W2") }, "\(report.verification)")
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
                  TwelveWeekMesoConversionMigration.reportKey,
                  TwelveWeekMesoConversionMigration.shapeWarnedKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    func test_migration_dryRunLoggedFlag_isKeyedByReportVersion_soAChangedReportLogsAgain() {
        XCTAssertEqual(TwelveWeekMesoConversionMigration.dryRunLoggedKey, "twelveWeekMesoConversion.v1.dryRunLogged.\(TwelveWeekMesoConversionMigration.reportVersion)")
        XCTAssertEqual(TwelveWeekMesoConversionMigration.reportVersion, "v2")
        // A flag left by an earlier report version does not suppress the current one.
        let legacy = "twelveWeekMesoConversion.v1.dryRunLogged"
        UserDefaults.standard.set(true, forKey: legacy); defer { UserDefaults.standard.removeObject(forKey: legacy); clearMigrationFlags() }
        clearMigrationFlags()
        UserDefaults.standard.set(true, forKey: legacy)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey))
    }

    func test_migration_reRunsDryRunWhenTheVersionedFlagIsMissing() throws {
        clearMigrationFlags(); defer { clearMigrationFlags(); UserDefaults.standard.removeObject(forKey: "twelveWeekMesoConversion.v1.dryRunLogged") }
        UserDefaults.standard.set(true, forKey: "twelveWeekMesoConversion.v1.dryRunLogged")   // old-version flag
        let (ctx, _) = try seededBlock()
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey), "logged again under the new version key")
        XCTAssertNotNil(UserDefaults.standard.string(forKey: TwelveWeekMesoConversionMigration.reportKey))
    }

    func test_migration_shipsArmed_applyMode() {
        XCTAssertFalse(TwelveWeekMesoConversionMigration.dryRun, "armed: the launch driver applies the conversion when every gate passes")
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

    // MARK: Apply verifies its own result and rolls back on failure

    private struct InjectedSaveFailure: Error {}

    private func assertAppliedNothing(_ ctx: ModelContext, _ block: MesoBlock, before: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey), "flag must stay unset", file: file, line: line)
        XCTAssertEqual(try fingerprint(ctx), before, "store must be exactly as before", file: file, line: line)
        XCTAssertEqual(block.totalWeeks, 10, file: file, line: line)
        XCTAssertEqual(block.name, "10-Week DUP Meso", file: file, line: line)
        XCTAssertEqual(try sessions(ctx).count, 60, file: file, line: line)
        XCTAssertFalse(ctx.hasChanges, "rollback leaves nothing pending", file: file, line: line)
    }

    func test_apply_forcedChainBreak_rollsBack_storeUnchanged_flagUnset() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        try ctx.save()
        let before = try fingerprint(ctx)
        let priorAutosave = ctx.autosaveEnabled

        // Remove one week-10 lift: the week-7 item's 7 -> 10 target (a link the conversion creates) disappears.
        let hooks = DUPMesoLengthConversion.ApplyHooks(beforeVerify: { c in
            let w10 = ((try? c.fetch(FetchDescriptor<Session>())) ?? []).first { $0.weekIndex == 10 }!
            let victim = w10.items.sorted { $0.order < $1.order }[0]
            w10.items.removeAll { $0 === victim }
            c.delete(victim)
        })
        XCTAssertThrowsError(try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal(), hooks: hooks)) { err in
            guard case DUPMesoLengthConversion.ApplyError.verificationFailed(let f) = err else { return XCTFail("\(err)") }
            XCTAssertTrue(f.contains { $0.hasPrefix("created links") }, "\(f)")
        }
        try assertAppliedNothing(ctx, block, before: before)
        XCTAssertEqual(ctx.autosaveEnabled, priorAutosave, "autosave restored")

        // Same break through the launch driver: nothing written, flag unset.
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false, hooks: hooks)
        try assertAppliedNothing(ctx, block, before: before)

        // And with no hook the very same store converts fine afterwards (retry works).
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
        XCTAssertEqual(block.totalWeeks, 12)
    }

    func test_apply_forcedSaveFailure_rollsBack_storeUnchanged_flagUnset() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        try ctx.save()
        let before = try fingerprint(ctx)
        let hooks = DUPMesoLengthConversion.ApplyHooks(save: { _ in throw InjectedSaveFailure() })

        XCTAssertThrowsError(try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal(), hooks: hooks)) { err in
            guard case DUPMesoLengthConversion.ApplyError.saveFailed = err else { return XCTFail("\(err)") }
        }
        try assertAppliedNothing(ctx, block, before: before)

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false, hooks: hooks)
        try assertAppliedNothing(ctx, block, before: before)

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey), "retry after a failed save succeeds")
    }

    func test_apply_forcedThursdaySession_failsVerification_andRollsBack() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        try ctx.save()
        let before = try fingerprint(ctx)
        let hooks = DUPMesoLengthConversion.ApplyHooks(beforeVerify: { c in
            let w11 = ((try? c.fetch(FetchDescriptor<Session>())) ?? []).first { $0.weekIndex == 11 }!
            var d = w11.date
            while Calendar(identifier: .gregorian).component(.weekday, from: d) != 5 { d = d.addingTimeInterval(86_400) }
            w11.date = d
        })
        XCTAssertThrowsError(try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal(), hooks: hooks))
        try assertAppliedNothing(ctx, block, before: before)
    }

    func test_apply_refusesToStartWithUnsavedChanges_andDoesNotDiscardThem() throws {
        let (ctx, block) = try seededBlock()
        try ctx.save()
        block.notes = "unsaved edit"
        XCTAssertThrowsError(try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())) { err in
            guard case DUPMesoLengthConversion.ApplyError.pendingChanges = err else { return XCTFail("\(err)") }
        }
        XCTAssertEqual(block.notes, "unsaved edit")
        XCTAssertEqual(block.totalWeeks, 10)
    }

    /// Every verification line is either [PASS] or one of the two known [INFO] kinds; anything else (a [FAIL], an
    /// unknown [INFO], stray text) fails the test.
    private func assertVerificationLinesAreKnown(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        let infoPatterns = [
            #"^\[INFO\] \d+ week 1-6 item\(s\) have no same-lift target 3 weeks later \(legacy dead ends, not verified, not failures\): "#,
            #"^\[INFO\] \d+ hand-added item\(s\) with no wave letter are outside the A/B/C chains "#
        ]
        for l in lines {
            if l.hasPrefix("[PASS]") { continue }
            let known = l.hasPrefix("[INFO]") && infoPatterns.contains { l.range(of: $0, options: .regularExpression) != nil }
            XCTAssertTrue(known, "unexpected verification line: \(l)", file: file, line: line)
        }
    }

    func test_logHeaders_sayApplyWhenTheLaunchMayWrite_andDryRunOnlyWhenReadOnly() {
        XCTAssertEqual(TwelveWeekMesoConversionMigration.logHeader(dryRun: false, blockName: "B"), "🧪 12-week conversion APPLY for 'B':")
        XCTAssertEqual(TwelveWeekMesoConversionMigration.logHeader(dryRun: true, blockName: "B"), "🧪 12-week conversion DRY RUN for 'B':")
        XCTAssertEqual(SameLetterTargetCatchUpMigration.logHeader(dryRun: false), "🧪 Same-letter catch-up APPLY:")
        XCTAssertEqual(SameLetterTargetCatchUpMigration.logHeader(dryRun: true), "🧪 Same-letter catch-up DRY RUN:")
        XCTAssertEqual(V52AlignmentRepair.logHeader(dryRun: false, blockName: "B"), "🧪 V52 alignment APPLY for 'B':")
        XCTAssertEqual(V52AlignmentRepair.logHeader(dryRun: true, blockName: "B"), "🧪 V52 alignment DRY RUN for 'B':")
        // The shipped switches decide which word a real launch prints.
        XCTAssertFalse(TwelveWeekMesoConversionMigration.dryRun)
        XCTAssertFalse(SameLetterTargetCatchUpMigration.dryRun)
        XCTAssertTrue(V52AlignmentRepair.dryRun)
    }

    func test_apply_success_reportsAllVerificationPassing_and18Chains() throws {
        let (ctx, block) = try seededBlock()
        try ctx.save()
        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.didWrite)
        XCTAssertFalse(report.verification.isEmpty)
        assertVerificationLinesAreKnown(report.verification)
        XCTAssertFalse(report.verification.contains { $0.hasPrefix("[INFO]") }, "a clean block has no INFO lines: \(report.verification)")
        XCTAssertTrue(report.verification.contains { $0.hasPrefix("[PASS] created links") }, "\(report.verification)")
        XCTAssertFalse(report.verification.contains { $0.contains("verifyChains") || $0.contains("18 chains") }, "the weeks 1-6 links and the 18-chains count are no longer asserted")
        XCTAssertEqual(report.postWriteChainTable.count, 18)
        XCTAssertTrue(report.postWriteChainTable.allSatisfy { $0.contains("W7→W10→nil") || $0.contains("W8→W11→nil") || $0.contains("W9→W12→nil") })
        XCTAssertTrue(report.postWriteChainTable.allSatisfy { line in
            let parts = line.components(separatedBy: "items linked ").last!.split(separator: "/")
            return parts.count == 2 && parts[0] == parts[1]
        }, "\(report.postWriteChainTable)")
    }

    func test_apply_handAddedUnwavedItem_isOutsideTheChains_andIsReportedNotGated() throws {
        let (ctx, block) = try seededBlock()
        let w1 = try XCTUnwrap(try week(1, ctx).first)
        let extra = SessionItem(order: 99, exerciseId: "dumbbell_lateral_raise", targetReps: 12, targetSets: 3, targetRIR: 2, suggestedLoad: 20)
        extra.planEdited = true
        ctx.insert(extra); w1.items.append(extra)
        try ctx.save()

        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertTrue(report.didWrite)
        XCTAssertTrue(report.verification.contains { $0.hasPrefix("[INFO] 1 hand-added item(s)") && $0.contains("dumbbell_lateral_raise") }, "\(report.verification)")
        assertVerificationLinesAreKnown(report.verification)
        XCTAssertEqual(report.postWriteChainTable.count, 18)
    }

    // MARK: Already-converted blocks and the killed-before-save case

    func test_migration_alreadyConvertedBlock_setsBothFlags_andWritesNothing() throws {
        for dry in [false, true] {
            clearMigrationFlags(); defer { clearMigrationFlags() }
            let (ctx, block) = try seededBlock()
            try ctx.save()
            try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
            clearMigrationFlags()                      // converted, but the flags were lost
            let before = try fingerprint(ctx)
            XCTAssertFalse(ctx.hasChanges)

            TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: dry)

            let d = UserDefaults.standard
            XCTAssertTrue(d.bool(forKey: TwelveWeekMesoConversionMigration.completionKey), "dryRun=\(dry)")
            XCTAssertTrue(d.bool(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey), "dryRun=\(dry)")
            XCTAssertFalse(d.bool(forKey: TwelveWeekMesoConversionMigration.shapeWarnedKey))
            XCTAssertEqual(try fingerprint(ctx), before, "writes nothing")
            XCTAssertFalse(ctx.hasChanges)
        }
    }

    func test_migration_partialTwelveWeekBlock_doesNotSetTheFlag_andWarnsOnce() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        try ctx.save()
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        let missing = try XCTUnwrap(try week(12, ctx).last)
        ctx.delete(missing)
        try ctx.save()
        clearMigrationFlags()
        let before = try fingerprint(ctx)

        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)

        let d = UserDefaults.standard
        XCTAssertFalse(d.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
        XCTAssertFalse(d.bool(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey))
        XCTAssertTrue(d.bool(forKey: TwelveWeekMesoConversionMigration.shapeWarnedKey), "one-time warning recorded")
        XCTAssertEqual(try fingerprint(ctx), before)
        XCTAssertTrue(DUPMesoLengthConversion.convertedShapeProblems(block: block, context: ctx).contains { $0.contains("week 12") })

        // Second launch: still unset, no second warning marker change needed.
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)
        XCTAssertFalse(d.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
    }

    func test_migration_twelveWeekBlockWithDeloadItem_doesNotSetTheFlag() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let (ctx, block) = try seededBlock()
        try ctx.save()
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        try XCTUnwrap(try week(5, ctx).first?.items.first).waveRaw = "deload"
        try ctx.save()
        clearMigrationFlags()
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx, dryRun: false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
    }

    /// Opens (or reopens) an on-disk store with the same schema the conversion tests use.
    private func onDiskContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
    }

    func test_apply_killedBeforeSave_leavesTheOnDiskStoreUnchanged_thenNextLaunchConverts() throws {
        clearMigrationFlags(); defer { clearMigrationFlags() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep-killtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("kill.store")

        var before = ""
        do {
            // "Launch 1": seed an on-disk store, then die between the mutations and save().
            let c1 = try onDiskContainer(at: url)
            let ctx1 = ModelContext(c1)
            ctx1.autosaveEnabled = false
            try DUPProgramSeeder.seed(
                startDate: date(2026, 9, 25), trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx1,
                template: DUP10WeekTemplate.template, calendar: cal(), mesoName: "10-Week DUP Meso", mesoStatus: .active)
            try ctx1.save()
            let block1 = try XCTUnwrap(try ctx1.fetch(FetchDescriptor<MesoBlock>()).first)
            before = try fingerprint(ctx1)

            // A save hook that persists nothing: exactly what a process kill before save() leaves behind.
            // The mutations (and the verification) really ran against ctx1; only the commit never happens.
            var mutatedInMemory = false
            let hooks = DUPMesoLengthConversion.ApplyHooks(save: { c in mutatedInMemory = c.hasChanges })
            try DUPMesoLengthConversion.apply(block: block1, context: ctx1, calendar: cal(), hooks: hooks)
            XCTAssertTrue(mutatedInMemory, "the conversion was staged in memory when the 'kill' hit")
            XCTAssertEqual(block1.totalWeeks, 12, "in-memory state only")
            // ctx1 / c1 go out of scope here without ever saving: the process is gone.
        }
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey), "flag unset")

        // "Launch 2": a fresh container on the same file sees exactly the pre-apply store.
        let c2 = try onDiskContainer(at: url)
        let ctx2 = ModelContext(c2)
        XCTAssertEqual(try fingerprint(ctx2), before, "on-disk store identical to before the killed apply")
        let block2 = try XCTUnwrap(try ctx2.fetch(FetchDescriptor<MesoBlock>()).first)
        XCTAssertEqual(block2.totalWeeks, 10)
        XCTAssertEqual(try sessions(ctx2).count, 60)

        // ...and the real migration then converts it.
        TwelveWeekMesoConversionMigration.runIfNeeded(in: ctx2, dryRun: false)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: TwelveWeekMesoConversionMigration.completionKey))
        XCTAssertEqual(block2.totalWeeks, 12)
        XCTAssertEqual(try sessions(ctx2).count, 72)
        // Reopen once more: the conversion really reached disk this time.
        let ctx3 = ModelContext(try onDiskContainer(at: url))
        XCTAssertEqual(try ctx3.fetch(FetchDescriptor<Session>()).count, 72)
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

// MARK: - Last same-letter performance (LastSameLetterPerformance)

/// The pure lookup behind the Today caption "Last A: 315 x 5, 6, 5, 5". Tested directly — never
/// through SessionScreenViewModel (its deinit aborts the test host).
final class LastSameLetterPerformanceTests: XCTestCase {

    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        return ModelContext(c)
    }

    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }

    private func logged(
        _ exerciseId: String = "bench_press", wave: String? = "a", sets: [(Int, Double)], order: Int = 1
    ) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: exerciseId, targetReps: 8, targetSets: max(sets.count, 1),
                            targetRIR: 2, suggestedLoad: sets.first?.1 ?? 0, waveRaw: wave)
        i.actualReps = sets.map(\.0)
        i.actualLoads = sets.map(\.1)
        return i
    }

    private func session(
        _ ctx: ModelContext, meso: MesoBlock, day dayOffset: Int, week: Int, label: String = "Push A",
        status: SessionStatus = .completed, items: [SessionItem]
    ) -> Session {
        let s = Session(date: day(dayOffset), status: status, weekIndex: week, dayLabel: label, items: items)
        s.meso = meso
        ctx.insert(s)
        return s
    }

    private func block(_ ctx: ModelContext, name: String = "DUP", maintenance: Bool = false) -> MesoBlock {
        let b = MesoBlock(name: name, startDate: day(-60), status: .active, totalWeeks: 10)
        b.isMaintenance = maintenance
        ctx.insert(b)
        return b
    }

    private func find(_ item: SessionItem, in s: Session, _ ctx: ModelContext) throws -> LastLetterPerformance? {
        try ctx.save()
        return LastSameLetterPerformance.find(
            for: item, in: s, allSessions: try ctx.fetch(FetchDescriptor<Session>()))
    }

    // MARK: Basics and captions

    func test_returnsTheMostRecentEarlierSameLetterExposure() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -20, week: 1, items: [logged(sets: [(5, 300)])])
        let newer = session(ctx, meso: m, day: -10, week: 4, items: [logged(sets: [(5, 315), (6, 315), (5, 315), (5, 315)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: m, day: 5, week: 7, status: .planned, items: [target])
        let r = try XCTUnwrap(try find(target, in: now, ctx))
        XCTAssertEqual(r.date, newer.date)
        XCTAssertEqual(r.weekIndex, 4)
        XCTAssertEqual(r.caption, "Last A: 315 x 5, 6, 5, 5")
    }

    func test_fourRowTopSetPattern_groupsOnLoadChange() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -10, week: 2, items: [logged(wave: "b", sets: [(8, 290), (7, 290), (6, 290), (5, 315)])])
        let target = logged(wave: "b", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 5, status: .planned, items: [target])
        XCTAssertEqual(try find(target, in: now, ctx)?.caption, "Last B: 290 x 8, 7, 6 · 315 x 5")
    }

    func test_fractionalLoad_keepsItsDecimal() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -10, week: 1, items: [logged("incline_rear_delt_fly", sets: [(12, 37.5), (12, 37.5), (12, 37.5)])])
        let target = logged("incline_rear_delt_fly", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        XCTAssertEqual(try find(target, in: now, ctx)?.caption, "Last A: 37.5 x 12, 12, 12")
    }

    func test_bodyweight_showsRepsOnly() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -10, week: 1, items: [logged("pull_up", sets: [(5, 0), (5, 0), (5, 0), (5, 0)])])
        let target = logged("pull_up", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        let r = try XCTUnwrap(try find(target, in: now, ctx))
        XCTAssertTrue(r.isBodyweight)
        XCTAssertEqual(r.caption, "Last A: 5, 5, 5, 5 reps")
    }

    func test_zeroRepPaddingRowsAreIgnored() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -10, week: 1, items: [logged(sets: [(5, 315), (6, 315), (5, 315), (0, 0)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        XCTAssertEqual(try find(target, in: now, ctx)?.caption, "Last A: 315 x 5, 6, 5")
    }

    // MARK: Scoping

    func test_crossMesoIsolation_anOlderBlockWithTheSameLabelNeverMatches() throws {
        let ctx = try makeContext()
        let old = block(ctx, name: "Old"); let current = block(ctx, name: "Current")
        _ = session(ctx, meso: old, day: -90, week: 3, items: [logged(sets: [(5, 400)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: current, day: 5, week: 4, status: .planned, items: [target])
        XCTAssertNil(try find(target, in: now, ctx), "same dayLabel + wave + lift in ANOTHER block must not match")
    }

    func test_plannedAndInProgressSessionsInBetweenAreSkipped() throws {
        let ctx = try makeContext(); let m = block(ctx)
        let real = session(ctx, meso: m, day: -20, week: 1, items: [logged(sets: [(5, 315)])])
        _ = session(ctx, meso: m, day: -10, week: 4, status: .planned, items: [logged(sets: [(9, 999)])])
        _ = session(ctx, meso: m, day: -5, week: 4, status: .inProgress, items: [logged(sets: [(9, 888)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: m, day: 5, week: 7, status: .planned, items: [target])
        XCTAssertEqual(try find(target, in: now, ctx)?.date, real.date)
    }

    func test_itemsWithNoLoggedSetsAreSkipped() throws {
        let ctx = try makeContext(); let m = block(ctx)
        let real = session(ctx, meso: m, day: -20, week: 1, items: [logged(sets: [(5, 315)])])
        _ = session(ctx, meso: m, day: -10, week: 4, items: [logged(sets: [(0, 0), (0, 0)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: m, day: 5, week: 7, status: .planned, items: [target])
        XCTAssertEqual(try find(target, in: now, ctx)?.date, real.date)
    }

    func test_otherDay_sameLiftAndLetter_neverMatches_andLabelsAreTrimmed() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -20, week: 1, label: "Push A", items: [logged("incline_rear_delt_fly", sets: [(12, 35)])])
        let pullA = session(ctx, meso: m, day: -19, week: 1, label: "Pull A ", items: [logged("incline_rear_delt_fly", sets: [(12, 40)])])
        let target = logged("incline_rear_delt_fly", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, label: "Pull A", status: .planned, items: [target])
        let r = try XCTUnwrap(try find(target, in: now, ctx))
        XCTAssertEqual(r.date, pullA.date, "Pull A, not Push A (and 'Pull A ' == 'Pull A')")
        XCTAssertEqual(r.caption, "Last A: 40 x 12")
    }

    func test_otherLetter_neverMatches() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -20, week: 1, items: [logged(wave: "a", sets: [(5, 315)])])
        let target = logged(wave: "b", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 2, status: .planned, items: [target])
        XCTAssertNil(try find(target, in: now, ctx), "only an A-week exposure exists")
    }

    func test_waveComesFromTheMatchedItem_notTheSessionsFirstItem() throws {
        let ctx = try makeContext(); let m = block(ctx)
        // First item is wave b; the matched bench is wave a.
        let first = logged("dumbbell_lateral_raise", wave: "b", sets: [(12, 35)], order: 1)
        let matched = logged(wave: "a", sets: [(5, 315)], order: 2)
        let src = session(ctx, meso: m, day: -20, week: 1, items: [first, matched])
        let target = logged(wave: "a", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        XCTAssertEqual(try find(target, in: now, ctx)?.date, src.date)
    }

    func test_laterSessionsAreNeverReturned() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: 10, week: 7, items: [logged(sets: [(5, 400)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        XCTAssertNil(try find(target, in: now, ctx))
    }

    // MARK: Nil cases

    func test_noWave_deload_andMaintenance_returnNil() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -20, week: 1, items: [logged(wave: "a", sets: [(5, 315)]), logged(wave: "deload", sets: [(5, 200)], order: 2)])

        let noWave = logged(wave: nil, sets: [])
        let s1 = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [noWave])
        XCTAssertNil(try find(noWave, in: s1, ctx))

        let empty = logged(wave: "", sets: [])
        let s2 = session(ctx, meso: m, day: 6, week: 4, status: .planned, items: [empty])
        XCTAssertNil(try find(empty, in: s2, ctx))

        let deload = logged(wave: "deload", sets: [])
        let s3 = session(ctx, meso: m, day: 7, week: 10, status: .planned, items: [deload])
        XCTAssertNil(try find(deload, in: s3, ctx), "a deload item has no letter")

        let maint = block(ctx, name: "Maintenance Block", maintenance: true)
        _ = session(ctx, meso: maint, day: -15, week: 1, items: [logged(wave: "a", sets: [(5, 315)])])
        let mt = logged(wave: "a", sets: [])
        let s4 = session(ctx, meso: maint, day: 8, week: 2, status: .planned, items: [mt])
        XCTAssertNil(try find(mt, in: s4, ctx), "maintenance blocks never show a letter caption")
    }

    func test_waveNilHistoryItem_isNotAnExposure() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -20, week: 1, items: [logged("dumbbell_lateral_raise", wave: nil, sets: [(12, 35)])])
        let target = logged("dumbbell_lateral_raise", wave: "a", sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        XCTAssertNil(try find(target, in: now, ctx))
    }

    // MARK: Purity

    func test_neverMutatesItsInput() throws {
        let ctx = try makeContext(); let m = block(ctx)
        let src = session(ctx, meso: m, day: -10, week: 1, items: [logged(sets: [(5, 315), (6, 315)])])
        let target = logged(sets: [])
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [target])
        try ctx.save()
        func snap() -> String {
            [src, now].flatMap { s in [s.status.rawValue, "\(s.date)", "\(s.weekIndex)"] + s.items.flatMap {
                ["\($0.suggestedLoad)", "\($0.plannedLoadsBySet)", "\($0.actualReps)", "\($0.actualLoads)", "\($0.planEdited)", $0.coachNote ?? ""]
            } }.joined(separator: "|")
        }
        let before = snap()
        let all = try ctx.fetch(FetchDescriptor<Session>())
        _ = LastSameLetterPerformance.find(for: target, in: now, allSessions: all)
        _ = LastSameLetterPerformance.captions(for: now, allSessions: all)
        XCTAssertEqual(snap(), before)
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_captions_isKeyedByExerciseId() throws {
        let ctx = try makeContext(); let m = block(ctx)
        _ = session(ctx, meso: m, day: -10, week: 1, items: [logged(sets: [(5, 315)]), logged("hammer_curl", sets: [(6, 102), (7, 102)], order: 2)])
        let a = logged(sets: []), b = logged("hammer_curl", sets: [], order: 2), c = logged("leg_extension", sets: [], order: 3)
        let now = session(ctx, meso: m, day: 5, week: 4, status: .planned, items: [a, b, c])
        try ctx.save()
        let caps = LastSameLetterPerformance.captions(for: now, allSessions: try ctx.fetch(FetchDescriptor<Session>()))
        XCTAssertEqual(caps["bench_press"], "Last A: 315 x 5")
        XCTAssertEqual(caps["hammer_curl"], "Last A: 102 x 6, 7")
        XCTAssertNil(caps["leg_extension"], "no prior exposure -> no caption")
    }

    // MARK: 12-week conversion: week 7 reaches week 10

    private func gregorian() -> Calendar { Calendar(identifier: .gregorian) }

    func test_afterTheConversion_weekTenResolvesToACompletedWeekSeven_seeded() throws {
        let ctx = try makeContext()
        let cal = gregorian()
        try DUPProgramSeeder.seed(
            startDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!,
            trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx, template: DUP10WeekTemplate.template,
            calendar: cal, mesoName: "10-Week DUP Meso", mesoStatus: .active)
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        try assertWeekTenResolves(ctx: ctx, block: block, calendar: cal)
    }

    /// Applies the conversion in memory, completes a week-7 session synthetically, and checks that
    /// the converted week 10 (now a real A week, not a deload) resolves to it.
    private func assertWeekTenResolves(ctx: ModelContext, block: MesoBlock, calendar: Calendar) throws {
        let all0 = try ctx.fetch(FetchDescriptor<Session>())
        let w10Before = try XCTUnwrap(all0.first { $0.weekIndex == 10 && $0.meso?.persistentModelID == block.persistentModelID })
        XCTAssertEqual(w10Before.items.first?.waveRaw, "deload", "before the conversion week 10 is a deload")

        let report = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: calendar)
        XCTAssertTrue(report.didWrite, "conversion must apply: \(report.blockers)")

        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        let blockSessions = all.filter { $0.meso?.persistentModelID == block.persistentModelID }
        let w7 = try XCTUnwrap(blockSessions.first { $0.weekIndex == 7 })
        let w7Item = try XCTUnwrap(w7.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) != "pull_up" })
        let w10 = try XCTUnwrap(blockSessions.first { $0.weekIndex == 10 && $0.dayLabel == w7.dayLabel })
        let w10Item = try XCTUnwrap(w10.items.first {
            ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: w7Item.exerciseId)
        })
        XCTAssertEqual(w7Item.waveRaw, w10Item.waveRaw, "week 10 now carries week 7's letter")

        // Week 7 completes (synthetically): week 10 now resolves to it, the nearest earlier A.
        w7.status = .completed
        w7Item.actualReps = [8, 8, 7]
        w7Item.actualLoads = [200, 200, 200]
        try ctx.save()
        let r = try XCTUnwrap(LastSameLetterPerformance.find(for: w10Item, in: w10, allSessions: all))
        XCTAssertEqual(r.weekIndex, 7)
        XCTAssertEqual(r.date, w7.date)
        XCTAssertEqual(r.caption, "Last \(w7Item.waveRaw!.uppercased()): 200 x 8, 8, 7")
    }

    // MARK: Fixture (EP_BACKUP_FIXTURE; the newest ElitePerformance_Backup_*.json in ~/Downloads)

    private func fixtureURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        print("LASTLETTER| fixture: \(URL(fileURLWithPath: path).lastPathComponent)")
        return URL(fileURLWithPath: path)
    }

    private func importFixture() throws -> (ModelContext, MesoBlock, [Session]) {
        let url = try fixtureURL()
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: c)
        let ctx = ModelContext(c)
        ctx.autosaveEnabled = false
        let active = try ctx.fetch(FetchDescriptor<MesoBlock>()).filter { $0.status == .active && !$0.isMaintenance }
        let block = try XCTUnwrap(active.first)
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        return (ctx, block, all)
    }

    private func sameDay(_ d: Date, _ m: Int, _ dd: Int) -> Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return c.year == 2026 && c.month == m && c.day == dd
    }

    private func fixtureItem(_ all: [Session], block: MesoBlock, month: Int, day: Int, label: String, name: String)
        throws -> (Session, SessionItem) {
        let s = try XCTUnwrap(all.first {
            $0.meso?.persistentModelID == block.persistentModelID && sameDay($0.date, month, day) && $0.dayLabel == label
        }, "no \(label) session on \(month)/\(day)")
        let i = try XCTUnwrap(s.items.first { ($0.exerciseNameSnapshot ?? "").lowercased() == name.lowercased() },
                              "\(name) missing from \(label) \(month)/\(day)")
        return (s, i)
    }

    func test_fixture_expectedCaptions_andSourceSessions() throws {
        let (ctx, block, all) = try importFixture()
        struct Case { let m: Int; let d: Int; let label: String; let lift: String
                      let srcM: Int; let srcD: Int; let caption: String }
        let cases = [
            Case(m: 10, d: 16, label: "Push A", lift: "Bench Press", srcM: 9, srcD: 25, caption: "Last A: 315 x 5, 6, 5, 5"),
            Case(m: 10, d: 18, label: "Pull A", lift: "T-Bar Row", srcM: 9, srcD: 27, caption: "Last A: 340 x 5, 5, 5, 5"),
            Case(m: 10, d: 18, label: "Pull A", lift: "Hammer Curl", srcM: 9, srcD: 27, caption: "Last A: 102 x 6, 7, 7"),
            Case(m: 10, d: 21, label: "Pull B", lift: "Hammer Curl", srcM: 9, srcD: 30, caption: "Last A: 102 x 8, 7, 7"),
            Case(m: 10, d: 18, label: "Pull A", lift: "Pull-Up", srcM: 9, srcD: 27, caption: "Last A: 5, 5, 5, 5 reps"),
            Case(m: 10, d: 23, label: "Push A", lift: "Bench Press", srcM: 10, srcD: 2, caption: "Last B: 290 x 8, 7, 6 · 315 x 5"),
            Case(m: 10, d: 24, label: "Legs A", lift: "Hack Squat", srcM: 10, srcD: 3, caption: "Last B: 300 x 12, 12, 10"),
            // The same lift on two days: Pull A's Sept 27 (37.5 x 12,12,12), never Push A's Sept 25.
            Case(m: 10, d: 18, label: "Pull A", lift: "Incline Rear Delt Fly", srcM: 9, srcD: 27, caption: "Last A: 37.5 x 12, 12, 12"),
        ]
        for c in cases {
            let (s, i) = try fixtureItem(all, block: block, month: c.m, day: c.d, label: c.label, name: c.lift)
            let r = try XCTUnwrap(LastSameLetterPerformance.find(for: i, in: s, allSessions: all),
                                  "\(c.label) \(c.m)/\(c.d) \(c.lift): nil")
            print("LASTLETTER| \(c.label) \(c.m)/\(c.d) \(c.lift) -> \(r.caption)  [source \(r.date), wk\(r.weekIndex)]")
            XCTAssertEqual(r.caption, c.caption, "\(c.label) \(c.m)/\(c.d) \(c.lift)")
            XCTAssertTrue(sameDay(r.date, c.srcM, c.srcD), "\(c.lift): source \(r.date), expected \(c.srcM)/\(c.srcD)")
        }
        _ = ctx
    }

    func test_fixture_nilCases() throws {
        let (_, block, all) = try importFixture()
        // Mon Oct 5 Push B decline (wave B): only an A-week exposure exists.
        let (s, i) = try fixtureItem(all, block: block, month: 10, day: 5, label: "Push B", name: "Decline Bench Press")
        XCTAssertEqual(i.waveRaw, "b")
        XCTAssertNil(LastSameLetterPerformance.find(for: i, in: s, allSessions: all))

        // Every week-1 session (no earlier exposure) and the hand-added wave-less lifts.
        let weekOne = all.filter { $0.meso?.persistentModelID == block.persistentModelID && $0.weekIndex == 1 }
        XCTAssertFalse(weekOne.isEmpty)
        for w in weekOne {
            for it in w.items {
                XCTAssertNil(LastSameLetterPerformance.find(for: it, in: w, allSessions: all),
                             "week 1 \(w.dayLabel ?? "?") \(it.exerciseNameSnapshot ?? it.exerciseId)")
            }
        }
        let handAdded = weekOne.flatMap { $0.items }.filter { ($0.waveRaw ?? "").isEmpty }
        XCTAssertGreaterThanOrEqual(handAdded.count, 2, "the two hand-added week-1 lifts have no wave letter")
    }

    func test_fixture_afterTheConversion_weekTenResolvesToACompletedWeekSeven() throws {
        let (ctx, block, _) = try importFixture()
        try assertWeekTenResolves(ctx: ctx, block: block, calendar: Calendar.current)
    }
}
